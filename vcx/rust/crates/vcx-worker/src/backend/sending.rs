//! The send path around a prompt, as the Swift `Session` runs it: the checks before a new turn, Shift+Return's "send
//! now", and a queued prompt taken back.

use super::{REQUEST_TIMEOUT, SessionBackend, text};
use crate::session::SendNow;
use serde_json::{Value, json};
use std::rc::Rc;
use std::time::Duration;

/// Claude answers its queue controls at once; a longer wait means the prompt already went.
const QUEUE_TIMEOUT: Duration = Duration::from_secs(5);

impl SessionBackend {
    /// Before a new turn: a mode changed in Settings is applied, and a limited account hands the conversation to the
    /// next available one. `false` when the prompt must not go.
    pub(super) async fn prepare_turn(self: &Rc<Self>) -> bool {
        let idle = {
            let session = self.session.borrow();
            session.ready && !session.busy && !session.changing
        };
        if !idle {
            return true;
        }
        let settings = self.settings();
        let preferred = self.preferred_mode(&settings);
        if self.session.borrow().active_mode != preferred {
            self.switch_mode(&preferred).await;
            if !self.session.borrow().ready {
                return false;
            }
        }
        let Some(next) = self.available(&settings).into_iter().next() else {
            self.session.borrow_mut().notice("All enabled accounts have reached their limits. Check Settings or wait for a reset.");
            return false;
        };
        if self.session.borrow().account["id"] == json!(next.id) {
            return true;
        }
        if let Err(error) = self.activate(&next, None, Some(&format!("switched to {}", next.name))).await {
            let mut session = self.session.borrow_mut();
            session.needs_attention = true;
            session.status = "Send failed".into();
            session.notice(&format!("Prompt was not sent: {error}"));
            return false;
        }
        self.refresh_catalog().await;
        true
    }

    /// The Swift `sendWaitingNow`: Claude takes the queued prompt in itself; another agent's turn is interrupted and
    /// a turn with no input answers the prompt it left unread.
    pub(super) async fn send_waiting_now(self: Rc<Self>) {
        let choice = self.session.borrow_mut().begin_send_now();
        match choice {
            Some(SendNow::Queued(id)) => {
                if let Err(error) = self.request("vcx/sendNow", json!({"id": id}), QUEUE_TIMEOUT).await {
                    self.session.borrow_mut().notice(&format!("Could not send now: {error}"));
                }
            }
            Some(SendNow::Interrupt) => Rc::clone(&self).stop("Shift+Return").await,
            None => {}
        }
    }

    /// The Swift `continueWith`: the stopped turn's waiting prompt is answered by a turn of its own.
    pub(super) async fn continue_with(self: Rc<Self>, prompt: String) {
        let params = self.session.borrow_mut().continue_with(&prompt);
        let Some(params) = params else { return };
        self.schedule();
        match self.request("turn/start", params, REQUEST_TIMEOUT).await {
            Ok(result) => {
                let mut session = self.session.borrow_mut();
                if session.busy && session.turn_id.is_none() {
                    session.turn_id = result["turn"]["id"].as_str().map(str::to_owned);
                }
            }
            Err(error) => self.session.borrow_mut().continue_failed(&error),
        }
        self.schedule();
    }

    /// The Swift `unsend`: the agent is asked to drop the prompt from its queue; only then does it leave the chat.
    pub(super) async fn unsend(&self, params: &super::Object) -> bool {
        let id = text(params, "id").unwrap_or_default();
        let answer = self.request("vcx/unsend", json!({"id": id}), QUEUE_TIMEOUT).await;
        let cancelled = answer.is_ok_and(|result| result.get("cancelled") == Some(&Value::Bool(true)));
        if cancelled {
            self.session.borrow_mut().unsent(id);
        }
        cancelled
    }
}
