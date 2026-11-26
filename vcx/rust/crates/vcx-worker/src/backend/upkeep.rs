//! What the Swift `Session` does around its turns besides showing them: the trace of what the agent sends, cleanup.py
//! after each turn and on close, and a thread open asked again when Codex's workspace routing timed out.

use super::{Object, REQUEST_TIMEOUT, SessionBackend, object};
use crate::cleanup;
use crate::session::Effect;
use crate::trace;
use serde_json::{Value, json};
use std::path::Path;
use vcx_agents::{Inbound, Kind};

const ROUTING_TIMEOUT: &str = "workspace routing discovery timed out";

impl SessionBackend {
    /// `thread/start` or `thread/resume`, asked once more when Codex's workspace routing timed out (Session.swift:631).
    pub(super) async fn open_thread(&self, method: &str, params: Value) -> Result<Object, String> {
        match self.request(method, params.clone(), REQUEST_TIMEOUT).await {
            Err(error) if error == ROUTING_TIMEOUT => self.request(method, params, REQUEST_TIMEOUT).await.map(object),
            result => result.map(object),
        }
    }

    /// Every agent event and request but the streamed deltas goes to the trace, before the session reads it.
    pub(super) fn trace_inbound(&self, message: &Inbound) {
        let (method, params, request) = match message {
            Inbound::Event(event) => (event.method(), event.params(), false),
            Inbound::Request { method, params, .. } => (method.as_str(), params, true),
            _ => return,
        };
        if !method.to_lowercase().ends_with("delta") {
            self.session.borrow().trace("event", json!({"method": method, "params": params, "request": request}));
        }
    }

    /// cleanup.py after a turn of this conversation ends, unless a usage limit moves its prompt to another account.
    pub(super) fn after_inbound(&self, message: &Inbound, effects: &[Effect]) {
        let Inbound::Event(event) = message else { return };
        let ours = event.thread_id.as_ref().is_none_or(|thread| self.session.borrow().thread_id.as_ref() == Some(thread));
        if matches!(event.kind, Kind::TurnCompleted { .. }) && ours && !effects.iter().any(|effect| matches!(effect, Effect::Limit(_))) {
            self.clean_disk(false);
        }
    }

    fn clean_disk(&self, force: bool) {
        cleanup::run(self.config.cleanup.as_deref(), &self.session.borrow().cwd, force);
    }

    /// The Swift `close`: a forced cleanup of the session's folder, and its trace moved into the database.
    pub(super) fn upkeep_on_close(&self) {
        self.clean_disk(true);
        trace::migrate(Path::new(&self.session.borrow().state_directory), true);
    }
}

#[cfg(test)]
mod tests {
    use crate::session::Session;
    use serde_json::json;

    #[test]
    fn the_instruction_files_the_agent_reports_on_open_are_listed() {
        let mut session = Session::new("/work", "/state");
        session.capabilities.instructions = vec!["~/AGENTS.md".into()];
        let reported = json!({"thread": {"id": "T"}, "instructionSources": ["/work/AGENTS.md", "/work/CLAUDE.md"]});

        session.opened(reported.as_object().unwrap(), &[], false);
        let listed = session.capabilities.instructions.clone();
        session.opened(json!({"thread": {"id": "T"}, "instructionSources": []}).as_object().unwrap(), &[], false);

        assert_eq!(listed, ["/work/AGENTS.md", "/work/CLAUDE.md"]);
        assert_eq!(session.capabilities.instructions, listed, "an empty list keeps the files already listed");
    }
}
