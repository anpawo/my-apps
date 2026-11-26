//! One conversation as its worker holds it, ported from the Swift `Session` without its display: rows of
//! provider-shaped items, the metadata a frontend reads, and what changed since the last patch.

use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap, HashSet};
use crate::recall;
use vcx_agents::claude_stream::usage_limit;
use vcx_agents::qwen_text::strip_recall;
use vcx_agents::{Event, Kind, Stream, TurnStatus};
use vcx_model::item;

pub type Object = serde_json::Map<String, Value>;

/// Tool output kept in the session; the complete output stays in the provider's history.
const MAX_OUTPUT_CHARS: usize = 16_384;
const STATUS_TITLE_CHARS: usize = 100;
const DEBATE_SCRIPTS: [&str; 7] = ["ask-codex.sh", "ask-qwen.sh", "ask-agy.sh", "ask-gemini.sh", "ask-grok.sh", "ask-muse.sh", "ask-meta.sh"];
const ASKED_REQUESTS: [&str; 3] = ["item/tool/requestUserInput", "item/commandExecution/requestApproval", "item/fileChange/requestApproval"];
const OWN_ROW_ITEMS: [&str; 3] = ["agentMessage", "plan", "userMessage"];
const HIDDEN_ITEMS: [&str; 2] = ["hookPrompt", "contextCompaction"];
pub const RECOVERED_NOTICE: &str = "Recovered saved conversation and unsent draft. The runtime was interrupted; previous tools were not replayed.";

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Row {
    pub id: String,
    pub kind: String,
    pub items: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Permission {
    pub id: String,
    /// The agent's request id exactly as it came: a number stays a number.
    pub rpc_id: Value,
    pub method: String,
    pub params: Object,
}

/// What the session asks of its driver after an event.
#[derive(Debug, PartialEq)]
pub enum Effect {
    Decline { id: Value, method: String },
    Stop,
    /// The plan's usage limit stopped the turn: its account rests and the next available one takes the prompt.
    Limit(Object),
    /// A server rate limit failed the turn: the same account retries it after a wait.
    RateLimited,
    /// The agent stopped on its own (why, its last error line, its log): it is restarted on its conversation.
    Crashed(Object),
    /// Claude could not find the conversation it was asked to resume: a new one takes the recent messages.
    ResumeFailed,
    /// The network may be gone (why): the process probes it until it answers.
    Offline(&'static str),
    /// A step stopped because it waited on a request sent while the network was down: the agent is told to go on.
    KeepGoing,
}

/// A prompt on its way: the row is already shown, the request not yet answered.
#[derive(Debug, Clone)]
pub struct Outgoing {
    pub id: String,
    pub method: &'static str,
    pub params: Value,
    was_busy: bool,
    saved_draft: Vec<Value>,
}

// Serialized whole for a live update (`swap.rs`); a field the frozen image did not have starts at its default.
#[derive(Debug, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Session {
    pub cwd: String,
    pub conversation_directory: String,
    pub state_directory: String,
    pub provider: String,
    pub provider_label: String,
    pub account: Value,
    pub model: String,
    pub status: String,
    pub ready: bool,
    pub busy: bool,
    pub needs_attention: bool,
    pub changing: bool,
    pub background_tasks: i64,
    pub active_actions: Vec<String>,
    pub context: String,
    pub usage: String,
    pub usage_loading: bool,
    pub usage_percent: Option<f64>,
    pub tokens: String,
    pub context_used: Option<i64>,
    pub context_limit: Option<i64>,
    pub models: Vec<String>,
    pub model_efforts: Object,
    pub model_default_efforts: Object,
    pub record_id: String,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
    pub effort: Option<String>,
    pub default_effort: Option<String>,
    pub active_mode: String,
    pub planning: bool,
    pub conversation_name: Option<String>,
    pub native_history_path: Option<String>,
    pub archive_service: String,
    pub permissions: Vec<Permission>,
    pub stop_requested: bool,
    pub stop_source: Option<String>,
    pub draft: Vec<Value>,
    pub draft_generation: i64,
    /// The prompt of the running turn, guidance included, sent again to a fallback account.
    pub pending_input: Option<(String, Vec<String>)>,
    /// The recent conversation a newly connected agent gets before its first prompt.
    pub injected_context: String,
    /// Retries sent on their own since the last turn that went well.
    pub auto_resumes: usize,
    /// Codex takes a changed permission mode with the next turn.
    pub mode_override: bool,
    /// The ERRORS lines recalled for this conversation's prompts, and the heading each sits under.
    pub recalled_rules: Vec<String>,
    pub recalled_sections: Object,
    /// The agent stopped or could not start: it reconnects once the network comes back from a real drop.
    pub lost_connection: bool,
    /// A turn the network killed continues once the network is back.
    pub resume_when_back: bool,
    /// When the API retry the agent announced is due (seconds since 1970), until the API answers.
    pub retry_attempt: Option<f64>,
    /// The running step was stopped because its retry hung on a dead network.
    pub retry_stopped: bool,
    draft_revision: u64,
    rows: Vec<Row>,
    items: HashMap<String, Object>,
    seen: HashSet<String>,
    group: Option<String>,
    deltas: Vec<(String, String)>,
    turn_prompt: Option<String>,
    dirty_items: BTreeSet<String>,
    dirty_rows: BTreeSet<String>,
    order_dirty: bool,
    last_meta: Option<Object>,
    published_draft: Option<(u64, i64)>,
}

/// What Codex is asked for in `mode`: `bypass` runs everything, any other mode asks first.
pub fn approval_policy(mode: &str) -> &'static str {
    if mode == "bypass" { "never" } else { "on-request" }
}

pub fn sandbox(mode: &str) -> &'static str {
    if mode == "bypass" { "danger-full-access" } else { "workspace-write" }
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

fn text<'a>(object: &'a Object, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

impl Session {
    pub fn new(cwd: &str, state_directory: &str) -> Self {
        Self {
            cwd: cwd.to_owned(),
            conversation_directory: cwd.to_owned(),
            state_directory: state_directory.to_owned(),
            provider: "codex".into(),
            provider_label: "Codex".into(),
            account: json!({"id": "codex-default", "name": "Default Codex", "provider": "codex"}),
            model: "Codex".into(),
            status: "Starting…".into(),
            usage_loading: true,
            record_id: new_id(),
            active_mode: "bypass".into(),
            ..Self::default()
        }
    }

    pub fn rows(&self) -> &[Row] {
        &self.rows
    }

    pub fn item(&self, id: &str) -> Option<&Object> {
        self.items.get(id)
    }

    pub fn metadata(&self) -> Object {
        let permissions: Vec<Value> = self.permissions.iter().map(|p| json!({"id": p.id, "rpcID": p.rpc_id, "method": p.method, "params": p.params})).collect();
        let value = json!({
            "cwd": self.cwd, "conversationDirectory": self.conversation_directory, "stateDirectory": self.state_directory,
            "model": self.model, "status": self.status, "ready": self.ready, "busy": self.busy, "needsAttention": self.needs_attention,
            "backgroundTasks": self.background_tasks, "changing": self.changing, "activeActions": self.active_actions, "context": self.context,
            "usage": self.usage, "usageLoading": self.usage_loading, "tokens": self.tokens, "repository": "", "branch": "",
            "repositoryStatus": "", "repositoryChanges": [], "pullRequest": "", "pullRequestURL": "", "hooks": [], "skills": [], "builtinCommands": [],
            "mcp": [], "instructions": [], "activeMode": self.active_mode, "providerLabel": self.provider_label, "models": self.models,
            "modelEfforts": self.model_efforts, "modelDefaultEfforts": self.model_default_efforts, "modelAliases": {}, "planning": self.planning,
            "skillPaths": {}, "legacyCommandPaths": {}, "recordID": self.record_id, "recalledRules": self.recalled_rules, "recalledRuleSections": self.recalled_sections, "recent": [], "permissions": permissions,
            "providerCommands": [], "account": self.account, "nativeSources": [], "archiveClientVersions": {},
            "nativeHistoryPath": self.native_history_path, "archiveService": self.archive_service, "threadID": self.thread_id, "turnID": self.turn_id,
            "effort": self.effort, "defaultEffort": self.default_effort, "usagePercent": self.usage_percent, "contextUsed": self.context_used,
            "contextLimit": self.context_limit, "repositoryDirectory": null, "conversationName": self.conversation_name,
        });
        let Value::Object(object) = value else { unreachable!("a JSON object literal") };
        object
    }

    pub fn snapshot(&mut self) -> Object {
        self.flush();
        let mut value = self.metadata();
        let rows: Vec<Value> = self.rows.iter().map(|row| json!({"id": row.id, "kind": row.kind, "items": row.items.iter().filter_map(|id| self.items.get(id)).collect::<Vec<_>>()})).collect();
        value.insert("rows".into(), Value::Array(rows));
        value.insert("draft".into(), Value::Array(self.draft.clone()));
        value.insert("draftGeneration".into(), json!(self.draft_generation));
        value
    }

    /// What changed since the last patch, or `None` when nothing did. The first call sends the metadata whole.
    pub fn take_patch(&mut self) -> Option<Object> {
        self.flush();
        let mut patch = Object::new();
        let meta = self.metadata();
        if self.last_meta.as_ref() != Some(&meta) {
            patch.insert("meta".into(), Value::Object(meta.clone()));
            self.last_meta = Some(meta);
        }
        if std::mem::take(&mut self.order_dirty) {
            patch.insert("rowOrder".into(), json!(self.rows.iter().map(|row| &row.id).collect::<Vec<_>>()));
        }
        let dirty_rows = std::mem::take(&mut self.dirty_rows);
        let updates: Vec<Value> = self.rows.iter().filter(|row| dirty_rows.contains(&row.id)).map(|row| json!({"id": row.id, "kind": row.kind, "itemIDs": row.items})).collect();
        if !updates.is_empty() {
            patch.insert("rowUpdates".into(), Value::Array(updates));
        }
        let changed: Vec<Value> = std::mem::take(&mut self.dirty_items).iter().filter_map(|id| self.items.get(id)).map(|item| Value::Object(item.clone())).collect();
        if !changed.is_empty() {
            patch.insert("items".into(), Value::Array(changed));
        }
        if self.published_draft != Some((self.draft_revision, self.draft_generation)) {
            patch.insert("draft".into(), Value::Array(self.draft.clone()));
            patch.insert("draftGeneration".into(), json!(self.draft_generation));
            self.published_draft = Some((self.draft_revision, self.draft_generation));
        }
        (!patch.is_empty()).then_some(patch)
    }

    /// Marks the current state as sent, as an attach snapshot does.
    pub fn mark_published(&mut self) {
        self.flush();
        self.last_meta = Some(self.metadata());
        self.order_dirty = false;
        self.dirty_rows.clear();
        self.dirty_items.clear();
        self.published_draft = Some((self.draft_revision, self.draft_generation));
    }

    pub fn set_draft(&mut self, draft: Vec<Value>, generation: i64) {
        self.draft = draft;
        self.draft_generation = generation;
        self.draft_revision += 1;
    }

    fn insert_row(&mut self, index: usize, kind: &str, items: Vec<String>) -> String {
        let id = new_id();
        self.dirty_rows.insert(id.clone());
        self.dirty_items.extend(items.iter().cloned());
        self.rows.insert(index, Row { id: id.clone(), kind: kind.to_owned(), items });
        self.order_dirty = true;
        id
    }

    fn remove_row(&mut self, id: &str) {
        let Some(index) = self.rows.iter().position(|row| row.id == id) else { return };
        let row = self.rows.remove(index);
        for item in row.items {
            self.items.remove(&item);
        }
        if self.group.as_deref() == Some(id) {
            self.group = None;
        }
        self.order_dirty = true;
    }

    fn set_item(&mut self, id: &str, data: Object) {
        self.items.insert(id.to_owned(), data);
        self.dirty_items.insert(id.to_owned());
    }

    pub fn notice(&mut self, message: &str) {
        self.notice_linked(message, None);
    }

    /// A notice that opens `link` (an agent's log) when clicked.
    pub fn notice_linked(&mut self, message: &str, link: Option<&str>) {
        let id = new_id();
        let mut data = json!({"id": id, "type": "notice", "text": message});
        if let Some(link) = link {
            data["link"] = json!(link);
        }
        self.set_item(&id, data.as_object().cloned().unwrap_or_default());
        let index = self.rows.len();
        self.insert_row(index, "notice", vec![id]);
    }

    /// A prompt comes back with the recalled ERRORS note the worker added: the note goes, its lines stay on the item.
    fn strip_recalled(&mut self, data: &mut Object) {
        let Some(Value::Array(content)) = data.get("content").filter(|_| text(data, "type") == Some("userMessage")) else { return };
        let mut lines = Vec::new();
        let mut kept = Vec::new();
        for piece in content {
            match piece.get("text").and_then(Value::as_str).filter(|text| text.contains(recall::MARKER)) {
                Some(text) => {
                    lines.extend(recall::lines(text));
                    let request = strip_recall(text).trim();
                    if !request.is_empty() {
                        let mut piece = piece.clone();
                        piece["text"] = json!(request);
                        kept.push(piece);
                    }
                }
                None => kept.push(piece.clone()),
            }
        }
        if lines.is_empty() {
            return;
        }
        data.insert("content".into(), Value::Array(kept));
        data.insert("recalled".into(), json!(lines));
        for line in lines {
            if !self.recalled_rules.contains(&line) {
                self.recalled_rules.push(line);
            }
        }
    }

    /// The ERRORS lines sent with prompt `id`, with the section each sits under when its file names one.
    pub fn recalled(&mut self, id: &str, lines: &[String], sections: Vec<(String, String)>) {
        if let Some(item) = self.items.get(id).cloned() {
            let mut item = item;
            item.insert("recalled".into(), json!(lines));
            self.set_item(id, item);
        }
        for line in lines {
            if !self.recalled_rules.contains(line) {
                self.recalled_rules.push(line.clone());
            }
        }
        for (rule, section) in sections {
            self.recalled_sections.insert(rule, json!(section));
        }
    }

    /// Adds or updates one provider item, grouping tools into the activity row under the last prompt.
    pub fn show(&mut self, source: &Object) {
        let mut data = source.clone();
        self.strip_recalled(&mut data);
        if text(&data, "type") == Some("agentMessage") && !data.contains_key("provider") {
            data.insert("provider".into(), json!(self.provider_label));
        }
        let (Some(id), Some(kind)) = (text(&data, "id").map(str::to_owned), text(&data, "type").map(str::to_owned)) else { return };
        if let Some(existing) = self.items.get(&id) {
            for key in ["sentAt", "endedTurn", "recalled"] {
                if let Some(value) = existing.get(key).filter(|_| !source.contains_key(key)) {
                    data.insert(key.into(), value.clone());
                }
            }
            self.set_item(&id, data);
            return;
        }
        if kind == "userMessage" {
            let client = text(&data, "clientId").unwrap_or(&id).to_owned();
            if self.seen.contains(&id) || self.seen.contains(&client) {
                return;
            }
            self.seen.insert(id.clone());
            self.seen.insert(client);
        }
        if HIDDEN_ITEMS.contains(&kind.as_str()) {
            return;
        }
        let title = item::title(&data);
        let failed = item::failed(&data);
        self.set_item(&id, data.clone());
        let unread = self.rows.iter().rposition(|row| !(row.kind == "user" && self.queued(row))).map_or(0, |index| index + 1);
        if unread < self.rows.len() {
            self.group = (unread > 0 && self.rows[unread - 1].kind == "activity").then(|| self.rows[unread - 1].id.clone());
        }
        let debate = kind == "commandExecution" && DEBATE_SCRIPTS.iter().any(|script| text(&data, "command").unwrap_or_default().contains(script));
        if OWN_ROW_ITEMS.contains(&kind.as_str()) || debate {
            self.group = None;
            let row_kind = match kind.as_str() {
                "userMessage" => "user",
                _ if debate => "debate",
                _ => "assistant",
            };
            self.insert_row(unread, row_kind, vec![id]);
            return;
        }
        match self.group.clone().and_then(|group| self.rows.iter().position(|row| row.id == group)) {
            Some(index) => {
                self.rows[index].items.push(id);
                let row = self.rows[index].id.clone();
                self.dirty_rows.insert(row);
            }
            None => self.group = Some(self.insert_row(unread, "activity", vec![id])),
        }
        if self.busy && !failed {
            self.status = format!("Working: {}", title.chars().take(STATUS_TITLE_CHARS).collect::<String>());
        }
    }

    fn queued(&self, row: &Row) -> bool {
        row.items.first().and_then(|id| self.items.get(id)).is_some_and(|item| item.get("queued") == Some(&Value::Bool(true)))
    }

    /// Appends streamed text into the items it belongs to.
    pub fn flush(&mut self) {
        for (id, delta) in std::mem::take(&mut self.deltas) {
            let Some(item) = self.items.get_mut(&id) else { continue };
            let key = if text(item, "type") == Some("commandExecution") { "aggregatedOutput" } else { "text" };
            let mut joined = text(item, key).unwrap_or_default().to_owned() + &delta;
            if key == "aggregatedOutput" {
                let extra = joined.chars().count().saturating_sub(MAX_OUTPUT_CHARS);
                joined = joined.chars().skip(extra).collect();
            }
            item.insert(key.into(), json!(joined));
            self.dirty_items.insert(id);
        }
    }

    /// Applies an agent request: a question or an approval waits for the frontend, anything else is declined.
    pub fn request(&mut self, id: Value, method: &str, params: &Object) -> Vec<Effect> {
        if text(params, "threadId").is_some_and(|thread| Some(thread) != self.thread_id.as_deref()) {
            return Vec::new();
        }
        if !ASKED_REQUESTS.contains(&method) {
            self.notice(&format!("Unsupported request declined: {method}"));
            return vec![Effect::Decline { id, method: method.to_owned() }];
        }
        let mut params = params.clone();
        if method == "item/fileChange/requestApproval" {
            let changes = text(&params, "itemId").and_then(|item| self.items.get(item)).and_then(|item| item.get("changes")).cloned();
            params.insert("changes".into(), changes.unwrap_or(Value::Null));
        }
        self.permissions.push(Permission { id: new_id(), rpc_id: id, method: method.to_owned(), params });
        Vec::new()
    }

    pub fn event(&mut self, event: &Event) -> Vec<Effect> {
        if event.thread_id.as_ref().is_some_and(|thread| Some(thread) != self.thread_id.as_ref()) {
            return Vec::new();
        }
        let (method, params) = (event.method(), event.params());
        if method == "vcx/limit" {
            return vec![Effect::Limit(params.get("limit").and_then(Value::as_object).cloned().unwrap_or_default())];
        }
        if ["error", "vcx/error", "vcx/disconnected"].contains(&method) && usage_limit(params) && self.busy && !self.stop_requested {
            return vec![Effect::Limit(params.clone())];
        }
        let turn = params.get("turn").and_then(Value::as_object);
        if matches!(event.kind, Kind::TurnCompleted { .. }) && !self.stop_requested && turn.is_some_and(usage_limit) {
            return vec![Effect::Limit(turn.cloned().unwrap_or_default())];
        }
        let mut effects = Vec::new();
        match &event.kind {
            Kind::ItemStarted { item } | Kind::ItemCompleted { item } => {
                let started = matches!(event.kind, Kind::ItemStarted { .. });
                let mut data = item.clone();
                if let Some(id) = text(item, "id").filter(|_| !OWN_ROW_ITEMS.contains(&text(item, "type").unwrap_or_default())) {
                    if started {
                        if !self.active_actions.iter().any(|action| action == id) {
                            self.active_actions.push(id.to_owned());
                        }
                        data.insert("status".into(), json!("inProgress"));
                    } else {
                        self.active_actions.retain(|action| action != id);
                    }
                }
                self.flush();
                self.show(&data);
                if !started {
                    let id = text(item, "id").unwrap_or_default().to_owned();
                    self.deltas.retain(|(item, _)| *item != id);
                }
            }
            Kind::Delta { item_id, delta, stream } => {
                if !self.items.contains_key(item_id) {
                    let kind = if *stream == Stream::Plan { "plan" } else { "agentMessage" };
                    self.show(json!({"id": item_id, "type": kind, "text": ""}).as_object().expect("an object literal"));
                }
                self.deltas.push((item_id.clone(), delta.clone()));
            }
            Kind::TurnStarted { turn_id } => {
                self.turn_id = turn_id.clone();
                self.busy = true;
                self.needs_attention = false;
                self.status = "Working…".into();
                if self.stop_requested {
                    effects.push(Effect::Stop);
                }
            }
            Kind::TurnCompleted { status, error, .. } => {
                let interrupted = *status == TurnStatus::Interrupted;
                let restarting = std::mem::take(&mut self.retry_stopped) && interrupted;
                self.retry_attempt = None;
                self.resume_when_back = false;
                self.turn_completed(status, error.as_deref(), restarting);
                if restarting {
                    effects.push(Effect::KeepGoing);
                }
                if !self.needs_attention {
                    self.auto_resumes = 0;
                } else if !interrupted && turn.is_some_and(crate::fallback::rate_limited) {
                    effects.push(Effect::RateLimited);
                } else if !interrupted && self.auto_resumes < crate::fallback::NETWORK_RESUMES && turn.is_some_and(crate::fallback::network_dropped) {
                    self.resume_when_back = true;
                    effects.push(Effect::Offline("a dropped connection"));
                }
            }
            Kind::Error { message, will_retry } => {
                if *will_retry {
                    self.status = "Reconnecting…".into();
                }
                self.notice(message);
            }
            Kind::Warning { message } => self.notice(message),
            Kind::Compacted => self.notice("Conversation compacted. Earlier messages remain in history."),
            Kind::TokenUsage { total, last, window } => {
                if let Some(total) = total {
                    self.tokens = format!("{total} total");
                }
                if let (Some(used), Some(limit)) = (last, window.filter(|limit| *limit > 0)) {
                    self.context = format!("{}% context", (*used as f64 / limit as f64 * 100.0).round() as i64);
                }
                self.context_used = *last;
                if let Some(limit) = window.filter(|limit| *limit > 0) {
                    self.context_limit = Some(limit);
                }
            }
            Kind::RequestResolved { request_id } => self.permissions.retain(|permission| permission.rpc_id.to_string() != request_id.to_string()),
            Kind::RateLimits { limits } => self.rate_limits(limits),
            Kind::Other if method == "vcx/error" => self.notice(text(params, "message").unwrap_or("The agent reported an error.")),
            Kind::Other if method == "vcx/disconnected" => effects.extend(self.agent_stopped(params)),
            Kind::Other if method == "vcx/resumeFailed" => effects.push(Effect::ResumeFailed),
            Kind::Other if method == "vcx/apiRetry" => {
                if params.get("done") == Some(&Value::Bool(true)) {
                    self.retry_attempt = None;
                } else {
                    let delay = params.get("delay").and_then(Value::as_f64).unwrap_or_default() / 1000.0;
                    self.retry_attempt = Some(crate::fallback::now() + delay);
                    effects.push(Effect::Offline("an API retry"));
                }
            }
            Kind::Other => {}
        }
        effects
    }

    /// `restarting`: the step was stopped to restart on a live network, which needs no notice.
    fn turn_completed(&mut self, status: &TurnStatus, error: Option<&str>, restarting: bool) {
        self.flush();
        self.turn_id = None;
        self.busy = false;
        self.stop_requested = false;
        self.active_actions.clear();
        if *status == TurnStatus::Completed {
            let last = self.rows.iter().rev().find(|row| row.kind == "assistant" || row.kind == "user");
            if let Some(item) = last.filter(|row| row.kind == "assistant").and_then(|row| row.items.last()).cloned() {
                if let Some(data) = self.items.get_mut(&item) {
                    data.insert("endedTurn".into(), json!(true));
                    self.dirty_items.insert(item);
                }
            }
        }
        self.permissions.clear();
        self.pending_input = None;
        let asked = self.stop_source.as_deref().is_some_and(|source| source != "Close Session");
        self.needs_attention = if *status == TurnStatus::Interrupted { !asked } else { *status == TurnStatus::Failed || error.is_some() };
        self.turn_prompt = None;
        if *status == TurnStatus::Interrupted {
            if !restarting {
                let who = self.stop_source.as_ref().map_or("The provider did not report who stopped it.".to_owned(), |source| format!("Stop requested by {source}."));
                self.notice(&format!("Work interrupted. {who} Send a message to continue."));
            }
        } else if self.needs_attention {
            self.notice(error.unwrap_or("Turn failed. Send a message to retry."));
        }
        self.stop_source = None;
        self.status = match (status, self.needs_attention) {
            (TurnStatus::Interrupted, _) => "Stopped",
            (_, true) => "Failed",
            _ => "Ready",
        }
        .into();
    }

    fn rate_limits(&mut self, limits: &Object) {
        self.usage_loading = false;
        let windows: Vec<&Object> = ["primary", "secondary"].iter().filter_map(|key| limits.get(*key).and_then(Value::as_object)).collect();
        self.usage_percent = windows.iter().filter_map(|window| window.get("usedPercent").and_then(Value::as_f64)).reduce(f64::max);
        self.usage = windows
            .iter()
            .filter_map(|window| {
                let used = window.get("usedPercent").and_then(Value::as_f64)?;
                let minutes = window.get("windowDurationMins").and_then(Value::as_i64).unwrap_or_default();
                let label = match minutes {
                    10_080 => "wk".to_owned(),
                    300 => "usage".to_owned(),
                    m if m >= 1440 && m % 1440 == 0 => format!("{}d", m / 1440),
                    m if m >= 60 && m % 60 == 0 => format!("{}h", m / 60),
                    m => format!("{m}m"),
                };
                Some(format!("{}% {label}", used.round() as i64))
            })
            .collect::<Vec<_>>()
            .join(" - ");
    }

    /// An adapter's agent stopped: on purpose (`ended`), or crashed, with why and its log's last error line, to restart.
    pub fn agent_stopped(&mut self, params: &Object) -> Vec<Effect> {
        let ended = params.get("ended") == Some(&Value::Bool(true));
        if params.contains_key("reason") && !ended {
            self.lost(false);
            return vec![Effect::Crashed(params.clone())];
        }
        let mut message = text(params, "message").unwrap_or("The agent disconnected.").to_owned();
        if let Some(line) = text(params, "line") {
            message = format!("{message} Last error: {line}");
        }
        self.notice_linked(&message, text(params, "log"));
        self.lost(ended);
        Vec::new()
    }

    /// The agent ended: the session cannot work until it is reopened.
    pub fn disconnected(&mut self, reason: &str, ended: bool) {
        self.notice(reason);
        self.lost(ended);
    }

    fn lost(&mut self, ended: bool) {
        self.needs_attention = !ended;
        self.lost_connection = !ended;
        self.ready = false;
        self.busy = false;
        self.background_tasks = 0;
        self.turn_id = None;
        self.status = if ended { "Ended" } else { "Disconnected" }.into();
        self.permissions.clear();
    }

    /// The thread is open: its history, if resumed, becomes the transcript; `keep_rows` keeps the transcript, as when
    /// another agent takes the conversation over.
    pub fn opened(&mut self, result: &Object, history: &[Value], keep_rows: bool) {
        self.flush();
        if !keep_rows {
            for row in std::mem::take(&mut self.rows) {
                for item in row.items {
                    self.items.remove(&item);
                }
            }
            self.seen.clear();
        }
        self.order_dirty = true;
        self.needs_attention = false;
        self.group = None;
        let thread = result.get("thread").and_then(Value::as_object);
        self.thread_id = thread.and_then(|thread| text(thread, "id")).map(str::to_owned);
        self.native_history_path = thread.and_then(|thread| text(thread, "path")).map(str::to_owned);
        self.conversation_name = thread.and_then(|thread| text(thread, "name")).map(str::to_owned);
        self.turn_id = None;
        self.busy = false;
        self.stop_requested = false;
        self.background_tasks = 0;
        self.planning = false;
        self.model = text(result, "model").unwrap_or(&self.provider_label).to_owned();
        self.archive_service = text(result, "modelProvider").unwrap_or_default().to_owned();
        self.default_effort = text(result, "reasoningEffort").map(str::to_owned);
        if let Some(policy) = text(result, "approvalPolicy") {
            let full = result.get("sandbox").and_then(|sandbox| sandbox.get("type")).and_then(Value::as_str) == Some("dangerFullAccess");
            self.active_mode = if policy == "never" && full { "bypass" } else { "ask" }.into();
        }
        self.context.clear();
        self.context_used = None;
        self.context_limit = None;
        for turn in history.iter().filter_map(Value::as_object) {
            self.group = None;
            for item in turn.get("items").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_object) {
                self.show(item);
            }
            if text(turn, "status") == Some("inProgress") {
                self.turn_id = text(turn, "id").map(str::to_owned);
                self.busy = true;
            }
        }
        self.ready = true;
        self.status = if self.busy { "Working…" } else { "Ready" }.into();
    }

    /// A conversation reopened cold: what was running is not replayed, the unsent draft comes back.
    pub fn recovered(&mut self, state: &Object) {
        if let Some(Value::Array(draft)) = state.get("draft") {
            let generation = state.get("draftGeneration").and_then(Value::as_i64).unwrap_or(self.draft_generation);
            self.set_draft(draft.clone(), generation);
        }
        self.busy = false;
        self.turn_id = None;
        self.permissions.clear();
        self.active_actions.clear();
        self.needs_attention = self.needs_attention || state.get("interrupted") == Some(&Value::Bool(true));
        if self.needs_attention {
            self.status = "Interrupted".into();
        }
        self.notice(RECOVERED_NOTICE);
    }

    pub fn apply_catalog(&mut self, catalog: &Object) {
        let entries: Vec<&Object> = catalog.get("data").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_object).collect();
        self.models = entries.iter().filter_map(|entry| text(entry, "id").map(str::to_owned)).collect();
        self.model_efforts = entries
            .iter()
            .filter_map(|entry| {
                let efforts: Vec<Value> = entry.get("supportedReasoningEfforts").and_then(Value::as_array).into_iter().flatten().filter_map(|effort| effort.get("reasoningEffort").cloned()).collect();
                Some((text(entry, "id")?.to_owned(), Value::Array(efforts)))
            })
            .collect();
        self.model_default_efforts = entries.iter().filter_map(|entry| Some((text(entry, "id")?.to_owned(), entry.get("defaultReasoningEffort")?.clone()))).collect();
        if self.default_effort.is_none() {
            self.default_effort = self.model_default_efforts.get(&self.model).and_then(Value::as_str).map(str::to_owned);
        }
    }

    /// Shows a prompt and builds its request, or tells why it cannot go (`None`, with a notice when the user must know).
    /// A `retry` sends a prompt already shown again, to a fallback account: no new row, the draft untouched.
    pub fn begin_send(&mut self, text: &str, images: &[String], expected_draft: Option<Vec<Value>>, expected_generation: Option<i64>, retry: bool) -> Option<Outgoing> {
        if !self.ready || self.changing {
            if !self.ready {
                self.notice("Not connected. Use /reconnect or /provider to continue. Your draft has been kept.");
            }
            return None;
        }
        if text.trim().is_empty() && images.is_empty() {
            return None;
        }
        if self.busy && self.turn_id.is_none() {
            self.notice("The current turn is still starting. Your draft has been kept.");
            return None;
        }
        let saved_draft = expected_draft.unwrap_or_else(|| self.draft.clone());
        let generation = expected_generation.unwrap_or(self.draft_generation);
        let was_busy = self.busy;
        let id = new_id();
        let mut content: Vec<Value> = if text.is_empty() { Vec::new() } else { vec![json!({"type": "text", "text": text})] };
        content.extend(images.iter().map(|path| json!({"type": "localImage", "path": path})));
        let sent_at = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |elapsed| elapsed.as_secs_f64());
        self.seen.insert(id.clone());
        self.group = None;
        if !retry {
            self.set_item(&id, json!({"id": id, "type": "userMessage", "content": content, "sentAt": sent_at}).as_object().cloned().unwrap_or_default());
            let index = self.rows.len();
            self.insert_row(index, "user", vec![id.clone()]);
            if self.draft_generation == generation && self.draft == saved_draft {
                self.set_draft(Vec::new(), self.draft_generation);
            }
        }
        if !was_busy {
            self.active_actions.clear();
            self.turn_prompt = (!retry).then(|| id.clone());
        }
        self.pending_input = match self.pending_input.take().filter(|_| was_busy) {
            Some((previous, mut earlier)) => {
                earlier.extend(images.iter().cloned());
                Some((format!("{previous}\n\nAdditional guidance: {text}"), earlier))
            }
            None => Some((text.to_owned(), images.to_vec())),
        };
        if !self.injected_context.is_empty() {
            content.insert(0, json!({"type": "text", "text": self.injected_context}));
        }
        self.busy = true;
        self.stop_requested = false;
        self.stop_source = None;
        self.needs_attention = false;
        self.status = if was_busy { "Sending guidance…" } else { "Working…" }.into();
        let mut params = json!({"threadId": self.thread_id.clone().unwrap_or_default(), "input": content, "clientUserMessageId": id});
        if was_busy {
            params["expectedTurnId"] = json!(self.turn_id);
        } else {
            params["cwd"] = json!(self.cwd);
            if let Some(effort) = &self.effort {
                params["effort"] = json!(effort);
            }
            if self.provider == "codex" {
                let effort = self.effort.clone().or_else(|| self.default_effort.clone());
                params["collaborationMode"] = json!({"mode": if self.planning { "plan" } else { "default" }, "settings": {"model": self.model, "reasoning_effort": effort, "developer_instructions": null}});
                // Codex takes a new mode with a turn and keeps it for the turns after.
                if self.mode_override {
                    let bypass = self.active_mode == "bypass";
                    params["approvalPolicy"] = json!(approval_policy(&self.active_mode));
                    params["sandboxPolicy"] = if bypass { json!({"type": "dangerFullAccess"}) } else { json!({"type": "workspaceWrite", "writableRoots": [], "networkAccess": false, "excludeTmpdirEnvVar": false, "excludeSlashTmp": false}) };
                }
            }
        }
        Some(Outgoing { id, method: if was_busy { "turn/steer" } else { "turn/start" }, params, was_busy, saved_draft })
    }

    pub fn send_succeeded(&mut self, result: &Value) {
        self.injected_context.clear();
        if self.busy && self.turn_id.is_none() {
            self.turn_id = result.get("turn").and_then(|turn| turn.get("id")).and_then(Value::as_str).map(str::to_owned);
        }
    }

    /// The prompt did not reach the agent: its row goes, its text comes back into the draft.
    pub fn send_failed(&mut self, outgoing: &Outgoing, message: &str) {
        if let Some(row) = self.rows.iter().find(|row| row.items.first() == Some(&outgoing.id)).map(|row| row.id.clone()) {
            self.remove_row(&row);
        }
        self.seen.remove(&outgoing.id);
        if !outgoing.was_busy && self.turn_id.is_none() {
            self.busy = false;
        }
        let mut restored = outgoing.saved_draft.clone();
        if !restored.is_empty() && !self.draft.is_empty() {
            restored.push(json!({"type": "text", "text": "\n"}));
        }
        restored.extend(self.draft.iter().cloned());
        self.set_draft(restored, self.draft_generation);
        self.needs_attention = !self.busy;
        self.notice(&format!("Prompt was not sent: {message}"));
        self.status = if self.busy { "Working…" } else { "Send failed" }.into();
    }

    /// Records a stop; gives the turn to interrupt once one is known.
    pub fn begin_stop(&mut self, source: &str) -> Option<(String, String)> {
        if !self.busy {
            return None;
        }
        if !self.stop_requested {
            self.stop_source = Some(source.to_owned());
        }
        self.stop_requested = true;
        match &self.turn_id {
            Some(turn) => Some((self.thread_id.clone().unwrap_or_default(), turn.clone())),
            None => {
                self.status = "Stopping when the turn starts…".into();
                None
            }
        }
    }

    pub fn take_permission(&mut self, rpc_id: &Value, method: &str) -> Option<Permission> {
        let index = self.permissions.iter().position(|permission| permission.method == method && permission.rpc_id == *rpc_id)?;
        Some(self.permissions.remove(index))
    }

    pub fn unsend(&mut self, id: &str) -> bool {
        let queued = self.rows.iter().find(|row| row.kind == "user" && row.items.first().map(String::as_str) == Some(id) && self.queued(row)).map(|row| row.id.clone());
        match queued {
            Some(row) => {
                self.remove_row(&row);
                true
            }
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vcx_agents::codex;

    fn event(value: Value) -> Event {
        match codex::parse(value.as_object().unwrap().clone()) {
            vcx_agents::Inbound::Event(event) => event,
            other => panic!("not an event: {other:?}"),
        }
    }

    fn opened() -> Session {
        let mut session = Session::new("/tmp", "/tmp/state");
        session.opened(json!({"thread": {"id": "T"}, "model": "gpt"}).as_object().unwrap(), &[], false);
        session.take_patch();
        session
    }

    fn kinds(session: &Session) -> Vec<&str> {
        session.rows().iter().map(|row| row.kind.as_str()).collect()
    }

    #[test]
    fn groups_tools_under_one_activity_row_between_the_prompt_and_the_answer() {
        let mut session = opened();
        session.begin_send("hi", &[], None, None, false).unwrap();

        for value in [
            json!({"method": "turn/started", "params": {"threadId": "T", "turn": {"id": "U"}}}),
            json!({"method": "item/started", "params": {"threadId": "T", "item": {"id": "c1", "type": "commandExecution", "command": "ls"}}}),
            json!({"method": "item/completed", "params": {"threadId": "T", "item": {"id": "c1", "type": "commandExecution", "command": "ls", "status": "completed"}}}),
            json!({"method": "item/started", "params": {"threadId": "T", "item": {"id": "c2", "type": "commandExecution", "command": "pwd"}}}),
            json!({"method": "item/agentMessage/delta", "params": {"threadId": "T", "itemId": "a", "delta": "Do"}}),
            json!({"method": "item/agentMessage/delta", "params": {"threadId": "T", "itemId": "a", "delta": "ne"}}),
            json!({"method": "turn/completed", "params": {"threadId": "T", "turn": {"id": "U", "status": "completed"}}}),
        ] {
            session.event(&event(value));
        }

        assert_eq!(kinds(&session), ["user", "activity", "assistant"]);
        assert_eq!(session.rows()[1].items, ["c1", "c2"]);
        assert_eq!(session.item("a").unwrap()["text"], "Done");
        assert_eq!(session.item("a").unwrap()["endedTurn"], true);
        assert_eq!((session.busy, session.status.as_str()), (false, "Ready"));
    }

    #[test]
    fn ignores_events_of_another_thread() {
        let mut session = opened();

        session.event(&event(json!({"method": "item/completed", "params": {"threadId": "other", "item": {"id": "x", "type": "agentMessage", "text": "no"}}})));

        assert!(session.rows().is_empty());
    }

    #[test]
    fn shows_the_echoed_prompt_once() {
        let mut session = opened();
        let outgoing = session.begin_send("once", &[], None, None, false).unwrap();

        session.event(&event(json!({"method": "item/completed", "params": {"threadId": "T", "item": {"id": "u", "type": "userMessage", "clientId": outgoing.id, "content": []}}})));

        assert_eq!(kinds(&session), ["user"]);
    }

    #[test]
    fn a_patch_names_only_what_changed() {
        let mut session = opened();
        session.begin_send("hi", &[], None, None, false).unwrap();
        session.take_patch();

        session.event(&event(json!({"method": "item/agentMessage/delta", "params": {"threadId": "T", "itemId": "a", "delta": "x"}})));
        let first = session.take_patch().unwrap();
        session.event(&event(json!({"method": "item/agentMessage/delta", "params": {"threadId": "T", "itemId": "a", "delta": "y"}})));
        let second = session.take_patch().unwrap();

        assert!(first.contains_key("rowOrder") && first.contains_key("rowUpdates"));
        assert_eq!(second.keys().collect::<Vec<_>>(), ["items"]);
        assert_eq!(second["items"][0]["text"], "xy");
        assert_eq!(session.take_patch(), None);
    }

    #[test]
    fn keeps_an_approval_until_the_turn_ends() {
        let mut session = opened();

        session.request(json!(731), "item/commandExecution/requestApproval", json!({"threadId": "T", "itemId": "c"}).as_object().unwrap());
        let held = session.metadata()["permissions"][0]["rpcID"].clone();
        session.event(&event(json!({"method": "turn/completed", "params": {"threadId": "T", "turn": {"id": "U", "status": "completed"}}})));

        assert_eq!(held, json!(731));
        assert!(session.permissions.is_empty());
    }

    #[test]
    fn declines_a_request_it_does_not_know() {
        let mut session = opened();

        let effects = session.request(json!(4), "item/tool/call", json!({"threadId": "T"}).as_object().unwrap());

        assert_eq!(effects, [Effect::Decline { id: json!(4), method: "item/tool/call".into() }]);
        assert_eq!(kinds(&session), ["notice"]);
    }

    #[test]
    fn a_failed_send_takes_the_row_back_and_restores_the_draft() {
        let mut session = opened();
        let draft = vec![json!({"type": "text", "text": "hi"})];
        session.set_draft(draft.clone(), 1);
        let outgoing = session.begin_send("hi", &[], Some(draft.clone()), Some(1), false).unwrap();

        session.send_failed(&outgoing, "boom");

        assert_eq!(kinds(&session), ["notice"]);
        assert_eq!(session.draft, draft);
        assert_eq!((session.busy, session.status.as_str()), (false, "Send failed"));
    }

    #[test]
    fn an_interrupted_turn_the_user_stopped_needs_no_attention() {
        let mut session = opened();
        session.begin_send("hi", &[], None, None, false).unwrap();
        session.event(&event(json!({"method": "turn/started", "params": {"threadId": "T", "turn": {"id": "U"}}})));

        let stop = session.begin_stop("Escape key");
        session.event(&event(json!({"method": "turn/completed", "params": {"threadId": "T", "turn": {"id": "U", "status": "interrupted"}}})));

        assert_eq!(stop, Some(("T".into(), "U".into())));
        assert_eq!((session.needs_attention, session.status.as_str()), (false, "Stopped"));
        assert_eq!(session.item(session.rows().last().unwrap().items[0].as_str()).unwrap()["text"], "Work interrupted. Stop requested by Escape key. Send a message to continue.");
    }

    #[test]
    fn a_resumed_thread_shows_its_history_and_a_recovery_notice() {
        let mut session = Session::new("/tmp", "/tmp/state");
        let history = [json!({"id": "U", "status": "completed", "items": [
            {"id": "u", "type": "userMessage", "content": [{"type": "text", "text": "before"}]},
            {"id": "c", "type": "commandExecution", "command": "ls"},
            {"id": "a", "type": "agentMessage", "text": "after"}
        ]})];

        session.opened(json!({"thread": {"id": "T"}}).as_object().unwrap(), &history, false);
        session.recovered(json!({"draft": [{"type": "text", "text": "unsent"}], "draftGeneration": 4, "interrupted": true}).as_object().unwrap());

        assert_eq!(kinds(&session), ["user", "activity", "assistant", "notice"]);
        assert_eq!((session.draft_generation, session.status.as_str(), session.busy), (4, "Interrupted", false));
    }

    #[test]
    fn a_codex_turn_carries_the_mode_chosen_during_the_session() {
        let mut session = opened();
        (session.provider, session.active_mode, session.mode_override) = ("codex".into(), "ask".into(), true);

        let outgoing = session.begin_send("hi", &[], None, None, false).unwrap();

        assert_eq!(outgoing.params["approvalPolicy"], "on-request");
        assert_eq!(outgoing.params["sandboxPolicy"]["type"], "workspaceWrite");
    }

    #[test]
    fn tells_a_usage_limit_from_a_rate_limit_when_a_turn_fails() {
        let failed = |error: Value| json!({"method": "turn/completed", "params": {"threadId": "T", "turn": {"id": "U", "status": "failed", "error": error}}});
        let mut session = opened();
        session.begin_send("hi", &[], None, None, false).unwrap();

        let limited = session.event(&event(failed(json!({"message": "You've hit your usage limit.", "codexErrorInfo": "usageLimitExceeded"}))));
        let throttled = session.event(&event(failed(json!({"message": "429 Too Many Requests"}))));

        assert!(matches!(limited.as_slice(), [Effect::Limit(_)]));
        assert_eq!(throttled, [Effect::RateLimited]);
    }
}
