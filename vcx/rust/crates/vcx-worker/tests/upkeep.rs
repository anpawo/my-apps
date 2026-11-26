//! What a session does around its turns, as the Swift `Session` does: cleanup.py after each turn and forced on close
//! (a test's own script in the worker's runtime home, never his), the trace of its prompts and agent events in its
//! state folder, and a thread open asked again when Codex's workspace routing timed out. Only fixtures run.

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};
use vcx_conformance::Target;
use vcx_conformance::peer::Held;
use vcx_model::SessionState;
use vcx_testkit::RustWorker;
use vcx_worker::{cleanup, trace};

const PRIVATE: u32 = 0o700;
const WAIT: Duration = Duration::from_secs(15);
const POLL: Duration = Duration::from_millis(20);
/// Stands in for cleanup.py: each run adds its arguments to `cleanup.log` beside it.
const RECORDER: &str = "import json, os, sys\nwith open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cleanup.log'), 'a') as log:\n    log.write(json.dumps(sys.argv[1:]) + '\\n')\n";
const ROUTING_TIMEOUT_FLAG: &str = "routing-timeout";
const ARCHIVED: &str = "import sqlite3, sys\nfor (payload,) in sqlite3.connect(sys.argv[1]).execute('SELECT payload FROM events'):\n    sys.stdout.buffer.write(payload)\n";
const LONG_PROMPT: usize = 5000;

fn codex(name: &str) -> RustWorker {
    let agent = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/fake_agent.py").canonicalize().unwrap();
    RustWorker::start_provider(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name, "codex", &["/usr/bin/python3".into(), agent.to_string_lossy().into_owned()], &json!({}))
}

fn held(worker: &RustWorker) -> Held {
    Held::open(&Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() })
}

/// The worker's runtime folder, made before its session asks for it.
fn runtime(worker: &RustWorker) -> PathBuf {
    let runtime = worker.directory.join(vcx_testkit::RUNTIME);
    fs::DirBuilder::new().recursive(true).mode(PRIVATE).create(&runtime).unwrap();
    runtime
}

fn meta(state: &SessionState, key: &str) -> String {
    state.meta.get(key).and_then(Value::as_str).unwrap_or_default().to_owned()
}

fn eventually<T>(what: &str, read: impl Fn() -> Option<T>) -> T {
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(value) = read() {
            return value;
        }
        assert!(Instant::now() < deadline, "never saw {what}");
        std::thread::sleep(POLL);
    }
}

fn cleanup_runs(runtime: &Path) -> Vec<Value> {
    fs::read_to_string(runtime.join("cleanup.log")).unwrap_or_default().lines().map(|line| serde_json::from_str(line).unwrap()).collect()
}

/// Every trace line in the state folder, wherever the migration has it: the trace files or the database.
fn traced(state: &Path) -> Vec<Value> {
    let mut text = String::new();
    for entry in fs::read_dir(state).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name == trace::TRACE_FILE || name == trace::ROTATED_FILE || name.starts_with(".trace-migration-") {
            text += &fs::read_to_string(entry.path()).unwrap_or_default();
        }
    }
    let database = state.join("conversations.sqlite");
    if database.exists() {
        let output = Command::new("/usr/bin/python3").args(["-I", "-c", ARCHIVED]).arg(&database).output().unwrap();
        text += &String::from_utf8_lossy(&output.stdout);
    }
    text.lines().filter_map(|line| serde_json::from_str(line).ok()).collect()
}

#[test]
fn cleanup_runs_on_the_sessions_folder_after_each_turn_and_forced_on_close() {
    let worker = codex("cleanup");
    let runtime = runtime(&worker);
    fs::write(runtime.join(cleanup::TEST_SCRIPT), RECORDER).unwrap();
    let mut held = held(&worker);
    let cwd = meta(held.replica.state().unwrap(), "cwd");

    held.turn("a turn ends");
    let after_turn = eventually("the cleanup after the turn", || Some(cleanup_runs(&runtime)).filter(|runs| !runs.is_empty()));
    held.lease.perform(&held.peer.client, "close", json!({})).unwrap();
    let all = eventually("the cleanup on close", || Some(cleanup_runs(&runtime)).filter(|runs| runs.len() == 2));

    assert_eq!(after_turn, [json!([cwd])]);
    assert_eq!(all[1], json!([cwd, "--force"]));
}

#[test]
fn the_trace_keeps_each_prompt_clipped_and_the_agents_events_without_their_deltas() {
    let worker = codex("trace");
    let mut held = held(&worker);
    let state = held.replica.state().unwrap();
    let (folder, record, cwd) = (PathBuf::from(meta(state, "stateDirectory")), meta(state, "recordID"), meta(state, "cwd"));

    held.turn(&"a".repeat(LONG_PROMPT));
    held.lease.perform(&held.peer.client, "close", json!({})).unwrap();
    let lines = eventually("the prompt and the turn's end in the trace", || {
        let lines = traced(&folder);
        let done = lines.iter().any(|line| line["type"] == "prompt") && lines.iter().any(|line| line["method"] == "turn/completed");
        done.then_some(lines)
    });

    let prompt = lines.iter().find(|line| line["type"] == "prompt").unwrap();
    assert!(prompt["text"].as_str().unwrap().chars().count() <= trace::LONGEST_STRING + 3, "{prompt}");
    assert_eq!([&prompt["images"], &prompt["record"], &prompt["cwd"], &prompt["retry"]], [&json!(0), &json!(record), &json!(cwd), &json!(false)]);
    assert!(lines.iter().all(|line| !line["method"].as_str().unwrap_or_default().to_lowercase().ends_with("delta")));
}

#[test]
fn a_thread_open_whose_workspace_routing_timed_out_is_asked_again() {
    let worker = codex("routing");
    let flag = runtime(&worker).join(ROUTING_TIMEOUT_FLAG);
    fs::write(&flag, "").unwrap();

    let held = held(&worker);

    assert!(!flag.exists(), "the first open met the routing timeout");
    assert_eq!(meta(held.replica.state().unwrap(), "status"), "Ready");
}
