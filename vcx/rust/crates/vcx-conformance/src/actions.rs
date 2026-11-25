//! `perform`: sequences, receipts, and the end of a session.

use crate::Target;
use crate::peer::{Held, Peer, fault, prompt, request_for, user_rows};
use serde_json::{Value, json};

pub fn a_sequence_gap_is_refused_and_spends_nothing(target: &Target) {
    let mut held = Held::open(target);

    let gap = held.peer.perform(&held.lease, 2, "send", prompt("too early"));
    let last = held.peer.listed(held.id()).unwrap()["lastSequence"].clone();
    held.turn("in order");

    assert_eq!(fault(gap), "sequenceGap");
    assert_eq!(last, 0);
    assert_eq!(user_rows(held.replica.state().unwrap()), 1);
}

pub fn a_malformed_action_is_refused(target: &Target) {
    let held = Held::open(target);
    let perform = |fields: Value| {
        let mut request = json!({"sessionId": held.lease.session_id, "lease": held.lease.lease});
        request.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
        held.peer.request("perform", request)
    };

    let zero = perform(json!({"sequence": 0, "action": "send", "params": prompt("zero")}));
    let unnamed = perform(json!({"sequence": 1, "action": "", "params": {}}));
    let without_params = perform(json!({"sequence": 1, "action": "send"}));

    assert_eq!([fault(zero), fault(unnamed), fault(without_params)], ["invalidAction", "invalidAction", "invalidAction"]);
    assert_eq!(held.peer.listed(held.id()).unwrap()["lastSequence"], 0, "a refused action spends no sequence");
}

pub fn a_replayed_sequence_returns_its_receipt_without_running_again(target: &Target) {
    let mut held = Held::open(target);
    held.turn("only once");

    let replayed = held.peer.perform(&held.lease, 1, "send", prompt("only once"));
    held.settle();

    assert!(replayed.is_ok(), "{replayed:?}");
    assert_eq!(user_rows(held.replica.state().unwrap()), 1, "the prompt ran once");
    assert_eq!(held.peer.listed(held.id()).unwrap()["lastSequence"], 1);
}

pub fn a_sequence_reused_for_another_action_is_refused(target: &Target) {
    let mut held = Held::open(target);
    held.turn("the first text");

    let reused = held.peer.perform(&held.lease, 1, "send", prompt("another text"));

    assert_eq!(fault(reused), "sequenceConflict");
}

pub fn a_failed_action_spends_its_sequence(target: &Target) {
    let mut held = Held::open(target);

    let failed = held.lease.perform(&held.peer.client, "send", json!({"text": 3}));
    let last = held.peer.listed(held.id()).unwrap()["lastSequence"].clone();
    held.turn("after the failure");

    assert_eq!(fault(failed), "actionFailed");
    assert_eq!((last, held.lease.sequence), (Value::from(1), 2));
    assert_eq!(held.turn_kinds(), ["user", "activity", "assistant"]);
}

pub fn close_ends_the_session_for_good(target: &Target) {
    let mut held = Held::open(target);
    held.turn("before closing");

    let closed = held.lease.perform(&held.peer.client, "close", json!({}));
    let replayed = held.peer.perform(&held.lease, 2, "close", json!({}));
    let later = held.peer.perform(&held.lease, 3, "send", prompt("after closing"));
    let reopened = Peer::greeted(target).client.attach(&request_for(target, held.id()));

    assert!(closed.is_ok(), "{closed:?}");
    assert!(replayed.is_ok(), "the close keeps its receipt: {replayed:?}");
    assert_eq!(fault(later), "closed");
    assert_eq!(fault(reopened), "closed");
}
