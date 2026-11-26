//! `agy acp` answering the requests a session sends `codex app-server`, as `AgyConnection` in `Agy.swift` does.
//! `AgyStream` reads its lines; this owns the process, the JSON-RPC calls and the running prompt.

use crate::agy_stream::AgyStream;
use crate::process::{Launch, Line, Lines};
use crate::rpc::{AgentError, Incoming};
use crate::shape::{Effect, obj, object, text};
use crate::{Object, codex};
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// A first answer can take a while on a big context; a stuck request still ends.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
const INITIALIZE_TIMEOUT: Duration = Duration::from_secs(30);
const OPEN_TIMEOUT: Duration = Duration::from_secs(60);
const BUSY: &str = "Stop Antigravity before sending another message. Your draft has been kept.";

pub struct AgyOptions {
    /// A fixed command (a fixture agent) replaces `agy acp`.
    pub command: Option<Vec<String>>,
    pub cwd: String,
    pub environment: Option<Vec<(String, String)>>,
    pub log: Option<PathBuf>,
}

pub struct AgyConnection {
    stream: RefCell<AgyStream>,
    process: Lines,
    next: Cell<i64>,
    pending: RefCell<HashMap<String, oneshot::Sender<Result<Object, String>>>>,
    events: mpsc::UnboundedSender<Incoming>,
    closed: Cell<bool>,
}

fn failure(message: impl Into<String>) -> AgentError {
    AgentError { message: message.into(), code: None }
}

impl AgyConnection {
    pub async fn start(options: AgyOptions) -> Result<(Rc<Self>, mpsc::UnboundedReceiver<Incoming>), AgentError> {
        let command = options.command.clone().unwrap_or_else(|| vec!["/usr/bin/env".into(), "agy".into(), "acp".into()]);
        let launch = Launch { command: &command, cwd: Path::new(&options.cwd), environment: options.environment.as_deref(), log: options.log.as_deref() };
        let (process, lines) = Lines::spawn(launch).map_err(|_| failure("Antigravity is not installed: brew install --cask antigravity-cli"))?;
        let (events, incoming) = mpsc::unbounded_channel();
        let connection = Rc::new(Self {
            stream: RefCell::new(AgyStream::new(&options.cwd)),
            process,
            next: Cell::new(0),
            pending: RefCell::default(),
            events,
            closed: Cell::new(false),
        });
        tokio::task::spawn_local(Rc::clone(&connection).read(lines));
        let capabilities = json!({"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false});
        let client = json!({"name": "vcx", "title": "Vibe Code X", "version": env!("CARGO_PKG_VERSION")});
        connection.call("initialize", json!({"protocolVersion": 1, "clientCapabilities": capabilities, "clientInfo": client}), Some(INITIALIZE_TIMEOUT)).await?;
        Ok((connection, incoming))
    }

    pub fn thread(&self) -> String {
        self.stream.borrow().thread.clone()
    }

    fn apply(&self, effects: Vec<Effect>) {
        for effect in effects {
            match effect {
                Effect::Event(message) => drop(self.events.send(Incoming::Message(codex::parse(message)))),
                Effect::Write(line) => drop(self.process.send(&line)),
                Effect::Resolve { request_id, outcome } => {
                    if let Some(waiter) = self.pending.borrow_mut().remove(&request_id) {
                        let _ = waiter.send(outcome);
                    }
                }
                Effect::Answered | Effect::TurnEnded => {}
            }
        }
    }

    fn notice(&self, method: &str, params: Value) {
        let _ = self.events.send(Incoming::Message(codex::parse(object(json!({"method": method, "params": params})))));
    }

    async fn read(self: Rc<Self>, mut lines: mpsc::UnboundedReceiver<Line>) {
        while let Some(line) = lines.recv().await {
            if self.closed.get() {
                return;
            }
            match line {
                Line::Message(message) => {
                    let effects = self.stream.borrow_mut().receive(&message);
                    self.apply(effects);
                }
                Line::Invalid(_) => {}
                Line::Failed(message) => self.notice("vcx/error", json!({"message": message.replace("agent", "Antigravity")})),
                Line::Exited { .. } => {
                    self.closed.set(true);
                    self.fail_pending();
                    self.notice("vcx/disconnected", json!({"message": "Antigravity stopped."}));
                }
            }
        }
    }

    async fn call(&self, method: &str, params: Value, timeout: Option<Duration>) -> Result<Object, AgentError> {
        if self.closed.get() || !self.process.is_running() {
            return Err(failure("Antigravity is disconnected."));
        }
        let id = self.next.get() + 1;
        self.next.set(id);
        let (waiter, answer) = oneshot::channel();
        self.pending.borrow_mut().insert(id.to_string(), waiter);
        if let Err(error) = self.process.send(&object(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))) {
            self.pending.borrow_mut().remove(&id.to_string());
            return Err(failure(error));
        }
        let outcome = match timeout {
            Some(timeout) => match tokio::time::timeout(timeout, answer).await {
                Ok(outcome) => outcome,
                Err(_) => {
                    self.pending.borrow_mut().remove(&id.to_string());
                    return Err(failure(format!("Antigravity timed out while handling {method}.")));
                }
            },
            // A turn runs as long as the agent works: Stop cancels it.
            None => answer.await,
        };
        outcome.map_err(|_| failure("Antigravity is disconnected."))?.map_err(failure)
    }

    async fn apply_mode(&self) -> Result<(), AgentError> {
        let (session, bypass) = {
            let stream = self.stream.borrow();
            (stream.session.clone(), stream.bypass)
        };
        if session.is_empty() {
            return Ok(());
        }
        // VCX's bypass answers every permission itself; "auto" only keeps agy from asking for the safe ones.
        self.call("session/set_mode", json!({"sessionId": session, "modeId": if bypass { "auto" } else { "default" }}), Some(REQUEST_TIMEOUT)).await.map(drop)
    }

    async fn set_model(&self, next: &str) -> Result<(), AgentError> {
        let session = self.stream.borrow().session.clone();
        self.call("session/set_model", json!({"sessionId": session, "modelId": next}), Some(REQUEST_TIMEOUT)).await?;
        self.stream.borrow_mut().model = next.to_owned();
        Ok(())
    }

    fn thread_answer(&self) -> Value {
        let stream = self.stream.borrow();
        json!({"thread": {"id": stream.thread}, "model": stream.model})
    }

    pub async fn request(self: &Rc<Self>, method: &str, params: Value, _timeout: Duration) -> Result<Value, AgentError> {
        let params = obj(Some(&params));
        match method {
            "initialize" => Ok(json!({})),
            "thread/start" | "thread/resume" => self.open(&params).await,
            "thread/turns/list" | "thread/list" => Ok(json!({"data": []})),
            "account/rateLimits/read" | "config/read" => Ok(json!({})),
            "model/list" => Ok(json!({"data": self.stream.borrow().models.iter().map(|id| json!({"id": id, "model": id})).collect::<Vec<_>>()})),
            "vcx/mode" => {
                self.stream.borrow_mut().bypass = text(&params, "mode") == Some("bypass");
                self.apply_mode().await?;
                Ok(json!({}))
            }
            "turn/start" => {
                if self.stream.borrow().turn.is_some() {
                    return Err(failure(BUSY));
                }
                if let Some(path) = text(&params, "cwd") {
                    self.stream.borrow_mut().cwd = path.to_owned();
                }
                let prompt = prompt(params.get("input").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default())?;
                let (current, started) = self.stream.borrow_mut().start_turn();
                self.apply(vec![started]);
                tokio::task::spawn_local(Rc::clone(self).run(current.clone(), prompt));
                Ok(json!({"turn": {"id": current}}))
            }
            "turn/steer" => Err(failure(BUSY)),
            "turn/interrupt" => {
                let session = self.stream.borrow().session.clone();
                if !session.is_empty() {
                    let _ = self.process.send(&object(json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": session}})));
                }
                Ok(json!({}))
            }
            _ => Err(failure("Antigravity does not support this action. Send your request as a message.")),
        }
    }

    async fn open(&self, params: &Object) -> Result<Value, AgentError> {
        if let Some(policy) = text(params, "approvalPolicy") {
            self.stream.borrow_mut().bypass = policy == "never";
        }
        if let Some(path) = text(params, "cwd") {
            self.stream.borrow_mut().cwd = path.to_owned();
        }
        let wanted = text(params, "threadId").map(|id| id.strip_prefix("agy:").unwrap_or(id).to_owned());
        let next = text(params, "model");
        if wanted.as_deref().is_some_and(|wanted| wanted == self.stream.borrow().session) {
            if let Some(next) = next.filter(|next| *next != self.stream.borrow().model) {
                self.set_model(next).await?;
            }
            return Ok(self.thread_answer());
        }
        let mut open = json!({"cwd": self.stream.borrow().cwd, "mcpServers": []});
        if let Some(instructions) = text(params, "developerInstructions").filter(|text| !text.is_empty()) {
            open["_meta"] = json!({"antigravity": {"systemPrompt": {"append": instructions}}});
        }
        let result = match &wanted {
            Some(wanted) => {
                open["sessionId"] = wanted.clone().into();
                self.call("session/resume", open, Some(OPEN_TIMEOUT)).await?
            }
            None => self.call("session/new", open, Some(OPEN_TIMEOUT)).await?,
        };
        self.stream.borrow_mut().opened(&result, wanted.as_deref()).map_err(failure)?;
        let offered = next.filter(|next| {
            let stream = self.stream.borrow();
            *next != stream.model && stream.models.iter().any(|model| model == next)
        });
        if let Some(next) = offered {
            self.set_model(next).await?;
        }
        self.apply_mode().await?;
        Ok(self.thread_answer())
    }

    async fn run(self: Rc<Self>, current: String, prompt: Vec<Value>) {
        let session = self.stream.borrow().session.clone();
        let result = self.call("session/prompt", json!({"sessionId": session, "prompt": prompt}), None).await;
        let effects = self.stream.borrow_mut().finish_turn(&current, result.as_ref().map_err(|error| error.message.as_str()));
        self.apply(effects);
    }

    pub fn respond(&self, id: &Value, result: Value) -> Result<(), AgentError> {
        let key = id.as_str().map_or_else(|| id.to_string(), str::to_owned);
        let effects = self.stream.borrow_mut().respond(&key, &obj(Some(&result)));
        self.apply(effects);
        Ok(())
    }

    pub fn reject(&self, id: &Value) -> Result<(), AgentError> {
        let key = id.as_str().map_or_else(|| id.to_string(), str::to_owned);
        let effects = self.stream.borrow_mut().reject(&key);
        self.apply(effects);
        Ok(())
    }

    fn fail_pending(&self) {
        for (_, waiter) in self.pending.borrow_mut().drain() {
            let _ = waiter.send(Err("Antigravity is disconnected.".into()));
        }
        self.stream.borrow_mut().forget_permissions();
    }

    pub fn is_closed(&self) -> bool {
        self.closed.get()
    }

    pub fn close(&self) {
        if self.closed.replace(true) {
            return;
        }
        self.fail_pending();
        self.process.close(libc::SIGTERM);
    }
}

/// The session's input as ACP prompt blocks: text as it is, images inline.
fn prompt(pieces: &[Value]) -> Result<Vec<Value>, AgentError> {
    use base64::Engine;
    pieces.iter().filter_map(|piece| {
        if let Some(text) = piece["text"].as_str() {
            return Some(Ok(json!({"type": "text", "text": text})));
        }
        let path = piece["path"].as_str()?;
        Some(std::fs::read(path).map_err(|error| failure(format!("Cannot read the image: {error}"))).map(|data| {
            let extension = Path::new(path).extension().and_then(|e| e.to_str()).unwrap_or_default().to_lowercase();
            let media = match extension.as_str() {
                "png" => "image/png",
                "gif" => "image/gif",
                "webp" => "image/webp",
                _ => "image/jpeg",
            };
            json!({"type": "image", "mimeType": media, "data": base64::engine::general_purpose::STANDARD.encode(data)})
        }))
    }).collect()
}
