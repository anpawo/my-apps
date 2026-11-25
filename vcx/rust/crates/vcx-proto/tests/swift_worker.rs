//! Conformance against the Swift worker: the Rust client attaches to a real `VCX --runtime-worker` whose agent is the
//! fixture, sends a prompt and follows the turn to its end. Skipped when no Swift VCX binary is found.

use serde_json::{Value, json};
use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use vcx_model::{Applied, Replica, SessionState, view};
use vcx_proto::{AttachRequest, Client, Event, Lease};

const SOCKET_WAIT: Duration = Duration::from_secs(15);
const TURN_WAIT: Duration = Duration::from_secs(30);
const POLL: Duration = Duration::from_millis(20);
const INSTALLED: &str = "Applications/Vibe Code X.app/Contents/MacOS/VCX";

struct Worker {
    child: Child,
    directory: PathBuf,
}

impl Drop for Worker {
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

fn uuid() -> String {
    let mut bytes = [0u8; 16];
    fs::File::open("/dev/urandom").unwrap().read_exact(&mut bytes).unwrap();
    bytes[6] = bytes[6] & 0x0f | 0x40;
    bytes[8] = bytes[8] & 0x3f | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

fn start_worker(binary: &Path, name: &str) -> (Worker, PathBuf) {
    // Unix socket paths are capped near 104 bytes, so the folder sits in /tmp.
    let directory = PathBuf::from(format!("/tmp/vcx-interop-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&directory);
    fs::create_dir(&directory).unwrap();
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
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
    let deadline = Instant::now() + SOCKET_WAIT;
    while !socket.exists() {
        assert!(Instant::now() < deadline, "the Swift worker never opened its socket");
        std::thread::sleep(POLL);
    }
    (Worker { child, directory }, socket)
}

#[test]
fn follows_a_turn_of_a_swift_worker_from_prompt_to_answer() {
    let Some(binary) = swift_binary() else {
        eprintln!("skipped: no Swift VCX binary (set VCX_SWIFT_BINARY)");
        return;
    };
    let (worker, socket) = start_worker(&binary, "turn");
    let (sender, events) = mpsc::channel();
    let client = Client::connect(&socket, move |event| drop(sender.send(event))).unwrap();
    let request = AttachRequest { session_id: uuid(), cwd: worker.directory.to_str().unwrap().to_owned(), ..AttachRequest::default() };
    let mut replica = Replica::default();

    let hello = client.hello().unwrap();
    let attachment = client.attach(&request).unwrap();
    let mut lease = Lease::of(&attachment);
    assert!(replica.snapshot(attachment.revision, &attachment.state));
    follow(&events, &mut replica, |state| state.meta.get("ready") == Some(&Value::Bool(true)));
    lease.perform(&client, "send", json!({"text": "hello from rust", "images": []})).unwrap();
    follow(&events, &mut replica, |state| state.meta.get("busy") == Some(&Value::Bool(false)) && state.rows.iter().any(|row| row.kind == "assistant"));
    let page = view::full(replica.state().unwrap());

    assert_eq!(hello.pid, i64::from(worker.child.id()));
    assert_eq!(attachment.session_id, request.session_id);
    let kinds: Vec<&str> = page["rows"].as_array().unwrap().iter().map(|row| row["kind"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["user", "activity", "assistant"], "{page:#}");
    assert_eq!(page["rows"][0]["items"][0]["text"], "hello from rust");
    assert_eq!(page["rows"][1]["items"][0]["title"], "echo fixture");
    let answer = page["rows"][2]["items"][0]["html"].as_str().unwrap();
    assert!(answer.contains("<table>") && answer.contains("<strong>bold</strong>"), "{answer}");
    assert_eq!(lease.sequence, attachment.last_sequence + 1);
}

/// Applies the worker's updates in order until the session reaches the wanted state.
fn follow(events: &mpsc::Receiver<Event>, replica: &mut Replica, reached: impl Fn(&SessionState) -> bool) {
    let deadline = Instant::now() + TURN_WAIT;
    while !reached(replica.state().unwrap()) {
        let event = events.recv_timeout(deadline.saturating_duration_since(Instant::now())).expect("the session never reached the wanted state");
        let Event::Update { revision, patch, .. } = event else { panic!("unexpected event: {event:?}") };
        assert!(matches!(replica.update(revision, patch), Applied::Changed(_)), "revision {revision} did not follow {}", replica.revision());
    }
}
