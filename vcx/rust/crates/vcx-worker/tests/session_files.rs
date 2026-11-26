//! What the agent is told when its thread opens and the files of its session, as the Swift `Session` gives them:
//! Codex gets his Claude instructions, the guidance and VCX's own instructions with the question tool, and every agent
//! its own session's Fleet, progress and task files, which the metadata names. Only fixtures run.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use vcx_conformance::Target;
use vcx_conformance::peer::Held;
use vcx_model::SessionState;
use vcx_testkit::RustWorker;
use vcx_worker::instructions::{AGENT_INSTRUCTIONS, GUIDANCE};

const OPENED: &str = "fixture:opened";

fn fixture() -> Vec<String> {
    let agent = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/fake_agent.py").canonicalize().unwrap();
    vec!["/usr/bin/python3".into(), agent.to_string_lossy().into_owned()]
}

fn codex(name: &str) -> RustWorker {
    RustWorker::start_provider(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name, "codex", &fixture(), &json!({}))
}

fn held(worker: &RustWorker) -> Held {
    Held::open(&Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() })
}

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

/// What the fixture said it was opened with, in answer to `fixture:opened`.
fn opened(held: &mut Held) -> Value {
    held.turn(OPENED);
    let state = held.replica.state().unwrap();
    let row = state.rows.iter().rev().find(|row| row.kind == "assistant").unwrap();
    serde_json::from_str(state.items[&row.items[0]]["text"].as_str().unwrap()).unwrap()
}

fn fleet_file(state: &SessionState) -> PathBuf {
    Path::new(meta(state, "taskFile").as_str().unwrap()).with_file_name("task.context")
}

#[test]
fn codex_opens_its_thread_with_his_claude_rules_vcx_instructions_and_the_question_tool() {
    let worker = codex("instructions");
    std::fs::create_dir_all(worker.directory.join("home/.claude")).unwrap();
    std::fs::write(worker.directory.join("home/.claude/CLAUDE.md"), "Fixture rule.\n").unwrap();
    let mut held = held(&worker);

    let opened = opened(&mut held);

    let instructions = opened["developerInstructions"].as_str().unwrap();
    assert!(instructions.contains("Fixture rule.") && instructions.ends_with(&format!("{GUIDANCE}\n\n{AGENT_INSTRUCTIONS}")), "{instructions}");
    assert_eq!(opened["dynamicTools"], json!(["AskUserQuestion"]));
}

#[test]
fn the_agent_runs_with_its_own_sessions_files_which_the_metadata_names() {
    let worker = codex("session-files");
    let mut held = held(&worker);

    let environment = opened(&mut held)["environment"].clone();

    let state = held.replica.state().unwrap();
    let fleet = fleet_file(state);
    assert_eq!(environment, json!({"FLEET_CONTEXT_FILE": fleet, "VCX_PROGRESS_FILE": meta(state, "progressFile"), "VCX_TASK_FILE": meta(state, "taskFile")}));
    assert_ne!(Some(fleet.to_string_lossy().into_owned()), std::env::var("FLEET_CONTEXT_FILE").ok(), "never the worker's inherited Fleet file");
    assert!(fleet.parent().unwrap().is_dir());
}

#[test]
fn the_fleet_label_shows_until_a_new_conversation_and_its_folder_goes_with_the_session() {
    let worker = codex("fleet-label");
    let mut held = held(&worker);
    let fleet = fleet_file(held.replica.state().unwrap());
    std::fs::write(&fleet, "Build feature\n").unwrap();
    held.turn("a turn publishes the label");
    let labelled = meta(held.replica.state().unwrap(), "fleetContext").clone();

    held.lease.perform(&held.peer.client, "switchThread", json!({})).expect("a new conversation opens");
    held.follow(|state| meta(state, "fleetContext") == "");
    held.lease.perform(&held.peer.client, "close", json!({})).unwrap();

    assert_eq!(labelled, json!("Build feature"));
    assert!(!fleet.exists() && !fleet.parent().unwrap().exists());
}
