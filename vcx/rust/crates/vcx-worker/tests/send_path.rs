//! The send path around a prompt, as the Swift `Session` runs it: Shift+Return sends a waiting prompt now, up arrow
//! takes a queued one back from the agent, Escape before any output puts the prompt back in the composer, a send
//! applies the mode and accounts his settings name now, and a model change keeps the session's mode and effort.
//! Only fixtures run.

use serde_json::{Value, json};
use std::path::Path;
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, answered, prompt, user_rows};
use vcx_model::SessionState;
use vcx_testkit::{RUNTIME, RustWorker};

type Object = serde_json::Map<String, Value>;

const INTERRUPTED: &str = "Work interrupted.";
const HOUR: f64 = 3600.0;

fn fixture() -> Vec<String> {
    let agent = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/fake_agent.py").canonicalize().unwrap();
    vec!["/usr/bin/python3".into(), agent.to_string_lossy().into_owned()]
}

fn codex(name: &str, settings: Value) -> RustWorker {
    RustWorker::start_provider(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name, "codex", &fixture(), &settings)
}

fn held(worker: &RustWorker) -> Held {
    Held::open(&Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() })
}

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

fn busy(state: &SessionState) -> bool {
    meta(state, "busy") == &json!(true)
}

fn notices(state: &SessionState) -> Vec<String> {
    state.rows.iter().filter(|row| row.kind == "notice").flat_map(|row| &row.items).filter_map(|id| state.items[id]["text"].as_str().map(str::to_owned)).collect()
}

fn noticed(text: &str) -> impl Fn(&SessionState) -> bool {
    move |state| notices(state).iter().any(|notice| notice.contains(text))
}

fn perform(held: &mut Held, action: &str, params: Value) -> Object {
    held.lease.perform(&held.peer.client, action, params).expect("the worker takes the action")
}

/// The id of the shown prompt whose text is `text`.
fn prompt_id(state: &SessionState, text: &str) -> Option<String> {
    state.rows.iter().filter(|row| row.kind == "user").map(|row| &row.items[0]).find(|id| state.items.get(*id).is_some_and(|item| item["content"][0]["text"] == text)).cloned()
}

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64()
}

#[test]
fn shift_return_stops_the_turn_and_answers_the_waiting_prompt_with_a_turn_of_its_own() {
    let worker = codex("send-now", json!({}));
    let mut held = held(&worker);
    perform(&mut held, "send", prompt("fixture:hold"));
    held.follow(busy);
    perform(&mut held, "send", prompt("go now"));

    perform(&mut held, "sendNow", json!({}));
    held.follow(answered);

    let state = held.replica.state().unwrap();
    let kinds: Vec<&str> = state.rows.iter().map(|row| row.kind.as_str()).collect();
    assert_eq!(kinds, ["user", "activity", "user", "activity", "assistant"]);
    assert!(!noticed(INTERRUPTED)(state), "{:?}", notices(state));
    assert_eq!((meta(state, "status"), meta(state, "needsAttention")), (&json!("Ready"), &json!(false)));
}

#[test]
fn up_arrow_takes_back_only_a_prompt_the_agent_still_holds_in_its_queue() {
    let worker = codex("unsend", json!({}));
    let mut held = held(&worker);
    perform(&mut held, "send", prompt("fixture:hold"));
    held.follow(busy);
    perform(&mut held, "send", prompt("fixture:queued later"));
    perform(&mut held, "send", prompt("already read"));
    held.follow(|state| prompt_id(state, "fixture:queued later").is_some_and(|id| state.items[&id].get("queued") == Some(&json!(true))));
    let (queued, read) = {
        let state = held.replica.state().unwrap();
        (prompt_id(state, "fixture:queued later").unwrap(), prompt_id(state, "already read").unwrap())
    };

    let taken = perform(&mut held, "unsend", json!({"id": queued}));
    let kept = perform(&mut held, "unsend", json!({"id": read}));
    held.follow(|state| user_rows(state) == 2);

    let state = held.replica.state().unwrap();
    assert_eq!((taken["cancelled"].clone(), kept["cancelled"].clone()), (json!(true), json!(false)));
    assert!(prompt_id(state, "already read").is_some() && prompt_id(state, "fixture:queued later").is_none());
}

#[test]
fn escape_before_any_output_puts_the_prompt_back_in_the_composer_without_a_notice() {
    let worker = codex("withdraw", json!({}));
    let mut held = held(&worker);
    perform(&mut held, "send", prompt("fixture:quiet"));
    held.follow(busy);

    perform(&mut held, "stop", json!({"source": "Escape"}));
    held.follow(|state| !busy(state) && user_rows(state) == 0);
    let withdrawn = held.replica.state().unwrap().clone();
    perform(&mut held, "send", prompt("fixture:hold"));
    held.follow(|state| busy(state) && state.rows.iter().any(|row| row.kind == "activity"));
    perform(&mut held, "stop", json!({"source": "Escape"}));
    held.follow(noticed(INTERRUPTED));

    assert_eq!(withdrawn.draft, [json!({"type": "text", "text": "fixture:quiet"})]);
    assert_eq!(meta(&withdrawn, "status"), "Ready");
    assert!(notices(&withdrawn).is_empty(), "{:?}", notices(&withdrawn));
    let state = held.replica.state().unwrap();
    assert!(notices(state).contains(&"Work interrupted. Stop requested by Escape. Send a message to continue.".to_owned()));
    assert_eq!(user_rows(state), 1, "a prompt the agent answered stays");
}

#[test]
fn a_send_applies_the_mode_set_in_settings_and_leaves_a_limited_account_for_the_next() {
    let accounts = json!([{"id": "codex-a", "name": "A", "provider": "codex"}, {"id": "codex-b", "name": "B", "provider": "codex"}]);
    let worker = codex("send-settings", json!({"accounts": accounts}));
    let mut held = held(&worker);
    let changed = json!({"accounts": accounts, "mode": "ask", "limits": {"codex-a": now() + HOUR}});
    std::fs::write(worker.directory.join("config/settings.json"), changed.to_string()).unwrap();

    perform(&mut held, "send", prompt("hello"));
    held.follow(answered);

    let state = held.replica.state().unwrap();
    assert_eq!((meta(state, "account")["id"].clone(), meta(state, "activeMode").clone()), (json!("codex-b"), json!("ask")));
    assert!(noticed("Permission mode changed to Ask for approval.")(state), "{:?}", notices(state));
    assert!(noticed("Connected to Codex: switched to B.")(state), "{:?}", notices(state));
    assert_eq!(user_rows(state), 1);
    let switched = state.rows.iter().position(|row| row.items.iter().any(|id| state.items.get(id).and_then(|item| item.get("text")?.as_str()).is_some_and(|text| text.contains("switched to B"))));
    let prompt = state.rows.iter().position(|row| row.kind == "user");
    assert!(prompt < switched, "the prompt shows before the account switch, as in Swift");
}

#[test]
fn a_send_with_every_account_limited_is_refused_and_the_draft_kept() {
    let accounts = json!([{"id": "codex-a", "name": "A", "provider": "codex"}]);
    let worker = codex("send-limited", json!({"accounts": accounts}));
    let mut held = held(&worker);
    let reset = now() + HOUR;
    std::fs::write(worker.directory.join("config/settings.json"), json!({"accounts": accounts, "limits": {"codex-a": reset, "qwen": reset, "agy": reset}}).to_string()).unwrap();

    perform(&mut held, "send", prompt("hello"));
    held.follow(noticed("All enabled accounts have reached their limits. Check Settings or wait for a reset."));

    assert_eq!(user_rows(held.replica.state().unwrap()), 0);
}

#[test]
fn a_model_change_keeps_the_sessions_mode_effort_and_instructions_and_the_codex_window_shows_before_any_turn() {
    let worker = codex("set-model", json!({}));
    let codex_home = worker.directory.join(RUNTIME).join(".codex");
    std::fs::create_dir_all(&codex_home).unwrap();
    let cache = json!({"models": [{"slug": "fixture-model", "context_window": 200_000, "effective_context_window_percent": 95}]});
    std::fs::write(codex_home.join("models_cache.json"), cache.to_string()).unwrap();
    let mut held = held(&worker);
    held.follow(|state| meta(state, "contextLimit") == &json!(190_000));

    perform(&mut held, "setModel", json!({"model": "fixture-model", "effort": "high"}));
    held.turn("fixture:lastopen");

    let state = held.replica.state().unwrap();
    let answer = state.items.values().find(|item| item["type"] == "agentMessage").and_then(|item| item["text"].as_str()).unwrap();
    let resumed: Value = serde_json::from_str(answer).unwrap();
    assert_eq!((&resumed["model"], &resumed["effort"], &resumed["excludeTurns"]), (&json!("fixture-model"), &json!("high"), &json!(true)));
    assert_eq!((&resumed["approvalPolicy"], &resumed["sandbox"]), (&json!("never"), &json!("danger-full-access")));
    assert!(resumed["developerInstructions"].as_str().is_some_and(|text| !text.is_empty()), "{resumed}");
    assert_eq!((meta(state, "effort"), meta(state, "defaultEffort")), (&json!("high"), &json!("high")));
}
