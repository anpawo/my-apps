//! The Codex adapter on recorded streams. No real Codex turn is recorded here (it would spend an account's quota):
//! the streams are written by hand to the schema codex-cli 0.172.0 generates, field for field.

use serde_json::{Value, json};
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use vcx_agents::{Agent, Event, Inbound, Incoming, Kind, Stream, TurnStatus};

const WAIT: Duration = Duration::from_secs(20);

fn stream(name: &str) -> Vec<Inbound> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/streams").join(name);
    std::fs::read(path).unwrap().split(|byte| *byte == b'\n').filter(|line| !line.is_empty()).map(vcx_agents::codex::parse_line).collect()
}

fn events(messages: &[Inbound]) -> Vec<&Event> {
    messages.iter().filter_map(|message| if let Inbound::Event(event) = message { Some(event) } else { None }).collect()
}

#[test]
fn reads_a_whole_turn_into_typed_events_in_order() {
    let messages = stream("codex_turn.jsonl");

    let kinds: Vec<&str> = events(&messages)
        .iter()
        .map(|event| match &event.kind {
            Kind::TurnStarted { .. } => "turnStarted",
            Kind::ItemStarted { .. } => "itemStarted",
            Kind::ItemCompleted { .. } => "itemCompleted",
            Kind::Delta { stream: Stream::CommandOutput, .. } => "outputDelta",
            Kind::Delta { stream: Stream::AgentMessage, .. } => "messageDelta",
            Kind::RequestResolved { .. } => "resolved",
            Kind::TokenUsage { .. } => "tokens",
            Kind::RateLimits { .. } => "limits",
            Kind::TurnCompleted { .. } => "turnCompleted",
            _ => "other",
        })
        .collect();

    assert_eq!(kinds, [
        "other", "turnStarted", "itemStarted", "itemCompleted", "itemStarted", "itemCompleted", "itemStarted", "resolved", "outputDelta", "outputDelta",
        "itemCompleted", "messageDelta", "messageDelta", "itemCompleted", "tokens", "limits", "turnCompleted",
    ]);
}

#[test]
fn keeps_the_message_each_event_came_from() {
    let messages = stream("codex_turn.jsonl");
    let started = events(&messages).into_iter().find(|event| event.method() == "thread/started").unwrap();

    let path = &started.params()["thread"]["path"];

    assert_eq!(started.kind, Kind::Other);
    assert_eq!(path, "/Users/example/.codex/sessions/2026/11/25/rollout.jsonl");
    assert_eq!(started.thread_id, None, "thread/started names its thread inside `thread`, not as threadId");
}

#[test]
fn gives_a_completed_item_whole_with_its_thread() {
    let messages = stream("codex_turn.jsonl");

    let command = events(&messages)
        .into_iter()
        .find_map(|event| match &event.kind {
            Kind::ItemCompleted { item } if item["type"] == "commandExecution" => Some((event.thread_id.clone(), item.clone())),
            _ => None,
        })
        .unwrap();

    assert_eq!(command.0.as_deref(), Some("019a7c1e-5b2f-7d40-9a3e-0c8f4e2d1b6a"));
    assert_eq!((&command.1["aggregatedOutput"], &command.1["exitCode"]), (&json!("README.md\nsrc\n"), &json!(0)));
}

#[test]
fn keeps_an_approval_request_id_as_the_number_it_was() {
    let messages = stream("codex_turn.jsonl");

    let request = messages.iter().find_map(|message| if let Inbound::Request { id, method, params } = message { Some((id, method, params)) } else { None }).unwrap();

    assert_eq!(request.0, &json!(731));
    assert!(request.0.is_u64());
    assert_eq!(request.1, "item/commandExecution/requestApproval");
    assert_eq!(request.2["itemId"], "item-ls");
}

#[test]
fn reads_tokens_and_the_context_window() {
    let messages = stream("codex_turn.jsonl");

    let usage = events(&messages).into_iter().find_map(|event| if let Kind::TokenUsage { total, last, window } = event.kind { Some((total, last, window)) } else { None });

    assert_eq!(usage, Some((Some(15_234), Some(15_234), Some(272_000))));
}

#[test]
fn answers_belong_to_the_request_id_they_name() {
    let messages = stream("codex_turn.jsonl");

    let answers: Vec<&Value> = messages.iter().filter_map(|message| if let Inbound::Response { id, .. } = message { Some(id) } else { None }).collect();

    assert_eq!(answers, [&json!(1), &json!(2)]);
}

#[test]
fn tells_retries_warnings_failures_and_interruptions_apart() {
    let messages = stream("codex_failures.jsonl");
    let events = events(&messages);

    assert_eq!(events[0].kind, Kind::Error { message: "stream disconnected before completion; retrying 1/5".into(), will_retry: true });
    assert_eq!(events[1].kind, Kind::Warning { message: "Falling back from WebSockets to HTTPS transport.".into() });
    assert_eq!(events[2].kind, Kind::Warning { message: "Unknown key `foo` in config.toml".into() });
    assert_eq!(events[3].kind, Kind::Compacted);
    assert_eq!(events[4].kind, Kind::TurnCompleted { turn_id: Some("turn-2".into()), status: TurnStatus::Failed, error: Some("You've hit your usage limit.".into()) });
    assert_eq!(events[5].kind, Kind::TurnCompleted { turn_id: Some("turn-3".into()), status: TurnStatus::Interrupted, error: None });
    assert_eq!(events[6].kind, Kind::Other);
}

#[test]
fn keeps_a_question_request_and_an_error_answer() {
    let messages = stream("codex_failures.jsonl");

    let question = messages.iter().find_map(|message| if let Inbound::Request { id, method, .. } = message { Some((id.clone(), method.clone())) } else { None });
    let error = messages.iter().find_map(|message| if let Inbound::Response { outcome: Err(error), .. } = message { Some(error.clone()) } else { None }).unwrap();

    assert_eq!(question, Some((json!("q-7"), "item/tool/requestUserInput".to_owned())));
    assert_eq!((error.code, error.message.as_str()), (-32600, "thread not found: 019a7c1e"));
}

#[test]
fn reports_a_line_that_is_no_message_instead_of_dropping_it() {
    let messages = stream("codex_failures.jsonl");

    let last = messages.last().unwrap();

    assert!(matches!(last, Inbound::Invalid(text) if text.contains("not a JSON object")), "{last:?}");
}

fn local<F: std::future::Future>(future: F) -> F::Output {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    tokio::task::LocalSet::new().block_on(&runtime, future)
}

fn fixture() -> Vec<String> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/fake_agent.py").canonicalize().unwrap();
    vec!["/usr/bin/python3".into(), path.to_str().unwrap().into()]
}

#[test]
fn runs_a_turn_of_the_fixture_agent_from_initialize_to_completion() {
    let seen = local(async {
        let (agent, mut incoming) = Agent::spawn(&fixture(), Path::new("/tmp"), Stdio::null()).unwrap();
        agent.request("initialize", json!({"clientInfo": {"name": "vcx"}}), WAIT).await.unwrap();
        agent.notify("initialized", None).unwrap();
        let thread = agent.request("thread/start", json!({"cwd": "/tmp"}), WAIT).await.unwrap();
        agent.request("turn/start", json!({"threadId": thread["thread"]["id"], "input": []}), WAIT).await.unwrap();
        let mut methods = Vec::new();
        while let Some(Incoming::Message(Inbound::Event(event))) = tokio::time::timeout(WAIT, incoming.recv()).await.unwrap() {
            methods.push(event.method().to_owned());
            if matches!(event.kind, Kind::TurnCompleted { .. }) {
                break;
            }
        }
        agent.close();
        let end = tokio::time::timeout(WAIT, incoming.recv()).await.unwrap();
        (thread["thread"]["id"].clone(), methods, end)
    });

    assert_eq!(seen.0, "fixture-thread");
    assert_eq!(seen.1.first().map(String::as_str), Some("turn/started"));
    assert_eq!(seen.1.last().map(String::as_str), Some("turn/completed"));
    assert!(seen.1.iter().any(|method| method == "item/agentMessage/delta"));
    assert!(matches!(seen.2, Some(Incoming::Exited { .. })), "the reader ends with the agent: {:?}", seen.2);
}

#[test]
fn fails_a_pending_request_when_the_agent_exits() {
    let outcome = local(async {
        let command = vec!["/bin/sh".to_owned(), "-c".to_owned(), "read line; exit 3".to_owned()];
        let (agent, mut incoming) = Agent::spawn(&command, Path::new("/tmp"), Stdio::null()).unwrap();
        let answer = agent.request("initialize", json!({}), WAIT).await;
        let end = tokio::time::timeout(WAIT, incoming.recv()).await.unwrap();
        (answer, end)
    });

    assert_eq!(outcome.0.unwrap_err().message, "The agent disconnected.");
    assert!(matches!(outcome.1, Some(Incoming::Exited { reason }) if reason == "The agent exited with status 3."));
}
