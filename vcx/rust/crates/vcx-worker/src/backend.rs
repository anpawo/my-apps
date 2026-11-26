//! A session's runtime, ported from the Swift `SessionBackend`: it owns the agent process, feeds its events to the
//! session, runs the frontend's actions, publishes patches and keeps the checkpoint.

use crate::checkpoint::Store;
use crate::fallback;
use crate::provider;
use crate::server::{Action, Backend};
use crate::session::{self as model, Effect, Session};
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use vcx_agents::claude_stream::usage_limit;
use vcx_agents::process::{last_error_line, log_tail};
use vcx_agents::rpc::METHOD_NOT_FOUND;
use vcx_agents::{AgentError, Connection, Inbound, Incoming};
use vcx_config::{Account, Settings, SettingsFile};

pub type Object = serde_json::Map<String, Value>;

/// Patches are gathered this long, so a streamed answer goes out a few times a second rather than per word.
const PUBLISH_DELAY: Duration = Duration::from_millis(80);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
const STOP_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_WINDOW_STATE_BYTES: usize = 65_536;
const TURNS_PAGE: u64 = 50;
const CATALOG_LIMIT: u64 = 100;
const FRONTEND_COMMANDS: [&str; 7] = ["/window", "/settings", "/login", "/attach", "/preview", "/quit", "/exit"];
const INTERRUPTING_ACTIONS: [&str; 3] = ["answer", "stop", "checkpoint"];
const CLAUDE_SETTINGS: &str = "claude-settings.json";
const MODE_TIMEOUT: Duration = Duration::from_secs(20);
const PROVIDER_CHOICES: [&str; 5] = ["auto", "claude", "codex", "qwen", "agy"];

/// How sessions start their agent.
pub struct Config {
    /// A test's agent in place of the provider's command: no sign-in check and no usage read.
    pub fixture: Option<Vec<String>>,
    /// A test's provider; a fixture without one speaks Codex, as the Swift worker's always does.
    pub provider: Option<String>,
    /// His settings folder: the default provider, the accounts, the mode and Qwen's endpoint.
    pub settings: PathBuf,
    pub store: Store,
    pub state_directory: PathBuf,
    /// The rate-limit waits are multiplied by this: 1, or a test's fraction.
    pub retry_scale: f64,
}

pub struct SessionBackend {
    id: String,
    config: Rc<Config>,
    session: RefCell<Session>,
    agent: RefCell<Option<Connection>>,
    on_change: RefCell<Option<Rc<dyn Fn(Object)>>>,
    scheduled: Cell<bool>,
    closed: Cell<bool>,
    started: watch::Sender<bool>,
    loading: Cell<bool>,
    buffered: RefCell<Vec<Inbound>>,
    window_state: RefCell<Value>,
    consumed_generation: Cell<i64>,
    recovery: RefCell<Option<Object>>,
    persisted: RefCell<Option<Object>>,
    /// Counts the agents this session started: events of one it replaced no longer count.
    generation: Cell<u64>,
    /// Where the running agent's part of the log starts.
    log_start: Cell<u64>,
    /// The provider the session follows: a test's, his default's, then the one `/provider` names.
    provider_choice: RefCell<Option<String>>,
    /// The mode `/perms` chose for this session over his settings'.
    mode_choice: RefCell<Option<String>>,
    /// A usage limit is moving the conversation to another account.
    transferring: Cell<bool>,
    /// A `/provider` asked during a turn, run once it ends.
    pending_command: RefCell<Option<String>>,
}

fn text<'a>(object: &'a Object, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

fn object(value: Value) -> Object {
    match value {
        Value::Object(object) => object,
        _ => Object::new(),
    }
}

impl SessionBackend {
    /// Makes the runtime of a new or cold-reopened session and starts its agent in the background.
    pub fn start(params: &Object, config: Rc<Config>) -> Result<Rc<Self>, String> {
        let id = text(params, "sessionId").ok_or("Attach requires a session id.")?.to_owned();
        let saved = config.store.read(&id).map_err(|error| error.to_string())?;
        let recovery = params.get("recovery").and_then(Value::as_object).cloned().or(saved);
        let cwd = recovery.as_ref().and_then(|state| text(state, "conversationDirectory")).or_else(|| text(params, "cwd")).unwrap_or("/").to_owned();
        let mut session = Session::new(&cwd, &config.state_directory.to_string_lossy());
        let mut window_state = json!({});
        let mut consumed = -1;
        if let Some(state) = &recovery {
            window_state = state.get("windowState").cloned().filter(Value::is_object).unwrap_or(window_state);
            consumed = state.get("consumedGeneration").and_then(Value::as_i64).unwrap_or(-1);
            if let Some(record) = text(state, "recordID").filter(|record| !record.is_empty()) {
                session.record_id = record.to_owned();
            }
            if let Some(Value::Array(draft)) = state.get("draft") {
                session.set_draft(draft.clone(), state.get("draftGeneration").and_then(Value::as_i64).unwrap_or(0));
            }
        }
        let backend = Rc::new(Self {
            id,
            config,
            session: RefCell::new(session),
            agent: RefCell::default(),
            on_change: RefCell::default(),
            scheduled: Cell::new(false),
            closed: Cell::new(false),
            started: watch::channel(false).0,
            loading: Cell::new(true),
            buffered: RefCell::default(),
            window_state: RefCell::new(window_state),
            consumed_generation: Cell::new(consumed),
            recovery: RefCell::new(recovery),
            persisted: RefCell::default(),
            generation: Cell::new(0),
            log_start: Cell::new(0),
            provider_choice: RefCell::default(),
            mode_choice: RefCell::default(),
            transferring: Cell::new(false),
            pending_command: RefCell::default(),
        });
        let (starting, params) = (Rc::clone(&backend), params.clone());
        tokio::task::spawn_local(async move {
            starting.connect(&params).await;
            starting.loading.set(false);
            let pending = std::mem::take(&mut *starting.buffered.borrow_mut());
            for message in pending {
                starting.apply(message);
            }
            starting.started.send_replace(true);
            starting.schedule();
            if let Some(prompt) = text(&params, "prompt").filter(|prompt| !prompt.is_empty()) {
                if let Err(error) = Rc::clone(&starting).send(prompt, &[], None, None, false).await {
                    starting.session.borrow_mut().notice(&error);
                    starting.schedule();
                }
            }
        });
        Ok(backend)
    }

    fn agent(&self) -> Result<Connection, String> {
        self.agent.borrow().clone().filter(|agent| !agent.is_closed()).ok_or_else(|| "The agent is not running.".to_owned())
    }

    async fn request(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, String> {
        self.agent()?.request(method, params, timeout).await.map_err(|error| error.message)
    }

    async fn connect(self: &Rc<Self>, params: &Object) {
        if let Err(error) = self.open_agent(params).await {
            let mut session = self.session.borrow_mut();
            session.ready = false;
            session.usage_loading = false;
            session.status = error.clone();
            session.notice(&error);
            return;
        }
        let recovery = self.recovery.borrow().clone();
        if let Some(mut state) = recovery {
            let session = &mut *self.session.borrow_mut();
            state.insert("draft".into(), Value::Array(session.draft.clone()));
            state.insert("draftGeneration".into(), json!(session.draft_generation));
            session.recovered(&state);
        }
        let backend = Rc::clone(self);
        tokio::task::spawn_local(async move { backend.refresh_catalog().await });
    }

    fn settings(&self) -> Settings {
        SettingsFile::new(&self.config.settings).load().unwrap_or_else(|error| {
            self.session.borrow_mut().notice(&format!("Could not read the settings ({error}); the defaults are used."));
            Settings::default()
        })
    }

    fn preferred_mode(&self, settings: &Settings) -> String {
        self.mode_choice.borrow().clone().unwrap_or_else(|| settings.mode())
    }

    /// The agent's stderr, one file per conversation, as the Swift `agentLogFile`.
    fn log_path(&self) -> PathBuf {
        let session = self.session.borrow();
        Path::new(&session.state_directory).join("logs").join(format!("{}.log", session.record_id))
    }

    async fn open_agent(self: &Rc<Self>, params: &Object) -> Result<(), String> {
        let settings = self.settings();
        let saved = self.recovery.borrow().as_ref().and_then(|state| text(state, "accountID")).map(str::to_owned);
        let account = provider::choose(&settings, self.config.provider.as_deref(), saved.as_deref(), fallback::now());
        *self.provider_choice.borrow_mut() = Some(self.config.provider.clone().unwrap_or_else(|| settings.default_provider()));
        self.session.borrow_mut().status = format!("Connecting to {}…", provider::label(&account.provider));
        let (agent, incoming) = self.start_agent(&account, &settings).await?;
        self.install(&account, agent, incoming, self.preferred_mode(&settings));
        let resume = self.resume_target(params);
        match resume {
            Some(thread) => {
                if let Err(error) = self.open(Some(&thread), false).await {
                    self.session.borrow_mut().notice(&format!("Could not reopen the saved conversation ({error}); a new one was started."));
                    self.open(None, false).await?;
                }
            }
            None => self.open(None, false).await?,
        }
        Ok(())
    }

    /// Starts `account`'s agent, greeted when it is Codex; the running one is left alone until this succeeds.
    async fn start_agent(&self, account: &Account, settings: &Settings) -> Result<(Connection, mpsc::UnboundedReceiver<Incoming>), String> {
        let cwd = self.session.borrow().cwd.clone();
        let log = self.log_path();
        self.log_start.set(std::fs::metadata(&log).map_or(0, |meta| meta.len()));
        let mode = self.preferred_mode(settings);
        let claude_settings = self.config.settings.join(CLAUDE_SETTINGS);
        let start = provider::Start { account, settings, mode: &mode, log, claude_settings, fixture: self.config.fixture.clone(), cwd: &cwd };
        let (agent, incoming) = provider::connect(start).await?;
        // Only Codex is a JSON-RPC server to greet and to ask for its sign-in; the adapters answer the rest themselves.
        if matches!(agent, Connection::Codex(_)) {
            if let Err(error) = self.greet(&agent).await {
                agent.close();
                return Err(error);
            }
        }
        Ok((agent, incoming))
    }

    async fn greet(&self, agent: &Connection) -> Result<(), String> {
        let failed = |error: AgentError| error.message;
        let client = json!({"clientInfo": {"name": "vcx", "title": "Vibe Code X", "version": "0.2.0"}, "capabilities": {"experimentalApi": true}});
        agent.request("initialize", client, REQUEST_TIMEOUT).await.map_err(failed)?;
        agent.notify("initialized", None).map_err(failed)?;
        if self.config.fixture.is_none() {
            let status = agent.request("account/read", json!({"refreshToken": false}), REQUEST_TIMEOUT).await.map_err(failed)?;
            if status["account"]["type"] != "chatgpt" {
                return Err("Sign in with a ChatGPT subscription in Settings. vcx does not use API-key billing.".into());
            }
        }
        Ok(())
    }

    /// Makes `agent` the session's: the one before is closed and its events no longer count.
    fn install(self: &Rc<Self>, account: &Account, agent: Connection, incoming: mpsc::UnboundedReceiver<Incoming>, mode: String) {
        if let Some(previous) = self.agent.replace(Some(agent)) {
            previous.close();
        }
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        tokio::task::spawn_local(Rc::clone(self).pump(incoming, generation));
        let mut session = self.session.borrow_mut();
        session.provider = account.provider.clone();
        session.provider_label = provider::label(&account.provider);
        session.model = session.provider_label.clone();
        session.account = json!({"id": account.id, "name": account.name, "provider": account.provider});
        session.active_mode = mode;
        session.mode_override = false;
        session.ready = false;
        session.busy = false;
        session.turn_id = None;
        session.permissions.clear();
        session.active_actions.clear();
        session.usage.clear();
        session.usage_loading = true;
        session.status = format!("Connecting to {}…", session.provider_label);
    }

    /// Moves the conversation to `account`'s agent on a new thread, handed the recent messages, as the Swift
    /// `activate` does with `keepRows`; `reason` is told when one is given.
    async fn activate(self: &Rc<Self>, account: &Account, reason: Option<&str>) -> Result<(), String> {
        if self.session.borrow().changing {
            return Err("A connection change is already in progress.".into());
        }
        self.session.borrow_mut().changing = true;
        self.schedule();
        let result = self.switch_to(account, reason).await;
        self.session.borrow_mut().changing = false;
        self.schedule();
        result
    }

    async fn switch_to(self: &Rc<Self>, account: &Account, reason: Option<&str>) -> Result<(), String> {
        let settings = self.settings();
        let (agent, incoming) = self.start_agent(account, &settings).await?;
        let previous = self.session.borrow().account["id"].clone();
        self.session.borrow_mut().flush();
        let handoff = fallback::handoff_context(&self.session.borrow());
        self.install(account, agent, incoming, self.preferred_mode(&settings));
        self.session.borrow_mut().injected_context = handoff;
        if let Err(error) = self.open(None, true).await {
            self.session.borrow_mut().ready = false;
            return Err(error);
        }
        let mut session = self.session.borrow_mut();
        if previous != json!(account.id) {
            session.effort = None;
        }
        if let Some(reason) = reason {
            let passed = if session.injected_context.is_empty() { "" } else { " Recent messages are passed to it as context." };
            let message = format!("Connected to {}: {reason}.{passed}", session.provider_label);
            session.notice(&message);
        }
        Ok(())
    }

    /// The account is not tried again before `reset` (seconds since 1970); his other sessions read it too.
    fn rest(&self, account: &str, reset: f64) {
        let rested = SettingsFile::new(&self.config.settings).update(|settings| {
            let _ = settings.set_limit(account, reset);
        });
        if let Err(error) = rested {
            self.session.borrow_mut().notice(&format!("Could not record the usage limit: {error}"));
        }
    }

    /// The first available account of the session's provider choice takes over; one at its own usage limit is
    /// rested and the next is tried. `false` when none is available.
    async fn activate_available(self: &Rc<Self>) -> Result<bool, String> {
        let settings = self.settings();
        let choice = self.provider_choice.borrow().clone().unwrap_or_else(|| settings.default_provider());
        let mut failure = None;
        for next in settings.available(&choice, fallback::now()) {
            match self.activate(&next, None).await {
                Ok(()) => return Ok(true),
                Err(error) if usage_limit(&object(json!({"error": error}))) => {
                    self.rest(&next.id, fallback::now() + fallback::LIMIT_PAUSE);
                    failure = Some(error);
                }
                Err(error) => return Err(error),
            }
        }
        failure.map_or(Ok(false), Err)
    }

    /// The Swift `limitReached`: the account rests until its limit resets and the prompt goes to the next one.
    async fn limit_reached(self: Rc<Self>, info: Object) {
        if self.session.borrow().stop_requested || self.transferring.replace(true) {
            return;
        }
        let (account, label) = {
            let session = self.session.borrow();
            (session.account["id"].as_str().unwrap_or_default().to_owned(), session.provider_label.clone())
        };
        self.rest(&account, fallback::limit_reset(&info, fallback::now()));
        let input = {
            let mut session = self.session.borrow_mut();
            session.flush();
            session.busy = false;
            session.turn_id = None;
            session.pending_input.take()
        };
        let switched = match &input {
            Some(_) => self.activate_available().await,
            None => Ok(false),
        };
        match (switched, input) {
            (Ok(true), Some((text, images))) => {
                self.refresh_catalog().await;
                let _ = Rc::clone(&self).send(&text, &images, None, None, true).await;
            }
            (Err(error), _) => {
                let mut session = self.session.borrow_mut();
                session.notice(&format!("Could not connect to the fallback: {error}"));
                session.status = "Fallback connection failed".into();
            }
            _ => {
                let mut session = self.session.borrow_mut();
                session.notice(&format!("{label} reached its usage limit. No enabled fallback is available. Your conversation is saved."));
                session.status = "Usage limit reached".into();
            }
        }
        self.transferring.set(false);
        self.schedule();
    }

    /// A server rate limit passes on its own: the same account retries after a growing wait, three times at most.
    async fn retry_rate_limit(self: Rc<Self>) {
        let (attempt, label) = {
            let session = self.session.borrow();
            (session.auto_resumes, session.provider_label.clone())
        };
        let retries = fallback::RATE_LIMIT_RETRIES.len();
        let Some(delay) = fallback::RATE_LIMIT_RETRIES.get(attempt).copied() else {
            self.session.borrow_mut().notice(&format!("{label} is still rate limited after {retries} retries. Send a message to try again."));
            self.schedule();
            return;
        };
        self.session.borrow_mut().notice(&format!("{label} is rate limited. Retry {} of {retries} in {delay} s.", attempt + 1));
        self.schedule();
        tokio::time::sleep(Duration::from_secs_f64(delay as f64 * self.config.retry_scale)).await;
        if self.closed.get() || !self.session.borrow().ready || self.session.borrow().busy {
            return;
        }
        self.session.borrow_mut().auto_resumes += 1;
        let _ = Rc::clone(&self).send(fallback::KEEP_GOING, &[], None, None, false).await;
    }

    /// The provider thread to reopen: the checkpoint's, or a bare thread id the frontend named.
    fn resume_target(&self, params: &Object) -> Option<String> {
        let saved = self.recovery.borrow().as_ref().and_then(|state| text(state, "threadID")).map(str::to_owned);
        let named = text(params, "resume").filter(|resume| !resume.is_empty() && !resume.starts_with("native:") && *resume != "last").map(str::to_owned);
        saved.or(named)
    }

    async fn open(&self, resume: Option<&str>, keep_rows: bool) -> Result<(), String> {
        let (cwd, mode) = {
            let session = self.session.borrow();
            (session.cwd.clone(), session.active_mode.clone())
        };
        let mut params = json!({"cwd": cwd, "approvalPolicy": model::approval_policy(&mode), "sandbox": model::sandbox(&mode)});
        if let Some(thread) = resume {
            params["threadId"] = json!(thread);
            params["excludeTurns"] = json!(true);
        }
        let method = if resume.is_some() { "thread/resume" } else { "thread/start" };
        let result = object(self.request(method, params, REQUEST_TIMEOUT).await?);
        let id = result.get("thread").and_then(|thread| thread.get("id")).and_then(Value::as_str).ok_or_else(|| format!("{} did not return a conversation.", self.session.borrow().provider_label))?.to_owned();
        if resume.is_some_and(|thread| thread.rsplit(':').next().map(str::to_lowercase) != id.rsplit(':').next().map(str::to_lowercase)) {
            return Err("The agent did not resume the exact requested native conversation.".into());
        }
        let mut history = Vec::new();
        if resume.is_some() {
            let mut cursor: Option<String> = None;
            loop {
                let mut page = json!({"threadId": id, "limit": TURNS_PAGE, "sortDirection": "asc", "itemsView": "full"});
                if let Some(cursor) = &cursor {
                    page["cursor"] = json!(cursor);
                }
                let page = self.request("thread/turns/list", page, REQUEST_TIMEOUT).await?;
                history.extend(page["data"].as_array().cloned().unwrap_or_default());
                cursor = page["nextCursor"].as_str().map(str::to_owned);
                if cursor.is_none() {
                    break;
                }
            }
        }
        self.session.borrow_mut().opened(&result, &history, keep_rows);
        Ok(())
    }

    async fn refresh_catalog(self: &Rc<Self>) {
        let Ok(catalog) = self.request("model/list", json!({"limit": CATALOG_LIMIT}), REQUEST_TIMEOUT).await else { return };
        self.session.borrow_mut().apply_catalog(&object(catalog));
        if self.config.fixture.is_none() {
            if let Ok(limits) = self.request("account/rateLimits/read", json!({}), REQUEST_TIMEOUT).await {
                let event = json!({"method": "account/rateLimits/updated", "params": {"rateLimits": limits["rateLimits"]}});
                if let Inbound::Event(event) = vcx_agents::codex::parse(object(event)) {
                    self.session.borrow_mut().event(&event);
                }
            }
        }
        self.schedule();
    }

    async fn pump(self: Rc<Self>, mut incoming: mpsc::UnboundedReceiver<Incoming>, generation: u64) {
        while let Some(message) = incoming.recv().await {
            if self.generation.get() != generation {
                return;
            }
            match message {
                Incoming::Message(message) if self.loading.get() => self.buffered.borrow_mut().push(message),
                Incoming::Message(message) => self.apply(message),
                Incoming::Exited { reason } => {
                    if !self.closed.get() {
                        // Codex's stderr goes to the log; the adapters read theirs and say why themselves.
                        let log = self.log_path();
                        let line = last_error_line(&log_tail(&log, self.log_start.get()));
                        let mut stopped = object(json!({"message": reason, "log": log.to_string_lossy()}));
                        if let Some(line) = line {
                            stopped.insert("line".into(), json!(line));
                        }
                        self.session.borrow_mut().agent_stopped(&stopped);
                        self.schedule();
                    }
                    return;
                }
            }
        }
    }

    fn apply(self: &Rc<Self>, message: Inbound) {
        let effects = match &message {
            Inbound::Event(event) => self.session.borrow_mut().event(event),
            Inbound::Request { id, method, params } => self.session.borrow_mut().request(id.clone(), method, params),
            Inbound::Invalid(text) => {
                self.session.borrow_mut().notice(text);
                Vec::new()
            }
            Inbound::Response { .. } => Vec::new(),
        };
        for effect in effects {
            match effect {
                Effect::Decline { id, method } => {
                    if let Ok(agent) = self.agent() {
                        let _ = agent.reject(&id, METHOD_NOT_FOUND, &format!("cx does not support {method}"));
                    }
                }
                Effect::Stop => {
                    let backend = Rc::clone(self);
                    tokio::task::spawn_local(async move { backend.stop("Stop command").await });
                }
                Effect::Limit(info) => {
                    tokio::task::spawn_local(Rc::clone(self).limit_reached(info));
                }
                Effect::RateLimited => {
                    tokio::task::spawn_local(Rc::clone(self).retry_rate_limit());
                }
            }
        }
        let idle = !self.session.borrow().busy && !self.transferring.get();
        if let Some(command) = self.pending_command.borrow_mut().take_if(|_| idle) {
            let backend = Rc::clone(self);
            tokio::task::spawn_local(async move {
                if let Err(error) = Rc::clone(&backend).command(&command).await {
                    backend.session.borrow_mut().notice(&error);
                    backend.schedule();
                }
            });
        }
        self.schedule();
    }

    fn schedule(self: &Rc<Self>) {
        if self.closed.get() || self.scheduled.replace(true) {
            return;
        }
        let backend = Rc::clone(self);
        tokio::task::spawn_local(async move {
            tokio::time::sleep(PUBLISH_DELAY).await;
            backend.scheduled.set(false);
            backend.publish();
        });
    }

    fn publish(&self) {
        if self.closed.get() {
            return;
        }
        self.save_checkpoint_noticing();
        let patch = self.session.borrow_mut().take_patch();
        let on_change = self.on_change.borrow().clone();
        if let (Some(patch), Some(on_change)) = (patch, on_change) {
            on_change(patch);
        }
    }

    fn checkpoint_state(&self) -> Object {
        let session = self.session.borrow();
        let mut state = object(json!({
            "cwd": session.cwd, "conversationDirectory": session.conversation_directory, "recordID": session.record_id,
            "stateDirectory": session.state_directory, "draft": session.draft, "draftGeneration": session.draft_generation,
            "windowState": *self.window_state.borrow(), "consumedGeneration": self.consumed_generation.get(), "interrupted": session.busy,
            "accountID": session.account["id"], "threadID": session.thread_id,
        }));
        // Until the reopened agent is ready, the conversation to recover stays the one the checkpoint named.
        if let Some(recovery) = self.recovery.borrow().as_ref().filter(|_| !session.ready) {
            for key in ["cwd", "conversationDirectory", "recordID", "threadID", "stateDirectory", "accountID", "interrupted"] {
                if let Some(value) = recovery.get(key) {
                    state.insert(key.into(), value.clone());
                }
            }
        }
        state
    }

    fn save_checkpoint(&self) -> Result<(), String> {
        let state = self.checkpoint_state();
        if self.persisted.borrow().as_ref() == Some(&state) {
            return Ok(());
        }
        self.config.store.save(&self.id, &state).map_err(|error| error.to_string())?;
        *self.persisted.borrow_mut() = Some(state);
        Ok(())
    }

    fn save_checkpoint_noticing(&self) {
        if let Err(error) = self.save_checkpoint() {
            let message = format!("Could not checkpoint recovery state: {error}");
            let mut session = self.session.borrow_mut();
            if session.status != message {
                session.status = message;
            }
        }
    }

    async fn send(self: Rc<Self>, text: &str, images: &[String], draft: Option<Vec<Value>>, generation: Option<i64>, retry: bool) -> Result<Object, String> {
        let outgoing = self.session.borrow_mut().begin_send(text, images, draft, generation, retry);
        self.schedule();
        let Some(outgoing) = outgoing else { return Ok(Object::new()) };
        if self.recovery.borrow().is_none() {
            let consumed = generation.unwrap_or(self.session.borrow().draft_generation);
            self.consumed_generation.set(self.consumed_generation.get().max(consumed));
        }
        match self.request(outgoing.method, outgoing.params.clone(), REQUEST_TIMEOUT).await {
            Ok(result) => {
                self.session.borrow_mut().send_succeeded(&result);
                let stopping = self.session.borrow().stop_requested;
                if stopping {
                    Rc::clone(&self).stop("Stop command").await;
                }
            }
            Err(error) => self.session.borrow_mut().send_failed(&outgoing, &error),
        }
        self.schedule();
        Ok(Object::new())
    }

    async fn stop(self: Rc<Self>, source: &str) {
        let Some((thread, turn)) = self.session.borrow_mut().begin_stop(source) else {
            self.schedule();
            return;
        };
        match self.request("turn/interrupt", json!({"threadId": thread, "turnId": turn}), STOP_TIMEOUT).await {
            Ok(_) => {
                let mut session = self.session.borrow_mut();
                if session.busy {
                    session.status = "Stopping…".into();
                }
            }
            Err(error) => self.session.borrow_mut().notice(&error),
        }
        self.schedule();
    }

    async fn run(self: Rc<Self>, action: &str, params: Object) -> Result<Object, String> {
        if !INTERRUPTING_ACTIONS.contains(&action) {
            let mut started = self.started.subscribe();
            let _ = started.wait_for(|started| *started).await;
        }
        if self.closed.get() {
            return Err("This runtime session is closed.".into());
        }
        if self.session.borrow().ready {
            self.recovery.borrow_mut().take();
        }
        if let (Some(Value::Array(draft)), Some(generation)) = (params.get("draft"), params.get("generation").and_then(Value::as_i64)) {
            let mut session = self.session.borrow_mut();
            if generation >= session.draft_generation && generation > self.consumed_generation.get() {
                session.set_draft(draft.clone(), generation);
            }
        }
        let result = match action {
            "checkpoint" => {
                if let Some(state) = params.get("windowState").filter(|state| state.is_object()) {
                    if serde_json::to_vec(state).map_or(usize::MAX, |data| data.len()) > MAX_WINDOW_STATE_BYTES {
                        return Err("Window state is too large.".into());
                    }
                    *self.window_state.borrow_mut() = state.clone();
                }
                self.save_checkpoint()?;
                self.schedule();
                return Ok(Object::new());
            }
            "send" => {
                let (Some(text), Some(Value::Array(images))) = (text(&params, "text"), params.get("images")) else { return Err("Invalid message payload.".into()) };
                let images: Option<Vec<String>> = images.iter().map(|image| image.as_str().map(str::to_owned)).collect();
                let Some(images) = images else { return Err("Invalid message payload.".into()) };
                if text.starts_with('/') && images.is_empty() {
                    return Box::pin(Rc::clone(&self).run("command", object(json!({"text": text})))).await;
                }
                let draft = params.get("draft").and_then(Value::as_array).cloned();
                let generation = params.get("generation").and_then(Value::as_i64);
                Rc::clone(&self).send(text, &images, draft, generation, false).await?
            }
            "stop" => {
                Rc::clone(&self).stop(text(&params, "source").unwrap_or("Stop command")).await;
                Object::new()
            }
            "sendNow" => Object::new(),
            "unsend" => {
                let cancelled = self.session.borrow_mut().unsend(text(&params, "id").unwrap_or_default());
                object(json!({"cancelled": cancelled}))
            }
            "answer" => {
                let (Some(rpc_id), Some(method), Some(Value::Object(result))) = (params.get("rpcID"), text(&params, "method"), params.get("result")) else {
                    return Err("This approval is no longer pending.".into());
                };
                let permission = self.session.borrow_mut().take_permission(rpc_id, method).ok_or("This approval is no longer pending.")?;
                if let Err(error) = self.agent()?.respond(&permission.rpc_id, Value::Object(result.clone())) {
                    self.session.borrow_mut().notice(&format!("Could not send your answer: {error}"));
                }
                Object::new()
            }
            "command" => Rc::clone(&self).command(text(&params, "text").ok_or("Invalid command payload.")?).await?,
            "setModel" => {
                let model = text(&params, "model").ok_or("Codex session is busy or the model is unavailable.")?;
                self.set_model(model, text(&params, "effort")).await?;
                Object::new()
            }
            "moveDirectory" => {
                let path = text(&params, "path").filter(|path| path.starts_with('/') && Path::new(path).is_dir()).ok_or("Directory does not exist.")?;
                self.session.borrow_mut().cwd = path.to_owned();
                Object::new()
            }
            "refreshCatalog" => {
                self.refresh_catalog().await;
                Object::new()
            }
            "refreshUsage" | "refreshRepository" | "refreshCapabilities" => Object::new(),
            "switchThread" => {
                let thread = text(&params, "id").map(str::to_owned);
                let success = match thread {
                    Some(thread) => self.open(Some(&thread), false).await.is_ok(),
                    None => self.open(None, false).await.is_ok(),
                };
                object(json!({"success": success}))
            }
            "close" => {
                let busy = self.session.borrow().busy;
                if busy {
                    Rc::clone(&self).stop("Close Session").await;
                }
                self.config.store.remove(&self.id).map_err(|error| error.to_string())?;
                self.close();
                return Ok(Object::new());
            }
            _ => return Err("Unknown runtime action.".into()),
        };
        self.publish();
        Ok(result)
    }

    async fn command(self: Rc<Self>, text: &str) -> Result<Object, String> {
        let token = text.split_whitespace().next().unwrap_or_default().to_lowercase();
        let verb = format!("/{}", token.rsplit(':').next().unwrap_or_default().trim_matches('/'));
        let argument = text.split_once(char::is_whitespace).map_or("", |(_, rest)| rest.trim());
        if FRONTEND_COMMANDS.contains(&verb.as_str()) {
            return Err("This command belongs to the frontend.".into());
        }
        match verb.as_str() {
            "/stop" => Rc::clone(&self).stop("Stop command").await,
            "/new" | "/clear" => self.open(None, false).await?,
            "/provider" | "/model" if !argument.is_empty() => Rc::clone(&self).change_provider(argument).await?,
            "/perms" if !argument.is_empty() => self.change_mode(argument).await?,
            // Anything else is the agent's own command or skill: it reads the text as typed.
            _ => return Rc::clone(&self).send(text, &[], None, None, false).await,
        }
        Ok(Object::new())
    }

    async fn set_model(&self, model: &str, effort: Option<&str>) -> Result<(), String> {
        if !self.session.borrow().models.iter().any(|known| known == model) {
            return Err("Codex session is busy or the model is unavailable.".into());
        }
        let effort = effort.map(str::to_owned).or_else(|| {
            let session = self.session.borrow();
            session.effort.clone().or_else(|| session.default_effort.clone())
        });
        let allowed = effort.as_ref().is_none_or(|effort| self.session.borrow().model_efforts.get(model).and_then(Value::as_array).is_some_and(|efforts| efforts.iter().any(|known| known == effort)));
        if !allowed {
            return Err("Reasoning effort is unavailable for this model.".into());
        }
        let thread = self.session.borrow().thread_id.clone().ok_or("No conversation is open.")?;
        self.request("thread/resume", json!({"threadId": thread, "model": model}), REQUEST_TIMEOUT).await?;
        let mut session = self.session.borrow_mut();
        session.model = model.to_owned();
        session.effort = effort;
        Ok(())
    }

    /// `/provider <provider> [model]` or `/model <model>`, as the Swift `command` runs them: during a turn the
    /// change waits for it to end; a provider other than the running one takes the conversation over.
    async fn change_provider(self: Rc<Self>, argument: &str) -> Result<(), String> {
        if self.session.borrow().changing {
            return Err("A connection change is already in progress.".into());
        }
        let args: Vec<&str> = argument.split_whitespace().collect();
        if self.session.borrow().busy || self.transferring.get() {
            *self.pending_command.borrow_mut() = Some(format!("/model {argument}"));
            self.session.borrow_mut().notice(&format!("Model change queued: {} applies when the current turn ends.", args.join(" ")));
            return Ok(());
        }
        let choice = args[0];
        if !PROVIDER_CHOICES.contains(&choice) {
            if !self.session.borrow().ready {
                return Err("Reconnect before changing models.".into());
            }
            return self.set_model(argument, None).await;
        }
        let settings = self.settings();
        let candidates = if choice == "auto" { settings.available(choice, fallback::now()) } else { settings.candidates(choice).into_iter().filter(|account| account.provider == choice).collect() };
        let next = candidates.into_iter().next().ok_or_else(|| format!("No enabled account is available for {choice}. Enable one with /account or add one with /login."))?;
        let previous = self.provider_choice.replace(Some(choice.to_owned()));
        let (current, ready) = {
            let session = self.session.borrow();
            (session.account["id"].clone(), session.ready)
        };
        if current != json!(next.id) || !ready {
            if let Err(error) = self.activate(&next, Some("provider changed")).await {
                *self.provider_choice.borrow_mut() = previous;
                return Err(error);
            }
            self.refresh_catalog().await;
        }
        if choice != "auto" && settings.limit(&next.id).is_some_and(|reset| reset > fallback::now()) {
            self.rest(&next.id, 0.0);
        }
        match args.get(1) {
            Some(model) => self.set_model(model, args.get(2).copied()).await,
            None => Ok(()),
        }
    }

    /// `/perms`: Codex takes the mode with its next turn, the adapters at once.
    async fn change_mode(&self, argument: &str) -> Result<(), String> {
        if self.session.borrow().busy || self.session.borrow().changing {
            return Err("Stop the current response before changing session settings.".into());
        }
        let mode = match argument {
            "bypass" | "yolo" => "bypass",
            "ask" => "ask",
            _ => return Err("Use /perms bypass or /perms ask.".into()),
        };
        *self.mode_choice.borrow_mut() = Some(mode.to_owned());
        let codex = self.session.borrow().provider == "codex";
        if !codex {
            self.request("cx/mode", json!({"mode": mode}), MODE_TIMEOUT).await?;
        }
        let mut session = self.session.borrow_mut();
        session.mode_override |= codex;
        session.active_mode = mode.to_owned();
        let label = if mode == "bypass" { "Bypass / YOLO" } else { "Ask for approval" };
        session.notice(&format!("Permission mode changed to {label}."));
        Ok(())
    }
}

impl Backend for SessionBackend {
    fn snapshot(&self) -> Object {
        let mut value = self.session.borrow_mut().snapshot();
        value.insert("windowState".into(), self.window_state.borrow().clone());
        value
    }

    fn perform(self: Rc<Self>, action: String, params: Object) -> Action {
        Box::pin(async move { self.run(&action, params).await })
    }

    fn close(&self) {
        if self.closed.replace(true) {
            return;
        }
        self.on_change.borrow_mut().take();
        if let Some(agent) = self.agent.borrow_mut().take() {
            agent.close();
        }
        self.started.send_replace(true);
    }

    fn set_on_change(&self, on_change: Option<Rc<dyn Fn(Object)>>) {
        *self.on_change.borrow_mut() = on_change;
    }
}
