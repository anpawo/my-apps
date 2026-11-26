//! The repository footer the worker reads for a session's folder, as the Swift `refreshRepository` does, on a
//! temporary repository with no GitHub remote: `gh` is never asked and nothing goes on the network.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, Peer, answered, prompt, request_for};
use vcx_model::SessionState;
use vcx_proto::AttachRequest;
use vcx_testkit::RustWorker;

const NO_HOOKS: &str = "core.hooksPath=/dev/null";

fn target(worker: &RustWorker) -> Target {
    Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() }
}

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

fn git(folder: &Path, arguments: &[&str]) {
    let status = Command::new("/usr/bin/git").args(["-c", NO_HOOKS, "-c", "commit.gpgsign=false", "-C"]).arg(folder).args(arguments).stdout(Stdio::null()).stderr(Stdio::null()).status().unwrap();
    assert!(status.success(), "git {arguments:?}");
}

/// `atlas`, one commit on `main` and no remote.
fn repository(worker: &RustWorker) -> PathBuf {
    let root = worker.directory.join("atlas");
    std::fs::create_dir(&root).unwrap();
    git(&root, &["init", "-b", "main"]);
    std::fs::write(root.join("file"), "fixture").unwrap();
    git(&root, &["add", "file"]);
    git(&root, &["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "Fixture"]);
    root
}

/// A session opened in `cwd`, followed until its agent is ready and its footer read.
fn open_in(worker: &RustWorker, cwd: &Path) -> Held {
    let target = target(worker);
    let request = AttachRequest { cwd: cwd.to_string_lossy().into_owned(), ..request_for(&target, &vcx_testkit::session_id()) };
    let mut held = Held::attach(Peer::greeted(&target), &request);
    held.follow(|state| meta(state, "ready") == &json!(true) && meta(state, "repository") != "Checking…");
    held
}

fn start(name: &str) -> RustWorker {
    RustWorker::start(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name)
}

#[test]
fn shows_the_branch_and_state_of_the_session_repository_and_no_pull_request_offline() {
    let worker = start("repository");
    let root = repository(&worker);

    let held = open_in(&worker, &root);

    let state = held.replica.state().unwrap();
    let footer = ["repository", "repositoryDirectory", "branch", "repositoryStatus", "pullRequest", "pullRequestURL"].map(|key| meta(state, key).clone());
    assert_eq!(footer, [json!("atlas"), json!("atlas"), json!("main"), json!("local only"), json!(""), json!("")]);
    assert_eq!(meta(state, "repositoryChanges"), &json!([]));
}

#[test]
fn a_turn_that_edits_a_file_shows_its_folder_and_the_uncommitted_change() {
    let worker = start("repository-edit");
    let root = repository(&worker);
    let mut held = open_in(&worker, &root);

    let edited = root.join("notes/todo.md");
    held.lease.perform(&held.peer.client, "send", prompt(&format!("fixture:edit:{}", edited.display()))).expect("the worker takes the prompt");
    held.follow(|state| answered(state) && meta(state, "repositoryDirectory") == "atlas/notes");

    let state = held.replica.state().unwrap();
    assert_eq!(meta(state, "repositoryStatus"), "uncommitted");
    assert_eq!(meta(state, "repositoryChanges"), &json!(["?? notes/"]));
}

#[test]
fn a_folder_outside_any_repository_shows_no_repository() {
    let worker = start("repository-none");
    let loose = worker.directory.join("loose");
    std::fs::create_dir(&loose).unwrap();

    let held = open_in(&worker, &loose);

    let state = held.replica.state().unwrap();
    assert_eq!((meta(state, "repository"), meta(state, "branch"), meta(state, "repositoryDirectory")), (&json!("No repository"), &json!(""), &Value::Null));
}
