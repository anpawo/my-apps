//! A session carried across the exec of a live update (`swap.rs`): what the leaving image writes down of it, and
//! the runtime the next image rebuilds from that. The agent stays the same process, on the same pipes.

use super::{Config, SessionBackend};
use crate::session::Session;
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::os::fd::RawFd;
use std::rc::Rc;
use tokio::sync::{mpsc, watch};
use vcx_agents::{Connection, Incoming};

pub(super) type Stream = Rc<RefCell<mpsc::UnboundedReceiver<Incoming>>>;

const CONSUMED_NOTHING: i64 = -1;
/// An adopted agent is the first one its image knows.
const ADOPTED_GENERATION: u64 = 1;

/// Counts a piece of detached work until it ends, however it ends.
struct Detached(Rc<SessionBackend>);

impl Drop for Detached {
    fn drop(&mut self) {
        self.0.detached.set(self.0.detached.get() - 1);
    }
}

fn session_of(state: &Value) -> Result<Session, String> {
    serde_json::from_value(state["session"].clone()).map_err(|error| format!("Invalid adopted session: {error}"))
}

/// Whether this image could adopt `state`, told without the descriptors it names: the check a leaving image asks
/// of the next one before it execs.
pub fn check(state: &Value) -> Result<(), String> {
    session_of(state)?;
    if state["agent"].is_null() || state["agent"]["kind"] == "codex" {
        return Ok(());
    }
    Err("This agent connection cannot be adopted.".into())
}

/// The descriptors a frozen session's agent goes on with.
pub fn descriptors(state: &Value) -> Vec<RawFd> {
    Connection::descriptors(&state["agent"])
}

impl SessionBackend {
    /// Runs `work` on its own, counted until it ends: an exec would lose it, so `frozen` waits for it.
    pub(super) fn detach(self: &Rc<Self>, work: impl Future<Output = ()> + 'static) {
        self.detached.set(self.detached.get() + 1);
        let counted = Detached(Rc::clone(self));
        tokio::task::spawn_local(async move {
            work.await;
            drop(counted);
        });
    }

    /// `None` while the session starts, changes its connection or has work of its own under way, while the agent's
    /// messages wait to be applied, or while the agent cannot be frozen (a request in flight, a provider other than
    /// Codex).
    pub(super) fn frozen(&self) -> Option<Value> {
        let waiting = self.incoming.borrow().as_ref().is_some_and(|incoming| !incoming.borrow().is_empty());
        let moving = self.transferring.get() || self.detached.get() > 0 || self.session.borrow().changing;
        if self.closed.get() || self.loading.get() || waiting || moving {
            return None;
        }
        let agent = match self.agent.borrow().as_ref() {
            Some(agent) if !agent.is_closed() => agent.freeze()?,
            // An agent that left is not carried: the session goes on as it is here, disconnected.
            _ => Value::Null,
        };
        Some(json!({
            "session": serde_json::to_value(&*self.session.borrow()).ok()?, "agent": agent, "windowState": *self.window_state.borrow(),
            "consumedGeneration": self.consumed_generation.get(), "recovery": *self.recovery.borrow(), "logStart": self.log_start.get(),
            "providerChoice": *self.provider_choice.borrow(), "modeChoice": *self.mode_choice.borrow(), "pendingCommand": *self.pending_command.borrow(),
            "accountChoice": *self.account_choice.borrow(), "lastCrash": self.last_crash.get(),
        }))
    }

    /// The runtime of a session a previous image froze. The agent's descriptors are taken over whether or not this
    /// succeeds: on an error the agent is stopped.
    pub fn adopt(id: &str, state: &Value, config: Rc<Config>) -> Result<Rc<Self>, String> {
        let connection = match &state["agent"] {
            Value::Null => None,
            frozen => Some(Connection::adopt(frozen).map_err(|error| error.to_string())?),
        };
        let session = session_of(state).inspect_err(|_| {
            if let Some((agent, _)) = &connection {
                agent.close();
            }
        })?;
        let text = |key: &str| state[key].as_str().map(str::to_owned);
        let (agent, incoming) = connection.map(|(agent, incoming)| (agent, Rc::new(RefCell::new(incoming)))).unzip();
        let backend = Rc::new(Self {
            id: id.to_owned(),
            config,
            session: RefCell::new(session),
            agent: RefCell::new(agent),
            incoming: RefCell::new(incoming.clone()),
            on_change: RefCell::default(),
            scheduled: Cell::new(false),
            closed: Cell::new(false),
            started: watch::channel(true).0,
            loading: Cell::new(false),
            buffered: RefCell::default(),
            window_state: RefCell::new(state["windowState"].clone()),
            consumed_generation: Cell::new(state["consumedGeneration"].as_i64().unwrap_or(CONSUMED_NOTHING)),
            recovery: RefCell::new(state["recovery"].as_object().cloned()),
            persisted: RefCell::default(),
            generation: Cell::new(ADOPTED_GENERATION),
            log_start: Cell::new(state["logStart"].as_u64().unwrap_or(0)),
            provider_choice: RefCell::new(text("providerChoice")),
            mode_choice: RefCell::new(text("modeChoice")),
            transferring: Cell::new(false),
            pending_command: RefCell::new(text("pendingCommand")),
            account_choice: RefCell::new(text("accountChoice")),
            last_crash: Cell::new(state["lastCrash"].as_f64()),
            detached: Cell::new(0),
        });
        if let Some(incoming) = incoming {
            tokio::task::spawn_local(Rc::clone(&backend).pump(incoming, ADOPTED_GENERATION));
            // The catalog request the previous image may have had on its way was never sent.
            let refreshing = Rc::clone(&backend);
            tokio::task::spawn_local(async move { refreshing.refresh_catalog().await });
        }
        backend.schedule();
        Ok(backend)
    }
}
