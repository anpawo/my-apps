//! What the rest of the Mac sees of a session: Fleet's card, the session list, the window list kept for a restart.

use serde_json::Value;
use vcx_model::{Object, SessionState, item};

/// Fleet reads the last rows only, and a few items of each (Swift `FleetPresence.publish`).
const PREVIEW_ROWS: usize = 16;
const PREVIEW_ITEMS: usize = 4;
const MAX_TEXT_CHARS: usize = 2000;
/// His Done line: an answer holding it, nothing left to run, is a finished task.
const DONE_MARK: &str = "✓ Done:";

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Summary {
    pub cwd: String,
    /// Fleet's word for it: waiting, failed, working, pending, fresh or ready.
    pub state: &'static str,
    /// Ready for a message from another window: nothing runs and nothing changes.
    pub idle: bool,
    /// What a close or quit warns about (Swift `runningWork`): a turn under way, and background tasks still running.
    pub busy: bool,
    pub background_tasks: u64,
    /// The composer holds text or a picture not sent yet, as last checkpointed to the worker.
    pub draft: bool,
    /// A permission the agent asked for waits on his answer.
    pub deciding: bool,
    pub prompt: Option<String>,
    pub last_prompt_at: Option<f64>,
    pub context: Option<String>,
    pub thread_id: Option<String>,
    pub record_id: Option<String>,
    /// Where the agent writes what it waits on ($VCX_PROGRESS_FILE).
    pub progress_file: Option<String>,
    /// Where the agent writes the task it works on ($VCX_TASK_FILE).
    pub task_file: Option<String>,
    /// The task bar's word for it (Swift `TaskBoard.state`): working, question or done.
    pub task_state: &'static str,
    /// The account the session runs on, as the worker names it: `{id, name, provider, …}`.
    pub account: Option<Value>,
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
        busy: flag("busy"),
        background_tasks: background,
        draft: state.draft.iter().any(|part| part.get("type").and_then(Value::as_str) != Some("text") || part.get("text").and_then(Value::as_str).is_some_and(|text| !text.is_empty())),
        deciding: waiting,
        prompt: prompt.map(|prompt| clipped(&prompt)),
        last_prompt_at: user_items.last().and_then(|item| item.get("sentAt")).and_then(Value::as_f64),
        context: text(meta, "fleetContext").filter(|context| !context.is_empty()),
        thread_id: text(meta, "threadID").filter(|thread| !thread.is_empty()),
        record_id: text(meta, "recordID").filter(|record| !record.is_empty()),
        progress_file: text(meta, "progressFile").filter(|file| !file.is_empty()),
        task_file: text(meta, "taskFile").filter(|file| !file.is_empty()),
        task_state: task_state(state, waiting || flag("needsAttention"), flag("busy") || flag("changing") || background > 0),
        account: meta.get("account").filter(|account| account.is_object()).cloned(),
        preview: preview(state),
    }
}

/// Green only once the last answer since his last prompt holds his Done line; an idle session without one waits on him.
fn task_state(state: &SessionState, waiting: bool, busy: bool) -> &'static str {
    if waiting {
        return "question";
    }
    if busy {
        return "working";
    }
    let since = state.rows.iter().rposition(|row| row.kind == "user").map_or(0, |last| last + 1);
    let answers = state.rows[since..].iter().filter(|row| row.kind == "assistant").flat_map(|row| row.items.iter().filter_map(|id| state.items.get(id)));
    let last = answers.filter_map(|item| text(item, "text")).last();
    match last.is_some_and(|answer| answer.split("\n\n").any(|paragraph| paragraph.trim().starts_with(DONE_MARK))) {
        true => "done",
        false => "question",
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

    #[test]
    fn counts_the_work_a_close_would_cut_short() {
        let pending = state(json!({"ready": true, "busy": false, "backgroundTasks": 2, "rows": []}));
        let running = state(json!({"ready": true, "busy": true, "rows": []}));

        let (pending, running) = (of(&pending), of(&running));

        assert_eq!((pending.busy, pending.background_tasks, pending.state), (false, 2, "pending"));
        assert_eq!((running.busy, running.background_tasks), (true, 0));
    }

    #[test]
    fn counts_a_draft_only_when_it_holds_text_or_a_picture() {
        let drafts = [json!([{"type": "text", "text": "unsent"}]), json!([{"type": "localImage", "path": "/tmp/p.png"}]), json!([{"type": "text", "text": ""}]), json!([])];

        let held: Vec<bool> = drafts.into_iter().map(|draft| of(&state(json!({"ready": true, "draft": draft, "rows": []}))).draft).collect();

        assert_eq!(held, [true, true, false, false]);
    }

    #[test]
    fn says_a_decision_waits_while_a_permission_is_asked() {
        let (asking, free) = (state(json!({"ready": true, "permissions": [{"id": "P"}], "rows": []})), state(json!({"ready": true, "rows": []})));

        let (asking, free) = (of(&asking), of(&free));

        assert_eq!((asking.deciding, free.deciding), (true, false));
    }

    #[test]
    fn marks_a_task_done_only_when_the_last_answer_holds_the_done_line() {
        let answer = |text: &str| state(json!({"ready": true, "taskFile": "/tmp/f/task.goal", "rows": [
            {"id": "R1", "kind": "user", "items": [{"id": "u", "type": "userMessage", "content": [{"type": "text", "text": "go"}]}]},
            {"id": "R2", "kind": "assistant", "items": [{"id": "a", "type": "agentMessage", "text": text}]}
        ]}));
        let running = state(json!({"ready": true, "busy": true, "rows": []}));

        let (done, open) = (of(&answer("Built it.\n\n✓ Done: the bar, you can close this session.")), of(&answer("Built it.\n\nNext: ship it?")));

        assert_eq!((done.task_state, open.task_state, of(&running).task_state), ("done", "question", "working"));
        assert_eq!(done.task_file.as_deref(), Some("/tmp/f/task.goal"));
    }
}
