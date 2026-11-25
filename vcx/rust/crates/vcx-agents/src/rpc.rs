//! An agent process spoken to over stdio, one JSON message per line, as the Swift `RPC` and `ProviderJSONReader` do.
//! Everything here runs on the caller's thread: it must be used inside a tokio `LocalSet`.

use crate::codex::{self, Inbound};
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::io;
use std::path::Path;
use std::process::Stdio;
use std::rc::Rc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{mpsc, oneshot};

/// The longest line read from an agent, as the Swift reader bounds it.
pub const MAX_LINE_BYTES: usize = 64 * 1024 * 1024;
/// A stopped agent gets this long after SIGTERM before its process group is killed.
const STOP_GRACE: Duration = Duration::from_secs(2);
/// JSON-RPC "method not found", the code a declined request is answered with.
pub const METHOD_NOT_FOUND: i64 = -32601;

#[derive(Debug, Clone, PartialEq)]
pub struct AgentError {
    pub message: String,
    pub code: Option<i64>,
}

impl AgentError {
    fn new(message: impl Into<String>) -> Self {
        Self { message: message.into(), code: None }
    }
}

impl std::fmt::Display for AgentError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

/// What the agent sends that is no answer to a request of ours, then once its end.
#[derive(Debug)]
pub enum Incoming {
    Message(Inbound),
    Exited { reason: String },
}

type Waiter = oneshot::Sender<Result<Value, AgentError>>;

struct Inner {
    writer: RefCell<Option<mpsc::UnboundedSender<Vec<u8>>>>,
    pending: RefCell<HashMap<i64, Waiter>>,
    next: Cell<i64>,
    group: Option<i32>,
    closed: Cell<bool>,
    exited: Cell<bool>,
}

#[derive(Clone)]
pub struct Agent {
    inner: Rc<Inner>,
}

impl Agent {
    /// Starts `command` in `cwd` in a process group of its own, so stopping it stops what it started.
    pub fn spawn(command: &[String], cwd: &Path, log: Stdio) -> io::Result<(Self, mpsc::UnboundedReceiver<Incoming>)> {
        let (program, arguments) = command.split_first().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "The agent command is empty."))?;
        let mut child = Command::new(program)
            .args(arguments)
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(log)
            .process_group(0)
            .kill_on_drop(true)
            .spawn()?;
        let (stdin, stdout) = (child.stdin.take().expect("piped stdin"), child.stdout.take().expect("piped stdout"));
        let group = child.id().and_then(|pid| i32::try_from(pid).ok());
        let (writer, queue) = mpsc::unbounded_channel();
        let inner = Rc::new(Inner { writer: RefCell::new(Some(writer)), pending: RefCell::default(), next: Cell::new(1), group, closed: Cell::new(false), exited: Cell::new(false) });
        let (events, incoming) = mpsc::unbounded_channel();
        tokio::task::spawn_local(write(stdin, queue));
        tokio::task::spawn_local(read(Rc::clone(&inner), stdout, child, events));
        Ok((Self { inner }, incoming))
    }

    pub async fn request(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, AgentError> {
        let id = self.inner.next.replace(self.inner.next.get() + 1);
        let (waiter, answer) = oneshot::channel();
        self.inner.pending.borrow_mut().insert(id, waiter);
        if let Err(error) = self.send(&json!({"id": id, "method": method, "params": params})) {
            self.inner.pending.borrow_mut().remove(&id);
            return Err(error);
        }
        match tokio::time::timeout(timeout, answer).await {
            Ok(Ok(outcome)) => outcome,
            Ok(Err(_)) => Err(AgentError::new("The agent disconnected.")),
            Err(_) => {
                self.inner.pending.borrow_mut().remove(&id);
                Err(AgentError::new(format!("The agent did not answer {method} in time.")))
            }
        }
    }

    pub fn notify(&self, method: &str, params: Option<Value>) -> Result<(), AgentError> {
        let mut message = json!({"method": method});
        if let Some(params) = params {
            message["params"] = params;
        }
        self.send(&message)
    }

    /// Answers a request the agent sent, with the id exactly as it came (a number stays a number).
    pub fn respond(&self, id: &Value, result: Value) -> Result<(), AgentError> {
        self.send(&json!({"id": id, "result": result}))
    }

    pub fn reject(&self, id: &Value, code: i64, message: &str) -> Result<(), AgentError> {
        self.send(&json!({"id": id, "error": {"code": code, "message": message}}))
    }

    pub fn is_closed(&self) -> bool {
        self.inner.closed.get()
    }

    /// Ends the agent: its input closes, its group gets SIGTERM, then SIGKILL after a grace.
    pub fn close(&self) {
        if self.inner.closed.replace(true) {
            return;
        }
        self.inner.writer.borrow_mut().take();
        fail_pending(&self.inner, "The agent was stopped.");
        if let Some(group) = self.inner.group {
            unsafe { libc::kill(-group, libc::SIGTERM) };
            let inner = Rc::clone(&self.inner);
            tokio::task::spawn_local(async move {
                tokio::time::sleep(STOP_GRACE).await;
                if !inner.exited.get() {
                    unsafe { libc::kill(-group, libc::SIGKILL) };
                }
            });
        }
    }

    fn send(&self, message: &Value) -> Result<(), AgentError> {
        let mut line = serde_json::to_vec(message).map_err(|error| AgentError::new(error.to_string()))?;
        line.push(b'\n');
        let writer = self.inner.writer.borrow();
        let sent = writer.as_ref().is_some_and(|writer| writer.send(line).is_ok());
        if sent { Ok(()) } else { Err(AgentError::new("The agent is not running.")) }
    }
}

fn fail_pending(inner: &Inner, message: &str) {
    for (_, waiter) in inner.pending.borrow_mut().drain() {
        let _ = waiter.send(Err(AgentError::new(message)));
    }
}

async fn write(mut stdin: ChildStdin, mut queue: mpsc::UnboundedReceiver<Vec<u8>>) {
    while let Some(line) = queue.recv().await {
        if stdin.write_all(&line).await.is_err() || stdin.flush().await.is_err() {
            return;
        }
    }
}

async fn read(inner: Rc<Inner>, stdout: ChildStdout, mut child: Child, events: mpsc::UnboundedSender<Incoming>) {
    let mut reader = BufReader::new(stdout);
    let mut line = Vec::new();
    let reason = loop {
        line.clear();
        match (&mut reader).take(MAX_LINE_BYTES as u64 + 1).read_until(b'\n', &mut line).await {
            Ok(0) => break None,
            Ok(_) if line.last() != Some(&b'\n') && line.len() > MAX_LINE_BYTES => break Some("The agent sent a line over the size limit.".to_owned()),
            Ok(_) => {}
            Err(error) => break Some(format!("Cannot read the agent: {error}")),
        }
        let text = line.strip_suffix(b"\n").unwrap_or(&line);
        if text.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        match codex::parse_line(text) {
            Inbound::Response { id, outcome } => {
                let waiter = id.as_i64().and_then(|id| inner.pending.borrow_mut().remove(&id));
                if let Some(waiter) = waiter {
                    let _ = waiter.send(outcome.map_err(|error| AgentError { message: error.message, code: Some(error.code) }));
                }
            }
            other => drop(events.send(Incoming::Message(other))),
        }
    };
    let stopped = inner.closed.replace(true);
    inner.writer.borrow_mut().take();
    fail_pending(&inner, "The agent disconnected.");
    if reason.is_some() || stopped {
        if let Some(group) = inner.group {
            unsafe { libc::kill(-group, libc::SIGTERM) };
        }
    }
    let status = match tokio::time::timeout(STOP_GRACE, child.wait()).await {
        Ok(status) => status.ok(),
        Err(_) => {
            if let Some(group) = inner.group {
                unsafe { libc::kill(-group, libc::SIGKILL) };
            }
            child.wait().await.ok()
        }
    };
    inner.exited.set(true);
    let reason = reason.unwrap_or_else(|| match status.and_then(|status| status.code()) {
        Some(0) => "The agent exited.".to_owned(),
        Some(code) => format!("The agent exited with status {code}."),
        None => "The agent was stopped by a signal.".to_owned(),
    });
    let _ = events.send(Incoming::Exited { reason });
}

