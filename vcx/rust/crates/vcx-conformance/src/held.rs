//! Turns the fixture agent keeps open (`fixture:hold`, `fixture:approve`), and what ends them: stop, an answer,
//! or nothing at all when the frontend leaves. Then the worker's own end, once its last session is closed.

use crate::Target;
use crate::peer::{Held, Peer, WAIT, prompt, request_for};
use serde_json::{Value, json};
use std::time::{Duration, Instant};
use vcx_model::SessionState;
use vcx_proto::AttachRequest;
use vcx_testkit::has_exited;

const HOLD: &str = "fixture:hold";
const APPROVE: &str = "fixture:approve";
const EXIT_POLL: Duration = Duration::from_millis(20);

fn busy(state: &SessionState) -> bool {
    state.meta.get("busy") == Some(&Value::Bool(true))
}

fn permissions(state: &SessionState) -> &[Value] {
    state.meta.get("permissions").and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

fn finished(state: &SessionState) -> bool {
    !busy(state) && state.rows.iter().any(|row| row.kind == "assistant")
}

/// A session whose agent asked for an approval and waits for it.
fn asked(target: &Target) -> (Held, Value) {
    let mut held = Held::open(target);
    held.lease.perform(&held.peer.client, "send", prompt(APPROVE)).expect("the worker takes the prompt");
    held.follow(|state| !permissions(state).is_empty());
    let request = permissions(held.replica.state().unwrap())[0].clone();
    (held, request)
}

fn answer(held: &mut Held, request: &Value, decision: &str) {
    let params = json!({"rpcID": request["rpcID"], "method": request["method"], "result": {"decision": decision}});
    held.lease.perform(&held.peer.client, "answer", params).expect("the worker takes the answer");
    held.follow(finished);
}

pub fn stop_ends_a_turn_the_agent_holds_open(target: &Target) {
    let mut held = Held::open(target);
    held.lease.perform(&held.peer.client, "send", prompt(HOLD)).unwrap();
    held.follow(busy);

    held.lease.perform(&held.peer.client, "stop", json!({})).unwrap();
    held.follow(|state| !busy(state));

    assert_eq!(held.turn_kinds().first().map(String::as_str), Some("user"));
    assert!(permissions(held.replica.state().unwrap()).is_empty());
}

pub fn an_accepted_approval_lets_the_held_turn_finish(target: &Target) {
    let (mut held, request) = asked(target);

    answer(&mut held, &request, "accept");

    let state = held.replica.state().unwrap();
    assert!(permissions(state).is_empty(), "the answered approval is gone");
    assert!(serde_json::to_string(&state.items).unwrap().contains("\"approved\""));
}

pub fn a_declined_approval_ends_the_turn_without_running_it(target: &Target) {
    let (mut held, request) = asked(target);

    answer(&mut held, &request, "decline");

    let state = held.replica.state().unwrap();
    assert!(permissions(state).is_empty(), "the answered approval is gone");
    assert!(serde_json::to_string(&state.items).unwrap().contains("\"declined\""));
}

pub fn a_turn_stays_open_when_its_frontend_leaves(target: &Target) {
    let mut first = Held::open(target);
    first.lease.perform(&first.peer.client, "send", prompt(HOLD)).unwrap();
    first.follow(busy);
    let id = first.id().to_owned();
    drop(first);

    let mut second = Held::attach(Peer::greeted(target), &AttachRequest { existing_only: true, ..request_for(target, &id) });
    let found_busy = busy(second.replica.state().unwrap());
    second.lease.perform(&second.peer.client, "stop", json!({})).unwrap();
    second.follow(|state| !busy(state));

    assert!(found_busy, "the turn went on with no frontend connected");
    assert_eq!(second.turn_kinds().first().map(String::as_str), Some("user"));
}

/// As `RuntimeServer.swift` does: a worker leaves after its last close only once no frontend is connected.
pub fn the_worker_leaves_once_its_last_session_is_closed(target: &Target) {
    let mut held = Held::open(target);
    held.turn("before closing");

    held.lease.perform(&held.peer.client, "close", json!({})).unwrap();
    drop(held);
    let deadline = Instant::now() + WAIT;
    while !has_exited(&target.directory) {
        assert!(Instant::now() < deadline, "the worker stayed after its last session closed");
        std::thread::sleep(EXIT_POLL);
    }

    assert!(!target.socket.exists(), "the socket is removed on the way out");
}
