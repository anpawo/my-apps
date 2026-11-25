//! The data contract between the core and the page template. A template states the contract version it was written
//! for; the shell refuses one it does not speak and keeps the last template that worked.

use crate::item::{self, text};
use crate::markdown;
use crate::state::{Changes, Object, Row, SessionState};
use serde_json::{Value, json};
use std::collections::HashSet;

pub const CONTRACT_VERSION: u32 = 1;

/// Metadata the page may read. The rest of the worker's metadata (paths, account, hooks) stays in the core.
const PAGE_META_KEYS: [&str; 16] = [
    "model", "providerLabel", "status", "ready", "busy", "needsAttention", "cwd", "conversationName", "repository", "branch", "contextUsed", "contextLimit",
    "usagePercent", "activeMode", "effort", "backgroundTasks",
];

pub fn full(state: &SessionState) -> Value {
    json!({
        "contract": CONTRACT_VERSION,
        "meta": meta(state),
        "rows": state.rows.iter().map(|row| row_view(state, row)).collect::<Vec<_>>(),
        "draft": state.draft,
    })
}

/// Only what a patch changed: redrawn rows whole, the order when rows came or went, the metadata when it moved.
pub fn patch(state: &SessionState, changes: &Changes) -> Value {
    let mut view = Object::new();
    if changes.meta {
        view.insert("meta".into(), meta(state));
    }
    if changes.order {
        view.insert("order".into(), json!(state.rows.iter().map(|row| &row.id).collect::<Vec<_>>()));
    }
    let rows: HashSet<&str> = changes.rows.iter().map(String::as_str).collect();
    let items: HashSet<&str> = changes.items.iter().map(String::as_str).collect();
    let redrawn: Vec<Value> = state
        .rows
        .iter()
        .filter(|row| rows.contains(row.id.as_str()) || row.items.iter().any(|item| items.contains(item.as_str())))
        .map(|row| row_view(state, row))
        .collect();
    if !redrawn.is_empty() {
        view.insert("rows".into(), Value::Array(redrawn));
    }
    if changes.draft {
        view.insert("draft".into(), json!(state.draft));
    }
    Value::Object(view)
}

fn meta(state: &SessionState) -> Value {
    Value::Object(PAGE_META_KEYS.iter().filter_map(|key| state.meta.get(*key).map(|value| ((*key).to_owned(), value.clone()))).collect())
}

fn row_view(state: &SessionState, row: &Row) -> Value {
    let items: Vec<Value> = row.items.iter().filter_map(|id| state.items.get(id)).map(|item| item_view(&row.kind, item)).collect();
    json!({"id": row.id, "kind": row.kind, "items": items})
}

fn item_view(row_kind: &str, data: &Object) -> Value {
    let kind = item::kind(data);
    let mut view = json!({"id": text(data, "id").unwrap_or_default(), "type": kind});
    match (row_kind, kind) {
        (_, "agentMessage") => view["html"] = json!(markdown::to_html(text(data, "text").unwrap_or_default())),
        (_, "userMessage") => {
            view["text"] = json!(pieces(data, "text", "text").collect::<String>());
            view["images"] = json!(pieces(data, "localImage", "path").collect::<Vec<_>>());
            view["queued"] = json!(data.get("queued") == Some(&Value::Bool(true)));
        }
        ("notice", _) => view["text"] = json!(text(data, "text").unwrap_or_default()),
        _ => {
            view["title"] = json!(item::title(data));
            view["output"] = json!(item::output(data));
            view["failed"] = json!(item::failed(data));
            view["status"] = json!(text(data, "status").unwrap_or_default());
        }
    }
    view
}

fn pieces<'a>(data: &'a Object, kind: &'a str, key: &'a str) -> impl Iterator<Item = &'a str> {
    data.get("content").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_object).filter(move |piece| text(piece, "type") == Some(kind)).filter_map(move |piece| text(piece, key))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> SessionState {
        let snapshot = json!({
            "model": "fable", "busy": true, "stateDirectory": "/private/state", "account": {"name": "secret"},
            "rows": [
                {"id": "R1", "kind": "user", "items": [{"id": "u1", "type": "userMessage", "content": [{"type": "text", "text": "show "}, {"type": "localImage", "path": "/tmp/a.png"}, {"type": "text", "text": "this"}]}]},
                {"id": "R2", "kind": "activity", "items": [{"id": "t1", "type": "commandExecution", "command": "ls", "aggregatedOutput": "a\nb", "exitCode": 0}]},
                {"id": "R3", "kind": "assistant", "items": [{"id": "a1", "type": "agentMessage", "text": "**done**"}]}
            ]
        });
        SessionState::from_snapshot(snapshot.as_object().unwrap())
    }

    #[test]
    fn gives_the_page_rendered_rows_and_only_the_allowed_metadata() {
        let view = full(&state());

        assert_eq!(view["contract"], CONTRACT_VERSION);
        assert_eq!(view["meta"], json!({"model": "fable", "busy": true}));
        assert_eq!(view["rows"][0]["items"][0]["text"], "show this");
        assert_eq!(view["rows"][0]["items"][0]["images"], json!(["/tmp/a.png"]));
        assert_eq!(view["rows"][1]["items"][0]["title"], "ls");
        assert_eq!(view["rows"][1]["items"][0]["output"], "a\nb\nExit: 0");
        assert_eq!(view["rows"][2]["items"][0]["html"], "<p><strong>done</strong></p>\n");
    }

    #[test]
    fn redraws_only_the_row_whose_item_changed() {
        let mut state = state();
        let update = json!({"items": [{"id": "a1", "type": "agentMessage", "text": "done, really"}]});

        let changes = state.apply_patch(update.as_object().unwrap());
        let view = patch(&state, &changes);

        assert_eq!(view, json!({"rows": [{"id": "R3", "kind": "assistant", "items": [{"id": "a1", "type": "agentMessage", "html": "<p>done, really</p>\n"}]}]}));
    }

    #[test]
    fn sends_the_order_when_a_row_arrives() {
        let mut state = state();
        let update = json!({"items": [{"id": "n1", "text": "Stopped."}], "rowUpdates": [{"id": "R4", "kind": "notice", "itemIDs": ["n1"]}], "rowOrder": ["R1", "R2", "R3", "R4"]});

        let changes = state.apply_patch(update.as_object().unwrap());
        let view = patch(&state, &changes);

        assert_eq!(view["order"], json!(["R1", "R2", "R3", "R4"]));
        assert_eq!(view["rows"], json!([{"id": "R4", "kind": "notice", "items": [{"id": "n1", "type": "activity", "text": "Stopped."}]}]));
    }
}
