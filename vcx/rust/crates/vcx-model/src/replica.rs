use crate::state::{Changes, Object, SessionState};
use std::collections::BTreeMap;

/// Updates kept while an attach is in flight, as the Swift client does.
const MAX_EARLY_UPDATES: usize = 256;

#[derive(Debug, PartialEq)]
pub enum Applied {
    Changed(Changes),
    /// Arrived before the snapshot it follows: kept until that snapshot lands.
    Early,
    /// Already covered by the snapshot or an earlier update.
    Stale,
    /// A revision is missing: the frontend must attach again for a fresh snapshot.
    Gap,
}

/// A session kept in step with its worker by revision number, whichever thread the snapshot and the updates arrive on.
#[derive(Debug, Default)]
pub struct Replica {
    state: Option<SessionState>,
    revision: u64,
    early: BTreeMap<u64, Object>,
}

impl Replica {
    pub fn state(&self) -> Option<&SessionState> {
        self.state.as_ref()
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// Takes a snapshot, then the early updates that follow it. Returns false when one of them is missing.
    pub fn snapshot(&mut self, revision: u64, state: &Object) -> bool {
        let mut session = SessionState::from_snapshot(state);
        self.revision = revision;
        let early = std::mem::take(&mut self.early);
        let mut complete = true;
        for (next, patch) in early.into_iter().filter(|(next, _)| *next > revision) {
            if next != self.revision + 1 {
                complete = false;
                break;
            }
            session.apply_patch(&patch);
            self.revision = next;
        }
        self.state = Some(session);
        complete
    }

    pub fn update(&mut self, revision: u64, patch: Object) -> Applied {
        let Some(state) = &mut self.state else {
            if self.early.len() >= MAX_EARLY_UPDATES {
                return Applied::Gap;
            }
            self.early.insert(revision, patch);
            return Applied::Early;
        };
        if revision <= self.revision {
            return Applied::Stale;
        }
        if revision != self.revision + 1 {
            return Applied::Gap;
        }
        self.revision = revision;
        Applied::Changed(state.apply_patch(&patch))
    }

    /// Forgets the session before a new attach, so updates wait for the next snapshot.
    pub fn detach(&mut self) {
        self.state = None;
        self.early.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn object(value: Value) -> Object {
        value.as_object().unwrap().clone()
    }

    fn item_patch(text: &str) -> Object {
        object(json!({"items": [{"id": "i1", "type": "agentMessage", "text": text}]}))
    }

    fn snapshot() -> Object {
        object(json!({"rows": [{"id": "R1", "kind": "assistant", "items": [{"id": "i1", "type": "agentMessage", "text": "a"}]}]}))
    }

    #[test]
    fn applies_the_next_revision() {
        let mut replica = Replica::default();
        replica.snapshot(4, &snapshot());

        let applied = replica.update(5, item_patch("ab"));

        assert!(matches!(applied, Applied::Changed(_)));
        assert_eq!(replica.state().unwrap().items["i1"]["text"], "ab");
        assert_eq!(replica.revision(), 5);
    }

    #[test]
    fn applies_updates_that_overtook_their_snapshot() {
        let mut replica = Replica::default();
        let early = replica.update(5, item_patch("ab"));

        let complete = replica.snapshot(4, &snapshot());

        assert_eq!(early, Applied::Early);
        assert!(complete);
        assert_eq!(replica.state().unwrap().items["i1"]["text"], "ab");
        assert_eq!(replica.revision(), 5);
    }

    #[test]
    fn drops_an_early_update_the_snapshot_already_holds() {
        let mut replica = Replica::default();
        replica.update(4, item_patch("old"));

        let complete = replica.snapshot(4, &snapshot());

        assert!(complete);
        assert_eq!(replica.state().unwrap().items["i1"]["text"], "a");
    }

    #[test]
    fn reports_a_gap_when_a_revision_is_skipped() {
        let mut replica = Replica::default();
        replica.snapshot(4, &snapshot());

        let applied = replica.update(6, item_patch("abc"));

        assert_eq!(applied, Applied::Gap);
        assert_eq!(replica.state().unwrap().items["i1"]["text"], "a");
    }

    #[test]
    fn ignores_a_revision_it_already_has() {
        let mut replica = Replica::default();
        replica.snapshot(4, &snapshot());

        let applied = replica.update(4, item_patch("zz"));

        assert_eq!(applied, Applied::Stale);
    }
}
