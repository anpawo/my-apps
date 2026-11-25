use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashMap, HashSet};

pub type Object = Map<String, Value>;

/// Snapshot keys that are not metadata.
const STATE_KEYS: [&str; 4] = ["rows", "draft", "draftGeneration", "windowState"];

#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    pub id: String,
    pub kind: String,
    pub items: Vec<String>,
}

/// One conversation, mirrored from its worker. Items stay the provider-shaped JSON the worker sends.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SessionState {
    pub meta: Object,
    pub rows: Vec<Row>,
    pub items: HashMap<String, Object>,
    pub draft: Vec<Value>,
    pub draft_generation: i64,
    pub window_state: Value,
}

/// What a patch touched, so the page redraws only that.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Changes {
    pub meta: bool,
    pub order: bool,
    pub rows: Vec<String>,
    pub items: Vec<String>,
    pub draft: bool,
}

impl Changes {
    pub fn is_empty(&self) -> bool {
        !self.meta && !self.order && !self.draft && self.rows.is_empty() && self.items.is_empty()
    }
}

impl SessionState {
    pub fn from_snapshot(state: &Object) -> Self {
        let mut session = Self::default();
        for piece in objects(state.get("rows")) {
            let (Some(id), Some(kind)) = (text(piece, "id"), text(piece, "kind")) else { continue };
            let mut ids = Vec::new();
            for item in objects(piece.get("items")) {
                let Some(item_id) = text(item, "id") else { continue };
                session.items.insert(item_id.clone(), item.clone());
                ids.push(item_id);
            }
            session.rows.push(Row { id, kind, items: ids });
        }
        session.meta = state.iter().filter(|(key, _)| !STATE_KEYS.contains(&key.as_str())).map(|(key, value)| (key.clone(), value.clone())).collect();
        session.apply_draft(state);
        session.window_state = state.get("windowState").cloned().unwrap_or(Value::Null);
        session
    }

    pub fn apply_patch(&mut self, patch: &Object) -> Changes {
        let mut changes = Changes::default();
        if let Some(Value::Object(meta)) = patch.get("meta") {
            self.meta.extend(meta.iter().map(|(key, value)| (key.clone(), value.clone())));
            changes.meta = true;
        }
        for item in objects(patch.get("items")) {
            let Some(id) = text(item, "id") else { continue };
            self.items.insert(id.clone(), item.clone());
            changes.items.push(id);
        }
        if patch.contains_key("rowUpdates") || patch.contains_key("rowOrder") {
            self.apply_rows(patch, &mut changes);
        }
        changes.draft = self.apply_draft(patch);
        changes
    }

    fn apply_rows(&mut self, patch: &Object, changes: &mut Changes) {
        // A row the patch updates but no order names stays out of the transcript, as in the Swift frontend.
        let mut mapped: BTreeMap<String, Row> = BTreeMap::new();
        for piece in objects(patch.get("rowUpdates")) {
            let (Some(id), Some(kind)) = (text(piece, "id"), text(piece, "kind")) else { continue };
            let items = strings(piece.get("itemIDs")).filter(|item| self.items.contains_key(item)).collect();
            changes.rows.push(id.clone());
            mapped.insert(id.clone(), Row { id, kind, items });
        }
        match patch.get("rowOrder") {
            Some(Value::Array(_)) => {
                let mut current: HashMap<String, Row> = self.rows.drain(..).map(|row| (row.id.clone(), row)).collect();
                current.extend(mapped);
                self.rows = strings(patch.get("rowOrder")).filter_map(|id| current.remove(&id)).collect();
                let retained: HashSet<&String> = self.rows.iter().flat_map(|row| &row.items).collect();
                self.items.retain(|id, _| retained.contains(id));
                changes.order = true;
            }
            _ => {
                for row in &mut self.rows {
                    if let Some(update) = mapped.remove(&row.id) {
                        row.items = update.items;
                    }
                }
            }
        }
    }

    fn apply_draft(&mut self, value: &Object) -> bool {
        let Some(Value::Array(draft)) = value.get("draft") else { return false };
        self.draft = draft.clone();
        if let Some(generation) = value.get("draftGeneration").and_then(Value::as_i64) {
            self.draft_generation = generation;
        }
        true
    }

    pub fn row(&self, id: &str) -> Option<&Row> {
        self.rows.iter().find(|row| row.id == id)
    }
}

fn objects(value: Option<&Value>) -> impl Iterator<Item = &Object> {
    value.and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_object)
}

fn strings(value: Option<&Value>) -> impl Iterator<Item = String> + '_ {
    value.and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_owned)
}

fn text(object: &Object, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn object(value: Value) -> Object {
        value.as_object().unwrap().clone()
    }

    fn snapshot() -> Object {
        object(json!({
            "model": "claude", "busy": false,
            "rows": [
                {"id": "R1", "kind": "user", "items": [{"id": "i1", "type": "userMessage", "text": "hello"}]},
                {"id": "R2", "kind": "assistant", "items": [{"id": "i2", "type": "agentMessage", "text": "hi"}]}
            ],
            "draft": [{"type": "text", "text": "next"}], "draftGeneration": 3, "windowState": {"width": 900}
        }))
    }

    #[test]
    fn reads_rows_items_metadata_and_draft_from_a_snapshot() {
        let state = SessionState::from_snapshot(&snapshot());

        assert_eq!(state.rows, vec![
            Row { id: "R1".into(), kind: "user".into(), items: vec!["i1".into()] },
            Row { id: "R2".into(), kind: "assistant".into(), items: vec!["i2".into()] },
        ]);
        assert_eq!(state.items["i2"]["text"], "hi");
        assert_eq!(state.meta, object(json!({"model": "claude", "busy": false})));
        assert_eq!(state.draft, vec![json!({"type": "text", "text": "next"})]);
        assert_eq!(state.draft_generation, 3);
        assert_eq!(state.window_state, json!({"width": 900}));
    }

    #[test]
    fn replaces_a_streaming_item_without_touching_the_rows() {
        let mut state = SessionState::from_snapshot(&snapshot());
        let rows = state.rows.clone();

        let changes = state.apply_patch(&object(json!({"items": [{"id": "i2", "type": "agentMessage", "text": "hi there"}]})));

        assert_eq!(state.items["i2"]["text"], "hi there");
        assert_eq!(state.rows, rows);
        assert_eq!(changes, Changes { items: vec!["i2".into()], ..Changes::default() });
    }

    #[test]
    fn appends_a_row_when_the_patch_brings_its_item_update_and_order() {
        let mut state = SessionState::from_snapshot(&snapshot());

        let changes = state.apply_patch(&object(json!({
            "items": [{"id": "i3", "type": "commandExecution", "command": "ls"}],
            "rowUpdates": [{"id": "R3", "kind": "activity", "itemIDs": ["i3"]}],
            "rowOrder": ["R1", "R2", "R3"]
        })));

        assert_eq!(state.rows[2], Row { id: "R3".into(), kind: "activity".into(), items: vec!["i3".into()] });
        assert!(changes.order);
        assert_eq!(changes.rows, vec!["R3".to_string()]);
    }

    #[test]
    fn drops_the_items_of_a_row_the_new_order_leaves_out() {
        let mut state = SessionState::from_snapshot(&snapshot());

        state.apply_patch(&object(json!({"rowOrder": ["R2"]})));

        assert_eq!(state.rows.len(), 1);
        assert!(!state.items.contains_key("i1"));
        assert!(state.items.contains_key("i2"));
    }

    #[test]
    fn keeps_a_new_row_out_of_the_transcript_until_an_order_names_it() {
        let mut state = SessionState::from_snapshot(&snapshot());

        state.apply_patch(&object(json!({"rowUpdates": [{"id": "R9", "kind": "notice", "itemIDs": []}]})));

        assert_eq!(state.rows.len(), 2);
        assert!(state.row("R9").is_none());
    }

    #[test]
    fn ignores_item_ids_the_worker_never_sent() {
        let mut state = SessionState::from_snapshot(&snapshot());

        state.apply_patch(&object(json!({"rowUpdates": [{"id": "R2", "kind": "assistant", "itemIDs": ["i2", "ghost"]}]})));

        assert_eq!(state.row("R2").unwrap().items, vec!["i2".to_string()]);
    }

    #[test]
    fn merges_metadata_and_reports_a_draft_change() {
        let mut state = SessionState::from_snapshot(&snapshot());

        let changes = state.apply_patch(&object(json!({"meta": {"busy": true}, "draft": [], "draftGeneration": 4})));

        assert_eq!(state.meta["busy"], true);
        assert_eq!(state.meta["model"], "claude");
        assert!(state.draft.is_empty());
        assert_eq!(state.draft_generation, 4);
        assert!(changes.meta && changes.draft);
    }
}
