//! An agent kept across an exec of its worker: what `freeze` hands over, and how `adopt` goes on from it. The exec
//! itself is the worker's (`vcx-worker/tests/swap.rs`); here the two ends are tried on their own.

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use std::os::fd::IntoRawFd;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;
use vcx_agents::{Agent, Inbound, Incoming};

const WAIT: Duration = Duration::from_secs(20);
const NEXT_REQUEST: i64 = 5;

fn local<F: std::future::Future>(future: F) -> F::Output {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    tokio::task::LocalSet::new().block_on(&runtime, future)
}

fn shell(script: &str) -> Vec<String> {
    vec!["/bin/sh".to_owned(), "-c".to_owned(), script.to_owned()]
}

fn method(message: Option<Incoming>) -> String {
    match message {
        Some(Incoming::Message(Inbound::Event(event))) => event.method().to_owned(),
        other => panic!("expected an event, got {other:?}"),
    }
}

#[test]
fn freezes_with_the_line_the_agent_has_not_finished() {
    let (first, frozen) = local(async {
        let script = r#"printf '%s\n%s' '{"method":"turn/started","params":{}}' '{"method":"turn/comp'; sleep 30"#;
        let (agent, mut incoming) = Agent::spawn(&shell(script), Path::new("/tmp"), Stdio::null()).unwrap();
        let first = method(tokio::time::timeout(WAIT, incoming.recv()).await.unwrap());

        let frozen = agent.freeze();

        agent.close();
        (first, frozen.expect("an agent with no request in flight can be frozen"))
    });

    assert_eq!(first, "turn/started");
    assert_eq!(BASE64.decode(frozen["leftover"].as_str().unwrap()).unwrap(), br#"{"method":"turn/comp"#);
    assert!(frozen["pid"].as_i64().unwrap() > 1 && frozen["input"] != frozen["output"], "{frozen}");
}

#[test]
fn refuses_to_freeze_while_a_request_waits_for_its_answer() {
    let frozen = local(async {
        let (agent, _incoming) = Agent::spawn(&shell("sleep 30"), Path::new("/tmp"), Stdio::null()).unwrap();
        let asking = agent.clone();
        tokio::task::spawn_local(async move { asking.request("thread/start", json!({}), WAIT).await });
        tokio::task::yield_now().await;

        let frozen = agent.freeze();

        agent.close();
        frozen
    });

    assert_eq!(frozen, None);
}

#[test]
fn an_adopted_agent_goes_on_from_the_unfinished_line_to_its_exit() {
    let script = r#"printf '%s\n' 'rted","params":{}}'; read line; case "$line" in *'"id":5'*) printf '%s\n' '{"id":5,"result":{"asked":true}}';; esac; exit 7"#;
    let mut child = Command::new("/bin/sh").args(["-c", script]).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    let (input, output) = (child.stdin.take().unwrap().into_raw_fd(), child.stdout.take().unwrap().into_raw_fd());
    let state = json!({"pid": child.id(), "input": input, "output": output, "next": NEXT_REQUEST, "leftover": BASE64.encode(br#"{"method":"turn/sta"#)});
    // The agent is the adopter's to reap, as after an exec.
    std::mem::forget(child);

    let (first, answer, end) = local(async {
        let (agent, mut incoming) = Agent::adopt(&state).unwrap();
        let first = method(tokio::time::timeout(WAIT, incoming.recv()).await.unwrap());
        let answer = agent.request("thread/read", json!({}), WAIT).await;
        let end = tokio::time::timeout(WAIT, incoming.recv()).await.unwrap();
        (first, answer, end)
    });

    assert_eq!(first, "turn/started", "the bytes read before the exec and the ones after make one line");
    assert_eq!(answer.unwrap(), json!({"asked": true}), "request ids go on where the previous image stopped");
    assert!(matches!(end, Some(Incoming::Exited { ref reason }) if reason == "The agent exited with status 7."), "{end:?}");
}

#[test]
fn refuses_to_adopt_a_state_that_names_no_pipes() {
    let refused = local(async { Agent::adopt(&json!({"pid": 4242, "next": 1, "leftover": ""})).map(drop) });

    assert_eq!(refused.unwrap_err().kind(), std::io::ErrorKind::InvalidData);
}

#[test]
fn a_frozen_state_is_plain_json() {
    let frozen = local(async {
        let (agent, _incoming) = Agent::spawn(&shell("sleep 30"), Path::new("/tmp"), Stdio::null()).unwrap();
        let frozen = agent.freeze();
        agent.close();
        frozen.unwrap()
    });

    let read_back: Value = serde_json::from_str(&frozen.to_string()).unwrap();
    assert_eq!(read_back["next"], 1);
    assert_eq!(read_back["leftover"], "");
}
