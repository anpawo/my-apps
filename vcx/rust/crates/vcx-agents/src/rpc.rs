//! An agent process spoken to over stdio, one JSON message per line, as the Swift `RPC` and `ProviderJSONReader` do.
//! Everything here runs on the caller's thread: it must be used inside a tokio `LocalSet`.
//!
//! A worker that execs a newer build of itself keeps its agents: `freeze` says what the next image needs (the pid,
//! the two pipes, the bytes read and not yet parsed) and `adopt` goes on from there, as `RuntimeSwap.swift` does.

use crate::codex::{self, Inbound};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;
use std::process::Stdio;
use std::rc::Rc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::unix::pipe;
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

/// The longest line read from an agent, as the Swift reader bounds it.
pub const MAX_LINE_BYTES: usize = 64 * 1024 * 1024;
/// A stopped agent gets this long after SIGTERM before its process group is killed.
const STOP_GRACE: Duration = Duration::from_secs(2);
/// JSON-RPC "method not found", the code a declined request is answered with.
pub const METHOD_NOT_FOUND: i64 = -32601;
const READ_CHUNK: usize = 64 * 1024;
const OVER_THE_LIMIT: &str = "The agent sent a line over the size limit.";

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
    /// The agent's stdin and stdout as this process holds them.
    pipes: (RawFd, RawFd),
    /// Bytes read from the agent that are no whole line yet. Here and not in the reader task, so a freeze sees them.
    unparsed: RefCell<Vec<u8>>,
    /// Lines handed to the writer that are not in the agent's pipe yet.
    unwritten: Rc<Cell<usize>>,
}

/// The agent's process: started by this image, or inherited from the image that exec'ed this one.
enum Process {
    Spawned(Child),
    Adopted { pid: i32, reaping: Option<JoinHandle<Option<i32>>> },
}

impl Process {
    /// The exit code, or `None` for an agent ended by a signal. Asked again after a timeout, it goes on waiting.
    async fn wait(&mut self) -> Option<i32> {
        match self {
            Self::Spawned(child) => child.wait().await.ok().and_then(|status| status.code()),
            Self::Adopted { pid, reaping } => {
                let pid = *pid;
                reaping.get_or_insert_with(|| tokio::task::spawn_blocking(move || reap(pid))).await.ok().flatten()
            }
        }
    }
}

/// Tokio cannot watch a child it did not start: a thread waits for it.
fn reap(pid: i32) -> Option<i32> {
    let mut status = 0;
    loop {
        // SAFETY: `waitpid` writes one int; the pid is a child this process kept through its exec.
        let reaped = unsafe { libc::waitpid(pid, &mut status, 0) };
        if reaped == pid {
            return libc::WIFEXITED(status).then(|| libc::WEXITSTATUS(status));
        }
        if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return None;
        }
    }
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
        let pipes = (stdin.as_raw_fd(), stdout.as_raw_fd());
        Ok(Self::start(group, pipes, 1, Vec::new(), stdin, stdout, Process::Spawned(child)))
    }

    fn start(group: Option<i32>, pipes: (RawFd, RawFd), next: i64, unparsed: Vec<u8>, stdin: impl AsyncWrite + Unpin + 'static, stdout: impl AsyncRead + Unpin + 'static, process: Process) -> (Self, mpsc::UnboundedReceiver<Incoming>) {
        let (writer, queue) = mpsc::unbounded_channel();
        let inner = Rc::new(Inner {
            writer: RefCell::new(Some(writer)),
            pending: RefCell::default(),
            next: Cell::new(next),
            group,
            closed: Cell::new(false),
            exited: Cell::new(false),
            pipes,
            unparsed: RefCell::new(unparsed),
            unwritten: Rc::default(),
        });
        let (events, incoming) = mpsc::unbounded_channel();
        tokio::task::spawn_local(write(Rc::clone(&inner.unwritten), stdin, queue));
        tokio::task::spawn_local(read(Rc::clone(&inner), stdout, process, events));
        (Self { inner }, incoming)
    }

    /// What another image of this process needs to go on with the agent, or `None` while a request waits for its
    /// answer or a line for its place in the pipe: neither survives an exec. Nothing changes here, so the caller
    /// either execs before anything else runs, or goes on as if it had not asked.
    pub fn freeze(&self) -> Option<Value> {
        let inner = &self.inner;
        let (pid, (input, output)) = (inner.group?, inner.pipes);
        if inner.closed.get() || !inner.pending.borrow().is_empty() || inner.unwritten.get() > 0 {
            return None;
        }
        Some(json!({"pid": pid, "input": input, "output": output, "next": inner.next.get(), "leftover": BASE64.encode(&*inner.unparsed.borrow())}))
    }

    /// The two pipes a frozen state names.
    pub fn descriptors(state: &Value) -> Vec<RawFd> {
        ["input", "output"].iter().filter_map(|key| state[*key].as_i64().and_then(|value| RawFd::try_from(value).ok())).collect()
    }

    /// Goes on with an agent a previous image of this process froze. The descriptors are taken over whether or not
    /// this succeeds: on an error they are closed, and the agent ends on its closed pipes.
    pub fn adopt(state: &Value) -> io::Result<(Self, mpsc::UnboundedReceiver<Incoming>)> {
        let invalid = || io::Error::new(io::ErrorKind::InvalidData, "Invalid adopted agent.");
        let number = |key: &str| state[key].as_i64().and_then(|value| i32::try_from(value).ok()).filter(|value| *value > 2);
        let (input, output) = (number("input").ok_or_else(invalid)?, number("output").ok_or_else(invalid)?);
        // SAFETY: the previous image left these two descriptors open for this one alone, and nothing else here owns them.
        let (stdin, stdout) = unsafe { (OwnedFd::from_raw_fd(input), OwnedFd::from_raw_fd(output)) };
        for descriptor in [input, output] {
            // SAFETY: both descriptors are open; a later exec must not hand them to a child by accident.
            unsafe { libc::fcntl(descriptor, libc::F_SETFD, libc::FD_CLOEXEC) };
        }
        let pid = number("pid").ok_or_else(invalid)?;
        let next = state["next"].as_i64().filter(|next| *next > 0).ok_or_else(invalid)?;
        let leftover = state["leftover"].as_str().and_then(|text| BASE64.decode(text).ok()).ok_or_else(invalid)?;
        let (stdin, stdout) = (pipe::Sender::from_owned_fd(stdin)?, pipe::Receiver::from_owned_fd(stdout)?);
        Ok(Self::start(Some(pid), (input, output), next, leftover, stdin, stdout, Process::Adopted { pid, reaping: None }))
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
        if !sent {
            return Err(AgentError::new("The agent is not running."));
        }
        self.inner.unwritten.set(self.inner.unwritten.get() + 1);
        Ok(())
    }
}

fn fail_pending(inner: &Inner, message: &str) {
    for (_, waiter) in inner.pending.borrow_mut().drain() {
        let _ = waiter.send(Err(AgentError::new(message)));
    }
}

async fn write(unwritten: Rc<Cell<usize>>, mut stdin: impl AsyncWrite + Unpin, mut queue: mpsc::UnboundedReceiver<Vec<u8>>) {
    while let Some(line) = queue.recv().await {
        if stdin.write_all(&line).await.is_err() || stdin.flush().await.is_err() {
            return;
        }
        unwritten.set(unwritten.get() - 1);
    }
}

/// One line of the agent: an answer goes to the request that waits for it, anything else to the session.
fn deliver(inner: &Inner, events: &mpsc::UnboundedSender<Incoming>, text: &[u8]) {
    if text.iter().all(u8::is_ascii_whitespace) {
        return;
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
}

/// Hands on every whole line received and keeps the unfinished one.
fn deliver_lines(inner: &Inner, events: &mpsc::UnboundedSender<Incoming>) {
    let mut received = std::mem::take(&mut *inner.unparsed.borrow_mut());
    let mut start = 0;
    while let Some(length) = received[start..].iter().position(|byte| *byte == b'\n') {
        deliver(inner, events, &received[start..start + length]);
        start += length + 1;
    }
    received.drain(..start);
    *inner.unparsed.borrow_mut() = received;
}

async fn read(inner: Rc<Inner>, mut stdout: impl AsyncRead + Unpin, mut process: Process, events: mpsc::UnboundedSender<Incoming>) {
    let mut chunk = vec![0; READ_CHUNK];
    // An adopted agent may come with whole lines its previous reader had not parsed.
    let mut ended_a_line = true;
    let reason = loop {
        if ended_a_line {
            deliver_lines(&inner, &events);
        }
        if inner.unparsed.borrow().len() > MAX_LINE_BYTES {
            break Some(OVER_THE_LIMIT.to_owned());
        }
        match stdout.read(&mut chunk).await {
            Ok(0) => {
                let last = std::mem::take(&mut *inner.unparsed.borrow_mut());
                deliver(&inner, &events, &last);
                break None;
            }
            Ok(count) => {
                ended_a_line = chunk[..count].contains(&b'\n');
                inner.unparsed.borrow_mut().extend_from_slice(&chunk[..count]);
            }
            Err(error) => break Some(format!("Cannot read the agent: {error}")),
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
    let code = match tokio::time::timeout(STOP_GRACE, process.wait()).await {
        Ok(code) => code,
        Err(_) => {
            if let Some(group) = inner.group {
                unsafe { libc::kill(-group, libc::SIGKILL) };
            }
            process.wait().await
        }
    };
    inner.exited.set(true);
    let reason = reason.unwrap_or_else(|| match code {
        Some(0) => "The agent exited.".to_owned(),
        Some(code) => format!("The agent exited with status {code}."),
        None => "The agent was stopped by a signal.".to_owned(),
    });
    let _ = events.send(Incoming::Exited { reason });
}

