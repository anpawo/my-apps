//! What the Swift `Session` does when a turn stops on a limit: the plan's usage limit moves the conversation to the next
//! available account, handed its recent messages; a server rate limit is retried on the same account.

use crate::session::Session;
use serde_json::Value;

pub type Object = serde_json::Map<String, Value>;

/// How long a usage-limited account rests when the provider names no reset time.
pub const LIMIT_PAUSE: f64 = 300.0;
/// The waits before each retry of a rate-limited turn, in seconds.
pub const RATE_LIMIT_RETRIES: [u64; 3] = [10, 30, 60];
pub const KEEP_GOING: &str = "Keep going: the request was rate limited. Retry the step that failed and continue.";
const RESET_KEYS: [&str; 3] = ["resetsAt", "resetAt", "resets_at"];
const HANDOFF_ROWS: usize = 60;
const HANDOFF_ITEMS: usize = 12;
const HANDOFF_OUTPUT: usize = 1500;
const HANDOFF_BYTES: usize = 48_000;
const RATE_LIMIT_STATUS: &str = "429";

pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// When the limited account may be tried again (seconds since 1970).
pub fn limit_reset(info: &Object, now: f64) -> f64 {
    for key in RESET_KEYS {
        match info.get(key) {
            Some(Value::Number(time)) if time.as_f64().is_some_and(|time| time > now) => return time.as_f64().unwrap_or(now),
            Some(Value::String(text)) => {
                if let Ok(time) = text.parse::<jiff::Timestamp>() {
                    return (time.as_millisecond() as f64 / 1000.0).max(now + 1.0);
                }
            }
            _ => {}
        }
    }
    now + LIMIT_PAUSE
}

/// A failed turn the server throttled, which passes on its own, unlike the plan's usage limit.
pub fn rate_limited(turn: &Object) -> bool {
    let Some(error) = turn.get("error").and_then(Value::as_object) else { return false };
    if error.get("rateLimited") == Some(&Value::Bool(true)) {
        return true;
    }
    let message = error.get("message").and_then(Value::as_str).unwrap_or_default().to_lowercase();
    names_rate_limit(&message) || names_status(&message, RATE_LIMIT_STATUS)
}

/// `rate.?limit`: "rate limit", "rate-limit", "ratelimit".
fn names_rate_limit(message: &str) -> bool {
    message.match_indices("rate").any(|(start, _)| {
        let rest = &message[start + "rate".len()..];
        rest.starts_with("limit") || rest.chars().next().is_some_and(|gap| rest[gap.len_utf8()..].starts_with("limit"))
    })
}

/// The status as a word of its own, not part of a longer number.
fn names_status(message: &str, status: &str) -> bool {
    message.match_indices(status).any(|(start, _)| {
        let before = message[..start].chars().next_back();
        let after = message[start + status.len()..].chars().next();
        !before.is_some_and(char::is_alphanumeric) && !after.is_some_and(char::is_alphanumeric)
    })
}

fn tail(text: &str, limit: usize) -> &str {
    let mut start = text.len().saturating_sub(limit);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    &text[start..]
}

/// The recent conversation a new agent is handed, as the Swift `handoffContext` writes it; empty when nothing was said.
pub fn handoff_context(session: &Session) -> String {
    let rows = session.rows();
    let mut lines = Vec::new();
    for row in &rows[rows.len().saturating_sub(HANDOFF_ROWS)..] {
        for id in &row.items[row.items.len().saturating_sub(HANDOFF_ITEMS)..] {
            let Some(item) = session.item(id) else { continue };
            let text = |key: &str| item.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
            let line = match row.kind.as_str() {
                "user" => {
                    let pieces = item.get("content").and_then(Value::as_array).into_iter().flatten();
                    format!("User: {}", pieces.filter_map(|piece| piece.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n"))
                }
                "assistant" => format!("{}: {}", item.get("provider").and_then(Value::as_str).unwrap_or("Assistant"), text("text")),
                "activity" => {
                    let failed = text("status") == "failed" || item.get("exitCode").and_then(Value::as_i64).is_some_and(|code| code != 0);
                    let title = [text("command"), text("title"), text("text")].into_iter().find(|title| !title.is_empty()).unwrap_or_default();
                    format!("Action ({}): {title}\n{}", if failed { "failed" } else { "recorded" }, tail(&text("aggregatedOutput"), HANDOFF_OUTPUT))
                }
                _ => continue,
            };
            lines.push(line);
        }
    }
    let joined = lines.join("\n\n");
    let text = tail(&joined, HANDOFF_BYTES);
    if text.is_empty() {
        return String::new();
    }
    format!("Context from this conversation, truncated to the latest 48 KB if necessary. Continue from the work already done. Check the current files before acting; do not repeat successful actions. The latest request follows this context.\n\n{text}\n\nEnd of conversation context.")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn object(value: Value) -> Object {
        value.as_object().cloned().unwrap()
    }

    #[test]
    fn reads_a_server_throttle_as_a_rate_limit() {
        let throttled = ["exceeded retry limit, last status: 429 Too Many Requests", "Rate limit reached", "rate-limited by the API"];

        let found = throttled.map(|message| rate_limited(&object(json!({"error": {"message": message}}))));

        assert_eq!(found, [true; 3]);
    }

    #[test]
    fn does_not_read_a_longer_number_or_a_plain_failure_as_a_rate_limit() {
        let plain = ["status 14290", "The command failed"];

        let found = plain.map(|message| rate_limited(&object(json!({"error": {"message": message}}))));

        assert_eq!(found, [false, false]);
    }

    #[test]
    fn takes_the_reset_the_provider_names_else_rests_five_minutes() {
        let named = limit_reset(&object(json!({"resetsAt": "2030-01-01T00:00:00Z"})), 0.0);
        let unnamed = limit_reset(&object(json!({"message": "limit"})), 100.0);

        assert_eq!(named, 1_893_456_000.0);
        assert_eq!(unnamed, 100.0 + LIMIT_PAUSE);
    }

    #[test]
    fn hands_over_the_prompts_answers_and_actions_and_nothing_when_empty() {
        let mut session = Session::new("/tmp", "/tmp/state");
        assert_eq!(handoff_context(&session), "");
        session.opened(json!({"thread": {"id": "T"}}).as_object().unwrap(), &[json!({"id": "t", "status": "completed", "items": [
            {"id": "u", "type": "userMessage", "content": [{"type": "text", "text": "list files"}]},
            {"id": "c", "type": "commandExecution", "command": "ls", "status": "completed", "exitCode": 0, "aggregatedOutput": "a.txt\n"},
            {"id": "a", "type": "agentMessage", "text": "One file."},
        ]})], false);

        let context = handoff_context(&session);

        assert!(context.contains("User: list files\n\nAction (recorded): ls\na.txt\n\n\nCodex: One file."), "{context}");
        assert!(context.starts_with("Context from this conversation") && context.ends_with("End of conversation context."));
    }
}
