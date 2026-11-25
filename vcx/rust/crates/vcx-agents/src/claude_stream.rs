//! What `claude -p --output-format stream-json` prints, turned into the Codex app-server events a session handles,
//! as `ClaudeConnection.receive` does in `Agents.swift`. No process here: the connection feeds lines in and carries
//! out the effects, so a recorded stream replays through the same code.

use crate::Object;
use crate::directory::shell_directory;
use crate::shape::{Effect, int, new_id, now, number, obj, object, pretty, suffix, text};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

/// A tool result is kept to its last 16 KB, as the Swift adapter keeps it.
const TOOL_OUTPUT_CHARS: usize = 16_384;
const FIVE_HOURS_MINUTES: i64 = 300;
const SEVEN_DAYS_MINUTES: i64 = 10_080;
/// System lines Claude Code shows as a notice: a safeguard stop, a model fallback, a prompt a hook dropped.
const NOTICES: [&str; 5] = ["informational", "model_fallback", "model_consent_fallback", "model_refusal_fallback", "model_refusal_no_fallback"];

/// Where the adapter reads Claude's side files.
#[derive(Debug, Clone)]
pub struct ClaudePaths {
    /// The profile folder (`~/.claude` or the account's own).
    pub config: PathBuf,
    /// Claude's live session registry, one `<pid>.json` per running session.
    pub sessions: PathBuf,
    /// Where images a remote client sent are saved.
    pub attachments: PathBuf,
    /// Folders a `cd` may move into besides the conversation's own (`permissions.additionalDirectories`).
    pub added: Vec<String>,
}

impl ClaudePaths {
    pub fn standard(config: Option<PathBuf>) -> Self {
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
        let added = std::fs::read(home.join(".claude/settings.json"))
            .ok()
            .and_then(|data| serde_json::from_slice::<Value>(&data).ok())
            .and_then(|settings| settings.pointer("/permissions/additionalDirectories").cloned())
            .and_then(|list| serde_json::from_value(list).ok())
            .unwrap_or_default();
        Self {
            config: config.unwrap_or_else(|| home.join(".claude")),
            sessions: home.join(".claude/sessions"),
            attachments: home.join("Library/Application Support/VCX/Attachments"),
            added,
        }
    }
}

pub struct ClaudeStream {
    pub thread: String,
    pub model: String,
    pub cwd: String,
    pub initial_directory: String,
    pub turn: String,
    pub mode: String,
    pub stopped: bool,
    pub sending_now: bool,
    pub pending_users: Vec<String>,
    pub resent: HashMap<String, String>,
    pub steered: HashMap<String, Object>,
    pub metadata: Option<Object>,
    pub served_model: Option<String>,
    pub paths: ClaudePaths,
    tools: HashMap<String, Object>,
    controls: HashMap<String, Object>,
    blocks: BTreeMap<i64, (String, String)>,
    message_id: String,
    last_answer: String,
    limit: Option<Value>,
    rate_limited: bool,
    retrying: bool,
}

impl ClaudeStream {
    pub fn new(cwd: &str, mode: &str, paths: ClaudePaths) -> Self {
        Self {
            thread: format!("claude:{}", uuid::Uuid::new_v4()),
            model: "Claude".into(),
            cwd: cwd.into(),
            initial_directory: cwd.into(),
            turn: String::new(),
            mode: mode.into(),
            stopped: false,
            sending_now: false,
            pending_users: Vec::new(),
            resent: HashMap::new(),
            steered: HashMap::new(),
            metadata: None,
            served_model: None,
            paths,
            tools: HashMap::new(),
            controls: HashMap::new(),
            blocks: BTreeMap::new(),
            message_id: String::new(),
            last_answer: String::new(),
            limit: None,
            rate_limited: false,
            retrying: false,
        }
    }

    /// The conversation id Claude knows, without the `claude:` prefix.
    pub fn session_id(&self) -> &str {
        self.thread.strip_prefix("claude:").unwrap_or(&self.thread)
    }

    /// A new turn starts: what the last one left is cleared.
    pub fn begin_turn(&mut self) -> String {
        self.turn = new_id();
        self.stopped = false;
        self.last_answer.clear();
        self.limit = None;
        self.rate_limited = false;
        self.tools.clear();
        self.blocks.clear();
        self.pending_users.clear();
        self.steered.clear();
        self.turn.clone()
    }

    /// The line that sends a prompt, and `turn/started` unless it steers the running turn.
    pub fn prompt(&mut self, user_id: &str, content: Vec<Value>, steering: bool) -> (Object, Vec<Effect>) {
        let line = object(json!({"type": "user", "uuid": user_id, "message": {"role": "user", "content": content}}));
        let mut out = Vec::new();
        if steering {
            self.steered.insert(user_id.to_owned(), line.clone());
        } else {
            self.begin_turn();
        }
        self.pending_users.push(user_id.to_owned());
        if !steering {
            out.push(self.event("turn/started", object(json!({"turn": {"id": self.turn}}))));
        }
        (line, out)
    }

    /// The process was killed by a watch: what it held is gone.
    pub fn forget_process(&mut self) {
        self.pending_users.clear();
        self.tools.clear();
        self.controls.clear();
    }

    pub fn has_controls(&self) -> bool {
        !self.controls.is_empty()
    }

    pub fn event(&self, method: &str, mut params: Object) -> Effect {
        params.insert("threadId".into(), self.thread.clone().into());
        Effect::Event(object(json!({"method": method, "params": params})))
    }

    pub fn receive(&mut self, message: &Object) -> Vec<Effect> {
        let mut out = Vec::new();
        if message.get("parent_tool_use_id").is_some_and(Value::is_string) {
            return out;
        }
        let kind = text(message, "type").unwrap_or_default();
        let subtype = text(message, "subtype").unwrap_or_default();
        // The echo of a prompt is no answer: a resumed claude sends it for a prompt it will not run.
        let echo = kind == "user" && message.get("isReplay") == Some(&Value::Bool(true));
        if !echo && (["stream_event", "assistant", "result", "user", "control_request"].contains(&kind) || (kind == "system" && subtype == "api_retry")) {
            out.push(Effect::Answered);
        }
        if kind == "system" && subtype == "api_retry" {
            self.retrying = true;
            out.push(self.event("cx/apiRetry", object(json!({"delay": int(message.get("retry_delay_ms")).unwrap_or(0)}))));
        } else if self.retrying && ["stream_event", "assistant", "result", "user"].contains(&kind) {
            self.retrying = false;
            out.push(self.event("cx/apiRetry", object(json!({"done": true}))));
        }
        match kind {
            "control_response" => self.control_response(message, &mut out),
            "system" => self.system(message, subtype, &mut out),
            "control_cancel_request" => {
                if let Some(id) = text(message, "request_id") {
                    self.controls.remove(id);
                    out.push(self.event("serverRequest/resolved", object(json!({"requestId": id}))));
                }
            }
            // "queued" while a prompt waits for the running turn, "started" once the turn has taken it in.
            "command_lifecycle" => {
                if let Some(id) = text(message, "command_uuid") {
                    let id = self.resent.get(id).map_or(id, String::as_str);
                    out.push(self.event("cx/userQueue", object(json!({"id": id, "queued": text(message, "state") == Some("queued")}))));
                }
            }
            "control_request" => self.control_request(message, &mut out),
            "stream_event" => self.stream_event(message, &mut out),
            "assistant" => self.assistant(message, &mut out),
            "user" => self.user(message, &mut out),
            "rate_limit_event" => self.rate_limits(message, &mut out),
            "result" => self.result(message, &mut out),
            _ => {}
        }
        out
    }

    fn control_response(&mut self, message: &Object, out: &mut Vec<Effect>) {
        let response = obj(message.get("response"));
        let Some(id) = text(&response, "request_id") else { return };
        let outcome = if text(&response, "subtype") == Some("error") {
            Err(text(&response, "error").unwrap_or("Claude rejected the control request.").to_owned())
        } else {
            Ok(obj(response.get("response")))
        };
        out.push(Effect::Resolve { request_id: id.to_owned(), outcome });
    }

    fn system(&mut self, message: &Object, subtype: &str, out: &mut Vec<Effect>) {
        if subtype == "init" {
            if let Some(model) = text(message, "model") {
                self.model = model.to_owned();
                out.push(self.event("cx/model", object(json!({"model": model}))));
            }
        }
        if subtype == "background_tasks_changed" {
            let count = message.get("tasks").and_then(Value::as_array).map_or(0, Vec::len);
            out.push(self.event("cx/backgroundTasks", object(json!({"count": count}))));
        }
        if NOTICES.contains(&subtype) && text(message, "level") != Some("info") {
            if let Some(content) = text(message, "content").filter(|content| !content.is_empty()) {
                out.push(self.event("warning", object(json!({"message": content}))));
            }
        }
        // A refusal fallback swaps the session's model unless only a subagent or side question fell back.
        if subtype == "model_refusal_fallback" && text(message, "scope") != Some("local") {
            if let Some(model) = text(message, "fallback_model") {
                self.model = model.to_owned();
                out.push(self.event("cx/model", object(json!({"model": model}))));
            }
        }
        // Idle Claude answers a finished background task with a turn of its own.
        if subtype == "task_notification" && self.pending_users.is_empty() {
            self.turn = new_id();
            self.stopped = false;
            out.push(self.event("turn/started", object(json!({"turn": {"id": self.turn}}))));
        }
    }

    fn control_request(&mut self, message: &Object, out: &mut Vec<Effect>) {
        let (Some(id), Some(request)) = (text(message, "request_id"), message.get("request").and_then(Value::as_object)) else { return };
        if text(request, "subtype") != Some("can_use_tool") {
            out.push(Effect::Write(object(json!({"type": "control_response", "response": {"subtype": "error", "request_id": id, "error": "Unsupported control request"}}))));
            return;
        }
        self.controls.insert(id.to_owned(), request.clone());
        let name = text(request, "tool_name").unwrap_or("Tool");
        let input = obj(request.get("input"));
        // Claude still asks in bypass when it cannot parse a command safely; bypass means never ask.
        if self.mode == "bypass" && name != "AskUserQuestion" {
            if let Ok(line) = self.respond(id, &object(json!({"decision": "accept"}))) {
                out.push(Effect::Write(line));
            }
            return;
        }
        let command = text(&input, "command").map_or_else(|| format!("{name}\n{}", pretty(&Value::Object(input.clone()))), str::to_owned);
        let reason = text(request, "decision_reason").map_or_else(|| format!("Claude requests permission for {name}."), str::to_owned);
        let mut params = object(json!({"threadId": self.thread, "command": command, "reason": reason}));
        let method = if name == "AskUserQuestion" {
            let questions: Vec<Value> = input.get("questions").and_then(Value::as_array).cloned().unwrap_or_default().into_iter().enumerate()
                .map(|(n, mut question)| {
                    let id = question.get("question").and_then(Value::as_str).map_or_else(|| n.to_string(), str::to_owned);
                    if let Some(question) = question.as_object_mut() {
                        question.insert("id".into(), id.into());
                    }
                    question
                })
                .collect();
            params.insert("questions".into(), questions.into());
            "item/tool/requestUserInput"
        } else {
            "item/commandExecution/requestApproval"
        };
        out.push(Effect::Event(object(json!({"id": id, "method": method, "params": params}))));
    }

    fn stream_event(&mut self, message: &Object, out: &mut Vec<Effect>) {
        let event = obj(message.get("event"));
        let index = int(event.get("index")).unwrap_or(0);
        match text(&event, "type") {
            Some("message_start") => self.message_id = event.get("message").and_then(|m| m.get("id")).and_then(Value::as_str).map_or_else(new_id, str::to_owned),
            Some("content_block_start") => {
                let block = obj(event.get("content_block"));
                if text(&block, "type") == Some("text") {
                    let id = format!("{}-{index}", self.message_id);
                    let start = text(&block, "text").unwrap_or_default().to_owned();
                    self.blocks.insert(index, (id.clone(), start.clone()));
                    out.push(self.event("item/started", object(json!({"item": {"id": id, "type": "agentMessage", "text": start, "provider": "Claude"}}))));
                }
            }
            Some("content_block_delta") => {
                let delta = obj(event.get("delta"));
                if let (Some(piece), Some(block)) = (text(&delta, "text"), self.blocks.get_mut(&index)) {
                    block.1.push_str(piece);
                    let id = block.0.clone();
                    out.push(self.event("item/agentMessage/delta", object(json!({"itemId": id, "delta": piece}))));
                }
            }
            _ => {}
        }
    }

    fn assistant(&mut self, message: &Object, out: &mut Vec<Effect>) {
        if text(message, "error") == Some("rate_limit") {
            // Only the plan's own limit says usage_limit_reached; a server throttle or capacity 429 is retried on the same account.
            if text(message, "api_error") == Some("usage_limit_reached") {
                self.limit = Some(message.get("api_error_params").and_then(|p| p.get("rate_limit_info")).filter(|v| v.is_object()).cloned().unwrap_or_else(|| json!({"error": "usage_limit_reached"})));
            } else {
                self.rate_limited = true;
            }
            return;
        }
        let body = obj(message.get("message"));
        let id = text(&body, "id").map_or_else(new_id, str::to_owned);
        if let Some(usage) = body.get("usage").and_then(Value::as_object) {
            self.served_model = text(&body, "model").map(str::to_owned).or_else(|| self.served_model.clone());
            let model = self.served_model.clone().unwrap_or_else(|| self.model.clone());
            out.push(self.event("cx/context", object(json!({"used": input_tokens(usage), "model": model}))));
        }
        for (index, block) in body.get("content").and_then(Value::as_array).cloned().unwrap_or_default().iter().enumerate() {
            let block = obj(Some(block));
            if text(&block, "type") == Some("text") {
                let Some(answer) = text(&block, "text") else { continue };
                self.last_answer = answer.to_owned();
                // Each assistant event holds one block, so its index is 0 even when the stream put a thinking block first.
                let prefix = format!("{id}-");
                let streamed = self.blocks.iter().find(|(_, (block, _))| block.starts_with(&prefix)).map(|(key, _)| *key).and_then(|key| self.blocks.remove(&key)).map(|(block, _)| block);
                let item_id = streamed.unwrap_or_else(|| format!("{id}-{index}"));
                out.push(self.event("item/completed", object(json!({"item": {"id": item_id, "type": "agentMessage", "text": answer, "provider": "Claude"}}))));
            } else if text(&block, "type") == Some("tool_use") {
                let Some(tool_id) = text(&block, "id") else { continue };
                let input = obj(block.get("input"));
                let name = text(&block, "name").unwrap_or("Tool");
                let command = text(&input, "command").map_or_else(|| format!("{name}\n{}", pretty(&Value::Object(input.clone()))), str::to_owned);
                let mut tool = object(json!({"id": tool_id, "type": "commandExecution", "command": command, "cwd": self.cwd, "status": "inProgress"}));
                if name == "Bash" {
                    if let Some(description) = text(&input, "description") {
                        tool.insert("description".into(), description.into());
                    }
                }
                if name == "SendMessage" {
                    let to = text(&input, "to").unwrap_or_default();
                    let subagent = subagent_name(to, self.session_id(), &self.paths.config);
                    tool = peer_item(tool_id, "sent", to, None, text(&input, "message").unwrap_or_default(), subagent, &self.paths.sessions);
                }
                self.tools.insert(tool_id.to_owned(), tool.clone());
                out.push(self.event("item/started", object(json!({"item": tool}))));
            }
        }
    }

    fn user(&mut self, message: &Object, out: &mut Vec<Effect>) {
        let origin = obj(message.get("origin"));
        // Replayed prompts come back too; only a peer session's message has an origin.
        if text(&origin, "kind") == Some("peer") {
            self.open_turn_if_idle(out);
            let id = text(message, "uuid").map_or_else(new_id, str::to_owned);
            let item = peer_item(&id, "received", text(&origin, "name").unwrap_or_default(), int(origin.get("verifiedPeerPid")), text(&origin, "body").unwrap_or_default(), None, &self.paths.sessions);
            out.push(self.event("item/completed", object(json!({"item": item}))));
            return;
        }
        // A prompt typed in another Remote Control client (the phone app): VCX did not send it, so it has no row yet.
        if text(&origin, "kind") == Some("human") {
            if let Some(id) = text(message, "uuid").filter(|id| !self.pending_users.iter().any(|pending| pending == id)) {
                self.open_turn_if_idle(out);
                let content = remote_content(message, &self.paths.attachments);
                out.push(self.event("item/completed", object(json!({"item": {"id": id, "type": "userMessage", "content": content, "sentAt": now()}}))));
                return;
            }
        }
        let blocks = message.get("message").and_then(|m| m.get("content")).and_then(Value::as_array).cloned().unwrap_or_default();
        for block in blocks {
            let block = obj(Some(&block));
            let Some(id) = text(&block, "tool_use_id") else { continue };
            let Some(mut tool) = self.tools.get(id).cloned() else { continue };
            let output = match block.get("content") {
                Some(Value::String(output)) => output.clone(),
                other => pretty(other.unwrap_or(&Value::String(String::new()))),
            };
            tool.insert("aggregatedOutput".into(), suffix(&output, TOOL_OUTPUT_CHARS).into());
            let failed = block.get("is_error") == Some(&Value::Bool(true));
            tool.insert("status".into(), if failed { "failed" } else { "completed" }.into());
            if let Some(directory) = shell_directory(&tool, &self.cwd, &self.initial_directory, &self.paths.added) {
                self.cwd = directory;
            }
            self.tools.insert(id.to_owned(), tool.clone());
            out.push(self.event("item/completed", object(json!({"item": tool}))));
        }
    }

    fn open_turn_if_idle(&mut self, out: &mut Vec<Effect>) {
        if self.pending_users.is_empty() {
            self.turn = new_id();
            self.stopped = false;
            out.push(self.event("turn/started", object(json!({"turn": {"id": self.turn}}))));
        }
    }

    fn rate_limits(&mut self, message: &Object, out: &mut Vec<Effect>) {
        let info = obj(message.get("rate_limit_info"));
        // The stream carries the plan windows; polling /api/oauth/usage from every session gets HTTP 429.
        let mut limits = Object::new();
        for (source, target, minutes) in [("five_hour", "primary", FIVE_HOURS_MINUTES), ("seven_day", "secondary", SEVEN_DAYS_MINUTES)] {
            let window = info.get("unifiedWindows").and_then(|w| w.get(source));
            let Some(used) = window.and_then(|w| w.get("utilization")).and_then(Value::as_f64) else { continue };
            let mut rate = object(json!({"usedPercent": used * 100.0, "windowDurationMins": minutes}));
            if let Some(reset) = window.and_then(|w| w.get("resetsAt")).and_then(Value::as_f64) {
                rate.insert("resetsAt".into(), reset.into());
            }
            limits.insert(target.into(), rate.into());
        }
        if !limits.is_empty() {
            out.push(self.event("account/rateLimits/updated", object(json!({"rateLimits": limits}))));
        }
        if text(&info, "status") == Some("rejected") {
            self.limit = Some(Value::Object(info));
        }
    }

    fn result(&mut self, message: &Object, out: &mut Vec<Effect>) {
        // `model` can be "Claude" or an alias; modelUsage is keyed by the model that served the turn.
        let served = self.served_model.clone().unwrap_or_else(|| self.model.clone());
        let usage_of = |key: &str| message.get("modelUsage").and_then(|m| m.get(key)).and_then(|m| m.get("contextWindow")).and_then(Value::as_i64);
        if let Some(limit) = usage_of(&served).or_else(|| usage_of(&self.model)) {
            out.push(self.event("cx/context", object(json!({"limit": limit, "model": served}))));
        }
        if let Some(usage) = message.get("usage").and_then(Value::as_object) {
            let output = int(usage.get("output_tokens")).unwrap_or(0);
            out.push(self.event("cx/tokens", object(json!({"input": input_tokens(usage), "output": output}))));
        }
        if let Some(limit) = self.limit.clone() {
            out.push(self.event("cx/limit", object(json!({"limit": limit}))));
            return;
        }
        if usage_limit(message) {
            out.push(self.event("cx/limit", object(json!({"limit": message}))));
            return;
        }
        let ids: Vec<String> = match message.get("user_message_uuids").and_then(Value::as_array) {
            Some(list) => list.iter().filter_map(Value::as_str).map(str::to_owned).collect(),
            None => text(message, "user_message_uuid").map(|id| vec![id.to_owned()]).unwrap_or_default(),
        };
        if ids.is_empty() {
            if !self.pending_users.is_empty() {
                self.pending_users.remove(0);
            }
        } else {
            self.pending_users.retain(|id| !ids.contains(id));
        }
        let queued = int(message.get("queued_turn_count"));
        let is_error = message.get("is_error") == Some(&Value::Bool(true));
        // The turn send-now stopped ends in error_during_execution with queued_turn_count 0 (claude 2.1.322),
        // then the waiting prompt runs: the VCX turn stays open for it.
        if self.sending_now && is_error {
            self.sending_now = false;
            return;
        }
        let failed = self.rate_limited || is_error;
        if queued == Some(0) || self.stopped || failed {
            self.pending_users.clear();
        }
        if !self.pending_users.is_empty() || queued.unwrap_or(0) > 0 {
            return;
        }
        out.push(Effect::TurnEnded);
        let mut turn = object(json!({"id": self.turn, "status": if self.stopped { "interrupted" } else { "completed" }}));
        if failed {
            let reason = text(message, "result").unwrap_or("Claude did not finish the turn.");
            turn.insert("error".into(), json!({"message": reason, "rateLimited": self.rate_limited}));
        }
        out.push(self.event("turn/completed", object(json!({"turn": turn}))));
    }

    /// The line answering a permission or question Claude asked, from the session's `{decision}` or `{answers}`.
    pub fn respond(&mut self, id: &str, result: &Object) -> Result<Object, String> {
        let request = self.controls.get(id).ok_or_else(|| "This Claude request has expired.".to_owned())?;
        let mut updated = obj(request.get("input"));
        let answers = result.get("answers").and_then(Value::as_object).filter(|answers| !answers.is_empty());
        let response = if let Some(answers) = answers {
            let joined: Object = answers.iter().map(|(key, value)| {
                let list: Vec<&str> = value.get("answers").and_then(Value::as_array).map(|l| l.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
                (key.clone(), Value::String(list.join(", ")))
            }).collect();
            updated.insert("answers".into(), joined.into());
            json!({"behavior": "allow", "updatedInput": updated})
        } else if text(result, "decision") == Some("accept") {
            json!({"behavior": "allow", "updatedInput": updated})
        } else {
            json!({"behavior": "deny", "message": "The user declined this action."})
        };
        self.controls.remove(id);
        Ok(object(json!({"type": "control_response", "response": {"subtype": "success", "request_id": id, "response": response}})))
    }
}

/// A user or project skill is tagged so at the end of its description; only those come from `reload_skills`.
pub fn reloaded_commands(commands: &[Value], fresh: &[Value]) -> Vec<Value> {
    let local = |command: &Value| command.get("description").and_then(Value::as_str).is_some_and(|d| d.ends_with("(user)") || d.ends_with("(project)"));
    let kept: Vec<Value> = commands.iter().filter(|c| !local(c)).cloned().collect();
    let names: Vec<&str> = kept.iter().filter_map(|c| c.get("name").and_then(Value::as_str)).collect();
    let added: Vec<Value> = fresh.iter().filter(|c| local(c) && !names.contains(&c.get("name").and_then(Value::as_str).unwrap_or_default())).cloned().collect();
    kept.into_iter().chain(added).collect()
}

/// A failed turn's error object holds the provider's own words ("not your usage limit"); only its codes are read.
pub fn usage_limit(value: &Object) -> bool {
    let error = value.get("error");
    let code = error.and_then(|e| e.get("codexErrorInfo")).filter(|v| !v.is_null())
        .or_else(|| value.get("codexErrorInfo"))
        .or_else(|| error.filter(|e| !e.is_object()))
        .or_else(|| value.get("subtype"));
    let text = match code {
        Some(Value::String(text)) => text.to_lowercase(),
        Some(other) => other.to_string().to_lowercase(),
        None => String::new(),
    };
    ["usagelimitexceeded", "usage_limit", "usage limit"].iter().any(|word| text.contains(word))
}

/// SendMessage names a peer by its ListAgents name, maybe followed by " [ref]", or by its uds:/…/<pid>.sock address.
pub fn peer_item(id: &str, direction: &str, peer: &str, pid: Option<i64>, text_body: &str, subagent: Option<String>, sessions: &Path) -> Object {
    let name = peer.split(" [").next().unwrap_or_default();
    let mut pid = pid.or_else(|| socket_pid(name));
    let mut entry = pid.and_then(|pid| registry(sessions, pid));
    if pid.is_none() {
        entry = std::fs::read_dir(sessions).into_iter().flatten().flatten()
            .filter_map(|file| file.file_name().to_str()?.strip_suffix(".json")?.parse::<i64>().ok())
            .filter_map(|pid| registry(sessions, pid))
            .filter(|entry| text(entry, "name") == Some(name) && int(entry.get("pid")).is_some_and(|pid| pid > 0 && alive(pid)))
            .max_by(|a, b| number(a.get("startedAt")).total_cmp(&number(b.get("startedAt"))));
        pid = entry.as_ref().and_then(|entry| int(entry.get("pid")));
    }
    let shown = entry.as_ref().and_then(|entry| text(entry, "name")).map(str::to_owned).or(subagent)
        .unwrap_or_else(|| if name.starts_with("uds:") { "another session".into() } else { name.to_owned() });
    let status = if direction == "sent" { "inProgress" } else { "completed" };
    let mut item = object(json!({"id": id, "type": "peerMessage", "direction": direction, "name": shown, "text": text_body, "status": status}));
    if let (Some(pid), Some(started)) = (pid, entry.as_ref().and_then(|entry| entry.get("startedAt"))) {
        item.insert("pid".into(), pid.into());
        item.insert("startedAt".into(), started.clone());
    }
    item
}

/// A subagent is addressed by its agent ID; Fleet names it by the description its spawn gave it, as here.
pub fn subagent_name(id: &str, session: &str, config: &Path) -> Option<String> {
    if id.is_empty() || id.contains('/') {
        return None;
    }
    let projects = config.join("projects");
    for project in std::fs::read_dir(&projects).ok()?.flatten() {
        let file = project.path().join(session).join("subagents").join(format!("agent-{id}.meta.json"));
        let Some(meta) = std::fs::read(file).ok().and_then(|data| serde_json::from_slice::<Object>(&data).ok()) else { continue };
        return text(&meta, "description").filter(|d| !d.is_empty()).or_else(|| text(&meta, "agentType")).map(str::to_owned);
    }
    None
}

fn socket_pid(name: &str) -> Option<i64> {
    let file = name.strip_prefix("uds:")?.rsplit('/').next()?;
    file.strip_suffix(".sock")?.parse().ok()
}

fn registry(sessions: &Path, pid: i64) -> Option<Object> {
    serde_json::from_slice(&std::fs::read(sessions.join(format!("{pid}.json"))).ok()?).ok()
}

fn alive(pid: i64) -> bool {
    i32::try_from(pid).is_ok_and(|pid| unsafe { libc::kill(pid, 0) } == 0)
}

/// The text and images of a prompt another client sent; images are saved as files the session can show.
fn remote_content(message: &Object, attachments: &Path) -> Vec<Value> {
    use base64::Engine;
    let body = message.get("message").and_then(|m| m.get("content"));
    if let Some(Value::String(text)) = body {
        return vec![json!({"type": "text", "text": text})];
    }
    let blocks = body.and_then(Value::as_array).cloned().unwrap_or_default();
    blocks.iter().filter_map(|block| {
        let kind = block.get("type").and_then(Value::as_str);
        if kind == Some("text") {
            return Some(json!({"type": "text", "text": block.get("text").and_then(Value::as_str).unwrap_or_default()}));
        }
        let source = block.get("source").filter(|_| kind == Some("image"))?;
        let data = base64::engine::general_purpose::STANDARD.decode(source.get("data")?.as_str()?).ok()?;
        let extension = match source.get("media_type").and_then(Value::as_str) {
            Some("image/jpeg") => "jpg",
            Some("image/gif") => "gif",
            Some("image/webp") => "webp",
            _ => "png",
        };
        let path = attachments.join(format!("{}.{extension}", uuid::Uuid::new_v4().to_string().to_uppercase()));
        match save_private(&path, &data) {
            Ok(()) => Some(json!({"type": "localImage", "path": path.to_string_lossy()})),
            Err(error) => Some(json!({"type": "text", "text": format!("[image not saved: {error}]")})),
        }
    }).collect()
}

fn save_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    use std::io::Write;
    if let Some(folder) = path.parent() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(folder)?;
    }
    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?.write_all(data)
}

pub(crate) fn input_tokens(usage: &Object) -> i64 {
    ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].iter().filter_map(|key| int(usage.get(*key))).sum()
}

