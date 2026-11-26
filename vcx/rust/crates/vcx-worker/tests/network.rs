//! What the worker does when the network goes and comes back, as the Swift `Connectivity` and `Session` do: a turn
//! the network killed continues, an agent that stopped or could not start reconnects, and a step stuck on a retry sent
//! while offline restarts. The test worker's network is down while `runtime/offline` exists; only fixtures run.

use serde_json::{Value, json};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, Peer, answered, prompt, request_for, user_rows};
use vcx_model::SessionState;
use vcx_testkit::RustWorker;

/// The worker's runtime folder, made before its session asks for it.
const PRIVATE: u32 = 0o700;
/// Several of the test worker's 100 ms network probes.
const PROBES: Duration = Duration::from_millis(500);
const DROPPED_KEEP_GOING: &str = "Keep going: the connection dropped.";
/// Starts the fake agent unless the fail flag exists, counting each start in the attempts file.
const FAILS_WHILE_FLAGGED: &str = "echo started >> \"$1\"; test -e \"$2\" && exit 1; shift 2; exec \"$@\"";

fn agent() -> String {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/fake_agent.py").canonicalize().unwrap().to_string_lossy().into_owned()
}

fn codex(name: &str, command: &[String]) -> RustWorker {
    RustWorker::start_provider(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name, "codex", command, &json!({}))
}

fn offline(worker: &RustWorker) -> PathBuf {
    let runtime = worker.directory.join(vcx_testkit::RUNTIME);
    std::fs::DirBuilder::new().recursive(true).mode(PRIVATE).create(&runtime).unwrap();
    let flag = runtime.join(vcx_worker::TEST_OFFLINE_FLAG);
    std::fs::write(&flag, "").unwrap();
    flag
}

fn target(worker: &RustWorker) -> Target {
    Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() }
}

fn open(worker: &RustWorker) -> Held {
    Held::open(&target(worker))
}

/// A new session, not waited on: its agent may never be ready.
fn attach(worker: &RustWorker) -> Held {
    let target = target(worker);
    Held::attach(Peer::greeted(&target), &request_for(&target, &vcx_testkit::session_id()))
}

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

fn texts(state: &SessionState, kind: &str) -> Vec<String> {
    let text = |item: &serde_json::Map<String, Value>| item.get("text").and_then(Value::as_str).or_else(|| item.get("content")?[0]["text"].as_str()).map(str::to_owned);
    state.rows.iter().filter(|row| row.kind == kind).flat_map(|row| &row.items).filter_map(|id| text(&state.items[id])).collect()
}

fn noticed(text: &str) -> impl Fn(&SessionState) -> bool {
    move |state| texts(state, "notice").iter().any(|notice| notice.contains(text))
}

fn send(held: &mut Held, text: &str) {
    held.lease.perform(&held.peer.client, "send", prompt(text)).expect("the worker takes the message");
}

/// The fake agent behind a wrapper that fails to start while `fail` exists; `attempts` gets a line per start.
fn failing_agent(scratch: &Path) -> (Vec<String>, PathBuf, PathBuf) {
    std::fs::create_dir_all(scratch).unwrap();
    let (attempts, fail) = (scratch.join("attempts"), scratch.join("fail"));
    let command = ["/bin/sh", "-c", FAILS_WHILE_FLAGGED, "sh"].into_iter().map(str::to_owned);
    let paths = [&attempts, &fail].map(|path| path.to_string_lossy().into_owned());
    (command.chain(paths).chain(["/usr/bin/python3".to_owned(), agent()]).collect(), attempts, fail)
}

fn starts(attempts: &Path) -> usize {
    std::fs::read_to_string(attempts).unwrap_or_default().lines().count()
}

fn scratch(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("vcx-network-{name}-{}", vcx_testkit::session_id()))
}

#[test]
fn a_turn_the_network_killed_continues_once_the_network_is_back() {
    let worker = codex("network-dropped", &["/usr/bin/python3".to_owned(), agent()]);
    let mut held = open(&worker);
    held.follow(|state| meta(state, "ready") == &json!(true));
    let flag = offline(&worker);

    send(&mut held, "fixture:dropped");
    held.follow(noticed("stream disconnected"));
    std::thread::sleep(PROBES);
    let waited = user_rows(held.replica.state().unwrap());
    std::fs::remove_file(&flag).unwrap();
    held.follow(|state| user_rows(state) == 2 && answered(state));

    assert_eq!(waited, 1, "nothing is sent while the network is down");
    assert!(texts(held.replica.state().unwrap(), "user")[1].starts_with(DROPPED_KEEP_GOING));
}

#[test]
fn a_crashed_agent_waits_for_the_network_then_reconnects_on_its_conversation() {
    let worker = codex("network-crash", &["/usr/bin/python3".to_owned(), agent()]);
    let mut held = open(&worker);
    held.follow(|state| meta(state, "ready") == &json!(true));
    let flag = offline(&worker);

    send(&mut held, "fixture:crash");
    held.follow(noticed("Codex stopped (exited with status 3). The network is down, so VCX restarts it once the network is back. Last error: fatal: fixture crashed"));
    std::thread::sleep(PROBES);
    let waited = meta(held.replica.state().unwrap(), "ready") == &json!(false);
    std::fs::remove_file(&flag).unwrap();
    held.follow(noticed("Reconnected to Codex: network back after a dropped connection. Context kept."));

    assert!(waited, "the agent is not restarted while the network is down");
    held.follow(|state| meta(state, "ready") == &json!(true));
}

#[test]
fn a_session_whose_agent_could_not_start_offline_connects_once_the_network_is_back() {
    let scratch = scratch("failed");
    let (command, attempts, fail) = failing_agent(&scratch);
    std::fs::write(&fail, "").unwrap();
    let worker = codex("network-failed", &command);
    let flag = offline(&worker);

    let mut held = attach(&worker);
    held.follow(|state| starts(&attempts) == 1 && !texts(state, "notice").is_empty());
    std::fs::remove_file(&fail).unwrap();
    std::thread::sleep(PROBES);
    let waited = (starts(&attempts), meta(held.replica.state().unwrap(), "ready").clone());
    std::fs::remove_file(&flag).unwrap();
    held.follow(|state| meta(state, "ready") == &json!(true));

    assert_eq!(waited, (1, json!(false)), "nothing is retried while the network is down");
    assert!(noticed("Reconnected to Codex: network back after a failed connection.")(held.replica.state().unwrap()));
    assert_eq!(starts(&attempts), 2);
    let _ = std::fs::remove_dir_all(scratch);
}

#[test]
fn a_connection_that_fails_while_the_internet_answers_is_not_retried_in_a_loop() {
    let scratch = scratch("online");
    let (command, attempts, fail) = failing_agent(&scratch);
    std::fs::write(&fail, "").unwrap();
    let worker = codex("network-online", &command);

    let mut held = attach(&worker);
    held.follow(|state| !texts(state, "notice").is_empty());
    std::thread::sleep(PROBES);

    assert_eq!(starts(&attempts), 1);
    assert_eq!(meta(held.replica.state().unwrap(), "ready"), &json!(false));
    let _ = std::fs::remove_dir_all(scratch);
}

#[test]
fn a_step_waiting_on_a_retry_sent_while_offline_restarts_once_the_network_is_back() {
    let worker = codex("network-retry", &["/usr/bin/python3".to_owned(), agent()]);
    let mut held = open(&worker);
    held.follow(|state| meta(state, "ready") == &json!(true));
    let flag = offline(&worker);

    send(&mut held, "fixture:apiretry");
    held.follow(|state| meta(state, "busy") == &json!(true));
    std::thread::sleep(PROBES);
    std::fs::remove_file(&flag).unwrap();
    held.follow(|state| user_rows(state) == 2 && answered(state));

    let state = held.replica.state().unwrap();
    assert!(noticed("The network is back but Codex was still waiting on a request sent while it was down, so VCX restarts the step.")(state));
    assert!(!noticed("Work interrupted")(state), "{:?}", texts(state, "notice"));
    assert!(texts(state, "user")[1].starts_with(DROPPED_KEEP_GOING));
}
