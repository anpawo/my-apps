//! An isolated Swift runtime worker for tests: its own runtime, config and state folders, and the fixture agent in
//! place of `codex app-server`, so a test never attaches to a session someone is working in.

use serde_json::json;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const SOCKET_WAIT: Duration = Duration::from_secs(15);
const POLL: Duration = Duration::from_millis(20);
const INSTALLED: &str = "Applications/Vibe Code X.app/Contents/MacOS/VCX";
const PRIVATE_FOLDER: u32 = 0o700;

pub struct SwiftWorker {
    child: Child,
    pub directory: PathBuf,
    pub socket: PathBuf,
}

impl SwiftWorker {
    /// Starts a worker, or gives `None` when no Swift VCX binary exists (`VCX_SWIFT_BINARY`, then the installed app).
    pub fn start(name: &str) -> Option<Self> {
        let binary = swift_binary()?;
        // Unix socket paths are capped near 104 bytes, so the folder sits in /tmp.
        let directory = PathBuf::from(format!("/tmp/vcx-interop-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/fake_agent.py");
        let command = directory.join("command.json");
        fs::write(&command, json!(["/usr/bin/python3", fixture.canonicalize().unwrap()]).to_string()).unwrap();
        let socket = directory.join("worker.sock");
        let child = Command::new(binary)
            .args(["--runtime-worker", socket.to_str().unwrap(), "--runtime-test", "--runtime-fixture-command", command.to_str().unwrap()])
            .env("VCX_RUNTIME_HOME", directory.join("runtime"))
            .env("VCX_CONFIG_HOME", directory.join("config"))
            .env("VCX_STATE_HOME", directory.join("state"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let worker = Self { child, directory, socket };
        let deadline = Instant::now() + SOCKET_WAIT;
        while !worker.socket.exists() {
            assert!(Instant::now() < deadline, "the Swift worker never opened its socket");
            std::thread::sleep(POLL);
        }
        Some(worker)
    }

    pub fn pid(&self) -> i64 {
        i64::from(self.child.id())
    }
}

impl Drop for SwiftWorker {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.directory);
    }
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
