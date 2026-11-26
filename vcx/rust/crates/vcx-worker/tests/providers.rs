//! A session on each provider the adapters speak, run end to end through the worker: Claude and agy replay their
//! recorded turn, Qwen talks to a fake Ollama behind a fake SOCKS5 proxy. No real agent runs and nothing of his is read.

mod common;

use common::{Ollama, answers, streams};
use serde_json::{Value, json};
use std::path::Path;
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, answered, prompt};
use vcx_model::SessionState;
use vcx_testkit::RustWorker;

const PROMPT: &str = "Run the shell command `echo vcx` once, then reply with the single word: done.";

fn replay(name: &str) -> Vec<String> {
    let streams = streams();
    ["/usr/bin/python3", "-I"].into_iter().map(str::to_owned).chain([streams.join("replay.py"), streams.join(name)].map(|path| path.to_string_lossy().into_owned())).collect()
}

fn worker(name: &str, provider: &str, command: &[String], settings: Value) -> RustWorker {
    RustWorker::start_provider(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name, provider, command, &settings)
}

fn target(worker: &RustWorker) -> Target {
    Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() }
}

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

fn permissions(state: &SessionState) -> Vec<Value> {
    meta(state, "permissions").as_array().cloned().unwrap_or_default()
}

/// Waits for the catalog (Claude reads it from the same process the turn runs in), sends the prompt and accepts
/// whatever the agent asks until it answers.
fn run_turn(held: &mut Held) {
    held.follow(|state| meta(state, "ready") == &json!(true) && meta(state, "models").as_array().is_some_and(|models| !models.is_empty()));
    held.lease.perform(&held.peer.client, "send", prompt(PROMPT)).expect("the worker takes the prompt");
    loop {
        held.follow(|state| answered(state) || !permissions(state).is_empty());
        let Some(asked) = permissions(held.replica.state().unwrap()).first().cloned() else { return };
        let answer = json!({"rpcID": asked["rpcID"], "method": asked["method"], "result": {"decision": "accept"}});
        held.lease.perform(&held.peer.client, "answer", answer).expect("the worker takes the answer");
    }
}

fn assert_ran(held: &Held, label: &str, provider: &str) {
    let state = held.replica.state().unwrap();
    assert_eq!(meta(state, "providerLabel"), label);
    assert_eq!(meta(state, "account")["provider"], provider);
    assert!(meta(state, "threadID").as_str().is_some_and(|thread| thread.starts_with(&format!("{provider}:"))), "{:?}", meta(state, "threadID"));
    let kinds = held.turn_kinds();
    assert_eq!(kinds.first().map(String::as_str), Some("user"), "{kinds:?}");
    assert!(kinds.iter().any(|kind| kind == "assistant"), "{kinds:?}");
}

#[test]
fn runs_a_replayed_claude_turn_through_the_worker() {
    // The recording ran in Claude's default mode: in any other, the send would first switch it (`vcx/mode`).
    let worker = worker("claude", "claude", &replay("claude-turn.jsonl"), json!({"mode": "ask"}));
    let mut held = Held::open(&target(&worker));

    run_turn(&mut held);

    assert_ran(&held, "Claude", "claude");
}

#[test]
fn runs_a_replayed_agy_turn_through_the_worker() {
    let worker = worker("agy", "agy", &replay("agy-turn.jsonl"), json!({}));
    let mut held = Held::open(&target(&worker));

    run_turn(&mut held);

    assert_ran(&held, "Antigravity", "agy");
}

#[test]
fn runs_a_qwen_turn_through_the_proxy_his_settings_name() {
    let ollama = Ollama::serve(answers("qwen-turn.jsonl"));
    let settings = json!({"qwenURL": "http://pc.fixture:11434/api/chat", "qwenProxy": format!("socks5h://{}", ollama.address)});
    let worker = worker("qwen", "qwen", &[], settings);
    let mut held = Held::open(&target(&worker));

    run_turn(&mut held);

    assert_ran(&held, "Qwen", "qwen");
    assert_eq!(ollama.requests(), 2, "one model step before the command, one after");
}
