//! C4 of the report: a session a Swift frontend holds is taken by another frontend. The Swift frontend must let it
//! go for good: left in its recovery list, the session is taken back at the Swift app's next cold launch.
//! The Swift side is the real app, run windowless through the entry points its own install checks use
//! (`--frontend-handoff-fixture`, `--recovery-frontend`); the taker attaches with `vcx-proto`, as the Rust app does.

use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, Peer, WAIT, request_for};
use vcx_proto::AttachRequest;
use vcx_testkit::{RUNTIME, SwiftWorker, session_id};

const POLL: Duration = Duration::from_millis(20);
const PRIVATE_FILE: u32 = 0o600;
const PRIVATE_FOLDER: u32 = 0o700;
/// What the Swift app's cold recovery says (`RecoveryCheck.frontend`) when its list holds no session to reopen.
const NOTHING_TO_REOPEN: &str = "Recovery registry did not restore";

struct Frontend(Child);

impl Drop for Frontend {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn wait_for(failure: &str, reached: impl Fn() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !reached() {
        assert!(Instant::now() < deadline, "{failure}");
        std::thread::sleep(POLL);
    }
}

/// A headless Swift frontend holding the session in a window of its own, as after an update's handover.
fn swift_frontend(worker: &SwiftWorker, id: &str) -> Frontend {
    let runtime = worker.directory.join(RUNTIME);
    fs::DirBuilder::new().recursive(true).mode(PRIVATE_FOLDER).create(&runtime).unwrap();
    let ticket = runtime.join(format!("{}.restore.json", session_id()));
    let windows = json!({"windows": [{"cwd": worker.directory, "sessionId": id, "socket": worker.socket, "windowState": {}}]});
    let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(PRIVATE_FILE).open(&ticket).unwrap();
    file.write_all(windows.to_string().as_bytes()).unwrap();
    let process = worker.app().args(["--frontend-handoff-fixture", ticket.to_str().unwrap(), "success"]).stdin(Stdio::null()).spawn().unwrap();
    let frontend = Frontend(process);
    let attached = PathBuf::from(format!("{}.ready.json", ticket.display()));
    wait_for("the Swift frontend never attached its window", || attached.exists());
    frontend
}

fn owner(entry: &Path) -> Option<Value> {
    let listed: Value = serde_json::from_slice(&fs::read(entry).ok()?).ok()?;
    Some(listed["ownerPID"].clone())
}

/// What a cold launch of the Swift app finds to reopen, read by the app itself once no frontend is alive.
fn cold_launch(worker: &SwiftWorker) -> String {
    let folder = worker.directory.to_str().unwrap();
    let launch = worker.app().args(["--recovery-frontend", folder, worker.socket.to_str().unwrap(), "second"]).stdin(Stdio::null()).output().unwrap();
    assert!(!launch.status.success(), "the Swift app reopened a session at its cold launch");
    String::from_utf8_lossy(&launch.stderr).into_owned()
}

#[test]
fn a_session_taken_from_a_swift_frontend_is_not_reopened_at_its_next_cold_launch() {
    let worker = SwiftWorker::start("takeover").expect("no Swift VCX binary: install the app or set VCX_SWIFT_BINARY");
    let target = Target::of(&worker);
    let id = Held::open(&target).id().to_owned();
    let frontend = swift_frontend(&worker, &id);
    let entry = worker.directory.join(RUNTIME).join("recovery").join(format!("{id}.window.json"));
    wait_for("the Swift frontend never listed its session for recovery", || owner(&entry) == Some(json!(frontend.0.id())));

    let mut taken = Held::attach(Peer::greeted(&target), &AttachRequest { existing_only: true, ..request_for(&target, &id) });
    wait_for("the Swift frontend kept in its recovery list a session another frontend took", || !entry.exists());
    drop(frontend);
    let found = cold_launch(&worker);

    assert!(found.contains(NOTHING_TO_REOPEN), "the cold launch failed for another reason: {found}");
    taken.turn("after the takeover");
    assert_eq!(taken.peer.listed(&id).unwrap()["attached"], true, "the taker still holds the session");
}
