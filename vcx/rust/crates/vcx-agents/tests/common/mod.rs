//! What the adapter tests share: the recordings and the steps of a turn a person sees.
#![allow(dead_code)]

use serde_json::Value;
use std::path::{Path, PathBuf};
use vcx_agents::claude_stream::ClaudePaths;
use vcx_agents::shape::Effect;
use vcx_agents::{Inbound, Kind, Object, Stream, codex};

pub const PROJECT: &str = "/tmp/vcx-fixture/project";

pub fn recording(name: &str) -> Vec<(String, Object)> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/streams").join(name);
    std::fs::read_to_string(path).unwrap().lines().map(|line| {
        let record: Value = serde_json::from_str(line).unwrap();
        (record["dir"].as_str().unwrap().to_owned(), record["message"].as_object().unwrap().clone())
    }).collect()
}

pub fn received(name: &str) -> Vec<Object> {
    recording(name).into_iter().filter(|(dir, _)| dir == "recv").map(|(_, message)| message).collect()
}

pub fn events(effects: Vec<Effect>) -> Vec<Inbound> {
    effects.into_iter().filter_map(|effect| match effect {
        Effect::Event(message) => Some(codex::parse(message)),
        _ => None,
    }).collect()
}

/// What a person sees of a turn: its start, each finished message and command, and how it ended. Message deltas
/// are checked to add up to the message they stream.
pub fn steps(inbound: &[Inbound]) -> Vec<String> {
    let mut streamed: std::collections::HashMap<String, String> = Default::default();
    let mut out = Vec::new();
    for message in inbound {
        let Inbound::Event(event) = message else { continue };
        match &event.kind {
            Kind::TurnStarted { .. } => out.push("turn started".to_owned()),
            Kind::Delta { item_id, delta, stream: Stream::AgentMessage } => streamed.entry(item_id.clone()).or_default().push_str(delta),
            Kind::ItemCompleted { item } => match item.get("type").and_then(Value::as_str) {
                Some("agentMessage") => {
                    let text = item["text"].as_str().unwrap();
                    if let Some(deltas) = streamed.get(item["id"].as_str().unwrap()) {
                        assert_eq!(deltas, text, "the deltas of a message add up to it");
                    }
                    out.push(format!("message: {}", text.trim()));
                }
                Some("commandExecution") => out.push(format!(
                    "command: {} ({})",
                    item.get("aggregatedOutput").and_then(Value::as_str).unwrap_or_default().trim(),
                    item["status"].as_str().unwrap(),
                )),
                _ => {}
            },
            Kind::TurnCompleted { status, .. } => out.push(format!("turn {status:?}")),
            _ => {}
        }
    }
    out
}

pub fn ends_like_every_provider(steps: &[String]) {
    assert_eq!(steps.first().map(String::as_str), Some("turn started"), "{steps:?}");
    let tail: Vec<&str> = steps[steps.len().saturating_sub(3)..].iter().map(String::as_str).collect();
    assert_eq!(tail, ["command: vcx (completed)", "message: done", "turn Completed"], "{steps:?}");
}

pub fn streams() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/streams").canonicalize().unwrap()
}

/// The replay agent playing `name`, as the command an adapter starts.
pub fn replay(name: &str) -> Vec<String> {
    let folder = streams();
    ["python3".into(), "-I".into(), folder.join("replay.py").to_string_lossy().into_owned(), folder.join(name).to_string_lossy().into_owned()].into()
}

pub fn claude_paths() -> ClaudePaths {
    let root = Path::new("/tmp/vcx-fixture/claude");
    ClaudePaths { config: root.into(), sessions: root.join("sessions"), attachments: root.join("attachments"), added: Vec::new() }
}

