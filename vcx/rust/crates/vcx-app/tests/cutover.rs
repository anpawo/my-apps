//! A rehearsal of `cutover/cutover.sh` on folders of its own: a Swift frontend stopped out of its window, VCX Rust
//! started through `open` and taking that window over on the same Swift worker, the `vcx` command switched, the Rust
//! worker made the default, the Swift app in the Trash; then the way back. And the switch's guards: nothing stops
//! while the Swift app installs, a window that never shows its session sends every window back, a newer draft carried.

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use vcx_cli::control;

const WAIT: Duration = Duration::from_secs(40);
const POLL: Duration = Duration::from_millis(100);
const PRIVATE_FOLDER: u32 = 0o700;
const PRIVATE_FILE: u32 = 0o600;
const EXECUTABLE: u32 = 0o755;
const MICROSECONDS_PER_SECOND: u64 = 1_000_000;
/// The Rust worker as the workspace builds it (`cargo build -p vcx-worker`), put in the rehearsal's VCX Rust bundle.
const RUST_WORKER: &str = "../../target/debug/vcx-worker";
/// Long enough for a window on a live worker to show its session, short enough for a rehearsal that waits it out.
const SHORT_ATTACH_WAIT: &str = "5";
/// Above the generation a worker holds for a session it has just started: the Swift window typed after its last checkpoint.
const NEWER_DRAFT_GENERATION: i64 = 7;
/// Where the Swift window stood (`NSStringFromRect`): its left edge and width read the same in VCX Rust's frame.
const SWIFT_FRAME: &str = "{{140, 180}, {960, 700}}";
const SWIFT_LEFT: f64 = 140.0;
const SWIFT_WIDTH: f64 = 960.0;
/// A worker that takes connections and never answers them, as one too busy to say hello.
const MUTE_WORKER: &str = "import socket, sys\nserver = socket.socket(socket.AF_UNIX)\nserver.bind(sys.argv[1])\nserver.listen(16)\nheld = []\nwhile True:\n    held.append(server.accept())\n";
/// What switch.sh takes for the Swift app's launcher: install-native.py's mark on the second line, and the app's path.
const SWIFT_LAUNCHER: &str = "#!/bin/bash\n# vcx launcher\nexec \"$HOME/Applications/Vibe Code X.app/Contents/MacOS/VCX\" \"$@\"\n";
const RUST_MARK: &str = "# vcx launcher: VCX Rust";
/// `open` starts VCX Rust windowless; any other app it is asked for is only written down.
const STUBS: [(&str, &str); 3] = [
    ("open", "#!/bin/bash\ncase \"$*\" in\n*'VCX Rust.app'*) HOME=\"$VCX_CUTOVER_REAL_HOME\" \"$VCX_CUTOVER_APP\" --windowless < /dev/null > /dev/null 2>&1 &\necho $! > \"$VCX_CUTOVER_PID\" ;;\n*) echo \"$*\" >> \"$VCX_CUTOVER_OPENED\" ;;\nesac\n"),
    ("gh", "#!/bin/bash\necho Vibe.Code.X.zip\n"),
    ("launchctl", "#!/bin/bash\necho \"$*\" >> \"$VCX_CUTOVER_LAUNCHCTL\"\n"),
];

/// The rehearsal's folders, and the app `open` started there, stopped and removed with it.
struct Rehearsal {
    root: PathBuf,
}

impl Rehearsal {
    fn new(name: &str, swift: &Path) -> Self {
        let root = PathBuf::from(format!("/tmp/vcx-cutover-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for folder in ["state", "config", "bin", "stubs", "update", "home/Applications/Vibe Code X.app/Contents", "home/Applications/VCX Rust.app/Contents/MacOS"] {
            fs::create_dir_all(root.join(folder)).unwrap();
        }
        for folder in ["state", "config"] {
            fs::set_permissions(root.join(folder), fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
        }
        fs::write(root.join("home/Applications/Vibe Code X.app/Contents/marker"), "swift").unwrap();
        symlink(env!("CARGO_BIN_EXE_vcx-rust"), root.join("home/Applications/VCX Rust.app/Contents/MacOS/vcx-rust")).unwrap();
        symlink(Path::new(env!("CARGO_MANIFEST_DIR")).join(RUST_WORKER), root.join("home/Applications/VCX Rust.app/Contents/MacOS/vcx-worker")).unwrap();
        write_executable(&root.join("bin/vcx"), SWIFT_LAUNCHER);
        for (name, body) in STUBS {
            write_executable(&root.join("stubs").join(name), body);
        }
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/fake_agent.py").canonicalize().unwrap();
        let command = root.join("command.json");
        fs::write(&command, json!(["/usr/bin/python3", fixture]).to_string()).unwrap();
        let settings = json!({"worker": swift, "workerArguments": ["--runtime-test", "--runtime-fixture-command", command]});
        fs::write(root.join("config/settings.json"), settings.to_string()).unwrap();
        fs::set_permissions(root.join("config/settings.json"), fs::Permissions::from_mode(PRIVATE_FILE)).unwrap();
        Self { root }
    }

    fn cutover(&self, recovery: &Path, arguments: &[&str], variables: &[(&str, &str)]) -> Output {
        let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../cutover/cutover.sh");
        let path = format!("{}:{}", self.root.join("stubs").display(), std::env::var("PATH").unwrap_or_default());
        Command::new(script)
            .args(arguments)
            .envs(vcx_config::Homes::under(&self.root).environment())
            .env("HOME", self.root.join("home"))
            .env("PATH", path)
            .env("VCX_SWIFT_RECOVERY", recovery)
            .env("VCX_BIN_HOME", self.root.join("bin"))
            .env("VCX_UPDATE_HOME", self.root.join("update"))
            .env("VCX_UPDATE_STATE", self.root.join("update-state"))
            .env("VCX_CUTOVER_APP", env!("CARGO_BIN_EXE_vcx-rust"))
            .env("VCX_CUTOVER_REAL_HOME", std::env::var_os("HOME").unwrap_or_default())
            .env("VCX_CUTOVER_PID", self.root.join("app.pid"))
            .env("VCX_CUTOVER_LAUNCHCTL", self.root.join("launchctl.log"))
            .env("VCX_CUTOVER_OPENED", self.root.join("opened.log"))
            .envs(variables.iter().copied())
            .env_remove("CLAUDE_CODE_SESSION_ID")
            .env_remove("VCX_THREAD_ID")
            .stdin(Stdio::null())
            .output()
            .unwrap()
    }

    fn report(&self) -> Option<Value> {
        control::ask(&self.root.join("state/control.sock"), &json!({"report": {}}))
    }

    /// VCX Rust running before the switch, as `open` starts it.
    fn start_app(&self) {
        let app = Command::new(env!("CARGO_BIN_EXE_vcx-rust")).arg("--windowless").envs(vcx_config::Homes::under(&self.root).environment()).env_remove("CLAUDE_CODE_SESSION_ID").env_remove("VCX_THREAD_ID")
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
        fs::write(self.root.join("app.pid"), app.id().to_string()).unwrap();
        wait_until(|| self.report().is_some(), "VCX Rust never answered");
    }

    /// A process the switch takes for a Swift frontend (named VCX), owning `id`'s window on `socket` in a recovery
    /// folder of the rehearsal's own.
    fn frontend(&self, id: &str, socket: &Path, state: Value) -> (Child, PathBuf) {
        let binary = self.root.join("VCX");
        fs::copy("/bin/sleep", &binary).unwrap();
        let frontend = Command::new(&binary).arg("600").stdin(Stdio::null()).spawn().unwrap();
        let recovery = self.root.join("recovery");
        fs::create_dir_all(&recovery).unwrap();
        fs::set_permissions(&recovery, fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
        let entry = recovery.join(format!("{id}.window.json"));
        let listed = json!({"sessionId": id, "socket": socket, "ownerPID": frontend.id(), "ownerStart": started(frontend.id() as i32), "closeRequested": false, "state": state});
        fs::write(&entry, listed.to_string()).unwrap();
        fs::set_permissions(&entry, fs::Permissions::from_mode(PRIVATE_FILE)).unwrap();
        (frontend, entry)
    }
}

impl Drop for Rehearsal {
    fn drop(&mut self) {
        if let Some(pid) = fs::read_to_string(self.root.join("app.pid")).ok().and_then(|pid| pid.trim().parse::<i32>().ok()) {
            // SAFETY: the pid is the app this rehearsal's `open` started.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
        let _ = Command::new("/usr/bin/pkill").args(["-KILL", "-f", &format!("{}/", self.root.display())]).status();
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn write_executable(path: &Path, body: &str) {
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(EXECUTABLE)).unwrap();
}

/// No process the rehearsal starts may keep `build-stack`'s lock (see `worker::keep_build_lock_out`).
fn keep_build_lock_out() {
    let Some(fd) = std::env::var("BUILD_STACK_FD").ok().and_then(|fd| fd.parse::<libc::c_int>().ok()) else { return };
    // SAFETY: F_SETFD on a number only changes that descriptor's flags.
    unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
}

fn started(pid: i32) -> u64 {
    // SAFETY: proc_bsdinfo is plain data; zeroed is a valid value for it.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    // SAFETY: the buffer is a proc_bsdinfo of exactly `size` bytes, which PROC_PIDTBSDINFO fills.
    assert_eq!(unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) }, size);
    info.pbi_start_tvsec * MICROSECONDS_PER_SECOND + info.pbi_start_tvusec
}

fn wait_until(done: impl Fn() -> bool, what: &str) {
    let deadline = Instant::now() + WAIT;
    while !done() {
        assert!(Instant::now() < deadline, "{what}");
        thread::sleep(POLL);
    }
}

fn rust_worker_built() -> bool {
    let built = Path::new(env!("CARGO_MANIFEST_DIR")).join(RUST_WORKER).is_file();
    if !built {
        eprintln!("skipped: no Rust worker (cargo build -p vcx-worker) for --rust-worker");
    }
    built
}

fn text(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned() + &String::from_utf8_lossy(&output.stderr)
}

#[test]
fn switches_to_vcx_rust_on_the_swift_sessions_and_back_in_one_command_each_way() {
    keep_build_lock_out();
    if !rust_worker_built() {
        return;
    }
    let Some(worker) = vcx_testkit::SwiftWorker::start("cutover") else {
        return eprintln!("skipped: no Swift VCX binary (VCX_SWIFT_BINARY or the installed app)");
    };
    let id = vcx_testkit::session_id();
    let request = vcx_proto::AttachRequest { session_id: id.clone(), cwd: worker.directory.to_string_lossy().into_owned(), prompt: "left in the swift app".into(), ..Default::default() };
    let client = vcx_proto::Client::connect(&worker.socket, |_| {}).unwrap();
    client.hello().unwrap();
    client.attach(&request).unwrap();
    drop(client);
    let runtime = worker.directory.join(vcx_testkit::RUNTIME);
    fs::create_dir_all(&runtime).unwrap();
    fs::set_permissions(&runtime, fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
    let ticket = runtime.join(format!("{}.restore.json", vcx_testkit::session_id()));
    fs::write(&ticket, json!({"windows": [{"cwd": worker.directory, "sessionId": id, "socket": worker.socket, "windowState": {}}]}).to_string()).unwrap();
    fs::set_permissions(&ticket, fs::Permissions::from_mode(PRIVATE_FILE)).unwrap();
    let mut frontend = worker.app().args(["--frontend-handoff-fixture", ticket.to_str().unwrap(), "success"]).stdin(Stdio::null()).spawn().unwrap();
    let frontend_pid = frontend.id();
    let recovery = runtime.join("recovery");
    let entry = recovery.join(format!("{id}.window.json"));
    let deadline = Instant::now() + WAIT;
    while fs::read(&entry).ok().and_then(|listed| serde_json::from_slice::<Value>(&listed).ok()).map(|listed| listed["ownerPID"].clone()) != Some(json!(frontend_pid)) {
        assert!(Instant::now() < deadline, "the Swift frontend never listed its window for recovery");
        thread::sleep(POLL);
    }
    // Reaped at once, as launchd reaps the real frontend: the script waits for the pid to be gone.
    let stopped = thread::spawn(move || frontend.wait().unwrap());
    let rehearsal = Rehearsal::new("both-ways", worker.app().get_program().as_ref());
    let home = rehearsal.root.join("home");

    let to_rust = rehearsal.cutover(&recovery, &["--to", "rust", "--rust-worker"], &[]);

    assert!(to_rust.status.success(), "{}", text(&to_rust));
    assert_eq!(stopped.join().unwrap().signal(), Some(libc::SIGKILL));
    let report = rehearsal.report().expect("VCX Rust answers once the script is done");
    let held: Vec<(&Value, &Value)> = report["windows"].as_array().unwrap().iter().map(|window| (&window["sessionId"], &window["socket"])).collect();
    assert_eq!(held, [(&json!(id), &json!(worker.socket))], "{}", text(&to_rust));
    assert!(!entry.exists(), "the Swift app would take the session back: {}", text(&to_rust));
    let launcher = fs::read_to_string(rehearsal.root.join("bin/vcx")).unwrap();
    assert!(launcher.lines().any(|line| line == RUST_MARK), "{launcher}");
    let settings: Value = serde_json::from_slice(&fs::read(rehearsal.root.join("config/settings.json")).unwrap()).unwrap();
    assert_eq!(settings["worker"], json!(home.join("Applications/VCX Rust.app/Contents/MacOS/vcx-worker")));
    assert!(home.join(".Trash/Vibe Code X.app/Contents/marker").exists() && !home.join("Applications/Vibe Code X.app").exists());

    let to_swift = rehearsal.cutover(&recovery, &["--to", "swift"], &[]);

    assert!(to_swift.status.success(), "{}", text(&to_swift));
    assert!(home.join("Applications/Vibe Code X.app/Contents/marker").exists());
    assert_eq!(fs::read_to_string(rehearsal.root.join("bin/vcx")).unwrap(), SWIFT_LAUNCHER);
    let verbs: Vec<String> = fs::read_to_string(rehearsal.root.join("launchctl.log")).unwrap().lines().filter_map(|line| line.split(' ').next().map(str::to_owned)).collect();
    assert_eq!(verbs, ["disable", "print", "bootout", "enable", "bootstrap"]);
}

#[test]
fn stops_no_swift_window_while_the_swift_app_installs() {
    keep_build_lock_out();
    let rehearsal = Rehearsal::new("installing", Path::new("/usr/bin/false"));
    fs::write(rehearsal.root.join("update/building"), "").unwrap();
    let (mut frontend, entry) = rehearsal.frontend(&vcx_testkit::session_id(), &rehearsal.root.join("gone.sock"), json!({"cwd": rehearsal.root}));

    let refused = rehearsal.cutover(&rehearsal.root.join("recovery"), &["--to", "rust"], &[]);

    assert!(!refused.status.success() && text(&refused).contains("being installed"), "{}", text(&refused));
    assert!(frontend.try_wait().unwrap().is_none(), "the Swift frontend was stopped: {}", text(&refused));
    assert_eq!(fs::read_to_string(rehearsal.root.join("bin/vcx")).unwrap(), SWIFT_LAUNCHER);
    assert!(entry.exists() && rehearsal.report().is_none(), "{}", text(&refused));
}

#[test]
fn gives_every_window_back_to_the_swift_app_when_one_never_shows_its_session() {
    keep_build_lock_out();
    let rehearsal = Rehearsal::new("give-back", Path::new("/usr/bin/false"));
    let (socket, mute) = (rehearsal.root.join("mute.sock"), rehearsal.root.join("mute.py"));
    fs::write(&mute, MUTE_WORKER).unwrap();
    Command::new("/usr/bin/python3").arg(&mute).arg(&socket).stdin(Stdio::null()).spawn().unwrap();
    wait_until(|| socket.exists(), "the mute worker never listened");
    let (mut frontend, entry) = rehearsal.frontend(&vcx_testkit::session_id(), &socket, json!({"cwd": rehearsal.root}));
    let stopped = thread::spawn(move || frontend.wait().unwrap());

    let switched = rehearsal.cutover(&rehearsal.root.join("recovery"), &["--to", "rust"], &[("VCX_CUTOVER_ATTACH_WAIT", SHORT_ATTACH_WAIT)]);

    assert!(!switched.status.success(), "{}", text(&switched));
    assert_eq!(stopped.join().unwrap().signal(), Some(libc::SIGKILL));
    assert_eq!(fs::read_to_string(rehearsal.root.join("bin/vcx")).unwrap(), SWIFT_LAUNCHER, "{}", text(&switched));
    let opened = fs::read_to_string(rehearsal.root.join("opened.log")).unwrap_or_default();
    assert!(opened.contains("Vibe Code X.app"), "the Swift app was not started again ({opened:?}): {}", text(&switched));
    assert!(entry.exists(), "the Swift app lost the window it reopens: {}", text(&switched));
    assert_eq!(rehearsal.report().unwrap()["windows"], json!([]), "{}", text(&switched));
    assert!(rehearsal.root.join("home/Applications/Vibe Code X.app/Contents/marker").exists());
}

#[test]
fn carries_the_window_files_newer_draft_and_frame_and_starts_new_sessions_on_the_rust_worker_in_a_vcx_rust_already_running() {
    keep_build_lock_out();
    if !rust_worker_built() {
        return;
    }
    let Some(worker) = vcx_testkit::SwiftWorker::start("carry") else {
        return eprintln!("skipped: no Swift VCX binary (VCX_SWIFT_BINARY or the installed app)");
    };
    let id = vcx_testkit::session_id();
    let request = vcx_proto::AttachRequest { session_id: id.clone(), cwd: worker.directory.to_string_lossy().into_owned(), prompt: "left in the swift app".into(), ..Default::default() };
    let client = vcx_proto::Client::connect(&worker.socket, |_| {}).unwrap();
    client.hello().unwrap();
    client.attach(&request).unwrap();
    drop(client);
    let rehearsal = Rehearsal::new("carry", worker.app().get_program().as_ref());
    rehearsal.start_app();
    let draft = json!([{"type": "text", "text": "typed in the swift window"}]);
    let (mut frontend, entry) = rehearsal.frontend(&id, &worker.socket, json!({"cwd": worker.directory, "draft": draft, "draftGeneration": NEWER_DRAFT_GENERATION, "windowState": {"frame": SWIFT_FRAME}}));
    let stopped = thread::spawn(move || frontend.wait().unwrap());

    let switched = rehearsal.cutover(&rehearsal.root.join("recovery"), &["--to", "rust", "--rust-worker"], &[]);

    assert!(switched.status.success(), "{}", text(&switched));
    assert_eq!(stopped.join().unwrap().signal(), Some(libc::SIGKILL));
    let report = rehearsal.report().unwrap();
    let window = report["windows"].as_array().unwrap().iter().find(|window| window["sessionId"] == json!(id)).cloned().unwrap_or_default();
    assert_eq!((&window["draftGeneration"], &window["carried"]), (&json!(NEWER_DRAFT_GENERATION), &json!(true)), "{report:#}");
    assert_eq!((&window["frame"][0], &window["frame"][2]), (&json!(SWIFT_LEFT), &json!(SWIFT_WIDTH)), "the window left the Swift frame: {report:#}");
    assert!(!entry.exists(), "{}", text(&switched));
    let folder = rehearsal.root.join("work");
    fs::create_dir_all(&folder).unwrap();
    let opened = control::ask(&rehearsal.root.join("state/control.sock"), &json!({"open": {"cwd": folder}})).unwrap();
    assert!(opened["sessionId"].is_string(), "{opened}");
    let started_from = format!("{} --runtime-worker ", rehearsal.root.join("home/Applications/VCX Rust.app/Contents/MacOS/vcx-worker").display());
    let on_rust_worker = || String::from_utf8_lossy(&Command::new("/bin/ps").args(["-axo", "command="]).output().unwrap().stdout).lines().any(|line| line.starts_with(&started_from));
    wait_until(on_rust_worker, "the running VCX Rust started the new session's worker elsewhere than the Rust worker");
}
