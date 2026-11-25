//! Turns the fixture agent keeps open (`fixture:hold`, `fixture:approve`): stop and answer end them, and a worker
//! whose last session is closed leaves once no frontend is connected, which a test reads from its exit marker.

use serde_json::{Value, json};
use std::path::Path;
use std::time::Instant;
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, WAIT, prompt};
use vcx_model::SessionState;
use vcx_testkit::{RustWorker, has_exited};

const POLL: std::time::Duration = std::time::Duration::from_millis(20);

fn worker(name: &str) -> RustWorker {
    RustWorker::start(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name)
}

fn target(worker: &RustWorker) -> Target {
    Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() }
}

fn busy(state: &SessionState) -> bool {
    state.meta.get("busy") == Some(&Value::Bool(true))
}

fn permissions(state: &SessionState) -> &[Value] {
    state.meta.get("permissions").and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

#[test]
fn stop_ends_a_turn_the_agent_holds_open() {
    let worker = worker("hold");
    let mut held = Held::open(&target(&worker));
    held.lease.perform(&held.peer.client, "send", prompt("fixture:hold")).unwrap();
    held.follow(busy);

    held.lease.perform(&held.peer.client, "stop", json!({})).unwrap();
    held.follow(|state| !busy(state));

    assert_eq!(held.kinds().first().map(String::as_str), Some("user"));
    assert!(permissions(held.replica.state().unwrap()).is_empty());
}

#[test]
fn an_accepted_approval_lets_the_held_turn_finish() {
    let worker = worker("approve");
    let mut held = Held::open(&target(&worker));
    held.lease.perform(&held.peer.client, "send", prompt("fixture:approve")).unwrap();
    held.follow(|state| !permissions(state).is_empty());
    let asked = permissions(held.replica.state().unwrap())[0].clone();

    let answer = json!({"rpcID": asked["rpcID"], "method": asked["method"], "result": {"decision": "accept"}});
    held.lease.perform(&held.peer.client, "answer", answer).unwrap();
    held.follow(|state| !busy(state) && state.rows.iter().any(|row| row.kind == "assistant"));

    let state = held.replica.state().unwrap();
    assert_eq!(asked["rpcID"], 7301);
    assert!(permissions(state).is_empty(), "the answered approval is gone");
    assert!(serde_json::to_string(&state.items).unwrap().contains("\"approved\""));
}

#[test]
fn the_worker_leaves_once_its_last_session_is_closed() {
    let worker = worker("retire");
    let mut held = Held::open(&target(&worker));
    held.turn("before closing");

    held.lease.perform(&held.peer.client, "close", json!({})).unwrap();
    drop(held);
    let deadline = Instant::now() + WAIT;
    while !has_exited(&worker.directory) {
        assert!(Instant::now() < deadline, "the worker stayed after its last session closed");
        std::thread::sleep(POLL);
    }

    assert!(!worker.socket.exists(), "the socket is removed on the way out");
}
