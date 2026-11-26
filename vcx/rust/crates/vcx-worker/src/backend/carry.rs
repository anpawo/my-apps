//! A session carried across the exec of a live update (`swap.rs`): what the leaving image writes down of it, and
//! the runtime the next image rebuilds from that. The agent stays the same process, on the same pipes.

use super::{Config, SessionBackend};
use crate::provider;
use crate::session::Session;
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::os::fd::RawFd;
use std::rc::Rc;
use tokio::sync::{mpsc, watch};
use vcx_agents::{Connection, Incoming};
use vcx_config::Account;

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

fn pending_json(pending: &Option<(Account, Option<String>)>) -> Value {
    pending.as_ref().map_or(Value::Null, |(account, resume)| {
        json!({"account": {"id": account.id, "name": account.name, "provider": account.provider, "home": account.home, "enabled": account.enabled}, "resume": resume})
    })
}

fn account_of(account: &Value) -> Option<Account> {
    let text = |key: &str| account[key].as_str().map(str::to_owned);
    Some(Account { id: text("id")?, name: text("name").unwrap_or_default(), provider: text("provider")?, home: text("home"), enabled: account["enabled"].as_bool().unwrap_or(true) })
}

fn pending_of(state: &Value) -> Option<(Account, Option<String>)> {
    Some((account_of(&state["account"])?, state["resume"].as_str().map(str::to_owned)))
}

/// What the session's account gives the agents it starts, as `provider::connect` builds it. An adopted Claude gets
/// it for its next process: without one, that process would inherit the worker's own, metered keys included.
fn environment_of(session: &Session) -> Result<Vec<(String, String)>, String> {
    let account = account_of(&session.account).ok_or("The adopted session names no account.")?;
    Ok(provider::environment(&account, &vcx_config::homes::home_directory(), &session.fleet_context_file))
}

/// Closes the pipes of an agent that is not adopted after all: it ends on them.
fn release(state: &Value) {
    for descriptor in descriptors(state) {
        // SAFETY: the previous image left these descriptors open for this one alone, and nothing here took them.
        unsafe { libc::close(descriptor) };
    }
}

fn session_of(state: &Value) -> Result<Session, String> {
    serde_json::from_value(state["session"].clone()).map_err(|error| format!("Invalid adopted session: {error}"))
}

/// Whether this image could adopt `state`, told without the descriptors it names: the check a leaving image asks
/// of the next one before it execs.
pub fn check(state: &Value) -> Result<(), String> {
    let session = session_of(state)?;
    if state["agent"].is_null() {
        return Ok(());
    }
    if !Connection::adoptable(&state["agent"]) {
        return Err("This agent connection cannot be adopted.".into());
    }
    environment_of(&session).map(drop)
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
    /// messages wait to be applied, or while the agent cannot be frozen (a request in flight, a Claude turn under
    /// way, agy or Qwen).
    pub(super) fn frozen(&self) -> Option<Value> {
        let waiting = self.incoming.borrow().as_ref().is_some_and(|incoming| !incoming.borrow().is_empty());
        let moving = self.transferring.get() || self.detached.get() > 0 || self.session.borrow().changing;
        if self.closed.get() || self.loading.get() || waiting || moving {
            return None;
        }
        let agent = match self.agent.borrow().as_ref() {
            // Only Codex's lines need no memory of the turn they belong to.
            Some(agent) if !agent.is_closed() && !matches!(agent, Connection::Codex(_)) && self.session.borrow().busy => return None,
            Some(agent) if !agent.is_closed() => agent.freeze()?,
            // An agent that left is not carried: the session goes on as it is here, disconnected.
            _ => Value::Null,
        };
        Some(json!({
            "session": serde_json::to_value(&*self.session.borrow()).ok()?, "agent": agent, "windowState": *self.window_state.borrow(),
            "consumedGeneration": self.consumed_generation.get(), "recovery": *self.recovery.borrow(), "logStart": self.log_start.get(),
            "providerChoice": *self.provider_choice.borrow(), "modeChoice": *self.mode_choice.borrow(), "pendingCommand": *self.pending_command.borrow(),
            "accountChoice": *self.account_choice.borrow(), "lastCrash": self.last_crash.get(),
            "pendingActivation": pending_json(&self.pending_activation.borrow()),
            "usageRead": self.usage_read.get() == self.generation.get(),
        }))
    }

    /// The runtime of a session a previous image froze. The agent's descriptors are taken over whether or not this
    /// succeeds: on an error the agent is stopped.
    pub fn adopt(id: &str, state: &Value, config: Rc<Config>) -> Result<Rc<Self>, String> {
        let mut session = session_of(state).inspect_err(|_| release(state))?;
        // An image from before the session files froze none: its next agent gets one.
        if session.fleet_context_file.is_empty() {
            session.fleet_context_file = crate::fleet::create();
        }
        let connection = match &state["agent"] {
            Value::Null => None,
            frozen => {
                let environment = environment_of(&session).inspect_err(|_| release(state))?;
                Some(Connection::adopt(frozen, Some(environment)).map_err(|error| error.to_string())?)
            }
        };
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
            pending_activation: RefCell::new(pending_of(&state["pendingActivation"])),
            detached: Cell::new(0),
            // Claude's usage, read once per agent, is not read again for the same agent.
            usage_read: Cell::new(if state["usageRead"] == true { ADOPTED_GENERATION } else { 0 }),
            repository_reads: Cell::new(0),
            project_guess: RefCell::default(),
            guess_delay: RefCell::default(),
        });
        backend.config.connectivity.watch(&backend);
        backend.refresh_periodically();
        // The probe the previous image ran did not come along: what waited on it waits on this one.
        let (lost, resuming) = {
            let session = backend.session.borrow();
            (session.lost_connection, session.resume_when_back || session.retry_attempt.is_some())
        };
        if lost || resuming {
            backend.config.connectivity.lost("a dropped connection", lost);
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_session_frozen_by_another_build_is_adopted_with_its_missing_fields_at_their_default() {
        let mut session = serde_json::to_value(Session::new("/work", "/state")).unwrap();
        let fields = session.as_object_mut().unwrap();
        fields.remove("recalled_rules").expect("a field this build writes");
        fields.insert("a_field_of_a_later_build".into(), json!(1));
        let frozen = json!({"session": session, "agent": null});

        let checked = check(&frozen);
        let adopted = session_of(&frozen).unwrap();

        assert_eq!(checked, Ok(()));
        assert_eq!(adopted.cwd, "/work");
        assert!(adopted.recalled_rules.is_empty());
    }

    #[test]
    fn a_connection_that_failed_to_open_is_tried_again_by_the_next_image() {
        let account = Account { id: "codex-work".into(), name: "Work".into(), provider: "codex".into(), home: Some("/tmp/codex-work".into()), enabled: true };
        let pending = Some((account, Some("T".to_owned())));

        let carried = pending_of(&pending_json(&pending));

        assert_eq!(carried, pending);
        assert_eq!(pending_of(&Value::Null), None);
    }

    #[test]
    fn a_frozen_agent_of_a_provider_that_is_not_carried_is_refused_before_the_exec() {
        let session = serde_json::to_value(Session::new("/work", "/state")).unwrap();

        let carried = ["codex", "claude"].map(|kind| check(&json!({"session": session, "agent": {"kind": kind}})));
        let refused = check(&json!({"session": session, "agent": {"kind": "agy"}}));

        assert_eq!(carried, [Ok(()), Ok(())]);
        assert!(refused.is_err());
    }

    #[test]
    fn a_frozen_agent_whose_session_names_no_account_is_refused_before_the_exec() {
        let mut session = serde_json::to_value(Session::new("/work", "/state")).unwrap();
        session["account"] = json!({});

        let checked = check(&json!({"session": session, "agent": {"kind": "claude"}}));

        assert_eq!(checked, Err("The adopted session names no account.".to_owned()));
    }
}
