//! A Claude connection kept across an exec of its worker, tried without the exec: what `freeze` hands over between
//! two turns, and how `adopt` goes on with the process it is given (`vcx-worker/tests/swap.rs` runs the exec).

mod common;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use common::*;
use serde_json::{Value, json};
use std::os::fd::IntoRawFd;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;
use tokio::sync::mpsc::UnboundedReceiver;
use vcx_agents::claude::{ClaudeConnection, ClaudeOptions};
use vcx_agents::process::{Launch, Line, Lines};
use vcx_agents::{Connection, Inbound, Incoming, Kind};

const TIMEOUT: Duration = Duration::from_secs(20);
const POLL: Duration = Duration::from_millis(10);
const SECRET: &str = "fixture-secret-value";
/// A command that plays no Claude: a connection that had to start its own process would run no turn.
const NO_CLAUDE: &str = "/usr/bin/false";

fn run<F: std::future::Future>(test: F) -> F::Output {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    tokio::task::LocalSet::new().block_on(&runtime, test)
}

fn options(command: Vec<String>, environment: Option<Vec<(String, String)>>) -> ClaudeOptions {
    ClaudeOptions { command: Some(command), cwd: "/tmp".into(), mode: "ask".into(), environment, log: None, settings: None, paths: claude_paths(), profile: None }
}

fn recorded_prompt() -> Value {
    let user = recording("claude-turn.jsonl").into_iter().find(|(dir, message)| dir == "send" && message["type"] == "user").unwrap().1;
    json!({"input": [{"type": "text", "text": "Run the recorded turn."}], "clientUserMessageId": user["uuid"]})
}

async fn turn(incoming: &mut UnboundedReceiver<Incoming>) -> Vec<Inbound> {
    let mut seen = Vec::new();
    loop {
        let next = tokio::time::timeout(TIMEOUT, incoming.recv()).await.expect("the turn ends in time").expect("the agent stays connected");
        let Incoming::Message(message) = next else { panic!("the agent exited mid-turn: {next:?}") };
        let ended = matches!(&message, Inbound::Event(event) if matches!(event.kind, Kind::TurnCompleted { .. }));
        seen.push(message);
        if ended {
            return seen;
        }
    }
}

async fn line(lines: &mut UnboundedReceiver<Line>) -> Line {
    tokio::time::timeout(TIMEOUT, lines.recv()).await.expect("the agent's line comes in time").expect("the reader goes on")
}

#[test]
fn an_idle_claude_connection_is_frozen_with_its_process_and_without_its_environment() {
    let frozen = run(async {
        let environment = vec![("PATH".to_owned(), std::env::var("PATH").unwrap()), ("FIXTURE_SECRET".to_owned(), SECRET.to_owned())];
        let (claude, _incoming) = ClaudeConnection::start(options(replay("claude-turn.jsonl"), Some(environment))).await.unwrap();
        claude.request("thread/start", json!({"approvalPolicy": "on-request"}), TIMEOUT).await.unwrap();
        claude.request("model/list", json!({}), TIMEOUT).await.expect("the catalog comes from a running Claude");

        let frozen = claude.freeze();

        claude.close();
        frozen.expect("a connection between two turns can be frozen")
    });

    assert_eq!(frozen["kind"], "claude");
    assert!(frozen["agent"]["pid"].as_i64().unwrap() > 1, "{}", frozen["agent"]);
    assert_eq!(Connection::descriptors(&frozen).len(), 2, "its two pipes are the ones the worker keeps open");
    assert!(frozen["stream"]["thread"].as_str().unwrap().starts_with("claude:"));
    assert!(!frozen.to_string().contains(SECRET), "the environment stays out of the manifest");
}

#[test]
fn refuses_to_freeze_a_claude_turn_under_way_and_freezes_once_it_ended() {
    let (during, after) = run(async {
        let (claude, mut incoming) = ClaudeConnection::start(options(replay("claude-turn.jsonl"), None)).await.unwrap();
        claude.request("thread/start", json!({"approvalPolicy": "on-request"}), TIMEOUT).await.unwrap();
        claude.request("model/list", json!({}), TIMEOUT).await.unwrap();
        claude.request("turn/start", recorded_prompt(), TIMEOUT).await.unwrap();

        let during = claude.freeze();
        turn(&mut incoming).await;
        // As the worker does: asked again until the last lines of the turn are read.
        let after = tokio::time::timeout(TIMEOUT, async {
            while claude.freeze().is_none() {
                tokio::time::sleep(POLL).await;
            }
        });
        let after = after.await.is_ok();

        claude.close();
        (during, after)
    });

    assert_eq!(during, None);
    assert!(after);
}

#[test]
fn an_adopted_claude_connection_runs_its_next_turn_on_the_process_it_was_given() {
    let (threads, models, seen) = run(async {
        let (first, _incoming) = ClaudeConnection::start(options(vec![NO_CLAUDE.to_owned()], None)).await.unwrap();
        first.request("thread/start", json!({"approvalPolicy": "on-request"}), TIMEOUT).await.unwrap();
        let mut frozen = first.freeze().expect("a connection that started no process can be frozen");
        first.close();
        let command = replay("claude-turn.jsonl");
        let mut child = Command::new(&command[0]).args(&command[1..]).stdin(Stdio::piped()).stdout(Stdio::piped()).process_group(0).spawn().unwrap();
        let (input, output) = (child.stdin.take().unwrap().into_raw_fd(), child.stdout.take().unwrap().into_raw_fd());
        frozen["agent"] = json!({"pid": child.id(), "input": input, "output": output, "leftover": ""});
        // The process is the adopter's to reap, as after an exec.
        std::mem::forget(child);

        let (claude, mut incoming) = ClaudeConnection::adopt(&frozen, None).unwrap();
        let threads = (first.thread(), claude.thread());
        let connection = Connection::Claude(claude);
        let models = connection.request("model/list", json!({}), TIMEOUT).await.unwrap();
        connection.request("turn/start", recorded_prompt(), TIMEOUT).await.unwrap();
        let seen = turn(&mut incoming).await;

        connection.close();
        (threads, models, seen)
    });

    assert_eq!(threads.0, threads.1, "the conversation is the one that was frozen");
    assert!(!models["data"].as_array().unwrap().is_empty(), "{models}");
    ends_like_every_provider(&steps(&seen));
}

#[test]
fn refuses_to_adopt_a_claude_connection_without_its_conversation() {
    let refused = run(async { ClaudeConnection::adopt(&json!({"kind": "claude", "agent": null, "cwd": "/tmp", "mode": "ask"}), None).map(drop) });

    assert_eq!(refused.unwrap_err().kind(), std::io::ErrorKind::InvalidData);
}

#[test]
fn a_line_reader_freezes_with_the_line_its_agent_has_not_finished() {
    let (first, frozen) = run(async {
        let script = r#"printf '%s\n%s' '{"type":"system"}' '{"type":"resu'; sleep 30"#;
        let command = ["/bin/sh".to_owned(), "-c".to_owned(), script.to_owned()];
        let (process, mut lines) = Lines::spawn(Launch { command: &command, cwd: Path::new("/tmp"), environment: None, log: None }).unwrap();
        let first = line(&mut lines).await;

        let frozen = process.freeze();

        process.close(libc::SIGTERM);
        (first, frozen.expect("a running agent with nothing left to write can be frozen"))
    });

    assert!(matches!(&first, Line::Message(message) if message["type"] == "system"), "{first:?}");
    assert_eq!(BASE64.decode(frozen["leftover"].as_str().unwrap()).unwrap(), br#"{"type":"resu"#);
}

#[test]
fn an_adopted_line_reader_goes_on_from_the_unfinished_line_to_the_agent_s_exit() {
    let script = r#"printf '%s\n' 'tem"}'; read line; printf '%s\n' "$line"; exit 7"#;
    let mut child = Command::new("/bin/sh").args(["-c", script]).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    let (input, output) = (child.stdin.take().unwrap().into_raw_fd(), child.stdout.take().unwrap().into_raw_fd());
    let state = json!({"pid": child.id(), "input": input, "output": output, "leftover": BASE64.encode(br#"{"type":"sys"#)});
    std::mem::forget(child);

    let (first, echoed, end) = run(async {
        let (process, mut lines) = Lines::adopt(&state).unwrap();
        let first = line(&mut lines).await;
        process.send(json!({"type": "user"}).as_object().unwrap()).unwrap();
        (first, line(&mut lines).await, line(&mut lines).await)
    });

    assert!(matches!(&first, Line::Message(message) if message["type"] == "system"), "the bytes read before the exec and the ones after make one line: {first:?}");
    assert!(matches!(&echoed, Line::Message(message) if message["type"] == "user"), "{echoed:?}");
    assert!(matches!(&end, Line::Exited { crash, .. } if crash["reason"] == "exited with code 7"), "{end:?}");
}
