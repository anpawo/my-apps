//! Provider adapters for the runtime worker. Each reads its agent's stream into typed events and keeps the message
//! each came from, so the session can show what it does not type yet.

pub mod agy_stream;
pub mod claude_stream;
pub mod codex;
pub mod directory;
pub mod rpc;
pub mod shape;

pub use codex::{Event, Inbound, Kind, Object, RpcError, Stream, TurnStatus};
pub use rpc::{Agent, AgentError, Incoming};
