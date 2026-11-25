//! A session's runtime, ported from the Swift `SessionBackend`: it owns the agent process, feeds its events to the
//! session, runs the frontend's actions, publishes patches and keeps the checkpoint.

use crate::checkpoint::Store;
use crate::server::{Action, Backend};
use crate::session::{Effect, Session};
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::rc::Rc;
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use vcx_agents::rpc::METHOD_NOT_FOUND;
use vcx_agents::{Agent, Inbound, Incoming};

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

/// How sessions start their agent.
pub struct Config {
    pub command: Vec<String>,
    /// The fixture agent stands in for Codex: no account check, no catalog of its own.
    pub fixture: bool,
    pub store: Store,
    pub state_directory: PathBuf,
}

pub struct SessionBackend {
    id: String,
    config: Rc<Config>,
    session: RefCell<Session>,
    agent: RefCell<Option<Agent>>,
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
                if let Err(error) = Rc::clone(&starting).send(prompt, &[], None, None).await {
                    starting.session.borrow_mut().notice(&error);
                    starting.schedule();
                }
            }
        });
        Ok(backend)
    }

    fn agent(&self) -> Result<Agent, String> {
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

    async fn open_agent(self: &Rc<Self>, params: &Object) -> Result<(), String> {
        let cwd = self.session.borrow().cwd.clone();
        let (agent, incoming) = Agent::spawn(&self.config.command, Path::new(&cwd), Stdio::null()).map_err(|error| format!("Cannot start the agent: {error}"))?;
        *self.agent.borrow_mut() = Some(agent.clone());
        tokio::task::spawn_local(Rc::clone(self).pump(incoming));
        let client = json!({"clientInfo": {"name": "vcx", "title": "Vibe Code X", "version": "0.2.0"}, "capabilities": {"experimentalApi": true}});
        self.request("initialize", client, REQUEST_TIMEOUT).await?;
        agent.notify("initialized", None).map_err(|error| error.message)?;
        if !self.config.fixture {
            let status = self.request("account/read", json!({"refreshToken": false}), REQUEST_TIMEOUT).await?;
            if status["account"]["type"] != "chatgpt" {
                agent.close();
                return Err("Sign in with a ChatGPT subscription in Settings. vcx does not use API-key billing.".into());
            }
        }
        let resume = self.resume_target(params);
        match resume {
            Some(thread) => {
                if let Err(error) = self.open(Some(&thread)).await {
                    self.session.borrow_mut().notice(&format!("Could not reopen the saved conversation ({error}); a new one was started."));
                    self.open(None).await?;
                }
            }
            None => self.open(None).await?,
        }
        Ok(())
    }

    /// The provider thread to reopen: the checkpoint's, or a bare thread id the frontend named.
    fn resume_target(&self, params: &Object) -> Option<String> {
        let saved = self.recovery.borrow().as_ref().and_then(|state| text(state, "threadID")).map(str::to_owned);
        let named = text(params, "resume").filter(|resume| !resume.is_empty() && !resume.starts_with("native:") && *resume != "last").map(str::to_owned);
        saved.or(named)
    }

    async fn open(&self, resume: Option<&str>) -> Result<(), String> {
        let cwd = self.session.borrow().cwd.clone();
        let mut params = json!({"cwd": cwd, "approvalPolicy": "never", "sandbox": "danger-full-access"});
        if let Some(thread) = resume {
            params["threadId"] = json!(thread);
            params["excludeTurns"] = json!(true);
        }
        let method = if resume.is_some() { "thread/resume" } else { "thread/start" };
        let result = object(self.request(method, params, REQUEST_TIMEOUT).await?);
        let id = result.get("thread").and_then(|thread| thread.get("id")).and_then(Value::as_str).ok_or("Codex did not return a conversation.")?.to_owned();
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
        self.session.borrow_mut().opened(&result, &history);
        Ok(())
    }

    async fn refresh_catalog(self: &Rc<Self>) {
        let Ok(catalog) = self.request("model/list", json!({"limit": CATALOG_LIMIT}), REQUEST_TIMEOUT).await else { return };
        self.session.borrow_mut().apply_catalog(&object(catalog));
        if !self.config.fixture {
            if let Ok(limits) = self.request("account/rateLimits/read", json!({}), REQUEST_TIMEOUT).await {
                let event = json!({"method": "account/rateLimits/updated", "params": {"rateLimits": limits["rateLimits"]}});
                if let Inbound::Event(event) = vcx_agents::codex::parse(object(event)) {
                    self.session.borrow_mut().event(&event);
                }
            }
        }
        self.schedule();
    }

    async fn pump(self: Rc<Self>, mut incoming: mpsc::UnboundedReceiver<Incoming>) {
        while let Some(message) = incoming.recv().await {
            match message {
                Incoming::Message(message) if self.loading.get() => self.buffered.borrow_mut().push(message),
                Incoming::Message(message) => self.apply(message),
                Incoming::Exited { reason } => {
                    if !self.closed.get() {
                        self.session.borrow_mut().disconnected(&reason, false);
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
            }
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

    async fn send(self: Rc<Self>, text: &str, images: &[String], draft: Option<Vec<Value>>, generation: Option<i64>) -> Result<Object, String> {
        let outgoing = self.session.borrow_mut().begin_send(text, images, draft, generation);
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
                Rc::clone(&self).send(text, &images, draft, generation).await?
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
                let model = text(&params, "model").map(str::to_owned);
                let valid = model.as_ref().filter(|model| self.session.borrow().models.contains(model));
                let Some(model) = valid.cloned() else { return Err("Codex session is busy or the model is unavailable.".into()) };
                let effort = text(&params, "effort").map(str::to_owned).or_else(|| {
                    let session = self.session.borrow();
                    session.effort.clone().or_else(|| session.default_effort.clone())
                });
                let allowed = effort.as_ref().is_none_or(|effort| self.session.borrow().model_efforts.get(&model).and_then(Value::as_array).is_some_and(|efforts| efforts.iter().any(|known| known == effort)));
                if !allowed {
                    return Err("Reasoning effort is unavailable for this model.".into());
                }
                let thread = self.session.borrow().thread_id.clone().ok_or("No conversation is open.")?;
                self.request("thread/resume", json!({"threadId": thread, "model": model}), REQUEST_TIMEOUT).await?;
                let mut session = self.session.borrow_mut();
                session.model = model;
                session.effort = effort;
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
                    Some(thread) => self.open(Some(&thread)).await.is_ok(),
                    None => self.open(None).await.is_ok(),
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
        if FRONTEND_COMMANDS.contains(&verb.as_str()) {
            return Err("This command belongs to the frontend.".into());
        }
        match verb.as_str() {
            "/stop" => Rc::clone(&self).stop("Stop command").await,
            "/new" | "/clear" => self.open(None).await?,
            // Anything else is the agent's own command or skill: it reads the text as typed.
            _ => return Rc::clone(&self).send(text, &[], None, None).await,
        }
        Ok(Object::new())
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
