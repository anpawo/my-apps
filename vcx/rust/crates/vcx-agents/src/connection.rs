//! One provider behind the requests a session sends `codex app-server`, as the Swift `Connection` protocol: Codex
//! answers them itself, the other adapters translate them.

use crate::agy::AgyConnection;
use crate::claude::ClaudeConnection;
use crate::qwen::QwenConnection;
use crate::rpc::{Agent, AgentError};
use serde_json::{Value, json};
use std::rc::Rc;
use std::time::Duration;

#[derive(Clone)]
pub enum Connection {
    Codex(Agent),
    Claude(Rc<ClaudeConnection>),
    Agy(Rc<AgyConnection>),
    Qwen(Rc<QwenConnection>),
}

impl Connection {
    pub async fn request(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, AgentError> {
        match self {
            Self::Codex(agent) => agent.request(method, params, timeout).await,
            Self::Claude(claude) => claude.request(method, params, timeout).await,
            Self::Agy(agy) => agy.request(method, params, timeout).await,
            Self::Qwen(qwen) => qwen.request(method, params, timeout).await,
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
            Self::Qwen(qwen) => qwen.respond(id, result),
        }
    }

    /// A request the session cannot answer: Codex hears the error, the others a declined permission.
    pub fn reject(&self, id: &Value, code: i64, message: &str) -> Result<(), AgentError> {
        match self {
            Self::Codex(agent) => agent.reject(id, code, message),
            Self::Claude(claude) => claude.respond(id, json!({"decision": "decline"})),
            Self::Agy(agy) => agy.reject(id),
            Self::Qwen(qwen) => qwen.reject(id),
        }
    }

    /// What a newer image of the worker needs to keep the agent, or `None` when it cannot be carried over now. Codex
    /// is carried at any time and Claude between two turns, as the Swift worker carries them; agy and Qwen never.
    pub fn freeze(&self) -> Option<Value> {
        match self {
            Self::Codex(agent) => agent.freeze().map(|agent| json!({"kind": "codex", "agent": agent})),
            Self::Claude(claude) => claude.freeze(),
            _ => None,
        }
    }

    /// Whether `adopt` knows the provider of a frozen connection.
    pub fn adoptable(state: &Value) -> bool {
        matches!(state["kind"].as_str(), Some("codex" | "claude"))
    }

    /// The descriptors a frozen connection names: its worker keeps them open across the exec.
    pub fn descriptors(state: &Value) -> Vec<std::os::fd::RawFd> {
        Agent::descriptors(&state["agent"])
    }

    /// `environment` is what this image gives the agents it starts: Claude's next process gets it, the frozen state
    /// carries none.
    pub fn adopt(state: &Value, environment: Option<Vec<(String, String)>>) -> std::io::Result<(Self, tokio::sync::mpsc::UnboundedReceiver<crate::rpc::Incoming>)> {
        match state["kind"].as_str() {
            Some("codex") => Agent::adopt(&state["agent"]).map(|(agent, incoming)| (Self::Codex(agent), incoming)),
            Some("claude") => ClaudeConnection::adopt(state, environment).map(|(claude, incoming)| (Self::Claude(claude), incoming)),
            _ => Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "This agent connection cannot be adopted.")),
        }
    }

    pub fn is_closed(&self) -> bool {
        match self {
            Self::Codex(agent) => agent.is_closed(),
            Self::Claude(claude) => claude.is_closed(),
            Self::Agy(agy) => agy.is_closed(),
            Self::Qwen(qwen) => qwen.is_closed(),
        }
    }

    pub fn close(&self) {
        match self {
            Self::Codex(agent) => agent.close(),
            Self::Claude(claude) => claude.close(),
            Self::Agy(agy) => agy.close(),
            Self::Qwen(qwen) => qwen.close(),
        }
    }
}
