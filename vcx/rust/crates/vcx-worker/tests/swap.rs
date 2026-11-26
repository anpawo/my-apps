//! A live update under a streaming agent (`src/swap.rs`): SIGUSR1 makes the worker continue in a new image of
//! itself. The agent must be the same process and nothing it wrote may be lost or doubled; the frontend is told,
//! loses its connection, and finds the session again with its sequence.

use serde_json::{Value, json};
use std::path::Path;
use std::time::Instant;
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, Peer, WAIT, prompt, request_for};
use vcx_model::SessionState;
use vcx_proto::{AttachRequest, Event, Hello};
use vcx_testkit::RustWorker;

/// As `tests/swap_agent.py` streams them.
const NUMBERS: u32 = 150;
const ANSWER: &str = "swap-answer";
/// Deltas shown before the update is asked for: the turn is then well under way, and far from its end.
const UNDER_WAY: &str = " 10 ";
/// The last delta before the line a `hold` prompt keeps unfinished, and the file that lets the agent finish it.
const BEFORE_THE_HELD_LINE: &str = " 19 ";
const RESUMED: &str = "swap-resumed";
const POLL: std::time::Duration = std::time::Duration::from_millis(20);

fn worker(name: &str) -> RustWorker {
    let agent = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/swap_agent.py");
    let command = ["/usr/bin/python3".to_owned(), "-I".to_owned(), agent.to_string_lossy().into_owned()];
    RustWorker::start_provider(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name, "codex", &command, &json!({}))
}

fn target(worker: &RustWorker) -> Target {
    Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() }
}

fn answer(state: &SessionState) -> &str {
    state.items.get(ANSWER).and_then(|item| item.get("text")).and_then(Value::as_str).unwrap_or_default()
}

fn busy(state: &SessionState) -> bool {
    state.meta.get("busy") == Some(&Value::Bool(true))
}

fn whole_answer(agent: &str) -> String {
    (1..=NUMBERS).fold(format!("{agent}:"), |text, number| format!("{text}{number} "))
}

fn hello(target: &Target) -> Option<Hello> {
    Peer::connect(target).client.hello().ok()
}

fn alive(pid: &str) -> bool {
    unsafe { libc::kill(pid.parse().expect("a pid"), 0) == 0 }
}

/// Asks for the update and waits for the worker to serve from its next image.
fn swapped(target: &Target, before: &Hello) -> Hello {
    unsafe { libc::kill(before.pid as libc::pid_t, libc::SIGUSR1) };
    let deadline = Instant::now() + WAIT;
    loop {
        match hello(target).filter(|hello| hello.instance_id != before.instance_id) {
            Some(hello) => return hello,
            None => assert!(Instant::now() < deadline, "the worker never came back in a new image"),
        }
        std::thread::sleep(POLL);
    }
}

/// Applies what the worker still sends on this connection, and tells what ended it.
fn until_disconnected(held: &mut Held) -> Vec<Event> {
    let mut last_words = Vec::new();
    loop {
        match held.peer.events.recv_timeout(WAIT).expect("the worker neither went on nor closed the connection") {
            Event::Update { revision, patch, .. } => drop(held.replica.update(revision, patch)),
            Event::Disconnected => return last_words,
            other => last_words.push(other),
        }
    }
}

#[test]
fn an_update_under_a_streaming_agent_keeps_the_agent_and_every_byte() {
    let worker = worker("swap");
    let target = target(&worker);
    let before = hello(&target).unwrap();
    let mut held = Held::open(&target);
    held.lease.perform(&held.peer.client, "send", prompt("count")).unwrap();
    held.follow(|state| answer(state).contains(UNDER_WAY));
    let agent = answer(held.replica.state().unwrap()).split(':').next().unwrap().to_owned();

    let after = swapped(&target, &before);
    let last_words = until_disconnected(&mut held);
    let seen_before = answer(held.replica.state().unwrap()).to_owned();
    let mut again = Held::attach(Peer::greeted(&target), &AttachRequest { existing_only: true, ..request_for(&target, held.id()) });
    again.follow(|state| !busy(state));

    assert_eq!(last_words, [Event::Swapping], "the frontend is told before its connection ends");
    assert!(seen_before.len() < whole_answer(&agent).len(), "the update came while the agent streamed");
    assert_eq!(after.pid, before.pid, "the worker is the same process");
    assert_eq!(answer(again.replica.state().unwrap()), whole_answer(&agent), "nothing the agent wrote is lost or doubled");
    assert!(alive(&agent), "the agent is the process that started the turn");
    assert_eq!(again.attachment.last_sequence, 1, "the session keeps its sequence");
    again.lease.perform(&again.peer.client, "stop", json!({})).expect("the adopted session takes the next action");
    assert!(!worker.socket.with_extension("sock.swap.json").exists(), "the manifest is removed once adopted");
}

#[test]
fn an_update_keeps_the_line_the_agent_had_not_finished() {
    let worker = worker("line");
    let target = target(&worker);
    let before = hello(&target).unwrap();
    let mut held = Held::open(&target);
    held.lease.perform(&held.peer.client, "send", prompt("hold")).unwrap();
    held.follow(|state| answer(state).contains(BEFORE_THE_HELD_LINE));
    let agent = answer(held.replica.state().unwrap()).split(':').next().unwrap().to_owned();

    swapped(&target, &before);
    std::fs::write(worker.directory.join(RESUMED), "").unwrap();
    let mut again = Held::attach(Peer::greeted(&target), &AttachRequest { existing_only: true, ..request_for(&target, held.id()) });
    again.follow(|state| !busy(state));

    assert_eq!(answer(again.replica.state().unwrap()), whole_answer(&agent), "the half read before the update and the half read after make one line");
    assert_eq!(again.kinds(), ["user", "assistant"], "no notice of a line the worker could not read");
}

#[test]
fn an_adopted_session_runs_its_next_turn_on_the_same_agent() {
    let worker = worker("again");
    let target = target(&worker);
    let before = hello(&target).unwrap();
    let held = Held::open(&target);

    swapped(&target, &before);
    let mut again = Held::attach(Peer::greeted(&target), &AttachRequest { existing_only: true, ..request_for(&target, held.id()) });
    again.lease.perform(&again.peer.client, "send", prompt("count")).unwrap();
    again.follow(|state| !busy(state) && answer(state).ends_with(&format!(" {NUMBERS} ")));

    let text = answer(again.replica.state().unwrap()).to_owned();
    let agent = text.split(':').next().unwrap();
    assert_eq!(text, whole_answer(agent));
    assert_ne!(hello(&target).unwrap().instance_id, before.instance_id, "the worker runs in its new image");
}
