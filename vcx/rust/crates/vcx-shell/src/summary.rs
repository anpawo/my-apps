//! What the rest of the Mac sees of a session: Fleet's card, the session list, the window list kept for a restart.

use serde_json::Value;
use vcx_model::{Object, SessionState, item};

/// Fleet reads the last rows only, and a few items of each (Swift `FleetPresence.publish`).
const PREVIEW_ROWS: usize = 16;
const PREVIEW_ITEMS: usize = 4;
const MAX_TEXT_CHARS: usize = 2000;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Summary {
    pub cwd: String,
    /// Fleet's word for it: waiting, failed, working, pending, fresh or ready.
    pub state: &'static str,
    /// Ready for a message from another window: nothing runs and nothing changes.
    pub idle: bool,
    pub prompt: Option<String>,
    pub last_prompt_at: Option<f64>,
    pub context: Option<String>,
    pub thread_id: Option<String>,
    pub record_id: Option<String>,
    /// Where the agent writes what it waits on ($VCX_PROGRESS_FILE).
    pub progress_file: Option<String>,
    /// (kind, text) with Fleet's kinds: user, tool, assistant.
    pub preview: Vec<(&'static str, String)>,
}

pub fn of(state: &SessionState) -> Summary {
    let meta = &state.meta;
    let flag = |key: &str| meta.get(key) == Some(&Value::Bool(true));
    let user = state.rows.iter().rev().find(|row| row.kind == "user");
    let user_items: Vec<&Object> = user.map(|row| row.items.iter().filter_map(|id| state.items.get(id)).collect()).unwrap_or_default();
    let prompt = user.map(|_| user_items.iter().map(|item| user_text(item)).collect::<Vec<_>>().join("\n"));
    let waiting = meta.get("permissions").and_then(Value::as_array).is_some_and(|permissions| !permissions.is_empty());
    let background = meta.get("backgroundTasks").and_then(Value::as_u64).unwrap_or(0);
    let fleet_state = if waiting {
        "waiting"
    } else if flag("needsAttention") {
        "failed"
    } else if flag("busy") || flag("changing") {
        "working"
    } else if background > 0 {
        "pending"
    } else if user.is_none() {
        "fresh"
    } else {
        "ready"
    };
    Summary {
        cwd: text(meta, "cwd").unwrap_or_default(),
        state: fleet_state,
        idle: flag("ready") && !flag("busy") && !flag("changing"),
        prompt: prompt.map(|prompt| clipped(&prompt)),
        last_prompt_at: user_items.last().and_then(|item| item.get("sentAt")).and_then(Value::as_f64),
        context: text(meta, "fleetContext").filter(|context| !context.is_empty()),
        thread_id: text(meta, "threadID").filter(|thread| !thread.is_empty()),
        record_id: text(meta, "recordID").filter(|record| !record.is_empty()),
        progress_file: text(meta, "progressFile").filter(|file| !file.is_empty()),
        preview: preview(state),
    }
}

fn preview(state: &SessionState) -> Vec<(&'static str, String)> {
    let first = state.rows.len().saturating_sub(PREVIEW_ROWS);
    let mut lines = Vec::new();
    for row in &state.rows[first..] {
        let items: Vec<&Object> = row.items.iter().filter_map(|id| state.items.get(id)).collect();
        let tool = matches!(row.kind.as_str(), "activity" | "peer");
        for item in &items[items.len().saturating_sub(PREVIEW_ITEMS)..] {
            let (kind, line) = match row.kind.as_str() {
                "user" => ("user", user_text(item)),
                _ if tool => ("tool", item::title(item)),
                _ => ("assistant", text(item, "text").unwrap_or_default()),
            };
            if !line.is_empty() {
                lines.push((kind, clipped(&line)));
            }
        }
    }
    lines
}

fn user_text(item: &Object) -> String {
    let parts = item.get("content").and_then(Value::as_array).into_iter().flatten();
    parts.filter_map(|part| part.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n")
}

fn text(object: &Object, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn clipped(text: &str) -> String {
    text.chars().take(MAX_TEXT_CHARS).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn state(value: Value) -> SessionState {
        SessionState::from_snapshot(value.as_object().unwrap())
    }

    #[test]
    fn calls_a_session_with_no_prompt_fresh_and_one_that_answered_ready() {
        let fresh = state(json!({"ready": true, "rows": []}));
        let answered = state(json!({"ready": true, "busy": false, "cwd": "/tmp/p", "threadID": "claude:T", "recordID": "R", "rows": [
            {"id": "R1", "kind": "user", "items": [{"id": "u", "type": "userMessage", "content": [{"type": "text", "text": "hi"}], "sentAt": 12.5}]},
            {"id": "R2", "kind": "assistant", "items": [{"id": "a", "type": "agentMessage", "text": "hello"}]}
        ]}));

        let (fresh, answered) = (of(&fresh), of(&answered));

        assert_eq!((fresh.state, fresh.idle, fresh.prompt), ("fresh", true, None));
        assert_eq!((answered.state, answered.idle, answered.prompt.as_deref()), ("ready", true, Some("hi")));
        assert_eq!((answered.thread_id.as_deref(), answered.record_id.as_deref(), answered.last_prompt_at), (Some("claude:T"), Some("R"), Some(12.5)));
        assert_eq!(answered.preview, [("user", "hi".to_owned()), ("assistant", "hello".to_owned())]);
    }

    #[test]
    fn puts_a_question_for_him_before_a_running_turn() {
        let asking = state(json!({"ready": true, "busy": true, "permissions": [{"id": "P"}], "rows": []}));
        let running = state(json!({"ready": true, "busy": true, "rows": []}));

        let (asking, running) = (of(&asking), of(&running));

        assert_eq!((asking.state, running.state), ("waiting", "working"));
        assert!(!running.idle);
    }
}
