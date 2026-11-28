//! A session's runtime, ported from the Swift `SessionBackend`: it owns the agent process, feeds its events to the
//! session, runs the frontend's actions, publishes patches and keeps the checkpoint.

use crate::capabilities::{self, Skill};
use crate::checkpoint::Store;
use crate::connectivity::Connectivity;
use crate::fallback;
use crate::fleet;
use crate::instructions;
use crate::provider;
use crate::question;
use crate::recall;
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
use vcx_agents::capabilities::{self as agent_capabilities, Provider};
use vcx_agents::directory::working_directory;
use vcx_agents::rpc::METHOD_NOT_FOUND;
use vcx_agents::{AgentError, Connection, Inbound, Incoming};
use vcx_config::{Account, Settings, SettingsFile};

pub mod carry;
pub(crate) mod commands;
mod records;
mod refresh;
mod route;
mod upkeep;
mod sending;

use sending::Prepared;

pub type Object = serde_json::Map<String, Value>;

/// Patches are gathered this long, so a streamed answer goes out a few times a second rather than per word.
const PUBLISH_DELAY: Duration = Duration::from_millis(80);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
const STOP_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_WINDOW_STATE_BYTES: usize = 65_536;
const TURNS_PAGE: u64 = 50;
const CATALOG_LIMIT: u64 = 100;
const INTERRUPTING_ACTIONS: [&str; 3] = ["answer", "stop", "checkpoint"];
const CLAUDE_SETTINGS: &str = "claude-settings.json";
const SKILLS_TIMEOUT: Duration = Duration::from_secs(15);
const CLAUDE_CATALOG_TIMEOUT: Duration = Duration::from_secs(25);
/// An agent that stops twice within this many seconds is left to the user.
const CRASH_WINDOW: f64 = 300.0;
const IDLE_ONLY: &str = "Stop the current response before changing session settings.";
const MODEL_UNAVAILABLE: &str = "Codex session is busy or the model is unavailable.";

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
    /// Where his `~/.claude/ERRORS*.md` are read for the lines recalled with each prompt: a test run's own folder.
    pub errors_home: PathBuf,
    /// The process's watch on the network, which every session of it hears.
    pub connectivity: Rc<Connectivity>,
    /// The project router's command: Haiku through `claude`, a test's agent, or none (no routing).
    pub router: Vec<String>,
    /// cleanup.py, run when it exists: the bundle's, or a test's own in its runtime home.
    pub cleanup: Option<PathBuf>,
    /// Where saved conversations keep their native history, and for a test worker whether they keep any.
    pub native: crate::archive::Native,
    /// Where each agent's provider version is read, for the archive to prune only the history of a verified one.
    pub versions: crate::archive::Versions,
}

pub struct SessionBackend {
    id: String,
    config: Rc<Config>,
    session: RefCell<Session>,
    agent: RefCell<Option<Connection>>,
    /// What the agent sent and `pump` has not taken yet, within reach of `frozen`: nothing may wait there at an exec.
    incoming: RefCell<Option<carry::Stream>>,
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
    /// The account `/account` chose, tried first among its provider's.
    account_choice: RefCell<Option<String>>,
    /// When the agent last stopped on its own, in seconds since 1970.
    last_crash: Cell<Option<f64>>,
    /// The account and thread a connection failed to open, which `/reconnect` and the network coming back try again.
    pending_activation: RefCell<Option<(Account, Option<String>)>>,
    /// Work `apply` started on its own (a stop, a fallback, a retry) and that has not ended: an exec would lose it.
    detached: Cell<usize>,
    /// The agent `generation` whose usage was read on connecting: Claude's is read once per agent.
    usage_read: Cell<u64>,
    /// Counts the repository reads started: one that ends after a later one began is dropped as stale.
    repository_reads: Cell<u64>,
    /// The project the draft being typed is about, asked before Enter; an exec drops it.
    project_guess: RefCell<Option<route::Guess>>,
    /// The wait before the draft's project is asked, cancelled by the next keystroke.
    guess_delay: RefCell<Option<tokio::task::JoinHandle<()>>>,
    /// The saved record: its lock, its native leases and its archive.
    records: RefCell<records::Records>,
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
        session.fleet_context_file = fleet::create();
        session.tracing = true;
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
        let native = config.native.enabled();
        let backend = Rc::new(Self {
            id,
            config,
            session: RefCell::new(session),
            agent: RefCell::default(),
            incoming: RefCell::default(),
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
            account_choice: RefCell::default(),
            last_crash: Cell::new(None),
            pending_activation: RefCell::default(),
            detached: Cell::new(0),
            usage_read: Cell::new(0),
            repository_reads: Cell::new(0),
            project_guess: RefCell::default(),
            guess_delay: RefCell::default(),
            records: RefCell::new(records::Records::new(native)),
        });
        backend.config.connectivity.watch(&backend);
        backend.refresh_periodically();
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
        Rc::clone(self).refresh_repository().await;
        if let Err(error) = self.open_agent(params).await {
            let mut session = self.session.borrow_mut();
            session.ready = false;
            session.usage_loading = false;
            session.status = "Connection failed".into();
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
        if let Some(named) = self.named_resume(params) {
            return self.resume_named(&named).await;
        }
        let settings = self.settings();
        let saved = self.recovery.borrow().as_ref().and_then(|state| text(state, "accountID")).map(str::to_owned);
        let account = provider::choose(&settings, self.config.provider.as_deref(), saved.as_deref(), fallback::now());
        *self.provider_choice.borrow_mut() = Some(self.config.provider.clone().unwrap_or_else(|| settings.default_provider()));
        self.session.borrow_mut().status = format!("Connecting to {}…", provider::label(&account.provider));
        let resume = self.resume_target(params);
        let opened = async {
            let (agent, incoming, version) = self.start_agent(&account, &settings).await?;
            self.install(&account, agent, incoming, version, self.preferred_mode(&settings));
            self.open(resume.as_deref(), false).await
        };
        let result = opened.await;
        if let Err(error) = &result {
            self.activation_failed(&account, resume, error);
        }
        result
    }

    /// Starts `account`'s agent, greeted when it is Codex, with its provider's version; the running one is left alone
    /// until this succeeds.
    async fn start_agent(&self, account: &Account, settings: &Settings) -> Result<(Connection, mpsc::UnboundedReceiver<Incoming>, Option<String>), String> {
        let (cwd, fleet) = {
            let session = self.session.borrow();
            (session.cwd.clone(), session.fleet_context_file.clone())
        };
        let environment = provider::environment(account, &vcx_config::homes::home_directory(), &fleet);
        let version = self.config.versions.read(&account.provider, &environment).await;
        let log = self.log_path();
        self.log_start.set(std::fs::metadata(&log).map_or(0, |meta| meta.len()));
        let mode = self.preferred_mode(settings);
        let claude_settings = self.config.settings.join(CLAUDE_SETTINGS);
        let start = provider::Start { account, settings, mode: &mode, log, claude_settings, fixture: self.config.fixture.clone(), cwd: &cwd, fleet: &fleet };
        let (agent, incoming) = provider::connect(start).await?;
        // Only Codex is a JSON-RPC server to greet and to ask for its sign-in; the adapters answer the rest themselves.
        if matches!(agent, Connection::Codex(_)) {
            if let Err(error) = self.greet(&agent).await {
                agent.close();
                return Err(error);
            }
        }
        Ok((agent, incoming, version))
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

    /// Makes `agent` the session's: the one before is closed and its events no longer count. `version` is its
    /// provider's, which the record's archive is told (the Swift `archiveClientVersions[next.provider]`).
    fn install(self: &Rc<Self>, account: &Account, agent: Connection, incoming: mpsc::UnboundedReceiver<Incoming>, version: Option<String>, mode: String) {
        self.records.borrow_mut().group = records::agent_group(&agent);
        if let Some(previous) = self.agent.replace(Some(agent)) {
            previous.close();
        }
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        let incoming = Rc::new(RefCell::new(incoming));
        *self.incoming.borrow_mut() = Some(Rc::clone(&incoming));
        tokio::task::spawn_local(Rc::clone(self).pump(incoming, generation));
        let mut session = self.session.borrow_mut();
        session.provider = account.provider.clone();
        match &version {
            Some(version) => session.archive_client_versions.insert(account.provider.clone(), json!(version)),
            None => session.archive_client_versions.remove(&account.provider),
        };
        session.client_version = version;
        session.provider_label = provider::label(&account.provider);
        session.model = session.provider_label.clone();
        session.account = json!({"id": account.id, "name": account.name, "provider": account.provider});
        if let Some(home) = &account.home {
            session.account["home"] = json!(home);
        }
        session.active_mode = mode;
        session.mode_override = false;
        session.ready = false;
        session.busy = false;
        session.turn_id = None;
        session.permissions.clear();
        session.active_actions.clear();
        session.capabilities = Default::default();
        session.usage.clear();
        session.usage_loading = true;
        session.status = format!("Connecting to {}…", session.provider_label);
    }

    /// Moves the conversation to `account`'s agent on a new thread, handed the recent messages, as the Swift
    /// `activate` does with `keepRows`; `reason` is told when one is given.
    async fn activate(self: &Rc<Self>, account: &Account, resume: Option<String>, reason: Option<&str>) -> Result<(), String> {
        self.activate_rows(account, resume, reason, true).await
    }

    /// `activate`, or with `keep_rows` false a conversation that starts over, as `/new` and `/dir` open one.
    async fn activate_rows(self: &Rc<Self>, account: &Account, resume: Option<String>, reason: Option<&str>, keep_rows: bool) -> Result<(), String> {
        if self.session.borrow().changing {
            return Err("A connection change is already in progress.".into());
        }
        self.before_activation(account, resume.as_deref())?;
        self.session.borrow_mut().changing = true;
        self.schedule();
        let result = async {
            self.recover_incomplete_archive().await?;
            self.switch_to(account, resume.clone(), reason, keep_rows).await
        };
        let result = result.await;
        self.session.borrow_mut().changing = false;
        match &result {
            Ok(()) => {
                *self.pending_activation.borrow_mut() = None;
                self.activated();
                self.session.borrow_mut().lost_connection = false;
            }
            Err(error) => self.activation_failed(account, resume, error),
        }
        self.schedule();
        result
    }

    /// The Swift `activate`'s failure, when the session has no working agent left: the target is kept for
    /// `/reconnect`, and a failure that is not a usage limit has the network probed.
    fn activation_failed(self: &Rc<Self>, account: &Account, resume: Option<String>, error: &str) {
        if self.session.borrow().ready {
            return;
        }
        *self.pending_activation.borrow_mut() = Some((account.clone(), resume));
        if !usage_limit(&object(json!({"error": error}))) {
            self.session.borrow_mut().lost_connection = true;
            self.config.connectivity.lost("a failed connection", false);
        }
    }

    async fn switch_to(self: &Rc<Self>, account: &Account, resume: Option<String>, reason: Option<&str>, keep_rows: bool) -> Result<(), String> {
        let settings = self.settings();
        let (agent, incoming, version) = self.start_agent(account, &settings).await?;
        let previous = self.session.borrow().account["id"].clone();
        self.session.borrow_mut().flush();
        // A resumed provider thread already holds the conversation; Qwen keeps none of its own.
        let handoff = if keep_rows && (resume.is_none() || account.provider == "qwen") { fallback::handoff_context(&self.session.borrow()) } else { String::new() };
        self.install(account, agent, incoming, version, self.preferred_mode(&settings));
        self.session.borrow_mut().injected_context = handoff;
        if let Err(error) = self.open(resume.as_deref(), keep_rows).await {
            self.session.borrow_mut().ready = false;
            return Err(error);
        }
        // A session whose first agent never started had no account to switch from.
        let switched = !previous.is_null() && previous != json!(account.id);
        let mut session = self.session.borrow_mut();
        if switched {
            session.effort = None;
        }
        if let Some(reason) = reason {
            let kept = if !session.injected_context.is_empty() { " Recent messages are passed to it as context." } else if resume.is_some() { " Context kept." } else { "" };
            let message = format!("{} {}: {reason}.{kept}", if switched { "Connected to" } else { "Reconnected to" }, session.provider_label);
            session.notice(&message);
        }
        Ok(())
    }

    /// His accounts of the session's provider that are not resting, the one `/account` chose first.
    fn available(&self, settings: &Settings) -> Vec<Account> {
        let choice = self.provider_choice.borrow().clone().unwrap_or_else(|| settings.default_provider());
        let mut accounts = settings.available(&choice, fallback::now());
        if let Some(chosen) = self.account_choice.borrow().as_ref() {
            if let Some(index) = accounts.iter().position(|account| &account.id == chosen) {
                let account = accounts.remove(index);
                accounts.insert(0, account);
            }
        }
        accounts
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
        let mut failure = None;
        for next in self.available(&settings) {
            match self.activate(&next, None, None).await {
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

    fn current_account(&self) -> Account {
        let session = self.session.borrow();
        let id = session.account["id"].as_str().unwrap_or_default().to_owned();
        let provider = session.provider.clone();
        drop(session);
        self.settings().candidates(&provider).into_iter().find(|account| account.id == id).unwrap_or_else(|| provider::choose(&Settings::default(), Some(&provider), None, fallback::now()))
    }

    /// The Swift `restartAfterCrash`: an agent that stopped on its own is restarted once on its conversation; a second
    /// stop within five minutes is left to the user.
    async fn restart_after_crash(self: Rc<Self>, params: Object) {
        let label = self.session.borrow().provider_label.clone();
        let stopped = format!("{label} stopped ({}).", text(&params, "reason").unwrap_or_default());
        let line = text(&params, "line").map(|line| format!(" Last error: {line}")).unwrap_or_default();
        let log = text(&params, "log");
        let now = fallback::now();
        if self.last_crash.get().is_some_and(|last| now - last < CRASH_WINDOW) {
            self.notice_linked(&format!("{stopped} It stopped twice in 5 minutes, so VCX did not restart it. Use /reconnect to try again.{line}"), log);
            return;
        }
        if !self.config.connectivity.online().await {
            self.config.connectivity.lost("a dropped connection", true);
            self.notice_linked(&format!("{stopped} The network is down, so VCX restarts it once the network is back.{line}"), log);
            return;
        }
        self.last_crash.set(Some(now));
        let thread = self.session.borrow().thread_id.clone();
        match self.activate(&self.current_account(), thread, None).await {
            Ok(()) => {
                self.session.borrow_mut().needs_attention = false;
                self.refresh_catalog().await;
                self.notice_linked(&format!("{stopped} Restarted it, context kept.{line}"), log);
            }
            Err(error) => self.notice_linked(&format!("{stopped} Restarting it failed: {error}{line}"), log),
        }
    }

    fn notice_linked(self: &Rc<Self>, message: &str, link: Option<&str>) {
        self.session.borrow_mut().notice_linked(message, link);
        self.schedule();
    }

    /// Claude exits when it cannot find the conversation it was asked to resume; a new one receives the recent messages
    /// and the prompt it was given.
    async fn resume_failed(self: Rc<Self>) {
        let input = {
            let session = self.session.borrow();
            session.pending_input.clone().filter(|_| session.busy)
        };
        if let Err(error) = self.activate(&self.current_account(), None, None).await {
            self.notice_linked(&format!("Claude could not resume this conversation: {error}"), None);
            return;
        }
        self.refresh_catalog().await;
        let passed = if self.session.borrow().injected_context.is_empty() { "" } else { " Recent messages are passed to it as context." };
        self.notice_linked(&format!("Claude could not resume this conversation, so a new one started.{passed}"), None);
        if let Some((text, images)) = input {
            let _ = Rc::clone(&self).send(&text, &images, None, None, true).await;
        }
    }

    /// The Swift `reconnect`: the running account on its conversation, unless another is chosen, disabled or resting.
    async fn reconnect(self: &Rc<Self>, reason: &str) -> Result<(), String> {
        if let Some(id) = self.pending_restore() {
            self.restore(&id, None, Some(reason)).await?;
            self.refresh_catalog().await;
            return Ok(());
        }
        let settings = self.settings();
        let available = self.available(&settings);
        let Some(fallback) = available.first().cloned() else {
            if let Some(agent) = self.agent.borrow_mut().take() {
                agent.close();
            }
            let mut session = self.session.borrow_mut();
            session.ready = false;
            session.status = "No available account".into();
            return Err("No enabled account is available for the selected provider. Use /account or /provider.".into());
        };
        let current = self.current_account();
        let thread = self.session.borrow().thread_id.clone();
        let auto = self.provider_choice.borrow().as_deref() == Some("auto");
        let mut target = self.pending_activation.borrow().clone().unwrap_or((current.clone(), thread.clone()));
        if !auto && fallback.id != target.0.id {
            target = (fallback.clone(), if fallback.id == current.id { thread } else { None });
        }
        let chosen = self.account_choice.borrow().clone();
        if settings.account(&target.0.id).is_some_and(|latest| !latest.enabled && chosen.as_ref() != Some(&latest.id)) {
            target = (fallback.clone(), None);
        }
        if !available.iter().any(|account| account.id == target.0.id) {
            target = (fallback, None);
        }
        self.activate(&target.0, target.1, Some(reason)).await?;
        self.refresh_catalog().await;
        Ok(())
    }

    /// The Swift `networkBack`: every session hears that the internet answers again; one that was fine does nothing.
    pub(crate) fn network_back(self: &Rc<Self>, cause: &str, reconnecting: bool) {
        if self.closed.get() {
            return;
        }
        let (backend, cause) = (Rc::clone(self), cause.to_owned());
        self.detach(async move { backend.came_back(&cause, reconnecting).await });
    }

    async fn came_back(self: Rc<Self>, cause: &str, reconnecting: bool) {
        let (lost, changing) = {
            let session = self.session.borrow();
            (session.lost_connection, session.changing)
        };
        if lost && reconnecting && !changing {
            if let Err(error) = self.reconnect(&format!("network back after {cause}")).await {
                self.notice_linked(&error, None);
            }
        }
        let (busy, attempt) = {
            let session = self.session.borrow();
            (session.busy, session.retry_attempt)
        };
        if let Some(attempt) = attempt.filter(|attempt| reconnecting && busy && *attempt < fallback::now()) {
            let backend = Rc::clone(&self);
            self.detach(async move { backend.stop_stuck_retry(attempt).await });
        }
        if !std::mem::take(&mut self.session.borrow_mut().resume_when_back) {
            return;
        }
        if !self.session.borrow().ready || self.session.borrow().busy {
            return;
        }
        self.session.borrow_mut().auto_resumes += 1;
        let _ = Rc::clone(&self).send(fallback::KEEP_GOING_DROPPED, &[], None, None, false).await;
    }

    /// An API retry sent while the network was down waits on a dead socket until its own timeout; if the API is still
    /// silent after a grace once the network is back, the step restarts on the live network.
    async fn stop_stuck_retry(self: Rc<Self>, attempt: f64) {
        tokio::time::sleep(self.config.connectivity.grace()).await;
        let label = {
            let session = self.session.borrow();
            if !session.busy || session.retry_attempt != Some(attempt) || session.stop_requested {
                return;
            }
            session.provider_label.clone()
        };
        {
            let mut session = self.session.borrow_mut();
            session.retry_stopped = true;
            session.notice(&format!("The network is back but {label} was still waiting on a request sent while it was down, so VCX restarts the step."));
        }
        self.schedule();
        self.stop("the network coming back").await;
    }

    /// `/account <id or name>` uses it; `/account enable|disable <id>` and `/account rename <id> <name>` change his settings.
    async fn change_account(self: &Rc<Self>, argument: &str) -> Result<(), String> {
        let args: Vec<&str> = argument.splitn(3, ' ').collect();
        let operation = if ["enable", "disable", "rename"].contains(&args[0]) { args[0] } else { "use" };
        let id = if operation == "use" { argument } else { args.get(1).copied().unwrap_or_default() };
        let settings = self.settings();
        let account = settings.accounts().into_iter().find(|account| account.id == id || account.name.eq_ignore_ascii_case(id)).ok_or("Choose an account from /account.")?;
        let changed = match operation {
            "use" => {
                *self.provider_choice.borrow_mut() = Some(account.provider.clone());
                *self.account_choice.borrow_mut() = Some(account.id.clone());
                return self.reconnect("account changed").await;
            }
            "rename" => {
                let name = args.get(2).filter(|name| !name.is_empty()).ok_or("Use /account rename <id> <name>.")?.to_string();
                SettingsFile::new(&self.config.settings).update(|settings| {
                    settings.set_account_name(&account.id, &name);
                })
            }
            _ => SettingsFile::new(&self.config.settings).update(|settings| {
                settings.set_account_enabled(&account.id, operation == "enable");
            }),
        };
        changed?;
        self.reconnect("account settings changed").await
    }

    fn idle(&self) -> Result<(), String> {
        let session = self.session.borrow();
        if session.busy || session.changing { Err(IDLE_ONLY.into()) } else { Ok(()) }
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
        let account = self.current_account();
        params["developerInstructions"] = json!(instructions::developer_instructions(&account, &cwd, &vcx_config::homes::home_directory()));
        if account.provider == "codex" && resume.is_none() {
            params["dynamicTools"] = json!([question::tool()]);
        }
        if let Some(thread) = resume {
            params["threadId"] = json!(thread);
            params["excludeTurns"] = json!(true);
        }
        let method = if resume.is_some() { "thread/resume" } else { "thread/start" };
        let result = self.open_thread(method, params).await?;
        let id = result.get("thread").and_then(|thread| thread.get("id")).and_then(Value::as_str).ok_or_else(|| format!("{} did not return a conversation.", self.session.borrow().provider_label))?.to_owned();
        if resume.is_some_and(|thread| thread.rsplit(':').next().map(str::to_lowercase) != id.rsplit(':').next().map(str::to_lowercase)) {
            return Err("The agent did not resume the exact requested native conversation.".into());
        }
        let mut history = Vec::new();
        if resume.is_some() && !keep_rows {
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
        if !keep_rows {
            fleet::clear(&self.session.borrow().fleet_context_file);
        }
        self.session.borrow_mut().opened(&result, &history, keep_rows);
        self.thread_opened(resume)
    }

    async fn refresh_catalog(self: &Rc<Self>) {
        let Ok(catalog) = self.request("model/list", json!({"limit": CATALOG_LIMIT}), REQUEST_TIMEOUT).await else { return };
        self.session.borrow_mut().apply_catalog(&object(catalog));
        self.refresh_recent().await;
        if self.session.borrow().context_limit.is_none() {
            self.refresh_context_limit().await;
        }
        self.refresh_connection_usage().await;
        Rc::clone(self).refresh_repository().await;
        self.schedule();
        // Not awaited: Claude's catalog can take its whole timeout, and a prompt resent after a switch does not wait on it.
        let backend = Rc::clone(self);
        tokio::task::spawn_local(async move { backend.refresh_capabilities().await });
    }

    /// The Swift `refreshCapabilities`: the lists the agent reports, and the instruction files and Claude hooks vcx
    /// reads from his folders; a reply from an agent since replaced is dropped.
    async fn refresh_capabilities(self: &Rc<Self>) {
        let Ok(agent) = self.agent() else { return };
        let generation = self.generation.get();
        let (provider, cwd, thread) = {
            let session = self.session.borrow();
            (session.provider.clone(), session.cwd.clone(), session.thread_id.clone().unwrap_or_default())
        };
        let Some(kind) = Provider::named(&provider) else { return };
        let home = &self.config.errors_home;
        let base = capabilities::provider_home(&self.current_account(), home);
        let local = capabilities::Local::read(kind, &base, home, Path::new(&cwd), &[self.config.settings.join(CLAUDE_SETTINGS)]);
        if kind == Provider::Claude {
            // A recorded Claude takes only the requests of its recording; its lists come with the catalog it sends itself.
            let catalog = if self.config.fixture.is_some() { Ok(json!({})) } else { self.request("vcx/catalog", json!({}), CLAUDE_CATALOG_TIMEOUT).await };
            if self.generation.get() == generation {
                let mut session = self.session.borrow_mut();
                if let Some(mode) = session.capabilities.claude(local, catalog) {
                    session.active_mode = mode;
                }
            }
        } else if let Ok(catalog) = agent_capabilities::catalog(&agent, kind, &cwd, &thread).await {
            // The catalog keeps only the skills' names; the palette needs their files and descriptions too.
            let listed = if kind == Provider::Codex { self.request("skills/list", json!({"cwds": [cwd]}), SKILLS_TIMEOUT).await.ok() } else { None };
            if self.generation.get() == generation {
                self.session.borrow_mut().capabilities.agent(kind, local, catalog, listed.as_ref());
            }
        }
        self.schedule();
    }

    async fn pump(self: Rc<Self>, incoming: carry::Stream, generation: u64) {
        while let Some(message) = std::future::poll_fn(|context| incoming.borrow_mut().poll_recv(context)).await {
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
                        let why = reason.trim_end_matches('.').trim_start_matches("The agent ");
                        let mut stopped = object(json!({"message": reason, "reason": why, "log": log.to_string_lossy()}));
                        if let Some(line) = line {
                            stopped.insert("line".into(), json!(line));
                        }
                        let effects = self.session.borrow_mut().agent_stopped(&stopped);
                        self.run_effects(effects);
                    }
                    return;
                }
            }
        }
    }

    fn apply(self: &Rc<Self>, message: Inbound) {
        self.trace_inbound(&message);
        let effects = match &message {
            Inbound::Event(event) => self.session.borrow_mut().event(event),
            Inbound::Request { id, method, params } => self.session.borrow_mut().request(id.clone(), method, params),
            Inbound::Invalid(text) => {
                self.session.borrow_mut().notice(text);
                Vec::new()
            }
            Inbound::Response { .. } => Vec::new(),
        };
        self.after_inbound(&message, &effects);
        self.run_effects(effects);
    }

    fn run_effects(self: &Rc<Self>, effects: Vec<Effect>) {
        for effect in effects {
            match effect {
                Effect::Respond { id, result } => {
                    if let Ok(agent) = self.agent() {
                        let _ = agent.respond(&id, result);
                    }
                }
                Effect::Decline { id, method } => {
                    if let Ok(agent) = self.agent() {
                        let _ = agent.reject(&id, METHOD_NOT_FOUND, &format!("vcx does not support {method}"));
                    }
                }
                Effect::Stop => {
                    let backend = Rc::clone(self);
                    self.detach(async move { backend.stop("Stop command").await });
                }
                Effect::Limit(info) => {
                    self.detach(Rc::clone(self).limit_reached(info));
                }
                Effect::RateLimited => {
                    self.detach(Rc::clone(self).retry_rate_limit());
                }
                Effect::Crashed(params) => {
                    self.detach(Rc::clone(self).restart_after_crash(params));
                }
                Effect::ResumeFailed => {
                    self.detach(Rc::clone(self).resume_failed());
                }
                Effect::Offline(reason) => self.config.connectivity.lost(reason, false),
                Effect::KeepGoing => {
                    let backend = Rc::clone(self);
                    self.detach(async move {
                        let _ = backend.send(fallback::KEEP_GOING_DROPPED, &[], None, None, false).await;
                    });
                }
                Effect::Rest(reset) => self.rest_current(reset),
                Effect::RefreshRepository => self.detach(Rc::clone(self).refresh_repository()),
                Effect::ContinueWith(prompt) => self.detach(Rc::clone(self).continue_with(prompt)),
            }
        }
        let idle = !self.session.borrow().busy && !self.transferring.get();
        if let Some(command) = self.pending_command.borrow_mut().take_if(|_| idle) {
            let backend = Rc::clone(self);
            self.detach(async move {
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
        self.save_if_changed();
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
        self.send_as(text, images, draft, generation, retry, None).await
    }

    /// `send`, for a skill also with its piece, its prompt showing the skill as it was typed.
    async fn send_as(self: Rc<Self>, text: &str, images: &[String], draft: Option<Vec<Value>>, generation: Option<i64>, retry: bool, skill: Option<Skill>) -> Result<Object, String> {
        let prepared = if retry { Prepared::Ready } else { self.prepare_turn().await };
        if matches!(prepared, Prepared::Refused) {
            self.schedule();
            return Ok(Object::new());
        }
        let routing = self.routing(text, retry);
        let outgoing = self.session.borrow_mut().begin_send(text, images, draft, generation, retry);
        self.schedule();
        let Some(mut outgoing) = outgoing else { return Ok(Object::new()) };
        if let Prepared::Switch(next) = &prepared {
            if let Err(error) = self.switch_for_turn(next, &mut outgoing).await {
                self.session.borrow_mut().send_failed(&outgoing, &error);
                self.schedule();
                return Ok(Object::new());
            }
        }
        if let Some(skill) = skill {
            if let (Some(piece), Some(input)) = (skill.piece, outgoing.params["input"].as_array_mut()) {
                input.push(piece);
            }
            self.session.borrow_mut().show_typed(&outgoing.id, &skill.shown);
        }
        if let Some(earlier) = routing {
            if let Err(error) = self.route(&mut outgoing, text, &earlier).await {
                self.session.borrow_mut().send_failed(&outgoing, &error);
                self.schedule();
                return Ok(Object::new());
            }
        }
        let recalled = self.recall(text);
        if !recalled.is_empty() {
            if let Some(input) = outgoing.params["input"].as_array_mut() {
                input.push(json!({"type": "text", "text": recall::note(&recalled)}));
            }
        }
        if self.recovery.borrow().is_none() {
            let consumed = generation.unwrap_or(self.session.borrow().draft_generation);
            self.consumed_generation.set(self.consumed_generation.get().max(consumed));
        }
        match self.request(outgoing.method, outgoing.params.clone(), REQUEST_TIMEOUT).await {
            Ok(result) => {
                if !recalled.is_empty() {
                    let cwd = PathBuf::from(&self.session.borrow().cwd);
                    let sections = recalled.iter().filter_map(|rule| Some((rule.clone(), recall::section(rule, &cwd, &self.config.errors_home)?))).collect();
                    self.session.borrow_mut().recalled(&outgoing.id, &recalled, sections);
                }
                self.session.borrow_mut().send_succeeded(&result);
                self.prompt_delivered();
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

    /// The Swift `ErrorsRecall`: his ERRORS lines that match the prompt, each sent once per conversation.
    fn recall(&self, text: &str) -> Vec<String> {
        let session = self.session.borrow();
        recall::recall(text, Path::new(&session.cwd), &self.config.errors_home).into_iter().filter(|rule| !session.recalled_rules.contains(rule)).collect()
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
                drop(session);
                self.guess_project();
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
                let skill = self.skill(text);
                if text.starts_with('/') && images.is_empty() && skill.is_none() {
                    self.session.borrow().trace_prompt(text, 0, false);
                    return Box::pin(Rc::clone(&self).run("command", object(json!({"text": text})))).await;
                }
                let draft = params.get("draft").and_then(Value::as_array).cloned();
                let generation = params.get("generation").and_then(Value::as_i64);
                match skill {
                    Some(skill) => Rc::clone(&self).send_as(&skill.text.clone(), &images, draft, generation, false, Some(skill)).await?,
                    None => Rc::clone(&self).send(text, &images, draft, generation, false).await?,
                }
            }
            "stop" => {
                Rc::clone(&self).stop(text(&params, "source").unwrap_or("Stop command")).await;
                Object::new()
            }
            "sendNow" => {
                Rc::clone(&self).send_waiting_now().await;
                Object::new()
            }
            "unsend" => object(json!({"cancelled": self.unsend(&params).await})),
            "answer" => {
                let (Some(rpc_id), Some(method), Some(Value::Object(result))) = (params.get("rpcID"), text(&params, "method"), params.get("result")) else {
                    return Err("This approval is no longer pending.".into());
                };
                let permission = self.session.borrow_mut().take_permission(rpc_id, method).ok_or("This approval is no longer pending.")?;
                let answer = if permission.params.get(question::MARKER) == Some(&json!(true)) { question::answer(&permission.params, result) } else { Value::Object(result.clone()) };
                if let Err(error) = self.agent()?.respond(&permission.rpc_id, answer) {
                    self.session.borrow_mut().notice(&format!("Could not send your answer: {error}"));
                }
                Object::new()
            }
            "command" => Rc::clone(&self).command(text(&params, "text").ok_or("Invalid command payload.")?).await?,
            "setModel" => {
                let model = text(&params, "model").ok_or(MODEL_UNAVAILABLE)?;
                self.set_model(model, text(&params, "effort")).await?;
                Object::new()
            }
            "moveDirectory" => {
                let path = text(&params, "path").and_then(|path| working_directory(path, "/")).ok_or("Directory does not exist.")?;
                if self.session.borrow().cwd != path {
                    let moved = self.session.borrow_mut().move_directory(&path);
                    self.run_effects(vec![moved]);
                }
                Object::new()
            }
            "refreshCatalog" => {
                self.refresh_catalog().await;
                Object::new()
            }
            "refreshUsage" => {
                self.refresh_usage(params.get("force").and_then(Value::as_bool).unwrap_or(true)).await;
                Object::new()
            }
            "refreshRepository" => {
                Rc::clone(&self).refresh_repository().await;
                Object::new()
            }
            // The Swift `refreshCapabilities` reads the repository first.
            "refreshCapabilities" => {
                Rc::clone(&self).refresh_repository().await;
                self.refresh_capabilities().await;
                Object::new()
            }
            "switchThread" => {
                let success = self.switch_thread(text(&params, "id"), params.get("fromCommand").and_then(Value::as_bool).unwrap_or(false)).await;
                object(json!({"success": success}))
            }
            "close" => {
                self.prepare_for_close()?;
                let busy = self.session.borrow().busy;
                if busy {
                    Rc::clone(&self).stop("Close Session").await;
                }
                // A failed archive keeps the record and its native history in place, so nothing is lost by
                // closing anyway: refusing left a window that could not be quit.
                match self.archive_for_close().await {
                    Err(problem) if problem != crate::archive::FAILED => return Err(problem),
                    _ => {}
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

    /// The skill or Claude command `text` names, as the agent takes it.
    fn skill(&self, text: &str) -> Option<Skill> {
        let session = self.session.borrow();
        session.capabilities.skill(&session.provider, text)
    }

    /// The Swift `setModel` action: Codex only, between turns, with the effort the next turn would run at unless
    /// one is named.
    async fn set_model(&self, model: &str, effort: Option<&str>) -> Result<(), String> {
        let usable = {
            let session = self.session.borrow();
            session.provider == "codex" && session.ready && !session.busy && !session.changing && session.models.iter().any(|known| known == model)
        };
        if !usable {
            return Err(MODEL_UNAVAILABLE.into());
        }
        let effort = effort.map(str::to_owned).or_else(|| self.session.borrow().effective_effort());
        if let Err(error) = self.change_model(model, effort.clone()).await {
            self.session.borrow_mut().notice(&error);
        }
        let session = self.session.borrow();
        if session.model != model || session.effective_effort() != effort {
            return Err("Model change did not complete.".into());
        }
        Ok(())
    }

    /// The Swift `changeModel`: the thread is reopened on `model` in the session's mode and with its instructions; no
    /// `effort` is the model's default.
    async fn change_model(&self, model: &str, effort: Option<String>) -> Result<(), String> {
        if !self.session.borrow().models.iter().any(|known| known == model) {
            return Err("Unknown model. Choose one from the model menu.".into());
        }
        let allowed = effort.as_ref().is_none_or(|effort| self.session.borrow().model_efforts.get(model).and_then(Value::as_array).is_some_and(|efforts| efforts.iter().any(|known| known == effort)));
        if !allowed {
            return Err("Reasoning effort is unavailable for this model.".into());
        }
        let (thread, cwd, mode, previous_limit) = {
            let mut session = self.session.borrow_mut();
            let thread = session.thread_id.clone().ok_or("No conversation is open.")?;
            let previous_limit = session.context_limit;
            if session.provider == "codex" && session.model != model {
                session.context_limit = None;
            }
            session.changing = true;
            (thread, session.cwd.clone(), session.active_mode.clone(), previous_limit)
        };
        let instructions = instructions::developer_instructions(&self.current_account(), &cwd, &vcx_config::homes::home_directory());
        let params = json!({"threadId": thread, "model": model, "excludeTurns": true, "approvalPolicy": model::approval_policy(&mode), "sandbox": model::sandbox(&mode), "developerInstructions": instructions, "effort": effort});
        let result = self.request("thread/resume", params, REQUEST_TIMEOUT).await;
        self.session.borrow_mut().changing = false;
        match result {
            Ok(result) => self.session.borrow_mut().model_changed(&object(result), model, effort),
            Err(error) => {
                let mut session = self.session.borrow_mut();
                session.context_limit = session.context_limit.or(previous_limit);
                return Err(error);
            }
        }
        if self.session.borrow().context_limit.is_none() {
            self.refresh_context_limit().await;
        }
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
        if self.closed.get() {
            return;
        }
        self.release_records();
        self.closed.set(true);
        self.on_change.borrow_mut().take();
        if let Some(agent) = self.agent.borrow_mut().take() {
            agent.close();
        }
        fleet::remove(&self.session.borrow().fleet_context_file);
        self.upkeep_on_close();
        self.started.send_replace(true);
    }

    fn set_on_change(&self, on_change: Option<Rc<dyn Fn(Object)>>) {
        *self.on_change.borrow_mut() = on_change;
    }

    fn freeze(&self) -> Option<Value> {
        self.frozen()
    }
}
