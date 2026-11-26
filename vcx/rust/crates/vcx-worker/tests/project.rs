//! The session follows its project as the Swift `Session` does: a `cd` during the first prompt, the project a turn
//! edited files in, the folder a frontend moves it to, and the project the first prompt of a window at `~` or `/` is
//! about. The fixture agent stands in for every agent and, with `--route`, for Haiku.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, Peer, answered, prompt, request_for, user_rows};
use vcx_model::SessionState;
use vcx_proto::AttachRequest;
use vcx_testkit::RustWorker;

const CD_THERE: &str = ": cd there before working on it.";

fn target(worker: &RustWorker) -> Target {
    Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() }
}

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

fn text(path: &Path) -> &str {
    path.to_str().unwrap()
}

fn start(name: &str) -> RustWorker {
    RustWorker::start(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name)
}

/// A worker whose home is its own `home` folder, so `~` and `~/self` are the test's.
fn with_home(name: &str) -> RustWorker {
    let agent = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/fake_agent.py").canonicalize().unwrap();
    let command = vec!["/usr/bin/python3".to_owned(), agent.to_string_lossy().into_owned()];
    RustWorker::start_provider(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name, "codex", &command, &json!({}))
}

fn open_in(worker: &RustWorker, cwd: &Path) -> Held {
    let target = target(worker);
    let request = AttachRequest { cwd: text(cwd).to_owned(), ..request_for(&target, &vcx_testkit::session_id()) };
    let mut held = Held::attach(Peer::greeted(&target), &request);
    held.follow(|state| meta(state, "ready") == &json!(true));
    held
}

/// Sends the prompt and follows the session until its `prompts`-th turn is answered.
fn turn(held: &mut Held, text: &str, prompts: usize) {
    held.lease.perform(&held.peer.client, "send", prompt(text)).expect("the worker takes the prompt");
    held.follow(|state| user_rows(state) == prompts && answered(state));
}

/// What the fixture echoed of the turn `fixture:echo` started: its `cwd` and its whole input.
fn echoed(state: &SessionState) -> Vec<Value> {
    let answers = state.items.values().filter(|item| item.get("type") == Some(&json!("agentMessage")));
    answers.filter_map(|item| serde_json::from_str::<Value>(item.get("text")?.as_str()?).ok()).filter(|echo| echo.get("input").is_some()).collect()
}

fn folder(path: PathBuf) -> PathBuf {
    std::fs::create_dir_all(&path).unwrap();
    path
}

#[test]
fn a_cd_during_the_first_prompt_moves_the_session_and_a_later_one_does_not() {
    let worker = start("project-cd");
    let atlas = folder(worker.directory.join("atlas"));
    let mut held = open_in(&worker, &worker.directory);

    turn(&mut held, &format!("fixture:cd:{}", text(&atlas)), 1);
    let moved = meta(held.replica.state().unwrap(), "cwd").clone();
    turn(&mut held, &format!("fixture:cd:{}", text(&worker.directory)), 2);

    let state = held.replica.state().unwrap();
    assert_eq!(moved, json!(text(&atlas)));
    assert_eq!(meta(state, "cwd"), text(&atlas));
    assert_eq!(meta(state, "conversationDirectory"), text(&worker.directory));
}

#[test]
fn a_turn_that_edits_files_in_another_project_moves_the_session_there() {
    let worker = start("project-turn");
    let atlas = folder(worker.directory.join("atlas"));
    let status = Command::new("/usr/bin/git").args(["-c", "core.hooksPath=/dev/null", "init", "-b", "main"]).arg(&atlas).stdout(Stdio::null()).stderr(Stdio::null()).status().unwrap();
    assert!(status.success());
    let mut held = open_in(&worker, &worker.directory);

    turn(&mut held, &format!("fixture:edit:{}/notes/todo.md", text(&atlas)), 1);

    held.follow(|state| meta(state, "cwd") == text(&atlas) && meta(state, "repository") == "atlas");
}

#[test]
fn a_frontend_moves_the_session_to_an_existing_folder_only() {
    let worker = start("project-move");
    let atlas = folder(worker.directory.join("atlas"));
    let mut held = open_in(&worker, &worker.directory);

    let moved = held.lease.perform(&held.peer.client, "moveDirectory", json!({"path": format!("{}/../atlas/", text(&atlas))}));
    let missing = held.lease.perform(&held.peer.client, "moveDirectory", json!({"path": format!("{}/missing", text(&atlas))}));

    held.follow(|state| meta(state, "cwd") == text(&atlas));
    assert!(moved.is_ok());
    assert!(missing.is_err_and(|error| error.to_string().contains("Directory does not exist.")));
}

#[test]
fn the_first_prompt_of_a_window_at_home_starts_in_the_project_chosen_for_it_its_row_kept() {
    let worker = with_home("project-route");
    let home = worker.directory.join("home");
    let atlas = folder(home.join("self/atlas"));
    let mut held = open_in(&worker, &home);

    turn(&mut held, "fixture:echo fixture:route:atlas fix the fixture", 1);

    let state = held.replica.state().unwrap();
    assert_eq!((meta(state, "cwd"), meta(state, "conversationDirectory")), (&json!(text(&atlas)), &json!(text(&atlas))));
    let echo = echoed(state);
    assert_eq!(echo.len(), 1);
    assert_eq!(echo[0]["cwd"], json!(text(&atlas)));
    assert!(!echo[0]["input"].as_str().unwrap().contains(CD_THERE));
}

#[test]
fn a_prompt_no_project_fits_starts_at_the_root_and_a_later_prompt_that_names_one_moves_the_chat_there() {
    let worker = with_home("project-route-later");
    let home = worker.directory.join("home");
    let atlas = folder(home.join("self/atlas"));
    let mut held = open_in(&worker, &home);

    turn(&mut held, "fixture:echo what time is it", 1);
    let unrouted = meta(held.replica.state().unwrap(), "cwd").clone();
    turn(&mut held, "fixture:echo fixture:route:atlas now fix the fixture", 2);

    let state = held.replica.state().unwrap();
    assert_eq!(unrouted, json!("/"));
    assert_eq!(meta(state, "cwd"), text(&atlas));
    let later = echoed(state).into_iter().find(|echo| echo["input"].as_str().unwrap().contains("now fix")).unwrap();
    assert_eq!(later["cwd"], json!(text(&atlas)));
    assert!(later["input"].as_str().unwrap().starts_with(&format!("This chat's project folder is {}{CD_THERE}", text(&atlas))));
}
