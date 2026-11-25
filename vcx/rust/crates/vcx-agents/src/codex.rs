//! `codex app-server`: JSON-RPC 2.0 over stdio, one message per line. Shapes follow the schema codex-cli 0.172.0
//! generates (`codex app-server generate-json-schema --experimental`); every event keeps the message it came from.

use serde_json::{Map, Value};

pub type Object = Map<String, Value>;

/// What one line from the agent is.
#[derive(Debug, Clone, PartialEq)]
pub enum Inbound {
    Response { id: Value, outcome: Result<Value, RpcError> },
    /// The agent asks the client something (an approval, a question); it waits for `respond` with the same `id`.
    Request { id: Value, method: String, params: Object },
    Event(Event),
    /// A line that is no JSON-RPC message; the session tells it instead of dropping it.
    Invalid(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

/// A notification, typed where the worker acts on it. `raw` is the whole message as the agent sent it.
#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub kind: Kind,
    pub thread_id: Option<String>,
    pub raw: Object,
}

impl Event {
    pub fn method(&self) -> &str {
        self.raw.get("method").and_then(Value::as_str).unwrap_or_default()
    }

    pub fn params(&self) -> &Object {
        static EMPTY: std::sync::OnceLock<Object> = std::sync::OnceLock::new();
        self.raw.get("params").and_then(Value::as_object).unwrap_or_else(|| EMPTY.get_or_init(Object::new))
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    TurnStarted { turn_id: Option<String> },
    TurnCompleted { turn_id: Option<String>, status: TurnStatus, error: Option<String> },
    ItemStarted { item: Object },
    ItemCompleted { item: Object },
    Delta { item_id: String, delta: String, stream: Stream },
    Error { message: String, will_retry: bool },
    Warning { message: String },
    Compacted,
    TokenUsage { total: Option<i64>, last: Option<i64>, window: Option<i64> },
    RateLimits { limits: Object },
    RequestResolved { request_id: Value },
    /// Any other notification; the raw message still says what it was.
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stream {
    AgentMessage,
    Plan,
    CommandOutput,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TurnStatus {
    Completed,
    Interrupted,
    Failed,
    InProgress,
    Unknown(String),
}

impl TurnStatus {
    fn of(text: &str) -> Self {
        match text {
            "completed" => Self::Completed,
            "interrupted" => Self::Interrupted,
            "failed" => Self::Failed,
            "inProgress" => Self::InProgress,
            other => Self::Unknown(other.to_owned()),
        }
    }

    pub fn as_str(&self) -> &str {
        match self {
            Self::Completed => "completed",
            Self::Interrupted => "interrupted",
            Self::Failed => "failed",
            Self::InProgress => "inProgress",
            Self::Unknown(text) => text,
        }
    }
}

const WARNINGS: [&str; 4] = ["warning", "guardianWarning", "configWarning", "deprecationNotice"];

pub fn parse_line(line: &[u8]) -> Inbound {
    match serde_json::from_slice::<Value>(line) {
        Ok(Value::Object(message)) => parse(message),
        Ok(_) => Inbound::Invalid("Codex sent a message that is not a JSON object.".into()),
        Err(error) => Inbound::Invalid(format!("Codex sent invalid JSON: {error}")),
    }
}

pub fn parse(message: Object) -> Inbound {
    let method = message.get("method").and_then(Value::as_str).map(str::to_owned);
    match (message.get("id").cloned(), method) {
        (Some(id), Some(method)) => {
            let params = message.get("params").and_then(Value::as_object).cloned().unwrap_or_default();
            Inbound::Request { id, method, params }
        }
        (Some(id), None) => Inbound::Response { id, outcome: outcome(&message) },
        (None, Some(method)) => Inbound::Event(Event { kind: kind(&method, &message), thread_id: thread_id(&message), raw: message }),
        (None, None) => Inbound::Invalid("Codex sent a message with neither an id nor a method.".into()),
    }
}

fn outcome(message: &Object) -> Result<Value, RpcError> {
    match message.get("error") {
        Some(Value::Object(error)) => Err(RpcError {
            code: error.get("code").and_then(Value::as_i64).unwrap_or_default(),
            message: text(error, "message").unwrap_or("Codex returned an error.").to_owned(),
        }),
        _ => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
    }
}

fn thread_id(message: &Object) -> Option<String> {
    message.get("params")?.get("threadId")?.as_str().map(str::to_owned)
}

fn kind(method: &str, message: &Object) -> Kind {
    let empty = Object::new();
    let params = message.get("params").and_then(Value::as_object).unwrap_or(&empty);
    let turn = params.get("turn").and_then(Value::as_object).unwrap_or(&empty);
    let item = || params.get("item").and_then(Value::as_object).cloned();
    let delta = |stream| match (text(params, "itemId"), text(params, "delta")) {
        (Some(item_id), Some(delta)) => Kind::Delta { item_id: item_id.to_owned(), delta: delta.to_owned(), stream },
        _ => Kind::Other,
    };
    match method {
        "turn/started" => Kind::TurnStarted { turn_id: text(turn, "id").map(str::to_owned) },
        "turn/completed" => Kind::TurnCompleted {
            turn_id: text(turn, "id").map(str::to_owned),
            status: TurnStatus::of(text(turn, "status").unwrap_or("completed")),
            error: turn.get("error").and_then(|error| error.get("message")).and_then(Value::as_str).map(str::to_owned),
        },
        "item/started" => item().map_or(Kind::Other, |item| Kind::ItemStarted { item }),
        "item/completed" => item().map_or(Kind::Other, |item| Kind::ItemCompleted { item }),
        "item/agentMessage/delta" => delta(Stream::AgentMessage),
        "item/plan/delta" => delta(Stream::Plan),
        "item/commandExecution/outputDelta" => delta(Stream::CommandOutput),
        "error" => Kind::Error {
            message: params.get("error").and_then(|error| error.get("message")).and_then(Value::as_str).unwrap_or("Codex reported an error.").to_owned(),
            will_retry: params.get("willRetry") == Some(&Value::Bool(true)),
        },
        "thread/compacted" => Kind::Compacted,
        "thread/tokenUsage/updated" => {
            let usage = params.get("tokenUsage").and_then(Value::as_object).unwrap_or(&empty);
            let tokens = |key: &str| usage.get(key).and_then(|part| part.get("totalTokens")).and_then(Value::as_i64);
            Kind::TokenUsage { total: tokens("total"), last: tokens("last"), window: usage.get("modelContextWindow").and_then(Value::as_i64) }
        }
        "account/rateLimits/updated" => Kind::RateLimits { limits: params.get("rateLimits").and_then(Value::as_object).cloned().unwrap_or_default() },
        "serverRequest/resolved" => params.get("requestId").cloned().map_or(Kind::Other, |request_id| Kind::RequestResolved { request_id }),
        warning if WARNINGS.contains(&warning) => Kind::Warning {
            message: text(params, "message").or_else(|| text(params, "summary")).unwrap_or("Codex reported a configuration warning.").to_owned(),
        },
        _ => Kind::Other,
    }
}

fn text<'a>(object: &'a Object, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}
