//! One provider behind the requests a session sends `codex app-server`, as the Swift `Connection` protocol: Codex
//! answers them itself, the other adapters translate them.

use crate::agy::AgyConnection;
use crate::claude::ClaudeConnection;
use crate::rpc::{Agent, AgentError};
use serde_json::{Value, json};
use std::rc::Rc;
use std::time::Duration;

#[derive(Clone)]
pub enum Connection {
    Codex(Agent),
    Claude(Rc<ClaudeConnection>),
    Agy(Rc<AgyConnection>),
}

impl Connection {
    pub async fn request(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, AgentError> {
        match self {
            Self::Codex(agent) => agent.request(method, params, timeout).await,
            Self::Claude(claude) => claude.request(method, params, timeout).await,
            Self::Agy(agy) => agy.request(method, params, timeout).await,
        }
    }

    /// Only Codex takes notifications (`initialized`); the others have nothing to be told.
    pub fn notify(&self, method: &str, params: Option<Value>) -> Result<(), AgentError> {
        match self {
            Self::Codex(agent) => agent.notify(method, params),
            _ => Ok(()),
        }
    }

    pub fn respond(&self, id: &Value, result: Value) -> Result<(), AgentError> {
        match self {
            Self::Codex(agent) => agent.respond(id, result),
            Self::Claude(claude) => claude.respond(id, result),
            Self::Agy(agy) => agy.respond(id, result),
        }
    }

    /// A request the session cannot answer: Codex hears the error, the others a declined permission.
    pub fn reject(&self, id: &Value, code: i64, message: &str) -> Result<(), AgentError> {
        match self {
            Self::Codex(agent) => agent.reject(id, code, message),
            Self::Claude(claude) => claude.respond(id, json!({"decision": "decline"})),
            Self::Agy(agy) => agy.reject(id),
        }
    }

    pub fn is_closed(&self) -> bool {
        match self {
            Self::Codex(agent) => agent.is_closed(),
            Self::Claude(claude) => claude.is_closed(),
            Self::Agy(agy) => agy.is_closed(),
        }
    }

    pub fn close(&self) {
        match self {
            Self::Codex(agent) => agent.close(),
            Self::Claude(claude) => claude.close(),
            Self::Agy(agy) => agy.close(),
        }
    }
}
