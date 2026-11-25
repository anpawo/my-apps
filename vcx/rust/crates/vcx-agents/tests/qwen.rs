//! Qwen against a fake Ollama (a local server answering each `/api/chat` with the next answer of a hand-written stream,
//! behind a fake SOCKS5 proxy), the way the worker drives it: requests in, typed events out, until the turn ends.

mod common;

use common::*;
use serde_json::{Value, json};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::UnboundedReceiver;
use vcx_agents::qwen::{QwenConnection, QwenOptions, STEP_LIMIT};
use vcx_agents::{Connection, Inbound, Incoming, Kind, TurnStatus};

const TIMEOUT: Duration = Duration::from_secs(20);

fn run<F: std::future::Future>(test: F) -> F::Output {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    tokio::task::LocalSet::new().block_on(&runtime, test)
}

/// The answers of a recording, one per request: the agent's lines after each line the client sent.
fn answers(name: &str) -> Vec<Vec<String>> {
    let mut answers: Vec<Vec<String>> = Vec::new();
    for (dir, message) in recording(name) {
        match dir.as_str() {
            "send" => answers.push(Vec::new()),
            _ => answers.last_mut().unwrap().push(serde_json::to_string(&message).unwrap()),
        }
    }
    answers
}

struct Ollama {
    address: String,
    bodies: Rc<RefCell<Vec<Value>>>,
}

/// Serves each connection the next answer, chunked as Ollama streams it; `cut` closes the last one before its end.
async fn ollama(mut answers: Vec<Vec<String>>, cut: bool) -> Ollama {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap().to_string();
    let bodies = Rc::new(RefCell::new(Vec::new()));
    let seen = Rc::clone(&bodies);
    answers.reverse();
    tokio::task::spawn_local(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let Some(answer) = answers.pop() else { return };
            let last = answers.is_empty();
            socks(&mut stream).await;
            seen.borrow_mut().push(request(&mut stream).await);
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n").await.unwrap();
            let shown = if cut && last { &answer[..answer.len() - 1] } else { &answer[..] };
            for line in shown {
                stream.write_all(format!("{:x}\r\n{line}\n\r\n", line.len() + 1).as_bytes()).await.unwrap();
            }
            if !(cut && last) {
                stream.write_all(b"0\r\n\r\n").await.unwrap();
            }
        }
    });
    Ollama { address, bodies }
}

/// The SOCKS5 greeting and CONNECT a client sends first; the server then speaks HTTP itself.
async fn socks(stream: &mut TcpStream) {
    let mut greeting = [0u8; 3];
    stream.read_exact(&mut greeting).await.unwrap();
    assert_eq!(greeting, [5, 1, 0], "the client goes through the SOCKS proxy");
    stream.write_all(&[5, 0]).await.unwrap();
    let mut head = [0u8; 5];
    stream.read_exact(&mut head).await.unwrap();
    let mut rest = vec![0u8; usize::from(head[4]) + 2];
    stream.read_exact(&mut rest).await.unwrap();
    stream.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await.unwrap();
}

async fn request(stream: &mut TcpStream) -> Value {
    let mut data = Vec::new();
    let mut byte = [0u8; 1];
    while !data.ends_with(b"\r\n\r\n") {
        stream.read_exact(&mut byte).await.unwrap();
        data.push(byte[0]);
    }
    let head = String::from_utf8(data).unwrap();
    let length: usize = head.lines().find_map(|line| line.strip_prefix("Content-Length: ")).unwrap().trim().parse().unwrap();
    let mut body = vec![0u8; length];
    stream.read_exact(&mut body).await.unwrap();
    serde_json::from_slice(&body).unwrap()
}

/// A login zsh with a home of its own, so his shell profile prints nothing into the command's output.
fn options(ollama: &Ollama, mode: &str) -> QwenOptions {
    let home: PathBuf = std::env::temp_dir().join(format!("vcx-qwen-test-{}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap();
    let environment = vec![("HOME".into(), home.to_string_lossy().into_owned()), ("ZDOTDIR".into(), home.to_string_lossy().into_owned()), ("PATH".into(), "/usr/bin:/bin".into())];
    let (host, port) = ollama.address.split_once(':').unwrap();
    QwenOptions {
        url: "http://pc.fixture:11434/api/chat".into(),
        proxy: format!("socks5h://{host}:{port}"),
        model: "qwen3.5-9b-abl".into(),
        mode: mode.into(),
        cwd: "/tmp".into(),
        environment: Some(environment),
        wake: None,
        home,
        step_limit: STEP_LIMIT,
    }
}

async fn until_turn_ends(connection: &Connection, incoming: &mut UnboundedReceiver<Incoming>, accept: bool) -> (Vec<Inbound>, usize) {
    let (mut seen, mut asked) = (Vec::new(), 0);
    loop {
        let Incoming::Message(message) = tokio::time::timeout(TIMEOUT, incoming.recv()).await.expect("the turn ends in time").unwrap() else { panic!("Qwen has no process to exit") };
        if let Inbound::Request { id, .. } = &message {
            asked += 1;
            if accept {
                connection.respond(id, json!({"decision": "accept"})).unwrap();
            } else {
                connection.request("turn/interrupt", json!({}), TIMEOUT).await.unwrap();
            }
        }
        let ended = matches!(&message, Inbound::Event(event) if matches!(event.kind, Kind::TurnCompleted { .. }));
        seen.push(message);
        if ended {
            return (seen, asked);
        }
    }
}

fn input() -> Value {
    json!({"input": [{"type": "text", "text": "Run the shell command `echo vcx` once, then reply with the single word: done."}]})
}

#[test]
fn runs_a_qwen_turn_through_the_proxy_into_the_shared_steps() {
    run(async {
        let ollama = ollama(answers("qwen-turn.jsonl"), false).await;
        let (qwen, mut incoming) = QwenConnection::start(options(&ollama, "ask")).await.unwrap();
        let connection = Connection::Qwen(qwen);

        connection.request("thread/start", json!({"developerInstructions": "Fixture instructions."}), TIMEOUT).await.unwrap();
        connection.request("turn/start", input(), TIMEOUT).await.unwrap();
        let (seen, asked) = until_turn_ends(&connection, &mut incoming, true).await;

        let steps = steps(&seen);
        assert_eq!(steps.iter().filter(|step| step.starts_with("message")).collect::<Vec<_>>(), ["message: I will run it once.", "message: done"]);
        ends_like_every_provider(&steps);
        assert_eq!(asked, 1);
        let bodies = ollama.bodies.borrow();
        assert_eq!(bodies.len(), 2);
        assert!(bodies[0]["messages"][0]["content"].as_str().unwrap().ends_with("\nFixture instructions."));
        assert_eq!(bodies[0]["options"]["num_ctx"], 32768);
        assert_eq!(bodies[1]["messages"].as_array().unwrap().last().unwrap()["content"], "Exit: 0\nvcx\n");
    });
}

#[test]
fn fails_the_turn_when_the_stream_closes_before_its_final_event() {
    run(async {
        let ollama = ollama(answers("qwen-turn.jsonl")[..1].to_vec(), true).await;
        let (qwen, mut incoming) = QwenConnection::start(options(&ollama, "bypass")).await.unwrap();
        let connection = Connection::Qwen(qwen);

        connection.request("turn/start", input(), TIMEOUT).await.unwrap();
        let (seen, _) = until_turn_ends(&connection, &mut incoming, true).await;

        let Some(Inbound::Event(event)) = seen.last() else { panic!() };
        let Kind::TurnCompleted { status, error, .. } = &event.kind else { panic!() };
        assert_eq!(*status, TurnStatus::Failed);
        assert!(error.as_deref().unwrap().contains("cut off"), "{error:?}");
    });
}

#[test]
fn ends_the_turn_interrupted_when_stopped_at_a_permission() {
    run(async {
        let ollama = ollama(answers("qwen-turn.jsonl"), false).await;
        let (qwen, mut incoming) = QwenConnection::start(options(&ollama, "ask")).await.unwrap();
        let connection = Connection::Qwen(qwen);

        connection.request("turn/start", input(), TIMEOUT).await.unwrap();
        let (seen, asked) = until_turn_ends(&connection, &mut incoming, false).await;

        assert_eq!(asked, 1);
        assert_eq!(steps(&seen).last().map(String::as_str), Some("turn Interrupted"));
        assert_eq!(ollama.bodies.borrow().len(), 1, "no step runs after the stop");
    });
}
