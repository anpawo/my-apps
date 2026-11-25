//! Each adapter driving a real child process (the replay agent playing a recording) through `Connection`, the way the
//! worker drives an agent: requests in, typed events out, a permission answered, until the turn ends.

mod common;

use common::*;
use serde_json::{Value, json};
use std::time::Duration;
use tokio::sync::mpsc::UnboundedReceiver;
use vcx_agents::agy::{AgyConnection, AgyOptions};
use vcx_agents::claude::{ClaudeConnection, ClaudeOptions};
use vcx_agents::{Agent, Connection, Inbound, Incoming, Kind};

const TIMEOUT: Duration = Duration::from_secs(20);
const PROMPT: &str = "Run the shell command `echo vcx` once, then reply with the single word: done.";

fn run<F: std::future::Future>(test: F) -> F::Output {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    tokio::task::LocalSet::new().block_on(&runtime, test)
}

/// Reads until the turn ends, accepting every permission asked on the way.
async fn turn(connection: &Connection, incoming: &mut UnboundedReceiver<Incoming>) -> (Vec<Inbound>, usize) {
    let (mut seen, mut asked) = (Vec::new(), 0);
    loop {
        let next = tokio::time::timeout(TIMEOUT, incoming.recv()).await.expect("the turn ends in time").expect("the agent stays connected");
        let Incoming::Message(message) = next else { panic!("the agent exited mid-turn: {next:?}") };
        if let Inbound::Request { id, .. } = &message {
            asked += 1;
            connection.respond(id, json!({"decision": "accept"})).unwrap();
        }
        let ended = matches!(&message, Inbound::Event(event) if matches!(event.kind, Kind::TurnCompleted { .. }));
        seen.push(message);
        if ended {
            return (seen, asked);
        }
    }
}

fn input() -> Value {
    json!([{"type": "text", "text": PROMPT}])
}

#[test]
fn runs_the_recorded_codex_turn_through_the_codex_adapter() {
    run(async {
        let (agent, mut incoming) = Agent::spawn(&replay("codex-turn.jsonl"), std::path::Path::new("/tmp"), std::process::Stdio::null()).unwrap();
        let connection = Connection::Codex(agent);

        connection.request("initialize", json!({"clientInfo": {"name": "vcx"}, "capabilities": {}}), TIMEOUT).await.unwrap();
        connection.notify("initialized", None).unwrap();
        connection.request("account/read", json!({"refreshToken": false}), TIMEOUT).await.unwrap();
        let models = connection.request("model/list", json!({"limit": 3}), TIMEOUT).await.unwrap();
        let thread = connection.request("thread/start", json!({"cwd": PROJECT, "approvalPolicy": "on-request"}), TIMEOUT).await.unwrap();
        let id = thread["thread"]["id"].as_str().unwrap().to_owned();
        connection.request("turn/start", json!({"threadId": id, "input": input()}), TIMEOUT).await.unwrap();
        let (seen, _) = turn(&connection, &mut incoming).await;
        connection.close();

        assert!(!models["data"].as_array().unwrap().is_empty());
        ends_like_every_provider(&steps(&seen));
    });
}

#[test]
fn runs_the_recorded_claude_turn_through_the_claude_adapter() {
    run(async {
        let user = recording("claude-turn.jsonl").into_iter().find(|(dir, message)| dir == "send" && message["type"] == "user").unwrap().1;
        let options = ClaudeOptions { command: Some(replay("claude-turn.jsonl")), cwd: "/tmp".into(), mode: "ask".into(), environment: None, log: None, settings: None, paths: claude_paths(), profile: None };
        let (claude, mut incoming) = ClaudeConnection::start(options).await.unwrap();
        let connection = Connection::Claude(claude);

        let thread = connection.request("thread/start", json!({"approvalPolicy": "on-request"}), TIMEOUT).await.unwrap();
        let models = connection.request("model/list", json!({}), TIMEOUT).await.unwrap();
        let started = connection.request("turn/start", json!({"input": input(), "clientUserMessageId": user["uuid"]}), TIMEOUT).await.unwrap();
        let (seen, _) = turn(&connection, &mut incoming).await;
        connection.close();

        assert!(thread["thread"]["id"].as_str().unwrap().starts_with("claude:"));
        assert!(models["data"].as_array().unwrap().iter().any(|model| model["id"] == "claude-opus-5"), "{models}");
        assert!(started["turn"]["id"].is_string());
        ends_like_every_provider(&steps(&seen));
    });
}

#[test]
fn runs_an_agy_turn_through_the_agy_adapter_and_answers_its_permission() {
    run(async {
        let options = AgyOptions { command: Some(replay("agy-turn.jsonl")), cwd: "/tmp".into(), environment: None, log: None };
        let (agy, mut incoming) = AgyConnection::start(options).await.unwrap();
        let connection = Connection::Agy(agy);

        let thread = connection.request("thread/start", json!({"approvalPolicy": "on-request", "cwd": PROJECT}), TIMEOUT).await.unwrap();
        let models = connection.request("model/list", json!({}), TIMEOUT).await.unwrap();
        connection.request("turn/start", json!({"input": input()}), TIMEOUT).await.unwrap();
        let (seen, asked) = turn(&connection, &mut incoming).await;
        connection.close();

        assert_eq!(thread["thread"]["id"], "agy:00000000-0000-4000-8000-000000000001");
        assert_eq!(models["data"].as_array().unwrap().len(), 2);
        assert_eq!(asked, 1);
        ends_like_every_provider(&steps(&seen));
    });
}
