//! What the worker does when a turn cannot go on, as the Swift `Session` does: a usage limit moves the conversation
//! to the next account, a rate limit is retried, `/provider` hands the conversation to another provider, his mode
//! sets the approval policy, and a crashed agent's last error is read from its log. Only fixtures run.

mod common;

use common::{Ollama, answers};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, answered, prompt, user_rows};
use vcx_model::SessionState;
use vcx_testkit::RustWorker;

const QWEN_PROMPT: &str = "Run the shell command `echo vcx` once, then reply with the single word: done.";
const HANDOFF: &str = "Context from this conversation";

fn fixture() -> Vec<String> {
    let agent = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/fake_agent.py").canonicalize().unwrap();
    vec!["/usr/bin/python3".into(), agent.to_string_lossy().into_owned()]
}

fn codex(name: &str, settings: Value) -> RustWorker {
    RustWorker::start_provider(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name, "codex", &fixture(), &settings)
}

fn held(worker: &RustWorker) -> Held {
    let mut held = Held::open(&Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() });
    held.follow(|state| meta(state, "ready") == &json!(true));
    held
}

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

fn notices(state: &SessionState) -> Vec<String> {
    state.rows.iter().filter(|row| row.kind == "notice").flat_map(|row| &row.items).filter_map(|id| state.items[id]["text"].as_str().map(str::to_owned)).collect()
}

fn noticed(text: &str) -> impl Fn(&SessionState) -> bool {
    move |state| notices(state).iter().any(|notice| notice.contains(text))
}

fn send(held: &mut Held, text: &str) {
    held.lease.perform(&held.peer.client, "send", prompt(text)).expect("the worker takes the message");
}

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64()
}

#[test]
fn moves_a_usage_limited_turn_to_the_next_account_with_the_conversation() {
    let accounts = json!({"accounts": [{"id": "codex-a", "name": "A", "provider": "codex"}, {"id": "codex-b", "name": "B", "provider": "codex"}]});
    let worker = codex("usage-limit", accounts);
    let mut held = held(&worker);

    send(&mut held, "fixture:limit");
    held.follow(|state| meta(state, "account")["id"] == "codex-b" && answered(state));

    let state = held.replica.state().unwrap();
    let settings: Value = serde_json::from_str(&std::fs::read_to_string(worker.directory.join("config/settings.json")).unwrap()).unwrap();
    assert!(settings["limits"]["codex-a"].as_f64().is_some_and(|reset| reset > now()), "{settings}");
    assert_eq!(user_rows(state), 1, "the prompt is sent again, not shown twice");
}

#[test]
fn retries_a_rate_limited_turn_on_the_same_account() {
    let worker = codex("rate-limit", json!({}));
    let mut held = held(&worker);

    send(&mut held, "fixture:ratelimit");
    held.follow(answered);

    let state = held.replica.state().unwrap();
    assert!(notices(state).contains(&"Codex is rate limited. Retry 1 of 3 in 10 s.".to_owned()), "{:?}", notices(state));
    assert_eq!(meta(state, "account")["id"], "codex-default");
}

#[test]
fn hands_the_conversation_to_the_provider_named_mid_conversation() {
    let ollama = Ollama::serve(answers("qwen-turn.jsonl"));
    let worker = codex("provider-switch", json!({"qwenURL": "http://pc.fixture:11434/api/chat", "qwenProxy": format!("socks5h://{}", ollama.address)}));
    let mut held = held(&worker);
    held.turn("list the files");

    held.lease.perform(&held.peer.client, "command", json!({"text": "/provider qwen"})).expect("the worker switches provider");
    held.follow(|state| meta(state, "providerLabel") == "Qwen" && meta(state, "ready") == &json!(true));
    send(&mut held, QWEN_PROMPT);
    held.follow(|state| user_rows(state) == 2 && answered(state) && state.rows.last().is_some_and(|row| row.kind == "assistant"));

    let state = held.replica.state().unwrap();
    assert_eq!(user_rows(state), 2, "the Codex turn stays in the transcript");
    assert!(notices(state).iter().any(|notice| notice == "Connected to Qwen: provider changed. Recent messages are passed to it as context."), "{:?}", notices(state));
    let first = ollama.bodies().into_iter().next().unwrap_or_default();
    assert!(first.contains(HANDOFF) && first.contains("User: list the files"), "{first}");
}

#[test]
fn asks_for_approval_when_his_mode_is_ask_and_after_perms_ask() {
    let asking = codex("mode-ask", json!({"mode": "ask"}));
    let bypassing = codex("mode-perms", json!({}));
    let asked = held(&asking);
    let mut changed = held(&bypassing);
    let before = meta(changed.replica.state().unwrap(), "activeMode").clone();

    changed.lease.perform(&changed.peer.client, "command", json!({"text": "/perms ask"})).expect("the worker changes the mode");
    changed.follow(noticed("Permission mode changed to Ask for approval."));

    assert_eq!(meta(asked.replica.state().unwrap(), "activeMode"), "ask", "the fixture echoes the on-request policy it was opened with");
    assert_eq!((before, meta(changed.replica.state().unwrap(), "activeMode")), (json!("bypass"), &json!("ask")));
}

#[test]
fn keeps_a_crashed_agents_stderr_and_names_its_last_error() {
    let worker = codex("crash", json!({}));
    let mut held = held(&worker);

    send(&mut held, "fixture:crash");
    held.follow(noticed("Last error: fatal: fixture crashed"));

    let state = held.replica.state().unwrap();
    let log = PathBuf::from(meta(state, "stateDirectory").as_str().unwrap()).join("logs").join(format!("{}.log", meta(state, "recordID").as_str().unwrap()));
    assert!(std::fs::read_to_string(&log).unwrap().contains("fatal: fixture crashed"), "{}", log.display());
    let notice = state.rows.iter().rev().find(|row| row.kind == "notice").unwrap();
    assert_eq!(state.items[&notice.items[0]]["link"], json!(log.to_string_lossy()));
}

