//! A worker killed with SIGKILL loses nothing a frontend can see: the next one reopens the session from the agent's
//! own history and the checkpoint, without replaying what ran.

use serde_json::{Value, json};
use std::path::Path;
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, Peer, prompt, request_for};
use vcx_testkit::RustWorker;

fn target(worker: &RustWorker) -> Target {
    Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() }
}

fn texts(held: &Held) -> Vec<String> {
    let state = held.replica.state().unwrap();
    state.rows.iter().flat_map(|row| &row.items).filter_map(|id| state.items.get(id)).filter_map(|item| item.get("text").and_then(Value::as_str).map(str::to_owned)).collect()
}

#[test]
fn reopens_a_killed_session_cold_with_its_history_and_unsent_draft() {
    let mut worker = RustWorker::start_with_history(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), "cold");
    let mut first = Held::open(&target(&worker));
    first.turn("before the crash");
    let draft = json!([{"type": "text", "text": "half typed"}]);
    first.lease.perform(&first.peer.client, "checkpoint", json!({"draft": draft, "generation": 7, "windowState": {"width": 900}})).unwrap();
    let id = first.id().to_owned();
    drop(first);

    worker.restart_after_kill();
    let mut second = Held::attach(Peer::greeted(&target(&worker)), &request_for(&target(&worker), &id));
    second.follow(|state| state.meta.get("ready") == Some(&Value::Bool(true)) && state.rows.iter().any(|row| row.kind == "notice"));

    let state = second.replica.state().unwrap();
    assert_eq!(second.kinds(), ["user", "activity", "assistant", "notice"]);
    assert_eq!(state.items[&state.rows[0].items[0]]["content"][0]["text"], "before the crash", "the prompt comes back from the agent's history");
    assert_eq!((state.draft.clone(), state.draft_generation), (vec![draft[0].clone()], 7));
    assert_eq!(state.meta["busy"], false, "nothing is replayed");
    assert!(texts(&second).iter().any(|text| text.starts_with("Recovered saved conversation")));
    assert_eq!(second.attachment.state["windowState"], json!({"width": 900}));
}

#[test]
fn a_reopened_session_takes_the_next_prompt_in_the_same_thread() {
    let mut worker = RustWorker::start_with_history(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), "next");
    let mut first = Held::open(&target(&worker));
    first.turn("first");
    let (id, thread) = (first.id().to_owned(), first.replica.state().unwrap().meta["threadID"].clone());
    drop(first);

    worker.restart_after_kill();
    let mut second = Held::attach(Peer::greeted(&target(&worker)), &request_for(&target(&worker), &id));
    second.follow(|state| state.meta.get("ready") == Some(&Value::Bool(true)));
    second.lease.perform(&second.peer.client, "send", prompt("second")).unwrap();
    let count = |state: &vcx_model::SessionState, kind: &str| state.rows.iter().filter(|row| row.kind == kind).count();
    second.follow(|state| count(state, "assistant") == 2 && state.meta.get("busy") == Some(&Value::Bool(false)));

    let state = second.replica.state().unwrap();
    assert_eq!(state.meta["threadID"], thread);
    assert_eq!(count(state, "user"), 2, "the echoed prompt is shown once: {:?}", second.kinds());
}
