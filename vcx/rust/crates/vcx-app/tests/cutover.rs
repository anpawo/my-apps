//! A rehearsal of `cutover/cutover.sh` on folders of its own: a Swift frontend stopped out of its window, VCX Rust
//! started through `open` and taking that window over on the same Swift worker, the `vcx` command switched, the Rust
//! worker made the default, the Swift app in the Trash; then the way back.

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use vcx_cli::control;

const WAIT: Duration = Duration::from_secs(40);
const POLL: Duration = Duration::from_millis(100);
const PRIVATE_FOLDER: u32 = 0o700;
const PRIVATE_FILE: u32 = 0o600;
const EXECUTABLE: u32 = 0o755;
/// What switch.sh takes for the Swift app's launcher: install-native.py's mark on the second line, and the app's path.
const SWIFT_LAUNCHER: &str = "#!/bin/bash\n# vcx launcher\nexec \"$HOME/Applications/Vibe Code X.app/Contents/MacOS/VCX\" \"$@\"\n";
const RUST_MARK: &str = "# vcx launcher: VCX Rust";
const STUBS: [(&str, &str); 3] = [
    ("open", "#!/bin/bash\nHOME=\"$VCX_CUTOVER_REAL_HOME\" \"$VCX_CUTOVER_APP\" --windowless < /dev/null > /dev/null 2>&1 &\necho $! > \"$VCX_CUTOVER_PID\"\n"),
    ("gh", "#!/bin/bash\nexit 0\n"),
    ("launchctl", "#!/bin/bash\necho \"$*\" >> \"$VCX_CUTOVER_LAUNCHCTL\"\n"),
];

/// The rehearsal's folders, and the app `open` started there, stopped and removed with it.
struct Rehearsal {
    root: PathBuf,
}

impl Rehearsal {
    fn new(swift: &Path) -> Self {
        let root = PathBuf::from(format!("/tmp/vcx-cutover-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for folder in ["state", "config", "bin", "stubs", "update", "home/Applications/Vibe Code X.app/Contents", "home/Applications/VCX Rust.app/Contents/MacOS"] {
            fs::create_dir_all(root.join(folder)).unwrap();
        }
        for folder in ["state", "config"] {
            fs::set_permissions(root.join(folder), fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
        }
        fs::write(root.join("home/Applications/Vibe Code X.app/Contents/marker"), "swift").unwrap();
        symlink(env!("CARGO_BIN_EXE_vcx-rust"), root.join("home/Applications/VCX Rust.app/Contents/MacOS/vcx-rust")).unwrap();
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

    fn cutover(&self, recovery: &Path, arguments: &[&str]) -> Output {
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
            .env_remove("CLAUDE_CODE_SESSION_ID")
            .env_remove("VCX_THREAD_ID")
            .stdin(Stdio::null())
            .output()
            .unwrap()
    }

    fn report(&self) -> Option<Value> {
        control::ask(&self.root.join("state/control.sock"), &json!({"report": {}}))
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

fn text(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned() + &String::from_utf8_lossy(&output.stderr)
}

#[test]
fn switches_to_vcx_rust_on_the_swift_sessions_and_back_in_one_command_each_way() {
    keep_build_lock_out();
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
    let rehearsal = Rehearsal::new(worker.app().get_program().as_ref());
    let home = rehearsal.root.join("home");

    let to_rust = rehearsal.cutover(&recovery, &["--to", "rust", "--rust-worker"]);

    assert!(to_rust.status.success(), "{}", text(&to_rust));
    assert_eq!(stopped.join().unwrap().signal(), Some(libc::SIGKILL));
    let report = rehearsal.report().expect("VCX Rust answers once the script is done");
    let held: Vec<(&Value, &Value)> = report["windows"].as_array().unwrap().iter().map(|window| (&window["sessionId"], &window["socket"])).collect();
    assert_eq!(held, [(&json!(id), &json!(worker.socket))], "{}", text(&to_rust));
    let launcher = fs::read_to_string(rehearsal.root.join("bin/vcx")).unwrap();
    assert!(launcher.lines().any(|line| line == RUST_MARK), "{launcher}");
    let settings: Value = serde_json::from_slice(&fs::read(rehearsal.root.join("config/settings.json")).unwrap()).unwrap();
    assert_eq!(settings["worker"], json!(home.join("Applications/VCX Rust.app/Contents/MacOS/vcx-worker")));
    assert!(home.join(".Trash/Vibe Code X.app/Contents/marker").exists() && !home.join("Applications/Vibe Code X.app").exists());

    let to_swift = rehearsal.cutover(&recovery, &["--to", "swift"]);

    assert!(to_swift.status.success(), "{}", text(&to_swift));
    assert!(home.join("Applications/Vibe Code X.app/Contents/marker").exists());
    assert_eq!(fs::read_to_string(rehearsal.root.join("bin/vcx")).unwrap(), SWIFT_LAUNCHER);
    let verbs: Vec<String> = fs::read_to_string(rehearsal.root.join("launchctl.log")).unwrap().lines().filter_map(|line| line.split(' ').next().map(str::to_owned)).collect();
    assert_eq!(verbs, ["disable", "print", "bootout", "enable", "bootstrap"]);
}
