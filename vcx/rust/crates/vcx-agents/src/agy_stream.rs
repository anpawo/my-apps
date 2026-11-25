//! Google's Antigravity CLI over the Agent Client Protocol (`agy acp`, JSON-RPC 2.0 on stdio), turned into the
//! Codex app-server events a session handles, as `AgyConnection` in `Agy.swift` does. No process here: the
//! connection feeds lines in and carries out the effects.

use crate::Object;
use crate::shape::{Effect, int, new_id, now, obj, object, text};
use serde_json::{Value, json};
use std::collections::HashMap;

pub struct AgyStream {
    pub thread: String,
    pub session: String,
    pub bypass: bool,
    pub models: Vec<String>,
    pub model: String,
    pub cwd: String,
    pub turn: Option<String>,
    message: Option<(String, String)>,
    thought: Option<(String, String, f64)>,
    /// Running tool calls in the order they started, so a turn's end closes them in that order.
    tools: Vec<(String, Object)>,
    permissions: HashMap<String, (Value, String, String)>,
}

impl AgyStream {
    pub fn new(cwd: &str) -> Self {
        Self {
            thread: String::new(),
            session: String::new(),
            bypass: true,
            models: Vec::new(),
            model: String::new(),
            cwd: cwd.into(),
            turn: None,
            message: None,
            thought: None,
            tools: Vec::new(),
            permissions: HashMap::new(),
        }
    }

    pub fn event(&self, method: &str, mut params: Object) -> Effect {
        params.insert("threadId".into(), self.thread.clone().into());
        Effect::Event(object(json!({"method": method, "params": params})))
    }

    /// Takes the answer to `session/new` or `session/resume`: the conversation and the models it offers.
    pub fn opened(&mut self, result: &Object, wanted: Option<&str>) -> Result<(), String> {
        self.session = text(result, "sessionId").or(wanted).unwrap_or_default().to_owned();
        if self.session.is_empty() {
            return Err("Antigravity did not return a conversation.".into());
        }
        self.thread = format!("agy:{}", self.session);
        let list = obj(result.get("models"));
        self.models = list.get("availableModels").and_then(Value::as_array).into_iter().flatten()
            .filter_map(|model| model.get("modelId").and_then(Value::as_str).map(str::to_owned)).collect();
        if let Some(current) = text(&list, "currentModelId") {
            self.model = current.to_owned();
        }
        Ok(())
    }

    pub fn start_turn(&mut self) -> (String, Effect) {
        let current = new_id();
        self.turn = Some(current.clone());
        let started = self.event("turn/started", object(json!({"turn": {"id": current}})));
        (current, started)
    }

    pub fn receive(&mut self, message: &Object) -> Vec<Effect> {
        let mut out = Vec::new();
        let method = text(message, "method");
        if method == Some("session/update") {
            let update = message.get("params").and_then(|p| p.get("update")).and_then(Value::as_object).cloned().unwrap_or_default();
            self.update(&update, &mut out);
            return out;
        }
        if let (Some(method), Some(id)) = (method, message.get("id")) {
            if method == "session/request_permission" {
                self.permission(id.clone(), &obj(message.get("params")), &mut out);
            } else {
                // No file system or terminal capability was offered, so agy has nothing else to ask.
                out.push(Effect::Write(object(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": format!("vcx does not support {method}")}}))));
            }
            return out;
        }
        let Some(id) = int(message.get("id")) else { return out };
        let outcome = match message.get("error") {
            Some(error) => Err(format!("Antigravity: {}", error.get("message").and_then(Value::as_str).unwrap_or("request failed"))),
            None => Ok(obj(message.get("result"))),
        };
        out.push(Effect::Resolve { request_id: id.to_string(), outcome });
        out
    }

    fn update(&mut self, value: &Object, out: &mut Vec<Effect>) {
        let content_text = || value.get("content").and_then(|c| c.get("text")).and_then(Value::as_str).unwrap_or_default().to_owned();
        match text(value, "sessionUpdate").unwrap_or_default() {
            "agent_message_chunk" => {
                self.end_thought(out);
                let piece = content_text();
                let (id, text) = self.message.get_or_insert_with(|| (new_id(), String::new()));
                text.push_str(&piece);
                let id = id.clone();
                out.push(self.event("item/agentMessage/delta", object(json!({"itemId": id, "delta": piece}))));
            }
            "agent_thought_chunk" => {
                let piece = content_text();
                if self.thought.is_none() {
                    let (id, start) = (new_id(), now());
                    self.thought = Some((id.clone(), String::new(), start));
                    out.push(self.event("item/started", object(json!({"item": {"id": id, "type": "reasoning", "description": "Thinking", "stepStartedAt": start}}))));
                }
                if let Some((_, text, _)) = self.thought.as_mut() {
                    text.push_str(&piece);
                }
            }
            "tool_call" | "tool_call_update" => {
                self.end_message(out);
                self.end_thought(out);
                let Some(id) = text(value, "toolCallId") else { return };
                let status = text(value, "status").unwrap_or_default();
                let finished = ["completed", "failed"].contains(&status);
                let known = self.tools.iter().position(|(tool, _)| tool == id);
                let Some(position) = known else {
                    let item = self.tool_item(value);
                    if !finished {
                        self.tools.push((id.to_owned(), item.clone()));
                        out.push(self.event("item/started", object(json!({"item": item}))));
                        return;
                    }
                    self.finish_tool(item, value, status, out);
                    return;
                };
                if finished {
                    let (_, item) = self.tools.remove(position);
                    self.finish_tool(item, value, status, out);
                }
            }
            "usage_update" => {
                let (used, limit) = (int(value.get("used")).unwrap_or(0), int(value.get("size")).unwrap_or(0));
                out.push(self.event("cx/context", object(json!({"used": used, "limit": limit, "model": self.model}))));
            }
            "current_model_update" => {
                if let Some(next) = text(value, "currentModelId").or_else(|| text(value, "modelId")) {
                    self.model = next.to_owned();
                    out.push(self.event("cx/model", object(json!({"model": next}))));
                }
            }
            _ => {}
        }
    }

    fn finish_tool(&self, mut item: Object, value: &Object, status: &str, out: &mut Vec<Effect>) {
        let raw = value.get("rawOutput").and_then(Value::as_object);
        let output = raw.and_then(|raw| text(raw, "output")).map(str::to_owned).unwrap_or_else(|| {
            value.get("content").and_then(Value::as_array).into_iter().flatten()
                .filter_map(|piece| piece.get("content").and_then(|c| c.get("text")).and_then(Value::as_str))
                .collect::<Vec<_>>().join("\n")
        });
        if text(&item, "type") == Some("commandExecution") {
            item.insert("aggregatedOutput".into(), output.into());
            let code = raw.and_then(|raw| int(raw.get("exit_code"))).unwrap_or(if status == "failed" { 1 } else { 0 });
            item.insert("exitCode".into(), code.into());
        }
        item.insert("status".into(), status.into());
        out.push(self.event("item/completed", object(json!({"item": item}))));
    }

    /// A shell call is shown as its command line; an edit as the files it changes; any other tool as its name over its input.
    fn tool_item(&self, value: &Object) -> Object {
        let id = text(value, "toolCallId").map_or_else(new_id, str::to_owned);
        let input = obj(value.get("rawInput"));
        let kind = text(value, "kind").unwrap_or_default();
        let diffs: Vec<&Value> = value.get("content").and_then(Value::as_array).into_iter().flatten().filter(|c| c.get("type").and_then(Value::as_str) == Some("diff")).collect();
        if kind == "edit" && !diffs.is_empty() {
            let changes: Vec<Value> = diffs.iter().map(|diff| {
                let lines = |key: &str, mark: char| diff.get(key).and_then(Value::as_str).unwrap_or_default().split('\n').map(|line| format!("{mark}{line}")).collect::<Vec<_>>();
                let mut all = lines("oldText", '-');
                all.extend(lines("newText", '+'));
                json!({"path": diff.get("path").and_then(Value::as_str).unwrap_or_default(), "kind": "update", "diff": all.join("\n")})
            }).collect();
            return object(json!({"id": id, "type": "fileChange", "changes": changes, "status": "inProgress"}));
        }
        let line = text(&input, "CommandLine").or_else(|| text(&input, "command"));
        let command = match line {
            Some(line) if kind == "execute" => line.to_owned(),
            _ => {
                let name = text(value, "name").or_else(|| text(value, "title")).unwrap_or("tool");
                // Keys sorted, as the Swift adapter prints them.
                let sorted: std::collections::BTreeMap<&String, &Value> = input.iter().collect();
                format!("{name}\n{}", serde_json::to_string(&sorted).unwrap_or_else(|_| "{}".into()))
            }
        };
        let description = if kind == "execute" { "" } else { text(value, "title").unwrap_or_default() };
        let cwd = text(&input, "Cwd").unwrap_or(&self.cwd);
        object(json!({"id": id, "type": "commandExecution", "command": command, "cwd": cwd, "status": "inProgress", "description": description, "stepStartedAt": now()}))
    }

    fn end_message(&mut self, out: &mut Vec<Effect>) {
        if let Some((id, text)) = self.message.take() {
            if !text.is_empty() {
                out.push(self.event("item/completed", object(json!({"item": {"id": id, "type": "agentMessage", "text": text, "provider": "Antigravity"}}))));
            }
        }
    }

    fn end_thought(&mut self, out: &mut Vec<Effect>) {
        if let Some((id, text, start)) = self.thought.take() {
            let seconds = (now() - start).round() as i64;
            out.push(self.event("item/completed", object(json!({"item": {"id": id, "type": "reasoning", "description": "Thinking", "summary": [text], "status": "completed", "seconds": seconds}}))));
        }
    }

    /// The prompt's answer ended the turn: what is still open closes, then `turn/completed`.
    pub fn finish_turn(&mut self, current: &str, outcome: Result<&Object, &str>) -> Vec<Effect> {
        let mut out = Vec::new();
        let (mut status, mut failure) = ("completed", None);
        match outcome {
            Ok(result) => {
                if text(result, "stopReason") == Some("cancelled") {
                    status = "interrupted";
                }
                let usage = obj(result.get("usage"));
                if let (Some(input), Some(output)) = (int(usage.get("inputTokens")), int(usage.get("outputTokens"))) {
                    out.push(self.event("cx/tokens", object(json!({"input": input, "output": output}))));
                }
            }
            Err(message) => {
                status = "failed";
                failure = Some(message.to_owned());
            }
        }
        self.end_message(&mut out);
        self.end_thought(&mut out);
        for (_, mut item) in std::mem::take(&mut self.tools) {
            item.insert("status".into(), if status == "completed" { "completed" } else { "failed" }.into());
            out.push(self.event("item/completed", object(json!({"item": item}))));
        }
        let mut turn = object(json!({"id": current, "status": status}));
        if let Some(failure) = failure {
            turn.insert("error".into(), json!({"message": failure}));
        }
        self.turn = None;
        out.push(self.event("turn/completed", object(json!({"turn": turn}))));
        out
    }

    fn permission(&mut self, rpc_id: Value, params: &Object, out: &mut Vec<Effect>) {
        let options: Vec<&Value> = params.get("options").and_then(Value::as_array).into_iter().flatten().collect();
        let option = |prefix: &str, fallback: &str| options.iter()
            .find(|option| option.get("kind").and_then(Value::as_str).unwrap_or_default().starts_with(prefix))
            .and_then(|option| option.get("optionId")).and_then(Value::as_str).unwrap_or(fallback).to_owned();
        let (allow, deny) = (option("allow", "allow"), option("reject", "deny"));
        if self.bypass {
            out.push(Effect::Write(answer(&rpc_id, &allow)));
            return;
        }
        let call = obj(params.get("toolCall"));
        let input = obj(call.get("rawInput"));
        let command = text(&input, "CommandLine").or_else(|| text(&call, "title")).or_else(|| text(&call, "name")).unwrap_or("an action").to_owned();
        let id = new_id();
        self.permissions.insert(id.clone(), (rpc_id, allow, deny));
        let reason = format!("Antigravity wants to run this in {}", self.cwd);
        out.push(Effect::Event(object(json!({"id": id, "method": "item/commandExecution/requestApproval", "params": {"threadId": self.thread, "command": command, "reason": reason}}))));
    }

    /// The session's answer to a permission: the line for agy, and the event that closes the card.
    pub fn respond(&mut self, id: &str, result: &Object) -> Vec<Effect> {
        let Some((rpc_id, allow, deny)) = self.permissions.remove(id) else { return Vec::new() };
        let option = if text(result, "decision") == Some("accept") { allow } else { deny };
        vec![self.event("serverRequest/resolved", object(json!({"requestId": id}))), Effect::Write(answer(&rpc_id, &option))]
    }

    pub fn reject(&mut self, id: &str) -> Vec<Effect> {
        let Some((rpc_id, _, deny)) = self.permissions.remove(id) else { return Vec::new() };
        vec![Effect::Write(answer(&rpc_id, &deny))]
    }

    pub fn forget_permissions(&mut self) {
        self.permissions.clear();
    }
}

fn answer(rpc_id: &Value, option: &str) -> Object {
    object(json!({"jsonrpc": "2.0", "id": rpc_id, "result": {"outcome": {"outcome": "selected", "optionId": option}}}))
}
