//! A fake Ollama behind a fake SOCKS5 proxy, for the tests that run Qwen.
// Each test file compiles this module on its own and uses only part of it.
#![allow(dead_code)]

use serde_json::Value;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const SOCKS_GREETING: [u8; 3] = [5, 1, 0];
const SOCKS_CHOSEN: [u8; 2] = [5, 0];
const SOCKS_CONNECTED: [u8; 10] = [5, 0, 0, 1, 0, 0, 0, 0, 0, 0];
const SOCKS_HEAD: usize = 5;
const SOCKS_PORT: usize = 2;

pub fn streams() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/streams").canonicalize().unwrap()
}

/// The recording's answers, one per request: the lines Ollama sent after each one the client sent.
pub fn answers(name: &str) -> Vec<Vec<String>> {
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
pub struct Ollama {
    pub address: String,
    bodies: Arc<Mutex<Vec<String>>>,
}

impl Ollama {
    pub fn serve(answers: Vec<Vec<String>>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap().to_string();
        let bodies = Arc::new(Mutex::new(Vec::new()));
        let received = Arc::clone(&bodies);
        std::thread::spawn(move || {
            for answer in answers {
                let Ok((mut stream, _)) = listener.accept() else { return };
                socks(&mut stream);
                let body = read_request(&mut stream);
                received.lock().unwrap().push(body);
                stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n").unwrap();
                for line in answer {
                    stream.write_all(format!("{:x}\r\n{line}\n\r\n", line.len() + 1).as_bytes()).unwrap();
                }
                stream.write_all(b"0\r\n\r\n").unwrap();
            }
        });
        Ollama { address, bodies }
    }

    pub fn requests(&self) -> usize {
        self.bodies.lock().unwrap().len()
    }

    /// The request bodies received so far, in order.
    pub fn bodies(&self) -> Vec<String> {
        self.bodies.lock().unwrap().clone()
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

fn read_request(stream: &mut TcpStream) -> String {
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
    String::from_utf8_lossy(&body).into_owned()
}
