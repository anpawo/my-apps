//! An agent process that speaks one JSON object per line but no Codex JSON-RPC (Claude's stream-json, agy's ACP): its
//! lines come out raw and the adapter reads them. Its stderr goes to a log whose tail says why it stopped, as
//! `agentLog`, `agentLogTail`, `agentCrash` and `lastErrorLine` in `RPC.swift` do. Used inside a tokio `LocalSet`.

use crate::Object;
use crate::rpc::MAX_LINE_BYTES;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{ExitStatus, Stdio};
use std::rc::Rc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::unix::pipe;
use tokio::process::{Child, Command};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

const STOP_GRACE: Duration = Duration::from_secs(2);
/// An agent log is cut back to its end past this size, as `agentLog` keeps it.
const LOG_LIMIT: u64 = 1024 * 1024;
const LOG_TAIL: u64 = 4096;
const ERROR_LINE_CHARS: usize = 300;
const READ_CHUNK: usize = 64 * 1024;

/// How a process is started: the whole environment is given (none is inherited) when `environment` is set.
pub struct Launch<'a> {
    pub command: &'a [String],
    pub cwd: &'a Path,
    pub environment: Option<&'a [(String, String)]>,
    pub log: Option<&'a Path>,
}

#[derive(Debug)]
pub enum Line {
    Message(Object),
    /// A line that is no JSON object; Claude and agy print none on purpose, so the adapters skip it.
    Invalid(String),
    /// The reader stopped on something the person should hear about (a line over the size limit).
    Failed(String),
    /// The last line: how the process ended. `crash` is empty for a TERM or HUP, the stop asked on purpose.
    Exited { crash: Object, log_tail: String },
}

/// The agent's process: started by this image, or inherited from the image that exec'ed this one.
pub(crate) enum Process {
    Spawned(Child),
    Adopted { pid: i32, reaping: Option<JoinHandle<Option<ExitStatus>>> },
}

impl Process {
    /// How it ended. Asked again after a timeout, it goes on waiting.
    pub(crate) async fn wait(&mut self) -> Option<ExitStatus> {
        match self {
            Self::Spawned(child) => child.wait().await.ok(),
            Self::Adopted { pid, reaping } => {
                let pid = *pid;
                reaping.get_or_insert_with(|| tokio::task::spawn_blocking(move || reap(pid))).await.ok().flatten()
            }
        }
    }
}

/// Tokio cannot watch a child it did not start: a thread waits for it.
fn reap(pid: i32) -> Option<ExitStatus> {
    let mut status = 0;
    loop {
        // SAFETY: `waitpid` writes one int; the pid is a child this process kept through its exec.
        let reaped = unsafe { libc::waitpid(pid, &mut status, 0) };
        if reaped == pid {
            return Some(ExitStatus::from_raw(status));
        }
        if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return None;
        }
    }
}

/// An agent a previous image of this process froze: its pid, its two pipes and the bytes of its unfinished line.
pub(crate) struct Kept {
    pub pid: i32,
    pub pipes: (RawFd, RawFd),
    pub leftover: Vec<u8>,
    pub stdin: pipe::Sender,
    pub stdout: pipe::Receiver,
}

/// The two pipes a frozen state names.
pub(crate) fn descriptors(state: &Value) -> Vec<RawFd> {
    ["input", "output"].iter().filter_map(|key| state[*key].as_i64().and_then(|value| RawFd::try_from(value).ok())).collect()
}

/// Takes over the agent a frozen state names. Its descriptors are taken over whether or not this succeeds: on an
/// error they are closed, and the agent ends on its closed pipes.
pub(crate) fn keep(state: &Value) -> io::Result<Kept> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidData, "Invalid adopted agent.");
    let number = |key: &str| state[key].as_i64().and_then(|value| i32::try_from(value).ok()).filter(|value| *value > libc::STDERR_FILENO);
    let (input, output) = (number("input").ok_or_else(invalid)?, number("output").ok_or_else(invalid)?);
    // SAFETY: the previous image left these two descriptors open for this one alone, and nothing else here owns them.
    let (stdin, stdout) = unsafe { (OwnedFd::from_raw_fd(input), OwnedFd::from_raw_fd(output)) };
    for descriptor in [input, output] {
        // SAFETY: both descriptors are open; a later exec must not hand them to a child by accident.
        unsafe { libc::fcntl(descriptor, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
    let pid = number("pid").ok_or_else(invalid)?;
    let leftover = state["leftover"].as_str().and_then(|text| BASE64.decode(text).ok()).ok_or_else(invalid)?;
    Ok(Kept { pid, pipes: (input, output), leftover, stdin: pipe::Sender::from_owned_fd(stdin)?, stdout: pipe::Receiver::from_owned_fd(stdout)? })
}

struct Inner {
    writer: RefCell<Option<mpsc::UnboundedSender<Vec<u8>>>>,
    group: Option<i32>,
    closed: Cell<bool>,
    exited: Cell<bool>,
    /// The agent's stdin and stdout as this process holds them.
    pipes: (RawFd, RawFd),
    /// Bytes read from the agent that are no whole line yet. Here and not in the reader task, so a freeze sees them.
    unparsed: RefCell<Vec<u8>>,
    /// Lines handed to the writer that are not in the agent's pipe yet.
    unwritten: Rc<Cell<usize>>,
    /// The agent's stderr and where this run starts in it.
    log: Option<(PathBuf, u64)>,
}

#[derive(Clone)]
pub struct Lines {
    inner: Rc<Inner>,
    pub pid: Option<i32>,
}

impl Lines {
    pub fn spawn(launch: Launch) -> io::Result<(Self, mpsc::UnboundedReceiver<Line>)> {
        let (program, arguments) = launch.command.split_first().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "The agent command is empty."))?;
        let mut command = Command::new(program);
        command.args(arguments).current_dir(launch.cwd).stdin(Stdio::piped()).stdout(Stdio::piped()).process_group(0).kill_on_drop(true);
        if let Some(environment) = launch.environment {
            command.env_clear().envs(environment.iter().map(|(key, value)| (key, value)));
        }
        let log = match launch.log {
            Some(path) => Some(open_log(path)?),
            None => None,
        };
        command.stderr(match &log {
            Some((file, _)) => Stdio::from(file.try_clone()?),
            None => Stdio::null(),
        });
        let mut child = command.spawn()?;
        let (stdin, stdout) = (child.stdin.take().expect("piped stdin"), child.stdout.take().expect("piped stdout"));
        let pid = child.id().and_then(|pid| i32::try_from(pid).ok());
        let pipes = (stdin.as_raw_fd(), stdout.as_raw_fd());
        let log = log.map(|(_, start)| (launch.log.unwrap().to_path_buf(), start));
        Ok(Self::start(pid, pipes, Vec::new(), log, stdin, stdout, Process::Spawned(child)))
    }

    fn start(pid: Option<i32>, pipes: (RawFd, RawFd), unparsed: Vec<u8>, log: Option<(PathBuf, u64)>, stdin: impl AsyncWrite + Unpin + 'static, stdout: impl AsyncRead + Unpin + 'static, process: Process) -> (Self, mpsc::UnboundedReceiver<Line>) {
        let (writer, queue) = mpsc::unbounded_channel();
        let inner = Rc::new(Inner {
            writer: RefCell::new(Some(writer)),
            group: pid,
            closed: Cell::new(false),
            exited: Cell::new(false),
            pipes,
            unparsed: RefCell::new(unparsed),
            unwritten: Rc::default(),
            log,
        });
        let (lines, incoming) = mpsc::unbounded_channel();
        tokio::task::spawn_local(write(Rc::clone(&inner.unwritten), stdin, queue));
        tokio::task::spawn_local(read(Rc::clone(&inner), stdout, process, lines));
        (Self { inner, pid }, incoming)
    }

    /// What another image of this process needs to go on with the agent, or `None` once it stopped or while a line
    /// waits for its place in the pipe. Nothing changes here, so the caller either execs before anything else runs,
    /// or goes on as if it had not asked.
    pub fn freeze(&self) -> Option<Value> {
        let inner = &self.inner;
        let (pid, (input, output)) = (inner.group?, inner.pipes);
        if inner.closed.get() || inner.unwritten.get() > 0 {
            return None;
        }
        let (log, log_start) = inner.log.as_ref().map(|(path, start)| (path.to_string_lossy().into_owned(), *start)).unzip();
        Some(json!({"pid": pid, "input": input, "output": output, "leftover": BASE64.encode(&*inner.unparsed.borrow()), "log": log, "logStart": log_start}))
    }

    /// Goes on with an agent a previous image of this process froze, as `keep` takes it over.
    pub fn adopt(state: &Value) -> io::Result<(Self, mpsc::UnboundedReceiver<Line>)> {
        let kept = keep(state)?;
        let log = state["log"].as_str().map(|path| (PathBuf::from(path), state["logStart"].as_u64().unwrap_or(0)));
        Ok(Self::start(Some(kept.pid), kept.pipes, kept.leftover, log, kept.stdin, kept.stdout, Process::Adopted { pid: kept.pid, reaping: None }))
    }

    pub fn send(&self, message: &Object) -> Result<(), String> {
        let mut line = serde_json::to_vec(message).map_err(|error| error.to_string())?;
        line.push(b'\n');
        let writer = self.inner.writer.borrow();
        if !writer.as_ref().is_some_and(|writer| writer.send(line).is_ok()) {
            return Err("The agent is not running.".into());
        }
        self.inner.unwritten.set(self.inner.unwritten.get() + 1);
        Ok(())
    }

    pub fn is_running(&self) -> bool {
        !self.inner.closed.get()
    }

    /// Ends the process group with `signal`, then SIGKILL after a grace.
    pub fn close(&self, signal: i32) {
        if self.inner.closed.replace(true) {
            return;
        }
        self.inner.writer.borrow_mut().take();
        let Some(group) = self.inner.group else { return };
        unsafe { libc::kill(-group, signal) };
        let inner = Rc::clone(&self.inner);
        tokio::task::spawn_local(async move {
            tokio::time::sleep(STOP_GRACE).await;
            if !inner.exited.get() {
                unsafe { libc::kill(-group, libc::SIGKILL) };
            }
        });
    }
}

/// Opens the log for appending, cut to its last part when it grew too big, and says where this run starts in it.
fn open_log(path: &Path) -> io::Result<(File, u64)> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if std::fs::metadata(path).is_ok_and(|meta| meta.len() > LOG_LIMIT) {
        let mut old = File::open(path)?;
        old.seek(SeekFrom::End(-(LOG_LIMIT as i64 / 2)))?;
        let mut kept = Vec::new();
        old.read_to_end(&mut kept)?;
        std::fs::write(path, kept)?;
    }
    let file = OpenOptions::new().create(true).append(true).open(path)?;
    let start = file.metadata()?.len();
    Ok((file, start))
}

pub fn log_tail(path: &Path, start: u64) -> String {
    let Ok(mut file) = File::open(path) else { return String::new() };
    let end = file.seek(SeekFrom::End(0)).unwrap_or(0);
    let _ = file.seek(SeekFrom::Start(start.max(end.saturating_sub(LOG_TAIL))));
    let mut bytes = Vec::new();
    let _ = file.read_to_end(&mut bytes);
    String::from_utf8_lossy(&bytes).into_owned()
}

/// The line of a log that names why the agent stopped: stack frames, Node's banner and warnings name no cause.
pub fn last_error_line(text: &str) -> Option<String> {
    let lines: Vec<&str> = text.lines().map(str::trim).filter(|line| {
        !line.is_empty() && !line.starts_with("at ") && !line.starts_with("Node.js v") && !line.starts_with("Warning:") && !line.chars().all(|c| "^~ ".contains(c))
    }).collect();
    let cause = |line: &&&str| ["error", "fatal", "failed", "exception", "panic", "abort"].iter().any(|word| line.to_lowercase().contains(word));
    let line = lines.iter().rev().find(cause).or(lines.last())?;
    Some(if line.chars().count() > ERROR_LINE_CHARS { format!("{}…", line.chars().take(ERROR_LINE_CHARS).collect::<String>()) } else { (*line).to_owned() })
}

/// Why the agent stopped; empty for the TERM or HUP that stops it on purpose (Claude catches both and exits 143 or 129).
pub fn crash(code: Option<i32>, signal: Option<i32>, tail: &str, log: Option<&Path>) -> Object {
    let on_purpose = match (code, signal) {
        (_, Some(signal)) => [libc::SIGTERM, libc::SIGHUP].contains(&signal),
        (Some(code), None) => [128 + libc::SIGTERM, 128 + libc::SIGHUP].contains(&code),
        (None, None) => false,
    };
    if on_purpose {
        return Object::new();
    }
    let reason = match (code, signal) {
        (_, Some(signal)) => format!("killed by signal {signal}"),
        (code, None) => format!("exited with code {}", code.unwrap_or(-1)),
    };
    let mut crash = json!({"reason": reason}).as_object().cloned().unwrap_or_default();
    if let Some(line) = last_error_line(tail) {
        crash.insert("line".into(), line.into());
    }
    if let Some(log) = log {
        crash.insert("log".into(), log.to_string_lossy().into_owned().into());
    }
    crash
}

async fn write(unwritten: Rc<Cell<usize>>, mut stdin: impl AsyncWrite + Unpin, mut queue: mpsc::UnboundedReceiver<Vec<u8>>) {
    while let Some(line) = queue.recv().await {
        if stdin.write_all(&line).await.is_err() || stdin.flush().await.is_err() {
            return;
        }
        unwritten.set(unwritten.get() - 1);
    }
}

fn deliver(lines: &mpsc::UnboundedSender<Line>, text: &[u8]) {
    if text.iter().all(u8::is_ascii_whitespace) {
        return;
    }
    let _ = lines.send(match serde_json::from_slice::<Value>(text) {
        Ok(Value::Object(message)) => Line::Message(message),
        _ => Line::Invalid(String::from_utf8_lossy(text).into_owned()),
    });
}

/// Hands on every whole line received and keeps the unfinished one.
fn deliver_lines(inner: &Inner, lines: &mpsc::UnboundedSender<Line>) {
    let mut received = std::mem::take(&mut *inner.unparsed.borrow_mut());
    let mut start = 0;
    while let Some(length) = received[start..].iter().position(|byte| *byte == b'\n') {
        deliver(lines, &received[start..start + length]);
        start += length + 1;
    }
    received.drain(..start);
    *inner.unparsed.borrow_mut() = received;
}

async fn read(inner: Rc<Inner>, mut stdout: impl AsyncRead + Unpin, mut process: Process, lines: mpsc::UnboundedSender<Line>) {
    let mut chunk = vec![0; READ_CHUNK];
    // An adopted agent may come with whole lines its previous reader had not parsed.
    let mut ended_a_line = true;
    loop {
        if ended_a_line {
            deliver_lines(&inner, &lines);
        }
        if inner.unparsed.borrow().len() > MAX_LINE_BYTES {
            let _ = lines.send(Line::Failed("The agent sent a line over the size limit.".into()));
            break;
        }
        match stdout.read(&mut chunk).await {
            Ok(0) => {
                let last = std::mem::take(&mut *inner.unparsed.borrow_mut());
                deliver(&lines, &last);
                break;
            }
            Ok(count) => {
                ended_a_line = chunk[..count].contains(&b'\n');
                inner.unparsed.borrow_mut().extend_from_slice(&chunk[..count]);
            }
            Err(_) => break,
        }
    }
    inner.closed.set(true);
    inner.writer.borrow_mut().take();
    let status = match tokio::time::timeout(STOP_GRACE, process.wait()).await {
        Ok(status) => status,
        Err(_) => {
            if let Some(group) = inner.group {
                unsafe { libc::kill(-group, libc::SIGKILL) };
            }
            process.wait().await
        }
    };
    inner.exited.set(true);
    let (code, signal) = status.map_or((None, None), |status| (status.code(), status.signal()));
    let tail = inner.log.as_ref().map(|(path, start)| log_tail(path, *start)).unwrap_or_default();
    let crash = crash(code, signal, &tail, inner.log.as_ref().map(|(path, _)| path.as_path()));
    let _ = lines.send(Line::Exited { crash, log_tail: tail });
}
