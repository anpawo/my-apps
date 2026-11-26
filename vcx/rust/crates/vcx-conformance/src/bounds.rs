//! The worker's bounds a frontend reaches through the fixture agent. The others need a backend made for them, which
//! `RuntimeBoundsCheck.swift` has and this suite has not: 64 pending requests, 8 pending controls and 256 sessions
//! want one that blocks on demand, and a snapshot larger than a frame wants a conversation of 32 MiB (a turn on a
//! 6 MiB prompt did not end within 30 s on the Swift worker).

use crate::Target;
use crate::peer::{Held, fault, prompt, user_rows};
use serde_json::json;

/// Completed receipts a session keeps: one more and the oldest goes (`RuntimeServer.swift`).
const RECEIPTS_KEPT: usize = 128;

pub fn an_expired_receipt_is_refused_and_does_not_run_again(target: &Target) {
    let mut held = Held::open(target);
    held.turn("only once");
    for _ in 0..RECEIPTS_KEPT {
        held.lease.perform(&held.peer.client, "stop", json!({})).expect("stopping an idle session is accepted");
    }

    let expired = held.peer.perform(&held.lease, 1, "send", prompt("only once"));
    held.settle();

    assert_eq!(fault(expired), "alreadyAccepted");
    assert_eq!(user_rows(held.replica.state().unwrap()), 1, "the prompt ran once");
}
