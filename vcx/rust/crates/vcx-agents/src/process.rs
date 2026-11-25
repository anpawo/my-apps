//! An agent process that speaks one JSON object per line but no Codex JSON-RPC (Claude's stream-json, agy's ACP): its
//! lines come out raw and the adapter reads them. Its stderr goes to a log whose tail says why it stopped, as
//! `agentLog`, `agentLogTail`, `agentCrash` and `lastErrorLine` in `RPC.swift` do. Used inside a tokio `LocalSet`.

use crate::Object;
use crate::rpc::MAX_LINE_BYTES;
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::rc::Rc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::mpsc;

const STOP_GRACE: Duration = Duration::from_secs(2);
/// An agent log is cut back to its end past this size, as `agentLog` keeps it.
const LOG_LIMIT: u64 = 1024 * 1024;
const LOG_TAIL: u64 = 4096;
const ERROR_LINE_CHARS: usize = 300;

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

struct Inner {
    writer: RefCell<Option<mpsc::UnboundedSender<Vec<u8>>>>,
    group: Option<i32>,
    closed: Cell<bool>,
    exited: Cell<bool>,
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
        let (writer, queue) = mpsc::unbounded_channel();
        let inner = Rc::new(Inner { writer: RefCell::new(Some(writer)), group: pid, closed: Cell::new(false), exited: Cell::new(false) });
        let (lines, incoming) = mpsc::unbounded_channel();
        let log = log.map(|(_, start)| (launch.log.unwrap().to_path_buf(), start));
        tokio::task::spawn_local(write(stdin, queue));
        tokio::task::spawn_local(read(Rc::clone(&inner), stdout, child, lines, log));
        Ok((Self { inner, pid }, incoming))
    }

    pub fn send(&self, message: &Object) -> Result<(), String> {
        let mut line = serde_json::to_vec(message).map_err(|error| error.to_string())?;
        line.push(b'\n');
        let writer = self.inner.writer.borrow();
        if writer.as_ref().is_some_and(|writer| writer.send(line).is_ok()) { Ok(()) } else { Err("The agent is not running.".into()) }
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

async fn write(mut stdin: ChildStdin, mut queue: mpsc::UnboundedReceiver<Vec<u8>>) {
    while let Some(line) = queue.recv().await {
        if stdin.write_all(&line).await.is_err() || stdin.flush().await.is_err() {
            return;
        }
    }
}

async fn read(inner: Rc<Inner>, stdout: ChildStdout, mut child: Child, lines: mpsc::UnboundedSender<Line>, log: Option<(PathBuf, u64)>) {
    let mut reader = BufReader::new(stdout);
    let mut line = Vec::new();
    loop {
        line.clear();
        match (&mut reader).take(MAX_LINE_BYTES as u64 + 1).read_until(b'\n', &mut line).await {
            Ok(0) | Err(_) => break,
            Ok(_) if line.last() != Some(&b'\n') && line.len() > MAX_LINE_BYTES => {
                let _ = lines.send(Line::Failed("The agent sent a line over the size limit.".into()));
                break;
            }
            Ok(_) => {}
        }
        let text = line.strip_suffix(b"\n").unwrap_or(&line);
        if text.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let _ = lines.send(match serde_json::from_slice::<Value>(text) {
            Ok(Value::Object(message)) => Line::Message(message),
            _ => Line::Invalid(String::from_utf8_lossy(text).into_owned()),
        });
    }
    inner.closed.set(true);
    inner.writer.borrow_mut().take();
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
    use std::os::unix::process::ExitStatusExt;
    let (code, signal) = status.map_or((None, None), |status| (status.code(), status.signal()));
    let tail = log.as_ref().map(|(path, start)| log_tail(path, *start)).unwrap_or_default();
    let crash = crash(code, signal, &tail, log.as_ref().map(|(path, _)| path.as_path()));
    let _ = lines.send(Line::Exited { crash, log_tail: tail });
}
