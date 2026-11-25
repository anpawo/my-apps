//! A turn of the fixture agent as a frontend sees it.

use crate::Target;
use crate::peer::{Held, Peer, request_for};
use serde_json::Value;
use vcx_proto::{AttachRequest, Event};

pub fn a_turn_streams_one_revision_at_a_time_to_its_answer(target: &Target) {
    let mut held = Held::open(target);
    let before = held.replica.revision();

    held.turn("hello from the suite");

    let rows = held.turn_rows();
    assert_eq!(held.turn_kinds(), ["user", "activity", "assistant"], "{rows:#?}");
    assert_eq!(rows[0]["items"][0]["text"], "hello from the suite");
    assert_eq!(rows[1]["items"][0]["title"], "echo fixture");
    let answer = rows[2]["items"][0]["html"].as_str().unwrap();
    assert!(answer.contains("<table>") && answer.contains("<strong>bold</strong>"), "{answer}");
    assert!(held.replica.revision() > before, "the turn moved the revision");
    assert_eq!(held.replica.state().unwrap().meta.get("busy"), Some(&Value::Bool(false)));
}

pub fn only_the_lease_holder_receives_updates(target: &Target) {
    let first = Held::open(target);
    let mut second = Held::attach(Peer::greeted(target), &AttachRequest { existing_only: true, ..request_for(target, first.id()) });
    let handover = first.peer.drain();

    second.turn("seen by the second only");
    let late = first.peer.drain();

    assert!(handover.contains(&Event::LeaseLost { session_id: first.id().to_owned() }), "{handover:?}");
    assert!(late.is_empty(), "the first frontend hears nothing of a turn it does not hold: {late:?}");
}
