//! The worker's bounds a frontend reaches through the fixture agent: a prompt whose `turn/start` the agent leaves
//! unanswered (`fixture:pending`) keeps actions under way, and heavy answers (`fixture:heavy`) grow a conversation
//! past a frame. Not reached: 8 pending controls (the fixture answers a stop at once) and 256 sessions (as many
//! agent processes), which `RuntimeBoundsCheck.swift` covers with a backend made for them.

use crate::Target;
use crate::peer::{Held, Peer, answered, fault, prompt, request_for, user_rows};
use serde_json::{Value, json};
use std::fs;
use vcx_model::SessionState;
use vcx_proto::{AttachRequest, Event};

/// Completed receipts a session keeps: one more and the oldest goes (`RuntimeServer.swift`).
const RECEIPTS_KEPT: usize = 128;
/// Requests one frontend, and actions one session, may have under way at once.
const PENDING: u64 = 64;
/// Three answers of this size make a conversation larger than a frame (32 MiB), each update staying under it.
const HEAVY_MEBIBYTES: usize = 11;
const HEAVY_TURNS: usize = 3;

/// An action that changes nothing and waits its turn behind the actions sent before it.
fn idle_action() -> (&'static str, Value) {
    ("unsend", json!({"id": "none"}))
}

/// A session whose first action stays unanswered until the returned file exists.
fn stalled(target: &Target) -> (Held, std::path::PathBuf) {
    let held = Held::open(target);
    let release = target.directory.join("release");
    held.peer.leave(&held.lease, 1, "send", prompt(&format!("fixture:pending:{}", release.display())));
    (held, release)
}

fn queue(peer: &Peer, held: &Held, sequences: std::ops::RangeInclusive<u64>) {
    for sequence in sequences {
        let (action, params) = idle_action();
        peer.leave(&held.lease, sequence, action, params);
    }
}

fn assistant_rows(state: &SessionState) -> usize {
    state.rows.iter().filter(|row| row.kind == "assistant").count()
}

pub fn a_frontend_with_too_many_requests_under_way_is_told_busy(target: &Target) {
    let (mut held, release) = stalled(target);
    queue(&held.peer, &held, 2..=PENDING);

    let refused = held.peer.request("list", json!({}));
    fs::write(&release, "").unwrap();
    held.follow(answered);
    held.lease.sequence = PENDING;
    let (action, params) = idle_action();
    let next = held.lease.perform(&held.peer.client, action, params);

    assert_eq!(fault(refused), "busy");
    assert!(next.is_ok(), "the requests under way ran and the next sequence follows them: {next:?}");
}

pub fn a_session_with_too_many_actions_under_way_refuses_one_more_as_busy(target: &Target) {
    let (first, release) = stalled(target);
    queue(&first.peer, &first, 2..=PENDING / 2);
    let mut second = Held::attach(Peer::greeted(target), &AttachRequest { existing_only: true, ..request_for(target, first.id()) });
    queue(&second.peer, &second, PENDING / 2 + 1..=PENDING);

    let (action, params) = idle_action();
    let refused = second.peer.perform(&second.lease, PENDING + 1, action, params.clone());
    let listed = second.peer.request("list", json!({}));
    fs::write(&release, "").unwrap();
    second.follow(answered);
    let next = second.peer.perform(&second.lease, PENDING + 1, action, params);

    assert_eq!(fault(refused), "busy");
    assert!(listed.is_ok(), "the frontend itself has room: {listed:?}");
    assert!(next.is_ok(), "the refused action spent no sequence: {next:?}");
}

pub fn a_conversation_larger_than_a_frame_refuses_a_second_frontend_and_keeps_the_first(target: &Target) {
    let mut held = Held::open(target);
    for turn in 1..=HEAVY_TURNS {
        held.lease.perform(&held.peer.client, "send", prompt(&format!("fixture:heavy:{HEAVY_MEBIBYTES}"))).expect("the worker takes the prompt");
        held.follow(|state| answered(state) && assistant_rows(state) == turn);
    }
    let request = AttachRequest { existing_only: true, ..request_for(target, held.id()) };

    let refused = Peer::greeted(target).client.attach(&request);
    let told = held.peer.drain();
    let (action, params) = idle_action();
    let kept = held.lease.perform(&held.peer.client, action, params);

    assert_eq!(fault(refused), "snapshotTooLarge");
    assert!(!told.contains(&Event::LeaseLost { session_id: held.id().to_owned() }), "the first frontend keeps its lease: {told:?}");
    assert!(kept.is_ok(), "and still acts on the session: {kept:?}");
}

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
