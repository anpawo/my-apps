//! Saved conversations, as the Swift `Session` keeps them: a record saved under its folder, resumed by a later worker,
//! held by one window at a time, and archived when the window moves on or closes. Only fixtures run, and native
//! history is on only inside each test worker's own folder: its state, Codex home, locks and archive.

use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, prompt, request_for};
use vcx_model::SessionState;
use vcx_testkit::{RustWorker, session_id};
use vcx_worker::archive::{TEST_FLAG, TEST_VERSIONS};
use vcx_worker::records::{RECORD_OPEN, canonical_archive_root, snapshot};

const IDLE_ONLY: &str = "Stop the current response before changing session settings.";
const ACCOUNT: &str = "codex-fixture";
const ARCHIVE: &str = "conversations.sqlite";
const WAIT: Duration = Duration::from_secs(20);
const POLL: Duration = Duration::from_millis(50);
const CLIENT_VERSION: &str = "codex-cli 0.0.0-fixture";
/// The archive script's `ADAPTER_REVISION`, under which a provider is certified.
const ADAPTER_REVISION: u64 = 1;
const EXECUTABLE: u32 = 0o755;

/// A Codex worker whose one account keeps its home in the worker's folder, with native history turned on there.
fn worker(name: &str) -> RustWorker {
    let agent = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/records_agent.py").canonicalize().unwrap();
    let worker = RustWorker::start_provider(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name, "codex", &["/usr/bin/python3".into(), agent.to_string_lossy().into_owned()], &json!({}));
    let home = worker.directory.join("home/.codex");
    std::fs::create_dir_all(&home).unwrap();
    let accounts = json!({"accounts": [{"id": ACCOUNT, "name": "Fixture", "provider": "codex", "home": home}]});
    std::fs::write(worker.directory.join("config/settings.json"), accounts.to_string()).unwrap();
    std::fs::create_dir_all(worker.directory.join("runtime")).unwrap();
    std::fs::write(worker.directory.join("runtime").join(TEST_FLAG), "").unwrap();
    worker
}

fn target(worker: &RustWorker) -> Target {
    Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() }
}

fn state_folder(worker: &RustWorker) -> PathBuf {
    worker.directory.join("runtime/test-state")
}

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

fn notices(state: &SessionState) -> Vec<String> {
    state.rows.iter().filter(|row| row.kind == "notice").flat_map(|row| &row.items).filter_map(|id| state.items[id]["text"].as_str().map(str::to_owned)).collect()
}

fn command(held: &mut Held, text: &str) {
    held.lease.perform(&held.peer.client, "command", json!({"text": text})).expect("the worker takes the command");
}

fn listed(record: &str) -> impl Fn(&SessionState) -> bool {
    let id = format!("native:{record}");
    move |state| meta(state, "recent").as_array().is_some_and(|recent| recent.iter().any(|entry| entry["id"] == id.as_str()))
}

/// The record's snapshot once `ready` holds, read from where the Swift `save` writes it.
fn saved(worker: &RustWorker, record: &str, ready: impl Fn(&Value) -> bool) -> Value {
    let path = snapshot(&state_folder(worker), worker.directory.to_str().unwrap(), record);
    let deadline = Instant::now() + WAIT;
    loop {
        let read = std::fs::read(&path).ok().and_then(|data| serde_json::from_slice::<Value>(&data).ok());
        if let Some(value) = read.filter(|value| ready(value)) {
            return value;
        }
        assert!(Instant::now() < deadline, "{} was never saved as expected", path.display());
        std::thread::sleep(POLL);
    }
}

fn answered_record(worker: &RustWorker, held: &mut Held, text: &str) -> String {
    held.turn(text);
    let record = meta(held.replica.state().unwrap(), "recordID").as_str().unwrap().to_owned();
    saved(worker, &record, |value| value["rows"].as_array().is_some_and(|rows| rows.len() >= 2));
    record
}

#[test]
fn a_saved_conversation_comes_back_with_its_rows_in_a_worker_started_after_a_kill() {
    let mut worker = worker("records-resume");
    let mut held = Held::open(&target(&worker));
    let record = answered_record(&worker, &mut held, "remember the fixture");
    let snapshot = saved(&worker, &record, |_| true);
    drop(held);

    worker.restart_after_kill();
    let mut held = Held::open(&target(&worker));
    held.follow(listed(&record));
    held.lease.perform(&held.peer.client, "switchThread", json!({"id": format!("native:{record}")})).unwrap();
    // The record id shows before its rows come back, as in Swift: the restore is over once its answer is in.
    held.follow(|state| meta(state, "recordID") == record.as_str() && meta(state, "ready") == &json!(true) && meta(state, "changing") == &json!(false) && state.rows.iter().any(|row| row.kind == "assistant"));

    let root = canonical_archive_root(&worker.directory).unwrap();
    let homes: Vec<&str> = snapshot["nativeSources"].as_array().unwrap().iter().map(|source| source["home"].as_str().unwrap()).collect();
    assert!(!homes.is_empty() && homes.iter().all(|home| Path::new(home).starts_with(&root)), "{homes:?}");
    assert_eq!(snapshot["recentSummary"]["hasRows"], json!(true));
    let state = held.replica.state().unwrap();
    let texts: Vec<String> = state.items.values().filter(|item| item["type"] == "userMessage").flat_map(|item| item["content"].as_array().cloned().unwrap_or_default()).filter_map(|piece| piece["text"].as_str().map(str::to_owned)).collect();
    assert!(texts.iter().any(|text| text == "remember the fixture"), "{texts:?}");
    assert!(state.rows.iter().any(|row| row.kind == "assistant"));
}

#[test]
fn a_second_window_is_refused_the_record_another_holds_and_shows_the_connection_failed() {
    let worker = worker("records-lock");
    let mut first = Held::open(&target(&worker));
    let record = answered_record(&worker, &mut first, "hold the record");

    let mut request = request_for(&target(&worker), &session_id());
    request.resume = Some(format!("native:{record}"));
    let mut second = Held::attach(vcx_conformance::peer::Peer::greeted(&target(&worker)), &request);
    second.follow(|state| meta(state, "status") == "Connection failed");

    assert!(notices(second.replica.state().unwrap()).contains(&RECORD_OPEN.to_owned()));
    assert_eq!(meta(first.replica.state().unwrap(), "recordID"), &json!(record));
}

#[test]
fn a_new_conversation_is_refused_during_a_turn_and_archives_the_old_record_after_it() {
    let worker = worker("records-new");
    let mut held = Held::open(&target(&worker));
    let record = answered_record(&worker, &mut held, "first conversation");
    let path = snapshot(&state_folder(&worker), worker.directory.to_str().unwrap(), &record);

    held.lease.perform(&held.peer.client, "send", prompt("fixture:hold")).unwrap();
    held.follow(|state| meta(state, "busy") == &json!(true));
    command(&mut held, "/new");
    held.follow(|state| notices(state).contains(&IDLE_ONLY.to_owned()));
    let during = meta(held.replica.state().unwrap(), "recordID").clone();
    command(&mut held, "/stop");
    held.follow(|state| meta(state, "busy") == &json!(false));
    command(&mut held, "/new");
    held.follow(|state| meta(state, "recordID") != record.as_str() && meta(state, "ready") == &json!(true) && meta(state, "changing") == &json!(false));
    held.follow(listed(&record));

    assert_eq!(during, json!(record), "the refused /new kept the record");
    assert!(!path.exists(), "the archived record left no snapshot");
    assert!(state_folder(&worker).join(ARCHIVE).is_file());
}

#[test]
fn closing_a_window_archives_its_record_which_the_next_window_lists() {
    let worker = worker("records-close");
    let mut held = Held::open(&target(&worker));
    let record = answered_record(&worker, &mut held, "close me");
    let path = snapshot(&state_folder(&worker), worker.directory.to_str().unwrap(), &record);

    held.lease.perform(&held.peer.client, "close", json!({})).expect("the record is archived and the session closed");
    let mut next = Held::open(&target(&worker));
    next.follow(listed(&record));

    assert!(!path.exists(), "the archived record left no snapshot");
    assert!(state_folder(&worker).join(ARCHIVE).is_file());
}

#[test]
fn a_window_opened_with_a_native_resume_comes_back_on_the_closed_windows_record() {
    let worker = worker("records-reopen");
    let mut held = Held::open(&target(&worker));
    let record = answered_record(&worker, &mut held, "reopen me");
    held.lease.perform(&held.peer.client, "close", json!({})).expect("the record is archived and the session closed");

    let mut request = request_for(&target(&worker), &session_id());
    request.resume = Some(format!("native:{record}"));
    let mut reopened = Held::attach(vcx_conformance::peer::Peer::greeted(&target(&worker)), &request);
    reopened.follow(|state| meta(state, "ready") == &json!(true) && meta(state, "changing") == &json!(false) && state.rows.iter().any(|row| row.kind == "assistant"));

    let state = reopened.replica.state().unwrap();
    let texts: Vec<String> = state.items.values().filter(|item| item["type"] == "userMessage").flat_map(|item| item["content"].as_array().cloned().unwrap_or_default()).filter_map(|piece| piece["text"].as_str().map(str::to_owned)).collect();
    assert_eq!(meta(state, "recordID"), &json!(record));
    assert!(texts.iter().any(|text| text == "reopen me"), "{texts:?}");
}

#[test]
fn fork_says_so_when_codex_returns_no_forked_conversation() {
    let worker = worker("records-fork");
    let mut held = Held::open(&target(&worker));

    command(&mut held, "/fork");
    held.follow(|state| notices(state).contains(&"Codex did not return a forked conversation.".to_owned()));
}

/// Runs one action of the archive script on the test worker's own state folder.
fn archive_action(worker: &RustWorker, mut request: Value) -> Value {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../conversation_archive.py");
    request["state"] = json!(state_folder(worker));
    let mut child = Command::new("/usr/bin/python3").arg(script).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().unwrap();
    std::io::Write::write_all(&mut child.stdin.take().unwrap(), request.to_string().as_bytes()).unwrap();
    let answer: Value = serde_json::from_slice(&child.wait_with_output().unwrap().stdout).unwrap();
    assert_eq!(answer["ok"], json!(true), "{request}");
    answer
}

#[test]
fn an_archived_record_carries_its_providers_client_version_so_the_verified_providers_history_is_pruned() {
    let worker = worker("records-version");
    let versions = worker.directory.join("runtime").join(TEST_VERSIONS);
    std::fs::create_dir_all(&versions).unwrap();
    let fake = versions.join("codex");
    std::fs::write(&fake, format!("#!/bin/sh\necho '  {CLIENT_VERSION}  '\n")).unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(EXECUTABLE)).unwrap();
    let mut held = Held::open(&target(&worker));
    let record = answered_record(&worker, &mut held, "version me");
    let thread = saved(&worker, &record, |_| true)["nativeSources"][0]["threadId"].as_str().unwrap().to_owned();
    let rollout = worker.directory.join("home/.codex/sessions").join(format!("rollout-{thread}.jsonl"));
    archive_action(&worker, json!({"action": "certifyProvider", "provider": "codex", "adapterRevision": ADAPTER_REVISION, "clientVersion": CLIENT_VERSION}));
    let (existed, carried) = (rollout.is_file(), meta(held.replica.state().unwrap(), "archiveClientVersions").clone());

    held.lease.perform(&held.peer.client, "close", json!({})).expect("the record is archived and the session closed");

    let archived = archive_action(&worker, json!({"action": "read", "id": record}));
    let sources = archived["record"]["nativeSources"].as_array().unwrap();
    assert!(existed, "{} was written before the close", rollout.display());
    assert_eq!(carried, json!({"codex": CLIENT_VERSION}));
    assert!(!rollout.exists(), "the verified provider's history was pruned");
    assert!(!sources.is_empty() && sources.iter().all(|source| source["clientVersion"] == CLIENT_VERSION && source["managed"] == json!(true)), "{sources:?}");
}
