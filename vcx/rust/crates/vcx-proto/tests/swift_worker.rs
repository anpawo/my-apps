//! Conformance against the Swift worker: the Rust client attaches to a real `VCX --runtime-worker` whose agent is the
//! fixture, sends a prompt and follows the turn to its end. Skipped when no Swift VCX binary is found.

use serde_json::{Value, json};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use vcx_model::{Applied, Replica, SessionState, view};
use vcx_proto::{AttachRequest, Client, Event, Lease};
use vcx_testkit::{SwiftWorker, session_id};

const TURN_WAIT: Duration = Duration::from_secs(30);

#[test]
fn follows_a_turn_of_a_swift_worker_from_prompt_to_answer() {
    let Some(worker) = SwiftWorker::start("turn") else {
        eprintln!("skipped: no Swift VCX binary (set VCX_SWIFT_BINARY)");
        return;
    };
    let (sender, events) = mpsc::channel();
    let client = Client::connect(&worker.socket, move |event| drop(sender.send(event))).unwrap();
    let request = AttachRequest { session_id: session_id(), cwd: worker.directory.to_str().unwrap().to_owned(), ..AttachRequest::default() };
    let mut replica = Replica::default();

    let hello = client.hello().unwrap();
    let attachment = client.attach(&request).unwrap();
    let mut lease = Lease::of(&attachment);
    assert!(replica.snapshot(attachment.revision, &attachment.state));
    follow(&events, &mut replica, |state| state.meta.get("ready") == Some(&Value::Bool(true)));
    lease.perform(&client, "send", json!({"text": "hello from rust", "images": []})).unwrap();
    follow(&events, &mut replica, |state| state.meta.get("busy") == Some(&Value::Bool(false)) && state.rows.iter().any(|row| row.kind == "assistant"));
    let page = view::full(replica.state().unwrap());

    assert_eq!(hello.pid, worker.pid());
    assert_eq!(attachment.session_id, request.session_id);
    let kinds: Vec<&str> = page["rows"].as_array().unwrap().iter().map(|row| row["kind"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["user", "activity", "assistant"], "{page:#}");
    assert_eq!(page["rows"][0]["items"][0]["text"], "hello from rust");
    assert_eq!(page["rows"][1]["items"][0]["title"], "echo fixture");
    let answer = page["rows"][2]["items"][0]["html"].as_str().unwrap();
    assert!(answer.contains("<table>") && answer.contains("<strong>bold</strong>"), "{answer}");
    assert_eq!(lease.sequence, attachment.last_sequence + 1);
}

/// Applies the worker's updates in order until the session reaches the wanted state.
fn follow(events: &mpsc::Receiver<Event>, replica: &mut Replica, reached: impl Fn(&SessionState) -> bool) {
    let deadline = Instant::now() + TURN_WAIT;
    while !reached(replica.state().unwrap()) {
        let event = events.recv_timeout(deadline.saturating_duration_since(Instant::now())).expect("the session never reached the wanted state");
        let Event::Update { revision, patch, .. } = event else { panic!("unexpected event: {event:?}") };
        assert!(matches!(replica.update(revision, patch), Applied::Changed(_)), "revision {revision} did not follow {}", replica.revision());
    }
}
