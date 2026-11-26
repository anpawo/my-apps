//! The session as a saved record holds it, in the Swift `save`'s JSON, and its transcript brought back by `restore`.

use super::{Object, Session, new_id, text};
use crate::{fleet, records};
use serde_json::{Value, json};

/// The choices the record keeps for the next window: the provider, account and mode this one chose.
#[derive(Default)]
pub struct Choices {
    pub provider: Option<String>,
    pub account: Option<String>,
    pub mode: Option<String>,
}

impl Session {
    fn saved_rows(&self) -> Vec<Value> {
        self.rows.iter().map(|row| json!({"kind": row.kind, "items": row.items.iter().filter_map(|id| self.items.get(id)).collect::<Vec<_>>()})).collect()
    }

    /// The record the Swift `save` writes.
    pub fn record(&self, choices: Choices) -> Object {
        let rows = self.saved_rows();
        let title = records::title(self.conversation_name.as_deref(), &rows);
        let fleet = fleet::context(&self.fleet_context_file);
        let thread = self.thread_id.clone().unwrap_or_default();
        let summary = json!({"title": records::last_answer(&rows).unwrap_or_else(|| title.clone()), "fleetContext": fleet, "hasRows": !rows.is_empty(), "threadId": thread});
        let value = json!({
            "cwd": self.conversation_directory, "workingDirectory": self.cwd, "title": title, "threadId": thread, "accountId": self.account["id"],
            "rows": rows, "draft": self.draft, "needsAttention": self.needs_attention, "provider": self.provider, "model": self.model,
            "nativeSources": self.native_sources, "injectedContext": self.injected_context, "recentSummary": summary, "planning": self.planning, "fleetContext": fleet,
        });
        let Value::Object(mut record) = value else { unreachable!("a JSON object literal") };
        let optional = [("effort", self.effort.clone()), ("nativeHistoryPath", self.native_history_path.clone()), ("conversationName", self.conversation_name.clone()), ("providerChoice", choices.provider), ("accountChoice", choices.account), ("modeChoice", choices.mode)];
        for (key, value) in optional {
            if let Some(value) = value {
                record.insert(key.into(), json!(value));
            }
        }
        record
    }

    /// The Swift `restore`'s transcript: the record's rows replace the session's.
    pub fn load_rows(&mut self, rows: &[Value]) {
        self.flush();
        self.rows.clear();
        self.items.clear();
        self.seen.clear();
        self.group = None;
        for row in rows {
            let mut ids = Vec::new();
            for item in row["items"].as_array().into_iter().flatten().filter_map(Value::as_object) {
                let mut item = item.clone();
                let id = text(&item, "id").map_or_else(new_id, str::to_owned);
                item.insert("id".into(), json!(id));
                if text(&item, "type") == Some("userMessage") {
                    self.seen.insert(id.clone());
                }
                self.set_item(&id, item);
                ids.push(id);
            }
            self.insert_row(self.rows.len(), row["kind"].as_str().unwrap_or("notice"), ids);
        }
        self.order_dirty = true;
    }

    /// What, once changed, makes the record worth saving again: a turn ending, a row, the thread, a setting.
    pub fn save_signature(&self) -> String {
        let last = self.rows.last().map_or(0, |row| row.items.len());
        format!(
            "{:?}",
            (
                (&self.record_id, &self.thread_id, self.busy, self.rows.len(), last, self.items.len(), self.needs_attention, &self.conversation_name),
                (self.planning, &self.effort, &self.model, &self.cwd, &self.conversation_directory, &self.account["id"], self.draft_generation, self.native_sources.len())
            )
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_record_carries_its_rows_and_summary_and_its_rows_come_back_on_restore() {
        let mut session = Session::new("/work", "/state");
        session.thread_id = Some("T".into());
        let rows = [json!({"kind": "user", "items": [{"id": "U", "type": "userMessage", "content": [{"type": "text", "text": "fix it"}]}]}), json!({"kind": "assistant", "items": [{"id": "A", "type": "agentMessage", "text": "⟶ Fixed."}]})];
        session.load_rows(&rows);

        let record = session.record(Choices { provider: Some("codex".into()), ..Choices::default() });
        let mut restored = Session::new("/work", "/state");
        restored.load_rows(record["rows"].as_array().unwrap());

        assert_eq!((record["title"].clone(), record["recentSummary"]["title"].clone()), (json!("fix it"), json!("Fixed.")));
        assert_eq!((record["threadId"].clone(), record["providerChoice"].clone(), record.get("accountChoice")), (json!("T"), json!("codex"), None));
        assert_eq!(restored.rows().iter().map(|row| row.kind.as_str()).collect::<Vec<_>>(), ["user", "assistant"]);
        assert_eq!(restored.item("A").and_then(|item| item.get("text")), Some(&json!("⟶ Fixed.")));
    }
}
