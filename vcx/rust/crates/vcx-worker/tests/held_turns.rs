//! Turns the fixture agent keeps open (`fixture:hold`, `fixture:approve`): stop and answer end them, and a worker
//! whose last session is closed leaves once no frontend is connected, which a test reads from its exit marker.
//! A turn/start the agent leaves unanswered (`fixture:pending`) keeps the session busy, and a heavy answer
//! (`fixture:heavy`) arrives whole.

use serde_json::{Value, json};
use std::fs;
use std::path::Path;
use std::sync::mpsc::Receiver;
use std::time::Instant;
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, WAIT, answered, prompt};
use vcx_model::{Applied, Replica, SessionState};
use vcx_proto::Event;
use vcx_testkit::{RustWorker, has_exited};

const POLL: std::time::Duration = std::time::Duration::from_millis(20);
const MEBIBYTE: usize = 1024 * 1024;

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

/// `Held::follow` on the replica and events alone, so another thread can wait on a send over the same connection.
fn follow(replica: &mut Replica, events: &Receiver<Event>, reached: impl Fn(&SessionState) -> bool) {
    let deadline = Instant::now() + WAIT;
    while !reached(replica.state().expect("a snapshot")) {
        let event = events.recv_timeout(deadline.saturating_duration_since(Instant::now())).expect("the session never reached the wanted state");
        let Event::Update { revision, patch, .. } = event else { panic!("unexpected event: {event:?}") };
        assert!(matches!(replica.update(revision, patch), Applied::Changed(_)), "revision {revision} did not follow {}", replica.revision());
    }
}

fn has_assistant_row(state: &SessionState) -> bool {
    state.rows.iter().any(|row| row.kind == "assistant")
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

#[test]
fn a_turn_start_left_unanswered_keeps_the_session_busy_until_the_agent_answers() {
    let worker = worker("pending");
    let release = worker.directory.join("release");
    let text = format!("fixture:pending:{}", release.display());
    let mut held = Held::open(&target(&worker));
    let Held { peer, lease, replica, .. } = &mut held;

    let (waiting, sent) = std::thread::scope(|scope| {
        let sending = scope.spawn(|| lease.perform(&peer.client, "send", prompt(&text)));
        follow(replica, &peer.events, busy);
        for event in peer.drain() {
            if let Event::Update { revision, patch, .. } = event {
                replica.update(revision, patch);
            }
        }
        let state = replica.state().unwrap();
        let waiting = !sending.is_finished() && busy(state) && !has_assistant_row(state);
        fs::write(&release, "").unwrap();
        (waiting, sending.join().unwrap())
    });
    held.follow(answered);

    assert!(waiting, "the session stays busy without an answer while turn/start is unanswered");
    assert!(sent.is_ok(), "the send completes once the agent answers turn/start: {sent:?}");
    assert!(has_assistant_row(held.replica.state().unwrap()));
}

#[test]
fn a_heavy_prompt_is_answered_with_a_message_that_many_mebibytes_long() {
    let worker = worker("heavy");
    let mut held = Held::open(&target(&worker));

    held.turn("fixture:heavy:1");

    let state = held.replica.state().unwrap();
    let answers: Vec<usize> = state.items.values().filter(|item| item.get("type") == Some(&json!("agentMessage"))).filter_map(|item| item.get("text").and_then(Value::as_str)).map(str::len).collect();
    assert_eq!(answers, [MEBIBYTE]);
}
