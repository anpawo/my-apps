//! The slash commands the worker answers itself, as the Swift `Session.command` does: menus, model shortcuts,
//! reports, conversation settings, pending approvals and Codex's own compact and review. None reaches the model as a
//! prompt. Only fixtures run.

use serde_json::{Value, json};
use std::path::Path;
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, prompt, user_rows};
use vcx_model::SessionState;
use vcx_testkit::RustWorker;

type Object = serde_json::Map<String, Value>;

const IDLE_ONLY: &str = "Stop the current response before changing session settings.";
const HELD_ANSWER: &str = "fixture-held-answer";

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

fn said(text: &str) -> impl Fn(&SessionState) -> bool {
    move |state| meta(state, "busy") == &json!(false) && state.items.values().any(|item| item.get("type") == Some(&json!("agentMessage")) && item.get("text") == Some(&json!(text)))
}

fn asked(state: &SessionState) -> bool {
    meta(state, "permissions").as_array().is_some_and(|permissions| !permissions.is_empty())
}

fn command(held: &mut Held, text: &str) -> Object {
    held.lease.perform(&held.peer.client, "command", json!({"text": text})).expect("the worker takes the command")
}

fn send(held: &mut Held, text: &str) {
    held.lease.perform(&held.peer.client, "send", prompt(text)).expect("the worker takes the message");
}

#[test]
fn opens_menus_and_changes_model_and_effort_by_command_and_shortcut() {
    let worker = codex("command-model", json!({}));
    let mut held = held(&worker);

    let menus: Vec<Value> = ["/model", "/model codex", "/model codex fixture-model", "/perms", "/account"].into_iter().map(|text| command(&mut held, text)["commandQuery"].clone()).collect();
    command(&mut held, "/model codex fixture-model high");
    command(&mut held, "/codex");
    command(&mut held, "/model codex nope");
    command(&mut held, "/effort low");
    held.follow(noticed("Choose an effort supported by the active model: high"));
    send(&mut held, "fixture:hold");
    held.follow(|state| meta(state, "busy") == &json!(true));
    let during = command(&mut held, "/model codex")["commandQuery"].clone();
    command(&mut held, "/codex");
    held.follow(noticed("Model change queued: codex applies when the current turn ends."));

    let state = held.replica.state().unwrap();
    assert_eq!(menus, ["/model ", "/model codex ", "/model codex fixture-model ", "/perms ", "/account "]);
    assert_eq!((meta(state, "model"), meta(state, "effort")), (&json!("fixture-model"), &json!("high")), "/codex keeps the effort the model has");
    assert!(notices(state).contains(&"Choose a model from the menu.".to_owned()), "{:?}", notices(state));
    assert_eq!(during, "/model codex ", "the current provider's menu opens during a turn");
}

#[test]
fn reports_tokens_usage_repository_catalogs_status_and_help_without_reaching_the_model() {
    let worker = codex("command-reports", json!({}));
    let mut held = held(&worker);

    for text in ["/tokens", "/usage", "/repo", "/hooks", "/skills", "/mcp", "/instructions", "/status", "/help"] {
        command(&mut held, text);
    }
    held.follow(noticed("/vcx:<command> explicitly selects vcx commands."));

    let state = held.replica.state().unwrap();
    let shown = notices(state);
    for expected in ["Not reported", "The provider has not reported subscription usage yet.", "No repository · not a repo", "No entries reported for hooks.", "No entries reported for skills.", "No entries reported for mcp.", "No entries reported for instructions."] {
        assert!(shown.contains(&expected.to_owned()), "{expected} not in {shown:?}");
    }
    let status = format!("Provider: Codex · {}\nMode: Bypass / YOLO\nModel: fixture-model\nTokens: Not reported\nUsage: Not reported\nRepository: No repository · ", meta(state, "account")["name"].as_str().unwrap());
    assert!(shown.iter().any(|notice| notice.starts_with("Directory: ") && notice.ends_with(&status)), "{shown:?}");
    let help = shown.last().unwrap();
    assert!(help.starts_with("/model · vcx: Choose provider, model, and reasoning effort\n"), "{help}");
    assert!(help.contains("\n/cwd · Codex: Use through vcx /dir\n") && help.contains("\n/daybreak · Codex terminal: Unavailable in vcx (Codex terminal action)\n"), "{help}");
    assert_eq!(user_rows(state), 0);
}

#[test]
fn renames_plans_and_moves_the_conversation_to_another_folder() {
    let worker = codex("command-conversation", json!({}));
    let mut held = held(&worker);
    let folder = worker.directory.join("elsewhere");
    std::fs::create_dir(&folder).unwrap();
    let (record, cwd) = {
        let state = held.replica.state().unwrap();
        (meta(state, "recordID").clone(), meta(state, "cwd").as_str().unwrap().to_owned())
    };

    command(&mut held, "/rename Fixture work");
    command(&mut held, "/plan on");
    held.follow(|state| meta(state, "conversationName") == "Fixture work" && meta(state, "planning") == &json!(true));
    command(&mut held, "/plan off");
    command(&mut held, "/dir");
    command(&mut held, "/dir /nonexistent/vcx-folder");
    held.follow(noticed("Directory does not exist."));
    let before = notices(held.replica.state().unwrap());
    command(&mut held, &format!("/dir {}", folder.display()));
    held.follow(|state| meta(state, "cwd") == folder.to_str().unwrap() && meta(state, "ready") == &json!(true));

    let state = held.replica.state().unwrap();
    assert!(before.contains(&"Plan mode enabled. Use /plan off to implement.".to_owned()) && before.contains(&"Implementation mode enabled.".to_owned()), "{before:?}");
    assert!(before.contains(&format!("{cwd}\nUse /dir <folder> to change directory.")), "{before:?}");
    assert_ne!(meta(state, "recordID"), &record, "a new folder is a new conversation");
    assert_eq!(meta(state, "conversationDirectory"), folder.to_str().unwrap());
}

#[test]
fn answers_approvals_and_questions_from_chat() {
    let worker = codex("command-answers", json!({}));
    let mut held = held(&worker);

    command(&mut held, "/allow");
    held.follow(noticed("No pending question or approval."));
    send(&mut held, "fixture:approve");
    held.follow(asked);
    command(&mut held, "/allow");
    held.follow(said("approved"));
    send(&mut held, "fixture:approve");
    held.follow(asked);
    command(&mut held, "/decline");
    held.follow(said("declined"));
    send(&mut held, "fixture:question");
    held.follow(asked);
    command(&mut held, "/answer");
    held.follow(noticed("Use /answer <text> for the next question."));
    command(&mut held, "/answer blue");
    held.follow(said(r#"answers {"pick": {"answers": ["blue"]}}"#));
    send(&mut held, "fixture:twoquestions");
    held.follow(asked);
    command(&mut held, r#"/answer {"first": "1"}"#);
    held.follow(noticed("Use /answer followed by a JSON object mapping every question ID to an answer."));
    command(&mut held, r#"/answer {"first": "1", "second": "2"}"#);
    held.follow(said(r#"answers {"first": {"answers": ["1"]}, "second": {"answers": ["2"]}}"#));

    assert_eq!(held.replica.state().unwrap().items[HELD_ANSWER]["type"], "agentMessage");
}

#[test]
fn compacts_and_reviews_through_codex_requests() {
    let worker = codex("command-codex", json!({}));
    let mut held = held(&worker);

    command(&mut held, "/compact");
    held.follow(noticed("Conversation compacted. Earlier messages remain in history."));
    command(&mut held, "/review");
    held.follow(said(r#"Review of {"type": "uncommittedChanges"}"#));
    command(&mut held, "/codex:review look at the tests");
    held.follow(said(r#"Review of {"instructions": "look at the tests", "type": "custom"}"#));

    assert_eq!(user_rows(held.replica.state().unwrap()), 0, "no prompt was sent");
}

#[test]
fn answers_a_codex_command_vcx_lacks_without_sending_it_to_the_model() {
    let worker = codex("command-native", json!({}));
    let mut held = held(&worker);

    send(&mut held, "/daybreak");
    command(&mut held, "/codex:pet");
    held.follow(noticed("/pet is listed"));

    let state = held.replica.state().unwrap();
    assert!(notices(state).contains(&"/daybreak is listed from the Codex terminal catalog but is not implemented in vcx. It was not sent to the model. Use /help for available vcx actions.".to_owned()), "{:?}", notices(state));
    assert_eq!(user_rows(state), 0);
}

#[test]
fn refuses_a_new_conversation_during_a_turn_and_starts_one_after_it() {
    let worker = codex("command-new", json!({}));
    let mut held = held(&worker);
    let record = meta(held.replica.state().unwrap(), "recordID").clone();

    send(&mut held, "fixture:hold");
    held.follow(|state| meta(state, "busy") == &json!(true));
    command(&mut held, "/new");
    held.follow(noticed(IDLE_ONLY));
    command(&mut held, "/stop");
    held.follow(|state| meta(state, "busy") == &json!(false));
    command(&mut held, "/clear");
    held.follow(|state| meta(state, "recordID") != &record && meta(state, "ready") == &json!(true));

    assert_eq!(user_rows(held.replica.state().unwrap()), 0, "the new conversation starts empty");
}

#[test]
fn reconnects_for_a_mode_change_when_the_agent_is_not_ready() {
    let worker = codex("command-perms", json!({}));
    let mut held = held(&worker);
    send(&mut held, "fixture:crash");
    held.follow(noticed("Restarted it, context kept."));
    held.follow(|state| meta(state, "ready") == &json!(true));
    send(&mut held, "fixture:crash");
    held.follow(noticed("It stopped twice in 5 minutes"));

    command(&mut held, "/perms ask");
    held.follow(noticed("Reconnected to Codex: permission mode changed. Context kept."));

    held.follow(|state| meta(state, "ready") == &json!(true));
}

#[test]
fn saves_qwen_settings_and_imports_a_profile() {
    let worker = codex("command-settings", json!({}));
    let mut held = held(&worker);
    let profile = worker.directory.join("codex-profile");
    std::fs::create_dir(&profile).unwrap();

    let menu = command(&mut held, "/qwen")["commandQuery"].clone();
    command(&mut held, "/qwen host mac");
    command(&mut held, "/qwen url ftp://pc.fixture");
    command(&mut held, "/qwen model none");
    command(&mut held, "/profile gemini ~/x");
    command(&mut held, &format!("/profile codex {}", profile.display()));
    held.follow(noticed("Profile added. Select it with /account."));

    let shown = notices(held.replica.state().unwrap());
    for expected in ["Qwen setting saved.", "Enter an HTTP or HTTPS Ollama URL without credentials.", "Model names cannot be empty.", "Use /profile claude|codex <profile directory>."] {
        assert!(shown.contains(&expected.to_owned()), "{expected} not in {shown:?}");
    }
    let settings: Value = serde_json::from_str(&std::fs::read_to_string(worker.directory.join("config/settings.json")).unwrap()).unwrap();
    assert_eq!((&settings["qwenURL"], &settings["qwenProxy"]), (&json!("http://localhost:11434/api/chat"), &json!("")));
    let imported = settings["accounts"].as_array().unwrap().iter().find(|account| account["home"] == profile.to_str().unwrap()).cloned();
    assert_eq!(imported.map(|account| (account["provider"].clone(), account["name"].clone())), Some((json!("codex"), json!("codex-profile"))));
    assert_eq!(menu, "/qwen ");
}
