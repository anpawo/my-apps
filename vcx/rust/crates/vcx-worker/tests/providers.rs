//! A session on each provider the adapters speak, run end to end through the worker: Claude and agy replay their
//! recorded turn, Qwen talks to a fake Ollama behind a fake SOCKS5 proxy. No real agent runs and nothing of his is read.

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, answered, prompt};
use vcx_model::SessionState;
use vcx_testkit::RustWorker;

const PROMPT: &str = "Run the shell command `echo vcx` once, then reply with the single word: done.";
const SOCKS_GREETING: [u8; 3] = [5, 1, 0];
const SOCKS_CHOSEN: [u8; 2] = [5, 0];
const SOCKS_CONNECTED: [u8; 10] = [5, 0, 0, 1, 0, 0, 0, 0, 0, 0];
const SOCKS_HEAD: usize = 5;
const SOCKS_PORT: usize = 2;

fn streams() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/streams").canonicalize().unwrap()
}

fn replay(name: &str) -> Vec<String> {
    let streams = streams();
    ["/usr/bin/python3", "-I"].into_iter().map(str::to_owned).chain([streams.join("replay.py"), streams.join(name)].map(|path| path.to_string_lossy().into_owned())).collect()
}

fn worker(name: &str, provider: &str, command: &[String], settings: Value) -> RustWorker {
    RustWorker::start_provider(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name, provider, command, &settings)
}

fn target(worker: &RustWorker) -> Target {
    Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() }
}

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

fn permissions(state: &SessionState) -> Vec<Value> {
    meta(state, "permissions").as_array().cloned().unwrap_or_default()
}

/// Waits for the catalog (Claude reads it from the same process the turn runs in), sends the prompt and accepts
/// whatever the agent asks until it answers.
fn run_turn(held: &mut Held) {
    held.follow(|state| meta(state, "ready") == &json!(true) && meta(state, "models").as_array().is_some_and(|models| !models.is_empty()));
    held.lease.perform(&held.peer.client, "send", prompt(PROMPT)).expect("the worker takes the prompt");
    loop {
        held.follow(|state| answered(state) || !permissions(state).is_empty());
        let Some(asked) = permissions(held.replica.state().unwrap()).first().cloned() else { return };
        let answer = json!({"rpcID": asked["rpcID"], "method": asked["method"], "result": {"decision": "accept"}});
        held.lease.perform(&held.peer.client, "answer", answer).expect("the worker takes the answer");
    }
}

fn assert_ran(held: &Held, label: &str, provider: &str) {
    let state = held.replica.state().unwrap();
    assert_eq!(meta(state, "providerLabel"), label);
    assert_eq!(meta(state, "account")["provider"], provider);
    assert!(meta(state, "threadID").as_str().is_some_and(|thread| thread.starts_with(&format!("{provider}:"))), "{:?}", meta(state, "threadID"));
    let kinds = held.turn_kinds();
    assert_eq!(kinds.first().map(String::as_str), Some("user"), "{kinds:?}");
    assert!(kinds.iter().any(|kind| kind == "assistant"), "{kinds:?}");
}

#[test]
fn runs_a_replayed_claude_turn_through_the_worker() {
    let worker = worker("claude", "claude", &replay("claude-turn.jsonl"), json!({}));
    let mut held = Held::open(&target(&worker));

    run_turn(&mut held);

    assert_ran(&held, "Claude", "claude");
}

#[test]
fn runs_a_replayed_agy_turn_through_the_worker() {
    let worker = worker("agy", "agy", &replay("agy-turn.jsonl"), json!({}));
    let mut held = Held::open(&target(&worker));

    run_turn(&mut held);

    assert_ran(&held, "Antigravity", "agy");
}

#[test]
fn runs_a_qwen_turn_through_the_proxy_his_settings_name() {
    let ollama = Ollama::serve(answers("qwen-turn.jsonl"));
    let settings = json!({"qwenURL": "http://pc.fixture:11434/api/chat", "qwenProxy": format!("socks5h://{}", ollama.address)});
    let worker = worker("qwen", "qwen", &[], settings);
    let mut held = Held::open(&target(&worker));

    run_turn(&mut held);

    assert_ran(&held, "Qwen", "qwen");
    assert_eq!(ollama.requests(), 2, "one model step before the command, one after");
}

/// The recording's answers, one per request: the lines Ollama sent after each one the client sent.
fn answers(name: &str) -> Vec<Vec<String>> {
    let mut answers: Vec<Vec<String>> = Vec::new();
    for line in std::fs::read_to_string(streams().join(name)).unwrap().lines() {
        let record: Value = serde_json::from_str(line).unwrap();
        match record["dir"].as_str() {
            Some("send") => answers.push(Vec::new()),
            _ => answers.last_mut().unwrap().push(record["message"].to_string()),
        }
    }
    answers
}

/// A local server that takes each connection's SOCKS5 CONNECT, then answers its `/api/chat` with the next
/// recorded answer, chunked as Ollama streams it.
struct Ollama {
    address: String,
    served: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

impl Ollama {
    fn serve(answers: Vec<Vec<String>>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap().to_string();
        let served = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = std::sync::Arc::clone(&served);
        std::thread::spawn(move || {
            for answer in answers {
                let Ok((mut stream, _)) = listener.accept() else { return };
                socks(&mut stream);
                read_request(&mut stream);
                counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n").unwrap();
                for line in answer {
                    stream.write_all(format!("{:x}\r\n{line}\n\r\n", line.len() + 1).as_bytes()).unwrap();
                }
                stream.write_all(b"0\r\n\r\n").unwrap();
            }
        });
        Ollama { address, served }
    }

    fn requests(&self) -> usize {
        self.served.load(std::sync::atomic::Ordering::SeqCst)
    }
}

fn socks(stream: &mut TcpStream) {
    let mut greeting = [0u8; 3];
    stream.read_exact(&mut greeting).unwrap();
    assert_eq!(greeting, SOCKS_GREETING, "the worker goes through the proxy his settings name");
    stream.write_all(&SOCKS_CHOSEN).unwrap();
    let mut head = [0u8; SOCKS_HEAD];
    stream.read_exact(&mut head).unwrap();
    let mut rest = vec![0u8; usize::from(head[SOCKS_HEAD - 1]) + SOCKS_PORT];
    stream.read_exact(&mut rest).unwrap();
    stream.write_all(&SOCKS_CONNECTED).unwrap();
}

fn read_request(stream: &mut TcpStream) {
    let mut reader = BufReader::new(stream);
    let mut length = 0;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        if line == "\r\n" {
            break;
        }
        if let Some(value) = line.strip_prefix("Content-Length: ") {
            length = value.trim().parse().unwrap();
        }
    }
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body).unwrap();
}
