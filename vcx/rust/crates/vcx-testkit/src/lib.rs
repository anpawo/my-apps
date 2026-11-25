//! Isolated runtime workers for tests, Swift or Rust: each has its own runtime, config and state folders, and the
//! fixture agent in place of `codex app-server`, so a test never attaches to a session someone is working in.

use serde_json::json;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

const SOCKET_WAIT: Duration = Duration::from_secs(15);
const POLL: Duration = Duration::from_millis(20);
const INSTALLED: &str = "Applications/Vibe Code X.app/Contents/MacOS/VCX";
const PRIVATE_FOLDER: u32 = 0o700;

/// Written into a worker's folder once its process has ended, with its exit code: a test reads an exit from
/// `Target.directory` alone, where `kill(pid, 0)` would still find the child until it is reaped.
pub const EXIT_MARKER: &str = "worker.exited";

pub fn has_exited(directory: &Path) -> bool {
    directory.join(EXIT_MARKER).exists()
}

pub struct SwiftWorker {
    process: Process,
    pub directory: PathBuf,
    pub socket: PathBuf,
}

impl SwiftWorker {
    /// Starts a worker, or gives `None` when no Swift VCX binary exists (`VCX_SWIFT_BINARY`, then the installed app).
    pub fn start(name: &str) -> Option<Self> {
        let binary = swift_binary()?;
        let directory = private_folder("interop", name);
        let command = fixture_command(&directory, None);
        let process = Process::watch(launch(&binary, &directory, &command), &directory);
        let worker = Self { process, socket: directory.join(SOCKET), directory };
        wait_for_socket(&worker.socket, "the Swift worker never opened its socket");
        Some(worker)
    }

    pub fn pid(&self) -> i64 {
        i64::from(self.process.pid)
    }
}

impl Drop for SwiftWorker {
    fn drop(&mut self) {
        self.process.kill();
        let _ = fs::remove_dir_all(&self.directory);
    }
}

/// The Rust worker under test, in a folder of its own. With a history file, the fixture agent keeps its turns
/// there, so a worker killed and started again can reopen the conversation from the agent's history.
pub struct RustWorker {
    process: Process,
    binary: PathBuf,
    command: PathBuf,
    pub directory: PathBuf,
    pub socket: PathBuf,
}

impl RustWorker {
    /// `binary` is the `vcx-worker` executable (`env!("CARGO_BIN_EXE_vcx-worker")` in its own tests).
    pub fn start(binary: &Path, name: &str) -> Self {
        Self::start_in(binary, private_folder("rust", name), false)
    }

    pub fn start_with_history(binary: &Path, name: &str) -> Self {
        Self::start_in(binary, private_folder("rust", name), true)
    }

    fn start_in(binary: &Path, directory: PathBuf, history: bool) -> Self {
        assert!(binary.exists(), "no Rust worker at {}", binary.display());
        let command = fixture_command(&directory, history.then(|| directory.join("history.json")));
        let process = Process::watch(launch(binary, &directory, &command), &directory);
        let worker = Self { process, binary: binary.to_owned(), command, socket: directory.join(SOCKET), directory };
        wait_for_socket(&worker.socket, "the Rust worker never opened its socket");
        worker
    }

    pub fn pid(&self) -> i64 {
        i64::from(self.process.pid)
    }

    /// Kills the worker with SIGKILL, as a crash would, and starts a new one on the same folder and socket.
    pub fn restart_after_kill(&mut self) {
        self.process.kill();
        let _ = fs::remove_file(self.directory.join(EXIT_MARKER));
        self.process = Process::watch(launch(&self.binary, &self.directory, &self.command), &self.directory);
        let deadline = Instant::now() + SOCKET_WAIT;
        while serves(&self.socket).is_none() {
            assert!(Instant::now() < deadline, "the restarted Rust worker never served its socket");
            std::thread::sleep(POLL);
        }
    }
}

impl Drop for RustWorker {
    fn drop(&mut self) {
        self.process.kill();
        let _ = fs::remove_dir_all(&self.directory);
    }
}

const SOCKET: &str = "worker.sock";

/// A worker process reaped by its own thread, which writes the exit marker.
struct Process {
    pid: u32,
    ended: Arc<AtomicBool>,
    waiter: Option<JoinHandle<()>>,
}

impl Process {
    fn watch(mut child: Child, directory: &Path) -> Self {
        let pid = child.id();
        let ended = Arc::new(AtomicBool::new(false));
        let (flag, marker) = (Arc::clone(&ended), directory.join(EXIT_MARKER));
        let waiter = std::thread::spawn(move || {
            let code = child.wait().ok().and_then(|status| status.code());
            let _ = fs::write(marker, json!({"code": code}).to_string());
            flag.store(true, Ordering::SeqCst);
        });
        Process { pid, ended, waiter: Some(waiter) }
    }

    /// SIGKILL, as a crash would, unless the process already ended, then waits for its marker.
    fn kill(&mut self) {
        if !self.ended.load(Ordering::SeqCst) {
            unsafe { libc::kill(self.pid as libc::pid_t, libc::SIGKILL) };
        }
        if let Some(waiter) = self.waiter.take() {
            let _ = waiter.join();
        }
    }
}

// Unix socket paths are capped near 104 bytes, so the folder sits in /tmp.
fn private_folder(kind: &str, name: &str) -> PathBuf {
    let directory = PathBuf::from(format!("/tmp/vcx-{kind}-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&directory);
    fs::create_dir(&directory).unwrap();
    fs::set_permissions(&directory, fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
    directory
}

fn fixture_command(directory: &Path, history: Option<PathBuf>) -> PathBuf {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/fake_agent.py").canonicalize().unwrap();
    let mut command = vec![json!("/usr/bin/python3"), json!(fixture)];
    if let Some(history) = history {
        command.extend([json!("--history"), json!(history)]);
    }
    let path = directory.join("command.json");
    fs::write(&path, json!(command).to_string()).unwrap();
    path
}

fn launch(binary: &Path, directory: &Path, command: &Path) -> Child {
    Command::new(binary)
        .args(["--runtime-worker", directory.join(SOCKET).to_str().unwrap(), "--runtime-test", "--runtime-fixture-command", command.to_str().unwrap()])
        .env("VCX_RUNTIME_HOME", directory.join("runtime"))
        .env("VCX_CONFIG_HOME", directory.join("config"))
        .env("VCX_STATE_HOME", directory.join("state"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}

fn wait_for_socket(socket: &Path, failure: &str) {
    let deadline = Instant::now() + SOCKET_WAIT;
    while !socket.exists() {
        assert!(Instant::now() < deadline, "{failure}");
        std::thread::sleep(POLL);
    }
}

/// The socket answers a connection (a killed worker's socket file stays behind until the next one replaces it).
fn serves(socket: &Path) -> Option<()> {
    std::os::unix::net::UnixStream::connect(socket).ok().map(drop)
}

fn swift_binary() -> Option<PathBuf> {
    let path = match std::env::var_os("VCX_SWIFT_BINARY") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(std::env::var_os("HOME")?).join(INSTALLED),
    };
    path.exists().then_some(path)
}

/// A session id in the form the Swift runtime prints them.
pub fn session_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}
