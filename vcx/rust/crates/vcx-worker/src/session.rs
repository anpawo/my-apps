//! One conversation as its worker holds it, ported from the Swift `Session` without its display: rows of
//! provider-shaped items, the metadata a frontend reads, and what changed since the last patch.

use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use crate::capabilities::{self, Capabilities};
use crate::records::NativeSource;
use crate::{draft, fleet, project, question, recall};
use crate::{repository, usage};
use vcx_agents::directory::shell_directory;
use vcx_agents::claude_stream::usage_limit;
use vcx_agents::qwen_text::strip_recall;
use vcx_agents::{Event, Kind, Stream, TurnStatus};
use vcx_model::item;

pub type Object = serde_json::Map<String, Value>;

mod records;
pub use records::Choices;

/// Tool output kept in the session; the complete output stays in the provider's history.
const MAX_OUTPUT_CHARS: usize = 16_384;
const STATUS_TITLE_CHARS: usize = 100;
const DEBATE_SCRIPTS: [&str; 7] = ["ask-codex.sh", "ask-qwen.sh", "ask-agy.sh", "ask-gemini.sh", "ask-grok.sh", "ask-muse.sh", "ask-meta.sh"];
const ASKED_REQUESTS: [&str; 3] = ["item/tool/requestUserInput", "item/commandExecution/requestApproval", "item/fileChange/requestApproval"];
const OWN_ROW_ITEMS: [&str; 3] = ["agentMessage", "plan", "userMessage"];
const HIDDEN_ITEMS: [&str; 2] = ["hookPrompt", "contextCompaction"];
const RECONNECTING: &str = "Reconnecting…";
const WEBSOCKET_FALLBACK: &str = "Falling back from WebSockets to HTTPS transport";
const AGENT_ERROR: &str = "Codex reported an error.";
/// Claude reports a model's window only when a turn ends; remembering it shows the percentage from a new session's first message.
const CONTEXT_WINDOWS_FILE: &str = "claude-context-windows.json";
const PRIVATE_FOLDER: u32 = 0o700;
const STATUS_EVENTS: [&str; 6] = ["vcx/model", "vcx/context", "vcx/tokens", "vcx/catalog", "vcx/backgroundTasks", "vcx/userQueue"];
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
    /// The agent's request is answered at once with this result.
    Respond { id: Value, result: Value },
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
    /// A Codex window is used up: the account rests until then (seconds since 1970), as the Swift `updateUsage` marks it.
    Rest(f64),
    /// A turn edited a file in another folder: the footer names it.
    RefreshRepository,
    /// The turn was stopped for the prompt waiting on it (its id): a turn with no input now answers it.
    ContinueWith(String),
}

/// How the prompt waiting for the running turn goes now (Shift+Return).
#[derive(Debug, PartialEq)]
pub enum SendNow {
    /// Claude takes this queued prompt in itself.
    Queued(String),
    /// The turn is interrupted; `ContinueWith` follows once it ends.
    Interrupt,
}

/// A prompt on its way: the row is already shown, the request not yet answered.
#[derive(Debug, Clone)]
pub struct Outgoing {
    pub id: String,
    pub method: &'static str,
    pub params: Value,
    was_busy: bool,
    saved_draft: Vec<Value>,
    /// What the prompt row shows, kept to rebuild `params` once an account switch behind the row is done.
    content: Vec<Value>,
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
    pub model_aliases: Object,
    pub record_id: String,
    /// Where the agent writes its Fleet label; its progress and task files sit beside it.
    pub fleet_context_file: String,
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
    /// The command palette's and the sidebar's lists.
    pub capabilities: Capabilities,
    /// The last rate limits reported, drawn again as their reset countdown moves.
    pub last_rate: Object,
    /// When the usage endpoint was last read, in seconds since 1970.
    pub last_usage_refresh: f64,
    pub repository: String,
    pub branch: String,
    pub repository_status: String,
    pub repository_changes: Vec<String>,
    pub repository_directory: Option<String>,
    pub pull_request: String,
    pub pull_request_url: String,
    /// The folder of the last file a turn edited, which the footer adds to the project's name.
    pub edited_folder: Option<String>,
    /// The conversations `/resume` lists: `{id, title, backendID}`.
    pub recent: Vec<Value>,
    /// The provider threads the record owns.
    pub native_sources: Vec<NativeSource>,
    pub archive_client_versions: Object,
    /// The running agent's provider version, which each source it writes keeps (the Swift `archiveClientVersion`).
    pub client_version: Option<String>,
    /// The files the running turn edited.
    turn_edits: Vec<String>,
    /// Prompts, agent events and notices go to the trace in `state_directory`: a worker's sessions, never a test's model.
    pub tracing: bool,
    draft_revision: u64,
    rows: Vec<Row>,
    items: HashMap<String, Object>,
    seen: HashSet<String>,
    group: Option<String>,
    deltas: Vec<(String, String)>,
    turn_prompt: Option<String>,
    /// The prompt Shift+Return stopped the turn for, answered once the turn ends.
    sending_now: Option<String>,
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

/// The message of an agent's error, inside its `error` object or beside it.
fn error_message(params: &Object) -> &str {
    text(params.get("error").and_then(Value::as_object).unwrap_or(params), "message").unwrap_or(AGENT_ERROR)
}

/// `number` with thousands separators, as Swift's `formatted()` writes it.
fn grouped(number: i64) -> String {
    let digits = number.unsigned_abs().to_string();
    let mut out = if number < 0 { "-".to_owned() } else { String::new() };
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

/// The effort his Claude settings give `model`: its `modelSettings` entry over `effortLevel`, the folder closest to `cwd` last.
fn configured_claude_effort(home: Option<&str>, cwd: &str, model: &str) -> Option<String> {
    let base = home.map_or_else(|| vcx_config::homes::home_directory().join(".claude"), PathBuf::from);
    let folders: Vec<&Path> = Path::new(cwd).ancestors().collect();
    let files = std::iter::once(base.join("settings.json")).chain(folders.iter().rev().flat_map(|folder| [".claude/settings.json", ".claude/settings.local.json"].map(|name| folder.join(name))));
    let (mut effort, mut model_effort) = (None, None);
    for file in files {
        let Some(Value::Object(settings)) = std::fs::read(file).ok().and_then(|data| serde_json::from_slice(&data).ok()) else { continue };
        effort = text(&settings, "effortLevel").map(str::to_owned).or(effort);
        model_effort = settings.get("modelSettings").and_then(|models| models.get(model)).and_then(|entry| entry.get("effortLevel")).and_then(Value::as_str).map(str::to_owned).or(model_effort);
    }
    model_effort.or(effort)
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
            status: "Connecting…".into(),
            tokens: "Not reported".into(),
            usage_loading: true,
            repository: "Checking…".into(),
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
            "usage": self.usage, "usageLoading": self.usage_loading, "tokens": self.tokens, "repository": self.repository, "branch": self.branch,
            "repositoryStatus": self.repository_status, "repositoryChanges": self.repository_changes, "pullRequest": self.pull_request, "pullRequestURL": self.pull_request_url, "hooks": self.capabilities.hooks,
            "skills": self.capabilities.skills, "builtinCommands": self.capabilities.builtin_commands, "mcp": self.capabilities.mcp,
            "instructions": self.capabilities.instructions, "activeMode": self.active_mode, "providerLabel": self.provider_label, "models": self.models,
            "modelEfforts": self.model_efforts, "modelDefaultEfforts": self.model_default_efforts, "modelAliases": self.model_aliases, "planning": self.planning,
            "skillPaths": self.capabilities.skill_paths, "legacyCommandPaths": self.capabilities.legacy_command_paths, "recordID": self.record_id, "fleetContext": fleet::context(&self.fleet_context_file),
            "progressFile": fleet::progress_path(&self.fleet_context_file), "taskFile": fleet::task_path(&self.fleet_context_file), "recalledRules": self.recalled_rules, "recalledRuleSections": self.recalled_sections, "recent": self.recent, "permissions": permissions,
            "providerCommands": self.capabilities.provider_commands, "account": self.account, "nativeSources": self.native_sources, "archiveClientVersions": self.archive_client_versions,
            "nativeHistoryPath": self.native_history_path, "archiveService": self.archive_service, "threadID": self.thread_id, "turnID": self.turn_id,
            "effort": self.effort, "defaultEffort": self.default_effort, "usagePercent": self.usage_percent, "contextUsed": self.context_used,
            "contextLimit": self.context_limit, "repositoryDirectory": self.repository_directory, "conversationName": self.conversation_name,
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

    /// The Swift `trace`: one line of the trace log, with the session's record, thread and folder.
    pub fn trace(&self, kind: &str, mut data: Value) {
        if !self.tracing {
            return;
        }
        if let Some(fields) = data.as_object_mut() {
            fields.insert("record".into(), json!(self.record_id));
            if let Some(thread) = &self.thread_id {
                fields.insert("thread".into(), json!(thread));
            }
            fields.insert("cwd".into(), json!(self.cwd));
        }
        crate::trace::write(Path::new(&self.state_directory), kind, data);
    }

    pub fn trace_prompt(&self, text: &str, images: usize, retry: bool) {
        self.trace("prompt", json!({"text": text, "images": images, "retry": retry, "ready": self.ready, "busy": self.busy}));
    }

    /// A notice that opens `link` (an agent's log) when clicked.
    pub fn notice_linked(&mut self, message: &str, link: Option<&str>) {
        self.trace("notice", json!({"text": message}));
        let id = new_id();
        let mut data = json!({"id": id, "type": "notice", "text": message});
        if let Some(link) = link {
            data["link"] = json!(link);
        }
        self.set_item(&id, data.as_object().cloned().unwrap_or_default());
        let index = self.rows.len();
        self.insert_row(index, "notice", vec![id]);
    }

    /// One notice says the agent retries, updated in place until the agent makes progress again.
    fn retry_notice(&mut self, message: &str) {
        self.trace("notice", json!({"text": message}));
        let retry = self.rows.iter().rev().filter_map(|row| row.items.first()).find(|id| self.is_retry(id)).cloned();
        match retry.and_then(|id| Some((self.items.get(&id)?.clone(), id))) {
            Some((mut item, id)) => {
                item.insert("text".into(), json!(message));
                self.set_item(&id, item);
            }
            None => {
                let id = new_id();
                self.set_item(&id, json!({"id": id, "type": "notice", "text": message, "retry": true}).as_object().cloned().unwrap_or_default());
                let index = self.rows.len();
                self.insert_row(index, "notice", vec![id]);
            }
        }
        self.status = RECONNECTING.into();
    }

    fn clear_retry_notice(&mut self) {
        if self.status != RECONNECTING {
            return;
        }
        let retries: Vec<String> = self.rows.iter().filter(|row| row.items.first().is_some_and(|id| self.is_retry(id))).map(|row| row.id.clone()).collect();
        for row in retries {
            self.remove_row(&row);
        }
        self.status = "Working…".into();
    }

    fn is_retry(&self, id: &str) -> bool {
        self.items.get(id).is_some_and(|item| item.get("retry") == Some(&Value::Bool(true)))
    }

    /// What an agent adapter reports beside the transcript: its model, context, tokens, catalog and background work.
    fn agent_status(&mut self, method: &str, params: &Object) {
        match method {
            "vcx/model" => self.model_resolved(params),
            "vcx/context" => self.context_reported(params),
            "vcx/tokens" => {
                if let (Some(input), Some(output)) = (params.get("input").and_then(Value::as_i64), params.get("output").and_then(Value::as_i64)) {
                    self.tokens = format!("{} in · {} out", grouped(input), grouped(output));
                }
            }
            "vcx/catalog" => {
                self.catalog_models(params);
                self.claude_catalog(&Value::Object(params.clone()));
            }
            "vcx/backgroundTasks" => self.background_tasks = params.get("count").and_then(Value::as_i64).unwrap_or_default(),
            "vcx/userQueue" => self.user_queue(params),
            _ => {}
        }
    }

    fn model_resolved(&mut self, params: &Object) {
        if let Some(model) = text(params, "model") {
            self.model = model.to_owned();
        }
        let claude = self.provider == "claude";
        if let Some(known) = self.remembered_window(&self.model).filter(|_| claude) {
            self.context_limit = Some(known);
        }
        self.default_effort = match text(params, "reasoningEffort") {
            Some(effort) => Some(effort.to_owned()),
            None if claude => self.configured_effort(),
            None => None,
        };
    }

    fn context_reported(&mut self, params: &Object) {
        if let Some(used) = params.get("used").and_then(Value::as_i64) {
            self.context_used = Some(used);
        }
        let served = text(params, "model");
        match params.get("limit").and_then(Value::as_i64).filter(|limit| *limit > 0) {
            Some(limit) => {
                self.context_limit = Some(limit);
                if let Some(served) = served {
                    self.remember_window(served, limit);
                }
            }
            None => {
                if let Some(known) = served.and_then(|served| self.remembered_window(served)) {
                    self.context_limit = Some(known);
                }
            }
        }
    }

    fn context_windows(&self) -> Object {
        let file = Path::new(&self.state_directory).join(CONTEXT_WINDOWS_FILE);
        std::fs::read(file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }

    pub fn remembered_window(&self, model: &str) -> Option<i64> {
        self.context_windows().get(model).and_then(Value::as_i64)
    }

    fn remember_window(&self, model: &str, limit: i64) {
        let mut windows = self.context_windows();
        if windows.get(model).and_then(Value::as_i64) == Some(limit) {
            return;
        }
        windows.insert(model.to_owned(), json!(limit));
        let _ = std::fs::DirBuilder::new().recursive(true).mode(PRIVATE_FOLDER).create(&self.state_directory);
        if let Ok(data) = serde_json::to_vec(&windows) {
            let _ = vcx_config::homes::write_private(&Path::new(&self.state_directory).join(CONTEXT_WINDOWS_FILE), &data);
        }
    }

    /// Claude's catalog models: the menu's list, the model each alias resolves to and the efforts each one takes.
    fn catalog_models(&mut self, catalog: &Object) {
        let Some(entries) = catalog.get("models").and_then(Value::as_array) else { return };
        let entries: Vec<&Object> = entries.iter().filter_map(Value::as_object).collect();
        self.models = entries.iter().filter_map(|entry| text(entry, "value").map(str::to_owned)).collect();
        self.model_aliases.clear();
        self.model_efforts.clear();
        for entry in entries {
            let Some(id) = text(entry, "value") else { continue };
            if let Some(resolved) = text(entry, "resolvedModel") {
                self.model_aliases.entry(id).or_insert_with(|| json!(resolved));
            }
            let efforts = if entry.get("supportsEffort") == Some(&Value::Bool(false)) { None } else { entry.get("supportedEffortLevels").filter(|levels| levels.is_array()) };
            self.model_efforts.entry(id).or_insert_with(|| efforts.cloned().unwrap_or_else(|| json!([])));
        }
    }

    /// A prompt sent while the agent works waits in its queue; once read, what the agent does next goes under it.
    fn user_queue(&mut self, params: &Object) {
        let Some(id) = text(params, "id") else { return };
        let shown = self.rows.iter().any(|row| row.kind == "user" && row.items.first().map(String::as_str) == Some(id));
        let Some(mut item) = self.items.get(id).cloned().filter(|_| shown) else { return };
        let queued = params.get("queued") == Some(&Value::Bool(true));
        if !queued && item.contains_key("queued") {
            self.group = None;
        }
        if queued {
            item.insert("queued".into(), json!(true));
        } else {
            item.remove("queued");
        }
        self.set_item(id, item);
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

    /// Claude's catalog: its commands, skills and MCP servers, and the permission mode it runs in.
    pub fn claude_catalog(&mut self, catalog: &Value) {
        if let Some(mode) = self.capabilities.claude_catalog(catalog) {
            self.active_mode = mode;
        }
    }

    /// Prompt `id` shows `typed` (a skill as it was typed) in place of the text sent for it.
    pub fn show_typed(&mut self, id: &str, typed: &str) {
        let Some(mut item) = self.items.get(id).cloned() else { return };
        if let Some(first) = item.get_mut("content").and_then(Value::as_array_mut).and_then(|content| content.first_mut()) {
            first["text"] = json!(typed);
            self.set_item(id, item);
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
        capabilities::typed_skill(&mut data);
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
        if method == "item/tool/call" && text(params, "tool") == Some(question::TOOL) {
            let Some(params) = question::questions(params) else { return vec![Effect::Respond { id, result: question::refused() }] };
            self.permissions.push(Permission { id: new_id(), rpc_id: id, method: question::ASKED_METHOD.to_owned(), params });
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
        if matches!(event.kind, Kind::ItemStarted { .. } | Kind::ItemCompleted { .. } | Kind::Delta { .. } | Kind::TurnStarted { .. } | Kind::TurnCompleted { .. }) {
            self.clear_retry_notice();
        }
        if ["error", "vcx/error", "vcx/disconnected"].contains(&method) && usage_limit(params) && self.busy && !self.stop_requested {
            self.clear_retry_notice();
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
                    self.note_edits(item);
                    effects.extend(self.followed_cd(item));
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
                effects.extend(self.turn_completed(status, error.as_deref(), restarting));
                let moved = self.turn_moved();
                effects.extend(self.edited_elsewhere().or(moved));
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
            Kind::Error { will_retry: true, .. } => {
                let message = params.get("error").and_then(Value::as_object).and_then(|error| text(error, "message")).unwrap_or(RECONNECTING).to_owned();
                self.retry_notice(&message);
            }
            Kind::Error { .. } => {
                self.clear_retry_notice();
                self.notice(error_message(params));
            }
            Kind::Warning { message } if method == "warning" && message.starts_with(WEBSOCKET_FALLBACK) => self.retry_notice(message),
            Kind::Warning { message } => self.notice(message),
            Kind::Compacted => self.notice("Conversation compacted. Earlier messages remain in history."),
            Kind::TokenUsage { total, last, window } => {
                if let Some(total) = total {
                    self.tokens = format!("{} total", grouped(*total));
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
            Kind::RateLimits { limits } => effects.extend(self.rate_limits(limits)),
            Kind::Other if method == "vcx/error" => {
                self.clear_retry_notice();
                self.notice(error_message(params));
            }
            Kind::Other if STATUS_EVENTS.contains(&method) => self.agent_status(method, params),
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

    /// `restarting`: the step was stopped to restart on a live network, which needs no notice. Gives the prompt
    /// Shift+Return stopped the turn for.
    fn turn_completed(&mut self, status: &TurnStatus, error: Option<&str>, restarting: bool) -> Option<Effect> {
        self.flush();
        self.turn_id = None;
        self.busy = false;
        self.stop_requested = false;
        // Codex sends no item/completed for a command its stopped turn cut short; Claude reports it failed.
        let running = std::mem::take(&mut self.active_actions);
        for id in running.into_iter().filter(|_| *status != TurnStatus::Completed) {
            if let Some(data) = self.items.get_mut(&id).filter(|data| data.get("status").and_then(Value::as_str) == Some("inProgress")) {
                data.insert("status".into(), json!("failed"));
                self.dirty_items.insert(id);
            }
        }
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
        let interrupted = *status == TurnStatus::Interrupted;
        let withdrawn = interrupted && self.stop_source.as_deref() == Some("Escape") && self.withdraw_prompt();
        self.turn_prompt = None;
        if withdrawn {
        } else if interrupted {
            if !restarting && self.sending_now.is_none() {
                let who = self.stop_source.as_ref().map_or("The provider did not report who stopped it.".to_owned(), |source| format!("Stop requested by {source}."));
                self.notice(&format!("Work interrupted. {who} Send a message to continue."));
            }
        } else if self.needs_attention {
            self.notice(error.unwrap_or("Turn failed. Send a message to retry."));
        }
        self.stop_source = None;
        self.status = match (status, self.needs_attention) {
            _ if withdrawn => "Ready",
            (TurnStatus::Interrupted, _) => "Stopped",
            (_, true) => "Failed",
            _ => "Ready",
        }
        .into();
        self.sending_now.take().filter(|_| interrupted).map(Effect::ContinueWith)
    }

    /// Escape before the agent showed anything takes the prompt back into the composer, as Claude Code does.
    fn withdraw_prompt(&mut self) -> bool {
        let Some(row) = self.rows.last().filter(|row| row.kind == "user" && row.items.first() == self.turn_prompt.as_ref()) else { return false };
        let row = row.id.clone();
        let Some(content) = self.turn_prompt.as_ref().and_then(|id| self.items.get(id)).and_then(|item| item.get("content")).and_then(Value::as_array).cloned() else { return false };
        self.remove_row(&row);
        let restored = draft::withdrawn(&content, &self.draft);
        self.set_draft(restored, self.draft_generation);
        true
    }

    fn instruction_sources(&mut self, result: &Object) {
        let sources: Vec<String> = result.get("instructionSources").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect();
        if !sources.is_empty() {
            self.capabilities.instructions = sources;
        }
    }

    /// The Swift `updateUsage`; a Codex window used up rests its account.
    pub fn rate_limits(&mut self, limits: &Object) -> Option<Effect> {
        let now = crate::fallback::now();
        self.last_rate = limits.clone();
        self.redraw_usage(now);
        usage::exhausted_reset(limits, now).filter(|_| self.provider == "codex").map(Effect::Rest)
    }

    /// The Swift `refreshUsage` gate: whether the usage endpoint is read now. Claude's answers HTTP 429 when polled, so
    /// an unasked refresh only redraws its countdown; the others' is read at most once a minute unless asked.
    pub fn begin_usage_refresh(&mut self, force: bool, now: f64) -> bool {
        if self.provider == "claude" && !force {
            if !self.last_rate.is_empty() {
                self.redraw_usage(now);
            }
            return false;
        }
        if !self.ready || self.changing || !(force || now - self.last_usage_refresh >= usage::REFRESH_INTERVAL) {
            return false;
        }
        self.last_usage_refresh = now;
        self.usage_loading = true;
        true
    }

    /// The usage line again from the last report, its countdown moved to `now`.
    pub fn redraw_usage(&mut self, now: f64) {
        self.usage_loading = false;
        self.usage_percent = usage::percent(&self.last_rate);
        self.usage = usage::line(&self.last_rate, now);
    }

    fn note_edits(&mut self, item: &Object) {
        match text(item, "type") {
            Some("commandExecution") => self.turn_edits.extend(text(item, "command").and_then(repository::edited_path)),
            Some("fileChange") => {
                let changes = item.get("changes").and_then(Value::as_array).into_iter().flatten();
                self.turn_edits.extend(changes.filter_map(|change| change.get("path").and_then(Value::as_str)).map(str::to_owned));
            }
            _ => {}
        }
    }

    fn user_prompts(&self) -> usize {
        self.rows.iter().filter(|row| row.kind == "user").count()
    }

    /// The text of each prompt sent, in order.
    pub fn sent_prompts(&self) -> Vec<String> {
        let prompts = self.rows.iter().filter(|row| row.kind == "user").flat_map(|row| row.items.iter()).filter_map(|id| self.items.get(id));
        let text = |item: &Object| item.get("content").and_then(Value::as_array).into_iter().flatten().filter_map(|piece| piece.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n");
        prompts.map(text).filter(|prompt| !prompt.is_empty()).collect()
    }

    /// A window at `/`, or at his home before its first prompt, asks which project its prompt is about.
    pub fn routable(&self, home: &str) -> bool {
        self.cwd == "/" || (self.cwd == home && self.user_prompts() == 0)
    }

    /// The Swift `moveDirectory`: the session works in `directory`, whose repository is read again.
    pub fn move_directory(&mut self, directory: &str) -> Effect {
        self.cwd = directory.to_owned();
        self.clear_repository();
        Effect::RefreshRepository
    }

    /// A finished lone `cd` places the session during its first prompt only; later, only edits move it.
    fn followed_cd(&mut self, item: &Object) -> Option<Effect> {
        if text(item, "type") != Some("commandExecution") || self.user_prompts() > 1 {
            return None;
        }
        let added = project::added_directories(&vcx_config::homes::home_directory());
        let directory = shell_directory(item, &self.cwd, &self.conversation_directory, &added).filter(|directory| *directory != self.cwd)?;
        Some(self.move_directory(&directory))
    }

    /// A turn that edited files in another project moves the session there.
    fn turn_moved(&mut self) -> Option<Effect> {
        if self.turn_edits.is_empty() {
            return None;
        }
        let home = vcx_config::homes::home_directory();
        let directory = project::turn_directory(&self.turn_edits, &self.cwd, &self.conversation_directory, &project::added_directories(&home), &home.to_string_lossy())?;
        Some(self.move_directory(&directory))
    }

    /// The footer is read again when the turn's last edit is in another folder than the one before.
    fn edited_elsewhere(&mut self) -> Option<Effect> {
        let path = std::mem::take(&mut self.turn_edits).pop()?;
        let folder = std::path::Path::new(&path).parent().map_or_else(String::new, |folder| folder.to_string_lossy().into_owned());
        (self.edited_folder.as_ref() != Some(&folder)).then(|| {
            self.edited_folder = Some(folder);
            Effect::RefreshRepository
        })
    }

    pub fn apply_repository(&mut self, footer: &repository::Footer) {
        self.repository_directory = footer.directory.clone();
        self.repository = footer.repository.clone();
        self.branch = footer.branch.clone();
        self.repository_status = footer.status.clone();
        self.repository_changes = footer.changes.clone();
    }

    /// A moved session shows no repository until its new folder is read.
    pub fn clear_repository(&mut self) {
        self.repository_directory = None;
        self.branch.clear();
        self.repository_status.clear();
        self.repository_changes.clear();
        self.pull_request.clear();
    }

    /// An adapter's agent stopped: on purpose (`ended`), or crashed, with why and its log's last error line, to restart.
    pub fn agent_stopped(&mut self, params: &Object) -> Vec<Effect> {
        self.clear_retry_notice();
        let ended = params.get("ended") == Some(&Value::Bool(true));
        if params.contains_key("reason") && !ended {
            self.lost(false);
            return vec![Effect::Crashed(params.clone())];
        }
        let mut message = error_message(params).to_owned();
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
        self.default_effort = text(result, "reasoningEffort").map(str::to_owned).or_else(|| if self.provider == "claude" { self.configured_effort() } else { None });
        if let Some(policy) = text(result, "approvalPolicy") {
            let full = result.get("sandbox").and_then(|sandbox| sandbox.get("type")).and_then(Value::as_str) == Some("dangerFullAccess");
            self.active_mode = if policy == "never" && full { "bypass" } else { "ask" }.into();
        }
        self.context.clear();
        self.context_used = None;
        self.context_limit = if self.provider == "claude" { self.remembered_window(&self.model) } else { None };
        self.instruction_sources(result);
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
        self.trace_prompt(text, images.len(), retry);
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
        self.busy = true;
        self.stop_requested = false;
        self.stop_source = None;
        self.needs_attention = false;
        self.status = if was_busy { "Sending guidance…" } else { "Working…" }.into();
        let params = self.turn_params(&id, content.clone(), was_busy);
        Some(Outgoing { id, method: if was_busy { "turn/steer" } else { "turn/start" }, params, was_busy, saved_draft, content })
    }

    /// The Swift `sendWith` after `activate(nextAccount, keepRows: true)`: the prompt already in the chat goes to the
    /// account just switched to, on its thread and with its model.
    pub fn resume_send(&mut self, outgoing: &mut Outgoing) {
        self.busy = true;
        self.status = "Working…".into();
        outgoing.params = self.turn_params(&outgoing.id, outgoing.content.clone(), outgoing.was_busy);
    }

    fn turn_params(&self, id: &str, mut content: Vec<Value>, was_busy: bool) -> Value {
        if !self.injected_context.is_empty() {
            content.insert(0, json!({"type": "text", "text": self.injected_context}));
        }
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
        params
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

    /// The agent dropped a queued prompt: it leaves the chat, and the guidance it added to the turn's input goes too.
    pub fn unsent(&mut self, id: &str) {
        let content = self.items.get(id).and_then(|item| item.get("content")).and_then(Value::as_array).cloned().unwrap_or_default();
        let guidance = format!("\n\nAdditional guidance: {}", content.iter().filter_map(|piece| piece.get("text").and_then(Value::as_str)).collect::<String>());
        let images = content.iter().filter(|piece| piece.get("path").is_some()).count();
        if let Some((input, paths)) = self.pending_input.as_mut() {
            if let Some(kept) = input.strip_suffix(&guidance) {
                *input = kept.to_owned();
                paths.truncate(paths.len().saturating_sub(images));
            }
        }
        let rows: Vec<String> = self.rows.iter().filter(|row| row.kind == "user" && row.items.first().map(String::as_str) == Some(id)).map(|row| row.id.clone()).collect();
        for row in rows {
            self.remove_row(&row);
        }
    }

    /// The Swift `sendWaitingNow`'s choice: the last prompt, sent during the turn and not yet read, goes now.
    pub fn begin_send_now(&mut self) -> Option<SendNow> {
        let row = self.rows.last().filter(|row| row.kind == "user")?;
        let id = row.items.first().filter(|id| self.busy && self.sending_now.is_none() && self.turn_prompt.as_ref() != Some(*id))?.clone();
        if self.provider == "claude" {
            return self.queued(row).then_some(SendNow::Queued(id));
        }
        self.sending_now = Some(id);
        Some(SendNow::Interrupt)
    }

    /// The turn/start that answers `prompt`, already in the agent's thread, once the turn Shift+Return stopped ended.
    pub fn continue_with(&mut self, prompt: &str) -> Option<Value> {
        let thread = self.thread_id.clone().filter(|_| self.ready && !self.busy && !self.changing)?;
        self.busy = true;
        self.turn_prompt = Some(prompt.to_owned());
        self.active_actions.clear();
        self.status = "Working…".into();
        let mut params = json!({"threadId": thread, "input": [], "cwd": self.cwd});
        if let Some(effort) = &self.effort {
            params["effort"] = json!(effort);
        }
        Some(params)
    }

    pub fn continue_failed(&mut self, message: &str) {
        self.busy = false;
        self.needs_attention = true;
        self.status = "Send failed".into();
        self.notice(&format!("Prompt was not sent: {message}"));
    }

    /// The Swift `effectiveEffort`: the effort the next turn runs at.
    pub fn effective_effort(&self) -> Option<String> {
        let default = || self.model_default_efforts.get(&self.model).and_then(Value::as_str).map(str::to_owned);
        self.effort.clone().or_else(|| self.default_effort.clone()).or_else(default).or_else(|| (self.provider == "qwen").then(|| "off".to_owned()))
    }

    /// The thread reopened on `model`; an already loaded Codex thread returns its old model, and turn/start applies the
    /// selection.
    pub fn model_changed(&mut self, result: &Object, model: &str, effort: Option<String>) {
        self.model = if self.provider == "codex" { model } else { text(result, "model").unwrap_or(model) }.to_owned();
        self.default_effort = text(result, "reasoningEffort").map(str::to_owned).or_else(|| match self.provider.as_str() {
            "claude" => self.configured_effort(),
            _ => self.model_default_efforts.get(&self.model).and_then(Value::as_str).map(str::to_owned),
        });
        self.effort = effort;
    }

    fn configured_effort(&self) -> Option<String> {
        configured_claude_effort(self.account.get("home").and_then(Value::as_str), &self.conversation_directory, &self.model)
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
    fn codexs_question_tool_is_asked_as_a_question() {
        let mut session = opened();
        let options = [json!({"label": "A", "description": ""}), json!({"label": "B", "description": ""})];
        let call = json!({"threadId": "T", "tool": "AskUserQuestion", "arguments": {"questions": [{"question": "Which?", "header": "H", "multiSelect": false, "options": options}]}});

        let effects = session.request(json!(5), "item/tool/call", call.as_object().unwrap());

        let asked = &session.metadata()["permissions"][0];
        assert!(effects.is_empty());
        assert_eq!((&asked["method"], &asked["params"]["vcxQuestionTool"], &asked["params"]["questions"][0]["id"]), (&json!("item/tool/requestUserInput"), &json!(true), &json!("question-0")));
    }

    #[test]
    fn an_invalid_question_is_refused_to_the_agent_without_asking() {
        let mut session = opened();
        let call = json!({"threadId": "T", "tool": "AskUserQuestion", "arguments": {"questions": []}});

        let effects = session.request(json!(6), "item/tool/call", call.as_object().unwrap());

        assert_eq!(effects, [Effect::Respond { id: json!(6), result: crate::question::refused() }]);
        assert!(session.permissions.is_empty());
    }

    #[test]
    fn the_metadata_names_the_fleet_label_and_the_progress_and_task_files() {
        let mut session = opened();
        session.fleet_context_file = crate::fleet::create();
        std::fs::write(&session.fleet_context_file, "Build feature\n").unwrap();

        let meta = session.metadata();
        crate::fleet::remove(&session.fleet_context_file);

        let folder = std::path::Path::new(&session.fleet_context_file).parent().unwrap();
        assert_eq!(meta["fleetContext"], json!("Build feature"));
        assert_eq!((&meta["progressFile"], &meta["taskFile"]), (&json!(folder.join("task.progress")), &json!(folder.join("task.goal"))));
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

    fn scratch() -> PathBuf {
        let folder = std::env::temp_dir().join(format!("vcx-session-{}", new_id()));
        std::fs::create_dir_all(&folder).unwrap();
        folder
    }

    fn claude(state: &Path, home: &Path) -> Session {
        let mut session = Session::new(&home.to_string_lossy(), &state.to_string_lossy());
        (session.provider, session.provider_label, session.model) = ("claude".into(), "Claude".into(), "Claude".into());
        session.account = json!({"id": "claude-default", "provider": "claude", "home": home});
        session.opened(json!({"thread": {"id": "T"}, "model": "Claude"}).as_object().unwrap(), &[], false);
        session
    }

    fn texts(session: &Session) -> Vec<String> {
        session.rows().iter().filter_map(|row| session.item(&row.items[0])?.get("text")?.as_str().map(str::to_owned)).collect()
    }

    #[test]
    fn a_new_session_connects_before_any_token_is_reported() {
        let session = Session::new("/tmp", "/tmp/state");

        assert_eq!((session.status.as_str(), session.tokens.as_str()), ("Connecting…", "Not reported"));
    }

    #[test]
    fn a_resolved_claude_model_takes_its_remembered_window_and_configured_effort() {
        let (state, home) = (scratch(), scratch());
        std::fs::write(state.join(CONTEXT_WINDOWS_FILE), r#"{"claude-opus-5-5": 1000000}"#).unwrap();
        std::fs::write(home.join("settings.json"), r#"{"effortLevel": "high", "modelSettings": {"claude-opus-5-5": {"effortLevel": "xhigh"}}}"#).unwrap();
        let mut session = claude(&state, &home);

        session.event(&event(json!({"method": "vcx/model", "params": {"model": "claude-opus-5-5"}})));

        assert_eq!(session.model, "claude-opus-5-5");
        assert_eq!((session.context_limit, session.default_effort.as_deref()), (Some(1_000_000), Some("xhigh")));
        let _ = (std::fs::remove_dir_all(state), std::fs::remove_dir_all(home));
    }

    #[test]
    fn a_reported_context_window_is_remembered_for_the_next_session_of_that_model() {
        let (state, home) = (scratch(), scratch());
        let mut first = claude(&state, &home);
        first.event(&event(json!({"method": "vcx/context", "params": {"used": 1200, "model": "claude-fixture"}})));
        first.event(&event(json!({"method": "vcx/context", "params": {"limit": 200000, "model": "claude-fixture"}})));
        let mut next = claude(&state, &home);

        next.event(&event(json!({"method": "vcx/context", "params": {"used": 3400, "model": "claude-fixture"}})));

        assert_eq!((first.context_used, first.context_limit), (Some(1200), Some(200_000)));
        assert_eq!((next.context_used, next.context_limit), (Some(3400), Some(200_000)));
        let _ = (std::fs::remove_dir_all(state), std::fs::remove_dir_all(home));
    }

    #[test]
    fn token_counts_carry_thousands_separators() {
        let mut claude = opened();
        let mut codex = opened();

        claude.event(&event(json!({"method": "vcx/tokens", "params": {"input": 12345, "output": 678}})));
        codex.event(&event(json!({"method": "thread/tokenUsage/updated", "params": {"threadId": "T", "tokenUsage": {"total": {"totalTokens": 1234567}}}})));

        assert_eq!(claude.tokens, "12,345 in · 678 out");
        assert_eq!(codex.tokens, "1,234,567 total");
    }

    #[test]
    fn counts_the_agents_background_tasks() {
        let mut session = opened();

        session.event(&event(json!({"method": "vcx/backgroundTasks", "params": {"count": 2}})));

        assert_eq!(session.metadata()["backgroundTasks"], 2);
    }

    #[test]
    fn a_queued_prompt_is_flagged_until_the_agent_reads_it() {
        let mut session = opened();
        let outgoing = session.begin_send("later", &[], None, None, false).unwrap();

        session.event(&event(json!({"method": "vcx/userQueue", "params": {"id": outgoing.id, "queued": true}})));
        let queued = session.item(&outgoing.id).unwrap().get("queued").cloned();
        session.event(&event(json!({"method": "vcx/userQueue", "params": {"id": outgoing.id, "queued": false}})));

        assert_eq!(queued, Some(json!(true)));
        assert!(!session.item(&outgoing.id).unwrap().contains_key("queued"));
    }

    #[test]
    fn the_claude_catalog_sets_the_models_their_aliases_and_efforts() {
        let mut session = opened();
        let models = json!([
            {"value": "opus", "resolvedModel": "claude-opus-5-5", "supportedEffortLevels": ["low", "high"]},
            {"value": "haiku", "supportsEffort": false, "supportedEffortLevels": ["low"]}
        ]);

        session.event(&event(json!({"method": "vcx/catalog", "params": {"models": models}})));

        assert_eq!(session.models, ["opus", "haiku"]);
        assert_eq!(session.metadata()["modelAliases"], json!({"opus": "claude-opus-5-5"}));
        assert_eq!(Value::Object(session.model_efforts.clone()), json!({"opus": ["low", "high"], "haiku": []}));
    }

    #[test]
    fn retries_keep_one_notice_updated_until_the_agent_makes_progress() {
        let mut session = opened();
        session.begin_send("hi", &[], None, None, false).unwrap();
        session.event(&event(json!({"method": "turn/started", "params": {"threadId": "T", "turn": {"id": "U"}}})));
        let retry = |attempt: &str| json!({"method": "error", "params": {"threadId": "T", "willRetry": true, "error": {"message": attempt}}});

        session.event(&event(retry("Reconnecting 1/5")));
        session.event(&event(retry("Reconnecting 2/5")));
        let during = (kinds(&session).len(), texts(&session).last().cloned(), session.status.clone());
        session.event(&event(json!({"method": "item/agentMessage/delta", "params": {"threadId": "T", "itemId": "a", "delta": "back"}})));

        assert_eq!(during, (2, Some("Reconnecting 2/5".into()), "Reconnecting…".into()));
        assert_eq!(kinds(&session), ["user", "assistant"]);
        assert_eq!(session.status, "Working…");
    }

    #[test]
    fn the_websockets_fallback_warning_is_a_retry_notice() {
        let mut session = opened();
        let warning = json!({"method": "warning", "params": {"threadId": "T", "message": "Falling back from WebSockets to HTTPS transport: closed"}});

        session.event(&event(warning.clone()));
        session.event(&event(warning));

        assert_eq!(kinds(&session), ["notice"]);
        assert_eq!(session.status, "Reconnecting…");
    }

    #[test]
    fn an_error_without_a_message_says_codex_reported_an_error() {
        let mut session = opened();

        session.event(&event(json!({"method": "vcx/error", "params": {}})));
        session.agent_stopped(json!({"ended": true}).as_object().unwrap());

        assert_eq!(texts(&session), ["Codex reported an error.", "Codex reported an error."]);
        assert_eq!(session.status, "Ended");
    }

    #[test]
    fn a_used_up_codex_window_rests_the_account_and_a_claude_one_does_not() {
        let reset = 4_000_000_000.0;
        let limits = json!({"method": "account/rateLimits/updated", "params": {"rateLimits": {"primary": {"usedPercent": 100.0, "windowDurationMins": 300, "resetsAt": reset}}}});
        let mut session = opened();

        let rested = session.event(&event(limits.clone()));
        session.provider = "claude".into();
        let kept = session.event(&event(limits));

        assert_eq!(rested, [Effect::Rest(reset)]);
        assert!(kept.is_empty());
        assert!(session.usage.starts_with("100% usage - reset "), "{}", session.usage);
        assert!(!session.usage_loading);
    }

    #[test]
    fn a_periodic_refresh_reads_codex_usage_once_a_minute_and_never_polls_claude() {
        let now = 1_000_000.0;
        let mut codex = opened();
        let mut claude = opened();
        claude.provider = "claude".into();
        claude.last_rate = json!({"primary": {"usedPercent": 5.0, "windowDurationMins": 300, "resetsAt": now + 120.0}}).as_object().unwrap().clone();

        let codex_reads = [codex.begin_usage_refresh(false, now), codex.begin_usage_refresh(false, now + 59.0), codex.begin_usage_refresh(false, now + 60.0), codex.begin_usage_refresh(true, now + 61.0)];
        let claude_reads = [claude.begin_usage_refresh(false, now), claude.begin_usage_refresh(false, now + 600.0), claude.begin_usage_refresh(true, now + 601.0)];

        assert_eq!(codex_reads, [true, false, true, true]);
        assert_eq!(claude_reads, [false, false, true]);
        assert_eq!(claude.usage, "5% usage - reset now");
    }

    #[test]
    fn a_turn_whose_last_edit_is_in_another_folder_reads_the_repository_again() {
        let completed = json!({"method": "turn/completed", "params": {"threadId": "T", "turn": {"id": "U", "status": "completed"}}});
        let edit = |path: &str| json!({"method": "item/completed", "params": {"threadId": "T", "item": {"id": path, "type": "commandExecution", "command": format!("Edit\n{}", json!({"file_path": path}))}}});
        let mut session = opened();

        session.event(&event(edit("/work/a/one.txt")));
        let moved = session.event(&event(completed.clone()));
        session.event(&event(edit("/work/a/two.txt")));
        let same = session.event(&event(completed.clone()));
        let unedited = session.event(&event(completed));

        assert_eq!(moved, [Effect::RefreshRepository]);
        assert!(same.is_empty() && unedited.is_empty());
        assert_eq!(session.edited_folder.as_deref(), Some("/work/a"));
    }

    fn started(session: &mut Session) {
        session.event(&event(json!({"method": "turn/started", "params": {"threadId": "T", "turn": {"id": "U"}}})));
    }

    #[test]
    fn shift_return_on_codex_stops_the_turn_and_a_turn_without_input_answers_the_waiting_prompt() {
        let mut session = opened();
        session.begin_send("first", &[], None, None, false).unwrap();
        started(&mut session);
        let waiting = session.begin_send("now", &[], None, None, false).unwrap();

        let choice = session.begin_send_now();
        session.begin_stop("Shift+Return");
        let effects = session.event(&event(json!({"method": "turn/completed", "params": {"threadId": "T", "turn": {"id": "U", "status": "interrupted"}}})));
        let params = session.continue_with(&waiting.id).unwrap();

        assert_eq!(choice, Some(SendNow::Interrupt));
        assert_eq!(effects, [Effect::ContinueWith(waiting.id.clone())]);
        assert_eq!(kinds(&session), ["user", "user"], "no interruption notice");
        assert_eq!((params["input"].clone(), session.busy, session.status.as_str()), (json!([]), true, "Working…"));
    }

    #[test]
    fn shift_return_on_claude_sends_only_a_prompt_still_in_its_queue() {
        let mut session = opened();
        session.provider = "claude".into();
        session.begin_send("first", &[], None, None, false).unwrap();
        started(&mut session);
        let waiting = session.begin_send("now", &[], None, None, false).unwrap();

        let read = session.begin_send_now();
        session.event(&event(json!({"method": "vcx/userQueue", "params": {"id": waiting.id, "queued": true}})));
        let queued = session.begin_send_now();

        assert_eq!((read, queued), (None, Some(SendNow::Queued(waiting.id))));
    }

    #[test]
    fn a_withdrawn_queued_prompt_leaves_the_chat_and_the_turns_input() {
        let mut session = opened();
        session.begin_send("first", &["/a.png".into()], None, None, false).unwrap();
        started(&mut session);
        let later = session.begin_send("later", &["/b.png".into()], None, None, false).unwrap();

        session.unsent(&later.id);

        assert_eq!(session.pending_input, Some(("first".into(), vec!["/a.png".into()])));
        assert_eq!(kinds(&session), ["user"]);
    }

    #[test]
    fn escape_before_any_output_takes_the_prompt_back_into_the_draft_without_a_notice() {
        let mut session = opened();
        session.begin_send("fix [Image #1]", &["/a.png".into()], None, None, false).unwrap();
        started(&mut session);

        session.begin_stop("Escape");
        session.event(&event(json!({"method": "turn/completed", "params": {"threadId": "T", "turn": {"id": "U", "status": "interrupted"}}})));

        assert!(kinds(&session).is_empty());
        assert_eq!(session.draft, [json!({"type": "text", "text": "fix "}), json!({"type": "localImage", "path": "/a.png"})]);
        assert_eq!((session.status.as_str(), session.needs_attention), ("Ready", false));
    }

    #[test]
    fn a_claude_conversation_opens_at_the_effort_his_settings_give_its_model() {
        let (state, home) = (scratch(), scratch());
        std::fs::write(home.join("settings.json"), r#"{"effortLevel": "high"}"#).unwrap();

        let session = claude(&state, &home);

        assert_eq!(session.default_effort.as_deref(), Some("high"));
        let _ = (std::fs::remove_dir_all(state), std::fs::remove_dir_all(home));
    }

    #[test]
    fn a_codex_model_change_keeps_the_selection_over_the_threads_old_model_and_takes_its_default_effort() {
        let mut session = opened();
        session.model_default_efforts = json!({"next": "medium"}).as_object().unwrap().clone();

        session.model_changed(json!({"model": "old"}).as_object().unwrap(), "next", None);

        assert_eq!((session.model.as_str(), session.default_effort.as_deref(), session.effective_effort().as_deref()), ("next", Some("medium"), Some("medium")));
    }
}
