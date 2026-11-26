//! Qwen on an Ollama server (`/api/chat`, streamed NDJSON), driven step by step with one `run_command` tool and
//! turned into the Codex app-server events a session handles, as `QwenConnection` in `Agents.swift` does.

use crate::http::{self, Endpoint};
use crate::qwen_text::{self, SHOWN_OUTPUT_LIMIT, TOOL_OUTPUT_LIMIT, WINDOW};
use crate::rpc::{AgentError, Incoming};
use crate::shape::{new_id, now, obj, object, text};
use crate::{Object, codex, directory};
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::io::Read;
use std::path::PathBuf;
use std::process::Stdio;
use std::rc::Rc;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

/// A model step longer than this pauses the turn with a question; a running command is waited for however long.
pub const STEP_LIMIT: Duration = Duration::from_secs(600);
const IMAGE_LIMIT: usize = 20 * 1024 * 1024;
/// The reader keeps this much of a command's output at each end and counts what it drops between.
const CAPTURE_END: usize = 16384;
const COMMAND_LIMIT: usize = 65536;
const SYSTEM: &str = "You are Qwen in Vibe Code X, a coding assistant. Use run_command to inspect or change files when the user asks. Check the project instructions before changing code. Never claim to have performed an action unless its tool result confirms it. Stop when the task is complete.";
const TOOL_DESCRIPTION: &str = "Run a shell command in the project folder using the configured permission mode. Use for inspecting or changing code. A command runs until it exits and gets no input: never start one that waits for input or runs forever (servers, watchers). Long outputs are cut to their head and tail.";
const SUMMARY_PROMPT: &str = "Your context is nearly full and older messages will be removed. Write a summary you will continue the task from: the task, the findings so far (facts, paths, names, values), the files touched and how, what was tried and failed, and the next step. Keep every detail needed to continue. Plain text, at most 600 words.";
const BUSY: &str = "Stop Qwen before sending another message. Your draft has been kept.";

pub struct QwenOptions {
    pub url: String,
    pub proxy: String,
    pub model: String,
    pub mode: String,
    pub cwd: String,
    /// The environment commands run in (none inherited when set); `VCX_THREAD_ID` is added to it.
    pub environment: Option<Vec<(String, String)>>,
    /// A command that wakes the PC Ollama runs on (`background.py --ensure-qwen`), run before the first request.
    pub wake: Option<Vec<String>>,
    pub home: PathBuf,
    pub step_limit: Duration,
}

struct State {
    thread: String,
    messages: Vec<Object>,
    developer_instructions: String,
    model: String,
    mode: String,
    cwd: String,
    turn: String,
    task_request: Option<Object>,
    paused: bool,
    context_tokens: usize,
    open: Vec<Object>,
}

pub struct QwenConnection {
    state: RefCell<State>,
    options: QwenOptions,
    events: mpsc::UnboundedSender<Incoming>,
    permissions: RefCell<HashMap<String, oneshot::Sender<bool>>>,
    task: RefCell<Option<JoinHandle<()>>>,
    command: Cell<Option<i32>>,
    closed: Cell<bool>,
}

/// Why a turn stopped before its answer: a step ran past the limit (the turn asks), or something failed.
enum Stop {
    Overdue(String),
    Failed(String),
}

fn failure(message: impl Into<String>) -> AgentError {
    AgentError { message: message.into(), code: None }
}

fn message(role: &str, content: &str) -> Object {
    object(json!({"role": role, "content": content}))
}

impl QwenConnection {
    pub async fn start(options: QwenOptions) -> Result<(Rc<Self>, mpsc::UnboundedReceiver<Incoming>), AgentError> {
        if let Some(wake) = options.wake.as_ref().filter(|command| !command.is_empty()) {
            let status = tokio::process::Command::new(&wake[0]).args(&wake[1..]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().await;
            if !status.is_ok_and(|status| status.success()) {
                return Err(failure("Qwen is unavailable. Check the remote machine and the Windows wake setting."));
            }
        }
        let (events, incoming) = mpsc::unbounded_channel();
        let state = State {
            thread: format!("qwen:{}", new_id()),
            messages: vec![message("system", SYSTEM)],
            developer_instructions: String::new(),
            model: options.model.clone(),
            mode: options.mode.clone(),
            cwd: options.cwd.clone(),
            turn: String::new(),
            task_request: None,
            paused: false,
            context_tokens: 0,
            open: Vec::new(),
        };
        let connection = Rc::new(Self { state: RefCell::new(state), options, events, permissions: RefCell::default(), task: RefCell::new(None), command: Cell::new(None), closed: Cell::new(false) });
        Ok((connection, incoming))
    }

    pub fn thread(&self) -> String {
        self.state.borrow().thread.clone()
    }

    fn send(&self, message: Value) {
        let _ = self.events.send(Incoming::Message(codex::parse(object(message))));
    }

    fn emit(&self, method: &str, mut params: Value) {
        params["threadId"] = self.state.borrow().thread.clone().into();
        self.send(json!({"method": method, "params": params}));
    }

    pub async fn request(self: &Rc<Self>, method: &str, params: Value, _timeout: Duration) -> Result<Value, AgentError> {
        let params = obj(Some(&params));
        match method {
            "initialize" => Ok(json!({})),
            "thread/start" | "thread/resume" => {
                let mut state = self.state.borrow_mut();
                if let Some(instructions) = text(&params, "developerInstructions") {
                    state.developer_instructions = instructions.to_owned();
                }
                if let Some(id) = text(&params, "threadId") {
                    state.thread = id.to_owned();
                }
                if let Some(model) = text(&params, "model") {
                    state.model = model.to_owned();
                }
                Ok(json!({"thread": {"id": state.thread}, "model": state.model}))
            }
            "thread/turns/list" | "thread/list" => Ok(json!({"data": []})),
            "account/rateLimits/read" => Ok(json!({})),
            "vcx/mode" => {
                self.state.borrow_mut().mode = if text(&params, "mode") == Some("bypass") { "bypass" } else { "ask" }.into();
                Ok(json!({}))
            }
            "model/list" => Ok(json!({"data": [{"id": self.options.model, "model": self.options.model}]})),
            "turn/start" => self.start_turn(&params),
            "turn/steer" => Err(failure(BUSY)),
            "turn/interrupt" => {
                self.interrupt();
                Ok(json!({}))
            }
            _ => Err(failure("Qwen does not support this action. Send your request as a message.")),
        }
    }

    fn start_turn(self: &Rc<Self>, params: &Object) -> Result<Value, AgentError> {
        if self.task.borrow().is_some() {
            return Err(failure(BUSY));
        }
        let endpoint = http::endpoint(&self.options.url).map_err(failure)?;
        let proxy = http::proxy(&self.options.proxy).map_err(failure)?;
        if let Some(path) = text(params, "cwd") {
            if let Some(folder) = directory::working_directory(path, &self.options.cwd) {
                self.state.borrow_mut().cwd = folder;
            }
        }
        let pieces = params.get("input").and_then(Value::as_array).cloned().unwrap_or_default();
        let words: Vec<&str> = pieces.iter().filter_map(|piece| piece["text"].as_str()).collect();
        let said = words.join("\n");
        let mut user = message("user", &said);
        let images = pieces.iter().filter_map(|piece| piece["path"].as_str()).map(image).collect::<Result<Vec<_>, _>>()?;
        if !images.is_empty() {
            user.insert("images".into(), images.into());
        }
        let (current, project) = {
            let mut state = self.state.borrow_mut();
            let project = (state.messages.len() == 1)
                .then(|| qwen_text::project(qwen_text::strip_recall(&said), &state.cwd, &self.options.home))
                .flatten()
                .and_then(|project| directory::working_directory(&project, &self.options.cwd));
            state.messages.push(user.clone());
            // A reply to a pause question continues the paused task, whose request compaction keeps.
            if !state.paused || state.task_request.is_none() {
                state.task_request = Some(user);
            }
            state.paused = false;
            state.turn = new_id();
            (state.turn.clone(), project)
        };
        self.emit("turn/started", json!({"turn": {"id": current}}));
        if let Some(project) = project {
            // Reported as the lone cd Claude would run, so the window moves the way it does for Claude.
            let cwd = self.state.borrow().cwd.clone();
            self.emit("item/completed", json!({"item": {"id": new_id(), "type": "commandExecution", "command": format!("cd {project}"), "cwd": cwd, "aggregatedOutput": "", "exitCode": 0, "status": "completed"}}));
            self.state.borrow_mut().cwd = project;
        }
        let handle = tokio::task::spawn_local(Rc::clone(self).run(current.clone(), endpoint, proxy));
        *self.task.borrow_mut() = Some(handle);
        Ok(json!({"turn": {"id": current}}))
    }

    async fn run(self: Rc<Self>, current: String, endpoint: Endpoint, proxy: Option<(String, u16)>) {
        let mut last = String::new();
        let outcome = self.steps(&current, &endpoint, proxy.as_ref(), &mut last).await;
        self.task.borrow_mut().take();
        match outcome {
            Ok(()) => {}
            Err(Stop::Overdue(title)) => {
                let minutes = self.options.step_limit.as_secs() / 60;
                let command = if last.is_empty() { String::new() } else { format!(" The last command I ran:\n\n```\n{last}\n```\n") };
                self.ask(&format!("{title} ran for over {minutes} minutes without finishing, so I stopped it.{command}\nShould I continue? Reply to resume where I stopped; the conversation is kept."), &current);
            }
            Err(Stop::Failed(message)) => self.emit("turn/completed", json!({"turn": {"id": current, "status": "failed", "error": {"message": message}}})),
        }
    }

    async fn steps(self: &Rc<Self>, current: &str, endpoint: &Endpoint, proxy: Option<&(String, u16)>, last: &mut String) -> Result<(), Stop> {
        let item = new_id();
        let (mut commands, mut number) = (Vec::new(), 0);
        loop {
            let (tokens, bytes) = {
                let state = self.state.borrow();
                let light: Vec<Object> = state.messages.iter().map(|message| message.iter().filter(|(key, _)| *key != "images").map(|(k, v)| (k.clone(), v.clone())).collect()).collect();
                (state.context_tokens, serde_json::to_vec(&light).map_or(0, |bytes| bytes.len()))
            };
            if qwen_text::needs_compaction(tokens, bytes, WINDOW) {
                self.step("Compacting context", self.compact(endpoint, proxy)).await?;
            }
            number += 1;
            let (answer, calls) = self.step(&format!("Step {number}"), self.completion(endpoint, proxy, &item)).await?.map_err(Stop::Failed)?;
            if calls.is_empty() {
                self.state.borrow_mut().messages.push(message("assistant", &answer));
                self.emit("turn/completed", json!({"turn": {"id": current, "status": "completed"}}));
                return Ok(());
            }
            let mut turn = message("assistant", &answer);
            turn.insert("tool_calls".into(), calls.clone().into());
            self.state.borrow_mut().messages.push(turn);
            let mut pause = None;
            for call in &calls {
                let function = obj(call.get("function"));
                let arguments = obj(function.get("arguments"));
                let name = text(&function, "name").unwrap_or_default().to_owned();
                let command = text(&arguments, "command").filter(|command| !command.is_empty() && command.len() < COMMAND_LIMIT && !command.contains('\0'));
                let result = match (&pause, name.as_str(), command) {
                    (Some(_), _, _) => "Not run: VCX paused the task to ask the user.".to_owned(),
                    (None, "run_command", Some(command)) => {
                        commands.push(command.to_owned());
                        // Without a step cap, a looping model in bypass mode would go on forever, each loop being fast.
                        if qwen_text::repeats(&commands) {
                            pause = Some(format!("I issued the same command three times in a row, so I stopped instead of running it again:\n\n```\n{command}\n```\n\nShould I continue? Reply to resume where I stopped, or tell me what to try instead."));
                            "Not run: this is the third identical command in a row. VCX paused the task to ask the user.".to_owned()
                        } else {
                            let result = self.command_result(command).await.map_err(Stop::Failed)?;
                            *last = command.to_owned();
                            result
                        }
                    }
                    _ => "Unsupported or invalid tool request. No command was executed.".to_owned(),
                };
                self.state.borrow_mut().messages.push(object(json!({"role": "tool", "tool_name": name, "content": result})));
            }
            if let Some(pause) = pause {
                self.ask(&pause, current);
                return Ok(());
            }
        }
    }

    /// Shown while it runs with a live counter, then with its duration; past the step limit the turn asks instead.
    async fn step<T>(&self, title: &str, body: impl std::future::Future<Output = T>) -> Result<T, Stop> {
        let (start, id) = (now(), new_id());
        let item = json!({"id": id, "type": "reasoning", "description": title, "stepStartedAt": start});
        self.emit("item/started", json!({"item": item}));
        self.state.borrow_mut().open.push(object(item));
        let outcome = tokio::time::timeout(self.options.step_limit, body).await;
        self.close_open(&id, "completed");
        outcome.map_err(|_| Stop::Overdue(title.to_owned()))
    }

    /// Ends a running step or command card; a step takes its duration, a command the status it ended with.
    fn close_open(&self, id: &str, status: &str) {
        let item = {
            let mut state = self.state.borrow_mut();
            let Some(at) = state.open.iter().position(|item| item["id"] == id) else { return };
            state.open.remove(at)
        };
        let mut item = item;
        if let Some(start) = item.remove("stepStartedAt").and_then(|start| start.as_f64()) {
            item.insert("seconds".into(), ((now() - start).round() as i64).into());
        }
        item.insert("status".into(), status.into());
        self.emit("item/completed", json!({"item": item}));
    }

    fn ask(&self, question: &str, current: &str) {
        {
            let mut state = self.state.borrow_mut();
            state.messages.push(message("assistant", question));
            state.paused = true;
        }
        self.emit("item/completed", json!({"item": {"id": new_id(), "type": "agentMessage", "text": question, "provider": "Qwen"}}));
        self.emit("turn/completed", json!({"turn": {"id": current, "status": "completed"}}));
    }

    fn chat_body(&self, mut body: Object, messages: Option<Vec<Object>>) -> Vec<u8> {
        let state = self.state.borrow();
        let mut outgoing = qwen_text::history(messages.as_deref().unwrap_or(&state.messages), WINDOW * 5 / 2);
        let system = format!("{}\n{}", text(&state.messages[0], "content").unwrap_or_default(), state.developer_instructions);
        outgoing[0].insert("content".into(), system.into());
        body.insert("model".into(), state.model.clone().into());
        body.insert("messages".into(), serde_json::to_value(outgoing).unwrap_or_default());
        body.insert("keep_alive".into(), "5m".into());
        body.insert("options".into(), json!({"num_ctx": WINDOW}));
        body.insert("think".into(), false.into());
        serde_json::to_vec(&body).unwrap_or_default()
    }

    /// Ollama drops the oldest messages of an overflowing window, the request first; a summary keeps what the task needs.
    async fn compact(&self, endpoint: &Endpoint, proxy: Option<&(String, u16)>) {
        let messages: Vec<Object> = self.state.borrow().messages.iter().cloned().chain([message("user", SUMMARY_PROMPT)]).collect();
        let body = self.chat_body(object(json!({"stream": false})), Some(messages));
        let summary = async {
            let mut response = http::post_json(endpoint, proxy, &body).await.map_err(|error| error.to_string())?;
            let answer = response.all().await.map_err(|error| error.to_string())?;
            let answer: Value = serde_json::from_slice(&answer).map_err(|_| "Qwen returned no summary.".to_owned())?;
            let text = answer.pointer("/message/content").and_then(Value::as_str).filter(|_| response.status == 200).ok_or("Qwen returned no summary.")?;
            let summary = text.rsplit("</think>").next().unwrap_or(text).trim().to_owned();
            if summary.is_empty() { Err("Qwen returned an empty summary.".to_owned()) } else { Ok(summary) }
        };
        let outcome = summary.await.and_then(|summary| self.state.borrow().task_request.clone().map(|request| (request, summary)).ok_or_else(|| "Qwen returned an empty summary.".to_owned()));
        match outcome {
            Ok((request, summary)) => {
                let mut state = self.state.borrow_mut();
                state.messages = qwen_text::compacted(&state.messages, &request, &summary);
                state.context_tokens = 0;
            }
            Err(error) => self.emit("warning", json!({"message": format!("Qwen could not compact its context ({error}); its oldest messages will be dropped instead.")})),
        }
    }

    async fn completion(&self, endpoint: &Endpoint, proxy: Option<&(String, u16)>, item: &str) -> Result<(String, Vec<Value>), String> {
        let tool = json!({"type": "function", "function": {"name": "run_command", "description": TOOL_DESCRIPTION, "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}});
        let body = self.chat_body(object(json!({"stream": true, "tools": [tool]})), None);
        let unreachable = |error: std::io::Error| format!("Qwen is unreachable ({error}). Check Settings and the remote machine.");
        let mut response = http::post_json(endpoint, proxy, &body).await.map_err(unreachable)?;
        if response.status != 200 {
            return Err(format!("Qwen server returned HTTP {}. Check Settings and the remote machine.", response.status));
        }
        let (mut answer, mut calls, mut finished) = (String::new(), Vec::new(), false);
        let id = format!("{item}-{}", new_id());
        while let Some(line) = response.line().await.map_err(unreachable)? {
            let Ok(Value::Object(event)) = serde_json::from_str::<Value>(&line) else { continue };
            if let Some(error) = text(&event, "error") {
                return Err(error.to_owned());
            }
            let message = obj(event.get("message"));
            let delta = text(&message, "content").unwrap_or_default().to_owned();
            answer.push_str(&delta);
            calls.extend(message.get("tool_calls").and_then(Value::as_array).cloned().unwrap_or_default());
            if event.get("done") == Some(&Value::Bool(true)) {
                finished = true;
                let (input, output) = (event["prompt_eval_count"].as_u64().unwrap_or(0), event["eval_count"].as_u64().unwrap_or(0));
                self.state.borrow_mut().context_tokens = (input + output) as usize;
                self.emit("vcx/tokens", json!({"input": input, "output": output}));
            }
            self.emit("item/agentMessage/delta", json!({"itemId": id, "delta": delta}));
        }
        if !answer.is_empty() {
            self.emit("item/completed", json!({"item": {"id": id, "type": "agentMessage", "text": answer, "provider": "Qwen"}}));
        }
        // Ollama ends every answer with a done event; a stream closed before it was cut (runner reload, dropped proxy).
        if !finished {
            return Err("Qwen's answer was cut off: the server closed the stream before its final event. Send your message again.".into());
        }
        if answer.is_empty() && calls.is_empty() {
            return Err("Qwen returned an empty answer. Send your message again.".into());
        }
        Ok((answer, calls))
    }

    async fn command_result(&self, command: &str) -> Result<String, String> {
        let (id, cwd, thread, mode) = {
            let state = self.state.borrow();
            (new_id(), state.cwd.clone(), state.thread.clone(), state.mode.clone())
        };
        let (start, clock) = (now(), Instant::now());
        let item = json!({"id": id, "type": "commandExecution", "command": command, "cwd": cwd, "status": "inProgress", "stepStartedAt": start});
        self.emit("item/started", json!({"item": item}));
        let allowed = mode == "bypass" || {
            let (waiter, answer) = oneshot::channel();
            self.permissions.borrow_mut().insert(id.clone(), waiter);
            self.send(json!({"id": id, "method": "item/commandExecution/requestApproval", "params": {"threadId": thread, "command": command, "reason": format!("Qwen wants to run this command in {cwd}")}}));
            answer.await.unwrap_or(false)
        };
        self.emit("serverRequest/resolved", json!({"requestId": id}));
        if !allowed {
            self.emit("item/completed", json!({"item": {"id": id, "type": "commandExecution", "command": command, "status": "declined"}}));
            return Ok("The user declined this command. Do not retry it.".into());
        }
        self.state.borrow_mut().open.push(object(item));
        let (output, dropped, code) = self.run_command(command, &cwd, &thread).await.inspect_err(|_| self.close_open(&id, "failed"))?;
        self.state.borrow_mut().open.retain(|open| open["id"] != id.as_str());
        let done = object(json!({"id": id, "type": "commandExecution", "command": command, "cwd": cwd, "aggregatedOutput": qwen_text::tool_output(&output, dropped, SHOWN_OUTPUT_LIMIT),
            "exitCode": code, "status": if code == 0 { "completed" } else { "failed" }, "seconds": clock.elapsed().as_secs_f64().round() as i64}));
        let initial = self.options.cwd.clone();
        if let Some(folder) = directory::shell_directory(&done, &cwd, &initial, &[]) {
            self.state.borrow_mut().cwd = folder;
        }
        self.emit("item/completed", json!({"item": done}));
        Ok(format!("Exit: {code}\n{}", qwen_text::tool_output(&output, dropped, TOOL_OUTPUT_LIMIT)))
    }

    /// Runs `command` in a login zsh with stdout and stderr in one pipe; only the head and tail of a huge output are kept.
    async fn run_command(&self, command: &str, cwd: &str, thread: &str) -> Result<(String, usize, i32), String> {
        let (reader, writer) = std::io::pipe().map_err(|error| error.to_string())?;
        let mut process = tokio::process::Command::new("/bin/zsh");
        process.args(["-lc", command]).current_dir(cwd).stdin(Stdio::null()).process_group(0).kill_on_drop(true);
        if let Some(environment) = &self.options.environment {
            process.env_clear().envs(environment.iter().map(|(key, value)| (key, value)));
        }
        process.env("VCX_THREAD_ID", thread);
        process.stdout(writer.try_clone().map_err(|error| error.to_string())?).stderr(writer);
        let mut child = process.spawn().map_err(|error| format!("Cannot run the command: {error}"))?;
        drop(process);
        self.command.set(child.id().and_then(|pid| i32::try_from(pid).ok()));
        let capture = tokio::task::spawn_blocking(move || capture(reader));
        let status = child.wait().await.map_err(|error| error.to_string())?;
        self.command.set(None);
        let (output, dropped) = capture.await.map_err(|error| error.to_string())?;
        use std::os::unix::process::ExitStatusExt;
        Ok((output, dropped, status.code().or(status.signal()).unwrap_or(-1)))
    }

    pub fn respond(&self, id: &Value, result: Value) -> Result<(), AgentError> {
        let key = id.as_str().map_or_else(|| id.to_string(), str::to_owned);
        if let Some(waiter) = self.permissions.borrow_mut().remove(&key) {
            let _ = waiter.send(result["decision"] == "accept");
        }
        Ok(())
    }

    pub fn reject(&self, id: &Value) -> Result<(), AgentError> {
        self.respond(id, json!({"decision": "decline"}))
    }

    /// Stop: the running step or command ends, a permission waiting is declined, and the turn ends interrupted.
    fn interrupt(&self) {
        let Some(task) = self.task.borrow_mut().take() else { return };
        task.abort();
        if let Some(group) = self.command.take() {
            unsafe { libc::kill(-group, libc::SIGKILL) };
        }
        self.permissions.borrow_mut().clear();
        let open: Vec<(String, bool)> = self.state.borrow().open.iter().map(|item| (item["id"].as_str().unwrap_or_default().to_owned(), item["type"] == "reasoning")).collect();
        for (id, step) in open {
            self.close_open(&id, if step { "completed" } else { "failed" });
        }
        let current = self.state.borrow().turn.clone();
        self.emit("turn/completed", json!({"turn": {"id": current, "status": "interrupted"}}));
    }

    pub fn is_closed(&self) -> bool {
        self.closed.get()
    }

    pub fn close(&self) {
        if self.closed.replace(true) {
            return;
        }
        if let Some(task) = self.task.borrow_mut().take() {
            task.abort();
        }
        if let Some(group) = self.command.take() {
            unsafe { libc::kill(-group, libc::SIGKILL) };
        }
        self.permissions.borrow_mut().clear();
    }
}

fn capture(mut reader: std::io::PipeReader) -> (String, usize) {
    let (mut head, mut tail, mut dropped) = (Vec::new(), Vec::new(), 0);
    let mut buffer = [0u8; 16384];
    while let Ok(read) = reader.read(&mut buffer) {
        if read == 0 {
            break;
        }
        let data = &buffer[..read];
        let taken = (CAPTURE_END - head.len()).min(data.len());
        head.extend_from_slice(&data[..taken]);
        tail.extend_from_slice(&data[taken..]);
        if tail.len() > CAPTURE_END {
            let excess = tail.len() - CAPTURE_END;
            dropped += excess;
            tail.drain(..excess);
        }
    }
    head.extend(tail);
    (String::from_utf8_lossy(&head).into_owned(), dropped)
}

fn image(path: &str) -> Result<Value, AgentError> {
    use base64::Engine;
    let data = std::fs::read(path).map_err(|error| failure(format!("Cannot read the image: {error}")))?;
    if data.len() > IMAGE_LIMIT {
        return Err(failure("Image is larger than 20 MB."));
    }
    Ok(base64::engine::general_purpose::STANDARD.encode(data).into())
}
