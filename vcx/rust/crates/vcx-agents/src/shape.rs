//! What every adapter shares: the effects a stream asks its connection to carry out, and typed reads of JSON.

use crate::Object;
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};

/// What one line from an agent asks its connection to do.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// A Codex-shaped message for the session: `{method, params}`, or `{id, method, params}` when it waits for an answer.
    Event(Object),
    /// A line to write to Claude's input.
    Write(Object),
    /// The answer to one of our control requests.
    Resolve { request_id: String, outcome: Result<Object, String> },
    /// Claude answered: the first-event watch stops.
    Answered,
    /// The turn ended: the stop watch stops.
    TurnEnded,
}

pub fn pretty(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => serde_json::to_string_pretty(other).unwrap_or_default(),
    }
}

pub fn suffix(text: &str, limit: usize) -> String {
    let count = text.chars().count();
    text.chars().skip(count.saturating_sub(limit)).collect()
}

pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0.0, |time| time.as_secs_f64())
}

pub fn object(value: Value) -> Object {
    match value {
        Value::Object(map) => map,
        _ => Object::new(),
    }
}

pub fn obj(value: Option<&Value>) -> Object {
    value.and_then(Value::as_object).cloned().unwrap_or_default()
}

pub fn text<'a>(object: &'a Object, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

/// A JSON number as an integer; a whole float counts, as `as? Int` reads an NSNumber.
pub fn int(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    value.as_i64().or_else(|| value.as_f64().filter(|f| f.fract() == 0.0).map(|f| f as i64))
}

pub fn number(value: Option<&Value>) -> f64 {
    value.and_then(Value::as_f64).unwrap_or(0.0)
}
