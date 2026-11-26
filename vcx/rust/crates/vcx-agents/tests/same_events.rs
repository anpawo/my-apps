//! Each provider's turn, recorded (Codex, Claude) or written from the Swift adapters (agy, Qwen), read into the
//! typed events of `codex app-server`: the session sees the same turn whichever agent ran it.

mod common;

use common::*;
use serde_json::json;
use vcx_agents::agy_stream::AgyStream;
use vcx_agents::claude_stream::ClaudeStream;
use vcx_agents::shape::Effect;
use vcx_agents::{Event, Inbound, Kind, TurnStatus, codex};

#[test]
fn reads_the_recorded_codex_turn_into_the_shared_steps() {
    let inbound: Vec<Inbound> = received("codex-turn.jsonl").into_iter().map(codex::parse).collect();

    let steps = steps(&inbound);

    ends_like_every_provider(&steps);
    assert!(!inbound.iter().any(|message| matches!(message, Inbound::Invalid(_))));
}

#[test]
fn reads_the_recorded_claude_turn_into_the_shared_steps() {
    let lines = recording("claude-turn.jsonl");
    let user = lines.iter().find(|(dir, message)| dir == "send" && message["type"] == "user").unwrap().1.clone();
    let mut stream = ClaudeStream::new(PROJECT, "ask", claude_paths());

    let (line, mut effects) = stream.prompt(user["uuid"].as_str().unwrap(), user["message"]["content"].as_array().unwrap().clone(), false);
    for message in received("claude-turn.jsonl") {
        effects.extend(stream.receive(&message));
    }
    let inbound = events(effects);
    let steps = steps(&inbound);

    assert_eq!(line["message"], user["message"]);
    ends_like_every_provider(&steps);
    assert_eq!(steps.iter().filter(|step| *step == "turn started").count(), 1, "the replayed prompt opens no second turn: {steps:?}");
    let thread = stream.thread.clone();
    assert!(inbound.iter().all(|message| match message {
        Inbound::Event(event) => event.thread_id.as_deref() == Some(thread.as_str()),
        _ => true,
    }));
}

#[test]
fn reads_an_agy_turn_into_the_shared_steps_and_asks_before_the_command() {
    let lines = received("agy-turn.jsonl");
    let mut stream = AgyStream::new(PROJECT);
    stream.bypass = false;
    stream.opened(lines[1]["result"].as_object().unwrap(), None).unwrap();

    let (turn, started) = stream.start_turn();
    let (mut effects, mut asked, mut answer) = (vec![started], None, None);
    for message in &lines[3..] {
        for effect in stream.receive(message) {
            match effect {
                Effect::Resolve { request_id, outcome } if request_id == "4" => effects.extend(stream.finish_turn(&turn, outcome.as_ref().map_err(String::as_str))),
                Effect::Event(event) if event.contains_key("id") => {
                    let id = event["id"].as_str().unwrap().to_owned();
                    asked = Some(codex::parse(event));
                    for reply in stream.respond(&id, json!({"decision": "accept"}).as_object().unwrap()) {
                        match reply {
                            Effect::Write(line) => answer = Some(line),
                            other => effects.push(other),
                        }
                    }
                }
                other => effects.push(other),
            }
        }
    }
    let inbound = events(effects);
    let steps = steps(&inbound);

    assert_eq!(stream.thread, "agy:00000000-0000-4000-8000-000000000001");
    assert_eq!(stream.models, ["gemini-3-pro", "gemini-3-flash"]);
    let Some(Inbound::Request { method, params, .. }) = asked else { panic!("agy's permission reaches the session as a request") };
    assert_eq!((method.as_str(), params["command"].as_str()), ("item/commandExecution/requestApproval", Some("echo vcx")));
    assert_eq!(answer.unwrap()["result"]["outcome"]["optionId"], "proceed_once");
    assert_eq!(steps, ["turn started", "message: I will run it once.", "command: vcx (completed)", "message: done", "turn Completed"]);
    assert!(inbound.iter().any(|message| matches!(message, Inbound::Event(event) if event.method() == "vcx/tokens")));
}

#[test]
fn ends_an_agy_turn_stopped_mid_command_as_interrupted_with_the_command_failed() {
    let lines = received("agy-turn.jsonl");
    let mut stream = AgyStream::new(PROJECT);
    stream.opened(lines[1]["result"].as_object().unwrap(), None).unwrap();
    let (turn, started) = stream.start_turn();
    let mut effects = vec![started];
    effects.extend(stream.receive(&lines[6]));

    effects.extend(stream.finish_turn(&turn, Ok(json!({"stopReason": "cancelled"}).as_object().unwrap())));
    let inbound = events(effects);

    let steps = steps(&inbound);
    assert_eq!(steps.last().map(String::as_str), Some("turn Interrupted"));
    let failed = inbound.iter().any(|message| matches!(message, Inbound::Event(Event { kind: Kind::ItemCompleted { item }, .. }) if item["status"] == "failed"));
    assert!(failed, "the running command closes as failed: {steps:?}");
    assert!(matches!(&inbound.last(), Some(Inbound::Event(Event { kind: Kind::TurnCompleted { status: TurnStatus::Interrupted, .. }, .. }))));
}
