//! `claude -p` in stream-json, answering the requests a session sends `codex app-server`, as `ClaudeConnection` in
//! `Agents.swift` does. `ClaudeStream` reads its lines; this owns the process, the control requests and the watches.

use crate::claude_stream::{ClaudePaths, ClaudeStream};
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

/// claude -p can wait forever on an API request that never answers (2026-11-09: 204 of ~270 KB sent, then only
/// keep-alives for 40 min), so a prompt with no event by then is sent again to a new process.
pub const FIRST_EVENT_TIMEOUT: Duration = Duration::from_secs(120);
/// A claude hung on an API request ignores the interrupt too, so a stop unanswered by then ends its process.
pub const STOP_TIMEOUT: Duration = Duration::from_secs(10);
const AUTH_TIMEOUT: Duration = Duration::from_secs(10);
const CONTROL_TIMEOUT: Duration = Duration::from_secs(15);
const QUICK_CONTROL_TIMEOUT: Duration = Duration::from_secs(5);
const CATALOG_TIMEOUT: Duration = Duration::from_secs(20);
const RELOAD_TIMEOUT: Duration = Duration::from_secs(10);
const REMOTE_CONTROL_TIMEOUT: Duration = Duration::from_secs(60);
/// Remote Control's "Session creation failed" is now and then a one-off on Anthropic's side, so it is tried again.
const REMOTE_CONTROL_WAITS: [u64; 3] = [0, 5, 20];
const IMAGE_LIMIT: usize = 20 * 1024 * 1024;

pub struct ClaudeOptions {
    /// A fixed command (a fixture agent) replaces `claude` and skips the sign-in check and Remote Control.
    pub command: Option<Vec<String>>,
    pub cwd: String,
    pub mode: String,
    pub environment: Option<Vec<(String, String)>>,
    pub log: Option<PathBuf>,
    /// VCX's own Claude settings (`claude-settings.json`), passed when the file exists.
    pub settings: Option<PathBuf>,
    pub paths: ClaudePaths,
}

pub struct ClaudeConnection {
    stream: RefCell<ClaudeStream>,
    options: ClaudeOptions,
    process: RefCell<Option<Lines>>,
    /// Which process a reader belongs to: the lines and the end of a replaced process are dropped.
    generation: Cell<u64>,
    waiting: RefCell<HashMap<String, oneshot::Sender<Result<Object, String>>>>,
    events: mpsc::UnboundedSender<Incoming>,
    closed: Cell<bool>,
    resumed: Cell<bool>,
    developer_instructions: RefCell<String>,
    pub history: RefCell<String>,
    first_event: Cell<u64>,
    stop_watch: Cell<u64>,
}

type Answer = Result<Value, AgentError>;

fn failure(message: impl Into<String>) -> AgentError {
    AgentError { message: message.into(), code: None }
}

impl ClaudeConnection {
    /// Checks the sign-in (a Claude subscription, never API billing) and makes the connection; claude itself starts
    /// with the first prompt or catalog read.
    pub async fn start(options: ClaudeOptions) -> Result<(Rc<Self>, mpsc::UnboundedReceiver<Incoming>), AgentError> {
        if options.command.is_none() {
            signed_in(options.environment.as_deref()).await?;
        }
        let (events, incoming) = mpsc::unbounded_channel();
        let stream = ClaudeStream::new(&options.cwd, &options.mode, options.paths.clone());
        let connection = Rc::new(Self {
            stream: RefCell::new(stream),
            options,
            process: RefCell::new(None),
            generation: Cell::new(0),
            waiting: RefCell::default(),
            events,
            closed: Cell::new(false),
            resumed: Cell::new(false),
            developer_instructions: RefCell::default(),
            history: RefCell::default(),
            first_event: Cell::new(0),
            stop_watch: Cell::new(0),
        });
        Ok((connection, incoming))
    }

    pub fn thread(&self) -> String {
        self.stream.borrow().thread.clone()
    }

    fn emit(&self, method: &str, params: Value) {
        let effect = self.stream.borrow().event(method, object(params));
        self.apply(vec![effect]);
    }

    fn apply(&self, effects: Vec<Effect>) {
        for effect in effects {
            match effect {
                Effect::Event(message) => drop(self.events.send(Incoming::Message(codex::parse(message)))),
                Effect::Write(line) => drop(self.write(&line)),
                Effect::Resolve { request_id, outcome } => {
                    if let Some(waiter) = self.waiting.borrow_mut().remove(&request_id) {
                        let _ = waiter.send(outcome);
                    }
                }
                Effect::Answered => self.first_event.set(self.first_event.get() + 1),
                Effect::TurnEnded => self.stop_watch.set(self.stop_watch.get() + 1),
            }
        }
    }

    fn write(&self, line: &Object) -> Result<(), AgentError> {
        let process = self.process.borrow();
        let process = process.as_ref().filter(|process| process.is_running()).ok_or_else(|| failure("Claude is disconnected."))?;
        process.send(line).map_err(failure)
    }

    fn arguments(&self, resume: bool) -> Vec<String> {
        if let Some(command) = &self.options.command {
            return command.clone();
        }
        let stream = self.stream.borrow();
        let id = stream.session_id().to_owned();
        let mut arguments: Vec<String> = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio", "--permission-mode"]
            .map(str::to_owned).into();
        arguments.push(if stream.mode == "bypass" { "bypassPermissions" } else { "default" }.into());
        arguments.push("--allow-dangerously-skip-permissions".into());
        arguments.push(if resume && saved(&id, &self.options.paths.config) { "--resume" } else { "--session-id" }.into());
        arguments.push(id);
        if !["", "Claude"].contains(&stream.model.as_str()) {
            arguments.extend(["--model".to_owned(), stream.model.clone()]);
        }
        if let Some(settings) = self.options.settings.as_ref().filter(|path| path.exists()) {
            arguments.extend(["--settings".to_owned(), settings.to_string_lossy().into_owned()]);
        }
        let instructions = self.developer_instructions.borrow();
        if !instructions.is_empty() {
            arguments.extend(["--append-system-prompt".to_owned(), instructions.clone()]);
        }
        arguments
    }

    fn launch(self: &Rc<Self>, resume: bool) -> Result<(), AgentError> {
        let arguments = self.arguments(resume);
        let cwd = self.stream.borrow().initial_directory.clone();
        let launch = Launch { command: &arguments, cwd: Path::new(&cwd), environment: self.options.environment.as_deref(), log: self.options.log.as_deref() };
        let (process, lines) = Lines::spawn(launch).map_err(|error| failure(format!("Cannot start Claude: {error}")))?;
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        self.emit("cx/launch", json!({"arguments": arguments, "pid": process.pid}));
        *self.process.borrow_mut() = Some(process);
        tokio::task::spawn_local(Rc::clone(self).read(lines, generation));
        if self.options.command.is_none() {
            tokio::task::spawn_local(Rc::clone(self).remote_control(generation));
        }
        Ok(())
    }

    fn current(&self, generation: u64) -> bool {
        !self.closed.get() && self.generation.get() == generation
    }

    async fn read(self: Rc<Self>, mut lines: mpsc::UnboundedReceiver<Line>, generation: u64) {
        while let Some(line) = lines.recv().await {
            if !self.current(generation) {
                return;
            }
            match line {
                Line::Message(message) => {
                    let effects = self.stream.borrow_mut().receive(&message);
                    self.apply(effects);
                }
                Line::Invalid(_) => {}
                Line::Failed(message) => self.emit("cx/error", json!({"message": message.replace("agent", "Claude")})),
                Line::Exited { crash, log_tail } => {
                    self.process.borrow_mut().take();
                    if log_tail.contains("No conversation found") {
                        self.emit("cx/resumeFailed", json!({}));
                    } else if crash.is_empty() {
                        self.emit("cx/disconnected", json!({"ended": true, "message": "Claude session ended."}));
                    } else {
                        let mut notice = crash;
                        notice.insert("message".into(), "Claude disconnected. Reconnect to continue the saved conversation.".into());
                        self.emit("cx/disconnected", Value::Object(notice));
                    }
                }
            }
        }
    }

    /// claude -p leaves Remote Control to its host, so VCX turns it on for every process it starts.
    async fn remote_control(self: Rc<Self>, generation: u64) {
        for wait in REMOTE_CONTROL_WAITS {
            tokio::time::sleep(Duration::from_secs(wait)).await;
            if !self.current(generation) {
                return;
            }
            match self.control_result(json!({"subtype": "remote_control", "enabled": true}), REMOTE_CONTROL_TIMEOUT).await {
                Ok(_) => return,
                Err(error) if wait == REMOTE_CONTROL_WAITS[REMOTE_CONTROL_WAITS.len() - 1] => {
                    self.emit("warning", json!({"message": format!("Remote Control did not start: {error}")}));
                }
                Err(_) => {}
            }
        }
    }

    async fn control_result(&self, request: Value, timeout: Duration) -> Result<Object, AgentError> {
        let id = crate::shape::new_id();
        let (waiter, answer) = oneshot::channel();
        self.waiting.borrow_mut().insert(id.clone(), waiter);
        if let Err(error) = self.write(&object(json!({"type": "control_request", "request_id": id, "request": request}))) {
            self.waiting.borrow_mut().remove(&id);
            return Err(error);
        }
        match tokio::time::timeout(timeout, answer).await {
            Ok(Ok(outcome)) => outcome.map_err(failure),
            Ok(Err(_)) => Err(failure("Claude is disconnected.")),
            Err(_) => {
                self.waiting.borrow_mut().remove(&id);
                Err(failure("Claude metadata request timed out."))
            }
        }
    }

    fn control(&self, request: Value) -> Result<(), AgentError> {
        self.write(&object(json!({"type": "control_request", "request_id": crate::shape::new_id(), "request": request})))
    }

    fn running(&self) -> bool {
        self.process.borrow().as_ref().is_some_and(Lines::is_running)
    }

    async fn catalog(self: &Rc<Self>) -> Result<Object, AgentError> {
        if let Some(metadata) = self.stream.borrow().metadata.clone() {
            return Ok(metadata);
        }
        if !self.running() {
            self.launch(self.resumed.get())?;
        }
        let mut result = self.control_result(json!({"subtype": "initialize"}), CATALOG_TIMEOUT).await?;
        let models: Vec<Value> = result.get("models").and_then(Value::as_array).cloned().unwrap_or_default();
        let resolved = models.iter().find(|model| model["value"] == "default").and_then(|model| model["resolvedModel"].as_str()).map(str::to_owned);
        if let Some(resolved) = resolved.filter(|_| self.stream.borrow().model == "Claude") {
            self.stream.borrow_mut().model = resolved.clone();
            self.emit("cx/model", json!({"model": resolved}));
        }
        // "default" duplicates the alias it resolves to; the menu highlights that alias instead.
        result.insert("models".into(), models.into_iter().filter(|model| model["value"] != "default").collect());
        self.stream.borrow_mut().metadata = Some(result.clone());
        self.emit("cx/catalog", Value::Object(result.clone()));
        Ok(result)
    }

    fn content(&self, pieces: &[Value]) -> Result<Vec<Value>, AgentError> {
        let mut content = Vec::new();
        let history = std::mem::take(&mut *self.history.borrow_mut());
        if !history.is_empty() {
            content.push(json!({"type": "text", "text": history}));
        }
        for piece in pieces {
            if piece["type"] == "text" {
                content.push(json!({"type": "text", "text": piece["text"].as_str().unwrap_or_default()}));
            } else if let Some(path) = piece["path"].as_str() {
                let (data, media) = image(path)?;
                use base64::Engine;
                content.push(json!({"type": "image", "source": {"type": "base64", "media_type": media, "data": base64::engine::general_purpose::STANDARD.encode(data)}}));
            }
        }
        Ok(content)
    }

    pub async fn request(self: &Rc<Self>, method: &str, params: Value, _timeout: Duration) -> Answer {
        let params = obj(Some(&params));
        let thread_answer = |connection: &Self| {
            let stream = connection.stream.borrow();
            Ok(json!({"thread": {"id": stream.thread}, "model": stream.model}))
        };
        match method {
            "initialize" => Ok(json!({})),
            "thread/start" => {
                *self.developer_instructions.borrow_mut() = text(&params, "developerInstructions").unwrap_or_default().to_owned();
                self.stream.borrow_mut().mode = mode(text(&params, "approvalPolicy"));
                thread_answer(self)
            }
            "thread/resume" => {
                if let Some(instructions) = text(&params, "developerInstructions") {
                    *self.developer_instructions.borrow_mut() = instructions.to_owned();
                }
                if let Some(approval) = text(&params, "approvalPolicy") {
                    self.stream.borrow_mut().mode = mode(Some(approval));
                }
                let id = text(&params, "threadId").ok_or_else(|| failure("Missing Claude conversation ID."))?.to_owned();
                if let Some(model) = text(&params, "model") {
                    if self.running() {
                        let settings = match params.get("effort") {
                            Some(effort) => json!({"subtype": "apply_flag_settings", "settings": {"model": model, "effortLevel": effort}}),
                            None => json!({"subtype": "set_model", "model": model}),
                        };
                        self.control_result(settings, CONTROL_TIMEOUT).await?;
                    }
                    self.stream.borrow_mut().model = model.to_owned();
                }
                self.stream.borrow_mut().thread = id;
                self.resumed.set(true);
                thread_answer(self)
            }
            "thread/turns/list" => Ok(json!({"data": []})),
            "thread/list" => Ok(json!({})),
            "model/list" => Ok(json!({"data": model_list(&self.catalog().await?)})),
            "cx/catalog" => {
                let mut result = self.catalog().await?;
                // initialize lists skills as at launch; reload_skills rereads only the user's and project's from disk.
                if let Ok(fresh) = self.control_result(json!({"subtype": "reload_skills"}), RELOAD_TIMEOUT).await {
                    if let Some(skills) = fresh.get("skills").and_then(Value::as_array) {
                        let commands = result.get("commands").and_then(Value::as_array).cloned().unwrap_or_default();
                        result.insert("commands".into(), crate::claude_stream::reloaded_commands(&commands, skills).into());
                        self.stream.borrow_mut().metadata = Some(result.clone());
                    }
                }
                let servers = match self.control_result(json!({"subtype": "mcp_status"}), RELOAD_TIMEOUT).await {
                    Ok(status) => status.get("mcpServers").or_else(|| status.get("mcp_servers")).cloned().unwrap_or(Value::Null),
                    Err(error) => json!([{"name": "MCP status", "status": error.message}]),
                };
                result.insert("mcp_servers".into(), servers);
                Ok(Value::Object(result))
            }
            "account/rateLimits/read" => Err(failure("Claude usage is not read by the Rust worker yet.")),
            "turn/start" | "turn/steer" => self.turn(method == "turn/steer", &params).await,
            "turn/interrupt" => {
                {
                    let mut stream = self.stream.borrow_mut();
                    stream.stopped = true;
                    stream.sending_now = false;
                }
                self.first_event.set(self.first_event.get() + 1);
                self.control(json!({"subtype": "interrupt"}))?;
                self.watch_stop();
                Ok(json!({}))
            }
            "cx/sendNow" => {
                self.stream.borrow_mut().sending_now = true;
                let request = json!({"subtype": "interrupt", "send_now": true, "message_uuid": text(&params, "id").unwrap_or_default()});
                let result = self.control_result(request, QUICK_CONTROL_TIMEOUT).await;
                // "delivering": the turn takes the prompt in and goes on; only "stopped" ends it with a result to absorb.
                if result.as_ref().map_or(true, |result| text(result, "send_now") != Some("stopped")) {
                    self.stream.borrow_mut().sending_now = false;
                }
                result.map(Value::Object)
            }
            "cx/mode" => {
                let value: String = if text(&params, "mode") == Some("bypass") { "bypass" } else { "ask" }.into();
                let native = if value == "bypass" { "bypassPermissions" } else { "default" };
                let mut result = Object::new();
                if self.running() {
                    result = self.control_result(json!({"subtype": "set_permission_mode", "mode": native}), CONTROL_TIMEOUT).await?;
                    if let Some(metadata) = self.stream.borrow_mut().metadata.as_mut() {
                        metadata.insert("current_permission_mode".into(), native.into());
                    }
                }
                self.stream.borrow_mut().mode = value;
                Ok(Value::Object(result))
            }
            // Claude drops a prompt only while it waits in its queue; once the turn took it in, it answers cancelled: false.
            "cx/unsend" => {
                let id = text(&params, "id").ok_or_else(|| failure("Missing message ID."))?.to_owned();
                let result = self.control_result(json!({"subtype": "cancel_async_message", "message_uuid": id}), QUICK_CONTROL_TIMEOUT).await?;
                if result.get("cancelled") == Some(&Value::Bool(true)) {
                    self.stream.borrow_mut().pending_users.retain(|pending| *pending != id);
                }
                Ok(Value::Object(result))
            }
            "thread/compact/start" => Err(failure("Claude manages context compaction automatically.")),
            "review/start" => Err(failure("Ask Claude to review your changes in a message.")),
            _ => Err(failure(format!("Unsupported Claude action: {method}"))),
        }
    }

    async fn turn(self: &Rc<Self>, steering: bool, params: &Object) -> Answer {
        if !self.running() {
            self.launch(self.resumed.get())?;
            self.resumed.set(true);
        }
        let pieces = params.get("input").and_then(Value::as_array).cloned().unwrap_or_default();
        let content = self.content(&pieces)?;
        let effort = params.get("effort").and_then(Value::as_str).map(str::to_owned);
        if let (false, Some(effort)) = (steering, &effort) {
            self.control_result(json!({"subtype": "apply_flag_settings", "settings": {"effortLevel": effort}}), CONTROL_TIMEOUT).await?;
        }
        if steering && text(params, "expectedTurnId") != Some(self.stream.borrow().turn.as_str()) {
            return Err(failure("The Claude turn has changed. Your draft has been kept."));
        }
        let user = text(params, "clientUserMessageId").map_or_else(crate::shape::new_id, str::to_owned);
        let (line, effects) = self.stream.borrow_mut().prompt(&user, content, steering);
        self.write(&line)?;
        if !steering {
            self.watch_first_event(line, effort, false);
        }
        self.resumed.set(true);
        self.apply(effects);
        Ok(json!({"turn": {"id": self.stream.borrow().turn}}))
    }

    fn kill_process(&self) {
        self.generation.set(self.generation.get() + 1);
        if let Some(process) = self.process.borrow_mut().take() {
            process.close(libc::SIGKILL);
        }
    }

    fn watch_stop(self: &Rc<Self>) {
        let token = self.stop_watch.get() + 1;
        self.stop_watch.set(token);
        let (connection, current) = (Rc::clone(self), self.stream.borrow().turn.clone());
        tokio::task::spawn_local(async move {
            tokio::time::sleep(STOP_TIMEOUT).await;
            let stream = connection.stream.borrow();
            if connection.closed.get() || connection.stop_watch.get() != token || !stream.stopped || stream.turn != current || !connection.running() {
                return;
            }
            drop(stream);
            connection.kill_process();
            connection.stream.borrow_mut().forget_process();
            connection.emit("turn/completed", json!({"turn": {"id": current, "status": "interrupted"}}));
        });
    }

    fn watch_first_event(self: &Rc<Self>, prompt: Object, effort: Option<String>, retried: bool) {
        let token = self.first_event.get() + 1;
        self.first_event.set(token);
        let (connection, current) = (Rc::clone(self), self.stream.borrow().turn.clone());
        tokio::task::spawn_local(async move {
            tokio::time::sleep(FIRST_EVENT_TIMEOUT).await;
            {
                let stream = connection.stream.borrow();
                if connection.closed.get() || connection.first_event.get() != token || stream.stopped || stream.turn != current || !connection.running() {
                    return;
                }
            }
            if retried {
                let seconds = FIRST_EVENT_TIMEOUT.as_secs();
                connection.emit("warning", json!({"message": format!("Claude has not answered in {seconds} s. Stop and send again.")}));
                return;
            }
            connection.kill_process();
            if let Err(error) = connection.resend(prompt, effort).await {
                connection.emit("cx/error", json!({"message": format!("Claude did not answer and could not be restarted: {error}")}));
            }
        });
    }

    /// A resumed claude replays a saved uuid as done without running it, so each prompt goes again under a new uuid,
    /// the steered ones too: they waited in the killed process's queue.
    async fn resend(self: &Rc<Self>, prompt: Object, effort: Option<String>) -> Result<(), AgentError> {
        self.launch(true)?;
        if let Some(effort) = &effort {
            self.control_result(json!({"subtype": "apply_flag_settings", "settings": {"effortLevel": effort}}), CONTROL_TIMEOUT).await?;
        }
        let first = text(&prompt, "uuid").map(str::to_owned);
        let queued: Vec<Object> = {
            let stream = self.stream.borrow();
            stream.pending_users.iter().filter(|id| Some(id.as_str()) != first.as_deref()).filter_map(|id| stream.steered.get(id).cloned()).collect()
        };
        let mut sent = Vec::new();
        for mut message in std::iter::once(prompt).chain(queued) {
            if let Some(old) = text(&message, "uuid").map(str::to_owned) {
                let fresh = crate::shape::new_id();
                message.insert("uuid".into(), fresh.clone().into());
                let mut stream = self.stream.borrow_mut();
                stream.resent.insert(fresh.clone(), old.clone());
                for pending in stream.pending_users.iter_mut().filter(|pending| **pending == old) {
                    *pending = fresh.clone();
                }
            }
            self.write(&message)?;
            sent.push(message);
        }
        self.watch_first_event(sent.swap_remove(0), effort, true);
        Ok(())
    }

    pub fn respond(&self, id: &Value, result: Value) -> Result<(), AgentError> {
        let key = id.as_str().map_or_else(|| id.to_string(), str::to_owned);
        let line = self.stream.borrow_mut().respond(&key, &obj(Some(&result))).map_err(failure)?;
        self.write(&line)
    }

    pub fn reject(&self, id: &Value) -> Result<(), AgentError> {
        self.respond(id, json!({"decision": "decline"}))
    }

    pub fn is_closed(&self) -> bool {
        self.closed.get()
    }

    pub fn close(&self) {
        if self.closed.replace(true) {
            return;
        }
        self.first_event.set(self.first_event.get() + 1);
        self.stop_watch.set(self.stop_watch.get() + 1);
        for (_, waiter) in self.waiting.borrow_mut().drain() {
            let _ = waiter.send(Err("Claude is disconnected.".into()));
        }
        if let Some(process) = self.process.borrow_mut().take() {
            process.close(libc::SIGTERM);
        }
    }
}

fn mode(approval: Option<&str>) -> String {
    if approval == Some("never") { "bypass" } else { "ask" }.into()
}

/// Claude's catalog models in the shape of Codex's `model/list`, with the efforts each one takes.
pub fn model_list(catalog: &Object) -> Vec<Value> {
    catalog.get("models").and_then(Value::as_array).into_iter().flatten().filter_map(|model| {
        let id = model["value"].as_str()?;
        let mut entry = json!({"id": id, "model": id, "displayName": model["displayName"].as_str().unwrap_or(id)});
        if model["supportsEffort"] == true {
            let efforts: Vec<Value> = model["supportedEffortLevels"].as_array().into_iter().flatten().map(|level| json!({"reasoningEffort": level})).collect();
            entry["supportedReasoningEfforts"] = efforts.into();
        }
        Some(entry)
    }).collect()
}

/// Whether Claude keeps a transcript of this conversation, so the process can `--resume` it.
pub fn saved(id: &str, config: &Path) -> bool {
    std::fs::read_dir(config.join("projects")).into_iter().flatten().flatten().any(|project| project.path().join(format!("{id}.jsonl")).exists())
}

/// PNG, JPEG, GIF or WebP as Claude takes them; other formats would need a conversion the worker cannot make.
pub fn image(path: &str) -> Result<(Vec<u8>, &'static str), AgentError> {
    let data = std::fs::read(path).map_err(|error| failure(format!("Cannot read the image: {error}")))?;
    if data.len() > IMAGE_LIMIT {
        return Err(failure("Image is larger than 20 MB. Use a smaller image."));
    }
    let media = match data.as_slice() {
        [0x89, b'P', b'N', b'G', ..] => "image/png",
        [0xFF, 0xD8, 0xFF, ..] => "image/jpeg",
        [b'G', b'I', b'F', b'8', ..] => "image/gif",
        [b'R', b'I', b'F', b'F', _, _, _, _, b'W', b'E', b'B', b'P', ..] => "image/webp",
        _ => return Err(failure("This file is not a supported image.")),
    };
    Ok((data, media))
}

async fn signed_in(environment: Option<&[(String, String)]>) -> Result<(), AgentError> {
    let mut command = tokio::process::Command::new("/usr/bin/env");
    command.args(["claude", "auth", "status", "--json"]).stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null()).kill_on_drop(true);
    if let Some(environment) = environment {
        command.env_clear().envs(environment.iter().map(|(key, value)| (key, value)));
    }
    let refused = || failure("Sign in with a Claude subscription in Settings. vcx does not use API-key billing.");
    let output = tokio::time::timeout(AUTH_TIMEOUT, command.output()).await.map_err(|_| refused())?.map_err(|_| refused())?;
    let status: Value = serde_json::from_slice(&output.stdout).map_err(|_| refused())?;
    if status["loggedIn"] == true && status["authMethod"] == "claude.ai" { Ok(()) } else { Err(refused()) }
}
