//! The app run windowless in its own state and config folders, its sessions on Swift workers that talk to the fixture
//! agent: nothing here touches a window or session someone works in.

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use vcx_cli::control;
use vcx_proto::Client;

const INSTALLED: &str = "Applications/Vibe Code X.app/Contents/MacOS/VCX";
/// The Rust worker as the workspace builds it (`cargo build -p vcx-worker`).
const RUST_WORKER: &str = "../../target/debug/vcx-worker";
const PRIVATE_FOLDER: u32 = 0o700;
const EXECUTABLE: u32 = 0o755;
const WAIT: Duration = Duration::from_secs(40);
const POLL: Duration = Duration::from_millis(100);
const THIRTEEN: usize = 13;

/// One app's homes, the app process, and every worker it started, all stopped and removed with it.
struct Run {
    root: PathBuf,
    app: Option<Child>,
}

impl Run {
    fn new(name: &str) -> Option<Self> {
        let Some(worker) = swift_binary() else {
            eprintln!("skipped: no Swift VCX binary (VCX_SWIFT_BINARY or the installed app) to run sessions on");
            return None;
        };
        Some(Self::on(name, &worker))
    }

    /// The app with its sessions on `worker`.
    fn on(name: &str, worker: &Path) -> Self {
        keep_build_lock_out();
        // Unix socket paths are capped near 104 bytes, so the homes sit in /tmp.
        let root = PathBuf::from(format!("/tmp/vcx-rust-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for folder in ["state", "config"] {
            fs::create_dir_all(root.join(folder)).unwrap();
            fs::set_permissions(root.join(folder), fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
        }
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/fake_agent.py").canonicalize().unwrap();
        let command = root.join("command.json");
        fs::write(&command, json!(["/usr/bin/python3", fixture]).to_string()).unwrap();
        let settings = json!({"worker": worker, "workerArguments": ["--runtime-test", "--runtime-fixture-command", command]});
        fs::write(root.join("config/settings.json"), settings.to_string()).unwrap();
        Self { root, app: None }
    }

    fn folder(&self, name: &str) -> PathBuf {
        let folder = self.root.join("work").join(name);
        fs::create_dir_all(&folder).unwrap();
        folder.canonicalize().unwrap()
    }

    fn command(&self) -> Command {
        // VCX_RUST_APP points the checks at an installed bundle's binary instead of the one just built.
        let mut command = Command::new(std::env::var_os("VCX_RUST_APP").unwrap_or_else(|| env!("CARGO_BIN_EXE_vcx-rust").into()));
        command.envs(vcx_config::Homes::under(&self.root).environment());
        // His own update state stays out of the checks.
        command.env("VCX_UPDATE_STATE", self.root.join("update"));
        // The test may itself run in an agent's window: the app must not take it for the caller.
        command.env_remove("CLAUDE_CODE_SESSION_ID").env_remove("VCX_THREAD_ID");
        command
    }

    fn cli(&self, arguments: &[&str]) -> Output {
        self.command().args(arguments).stdin(Stdio::null()).output().unwrap()
    }

    /// Starts the app windowless and waits for its control socket.
    fn start(&mut self, arguments: &[&str]) {
        let child = self.command().arg("--windowless").args(arguments).stdin(Stdio::null()).stdout(Stdio::null()).spawn().unwrap();
        self.app = Some(child);
        self.wait_for(|_| true);
    }

    fn ask(&self, body: &Value) -> Option<Value> {
        control::ask(&self.root.join("state/control.sock"), body)
    }

    fn report(&self) -> Option<Value> {
        self.ask(&json!({"report": {}}))
    }

    fn wait_for(&self, done: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + WAIT;
        let mut last = Value::Null;
        while Instant::now() < deadline {
            if let Some(report) = self.report() {
                if done(&report) {
                    return report;
                }
                last = report;
            }
            thread::sleep(POLL);
        }
        panic!("the app never reached the state awaited: {last:#}");
    }

    /// Ends the app as a crash would: its workers stay.
    fn kill_app(&mut self) {
        if let Some(mut app) = self.app.take() {
            let _ = app.kill();
            let _ = app.wait();
        }
    }

    fn wait_for_exit(&mut self) -> bool {
        let Some(app) = &mut self.app else { return true };
        let deadline = Instant::now() + WAIT;
        while Instant::now() < deadline {
            if let Ok(Some(_)) = app.try_wait() {
                self.app = None;
                return true;
            }
            thread::sleep(POLL);
        }
        false
    }

    fn worker_pids(&self) -> Vec<i64> {
        let Ok(entries) = fs::read_dir(self.root.join("state/runtime")) else { return Vec::new() };
        entries.flatten().filter(|entry| entry.path().extension().is_some_and(|extension| extension == "sock")).filter_map(|entry| Client::connect(&entry.path(), |_| {}).ok()?.hello().ok().map(|hello| hello.pid)).collect()
    }

    fn kill_workers(&self) {
        for pid in self.worker_pids() {
            // SAFETY: the pid was named by a worker on this run's own socket.
            unsafe { libc::kill(pid as i32, libc::SIGKILL) };
        }
        // A worker that no longer answers on its socket still names this run's folder in its arguments.
        let _ = Command::new("/usr/bin/pkill").args(["-KILL", "-f", &format!("{}/", self.root.display())]).status();
    }
}

impl Drop for Run {
    fn drop(&mut self) {
        self.kill_app();
        self.kill_workers();
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// No process a test starts may keep `build-stack`'s lock once the test is gone (see `worker::keep_build_lock_out`).
fn keep_build_lock_out() {
    let Some(fd) = std::env::var("BUILD_STACK_FD").ok().and_then(|fd| fd.parse::<libc::c_int>().ok()) else { return };
    // SAFETY: F_SETFD on a number only changes that descriptor's flags.
    unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
}

fn swift_binary() -> Option<PathBuf> {
    let path = match std::env::var_os("VCX_SWIFT_BINARY") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(std::env::var_os("HOME")?).join(INSTALLED),
    };
    path.exists().then_some(path)
}

fn rust_worker() -> Option<PathBuf> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(RUST_WORKER);
    path.is_file().then(|| path.canonicalize().unwrap())
}

fn windows(report: &Value) -> &Vec<Value> {
    report["windows"].as_array().unwrap()
}

fn kinds(window: &Value) -> Vec<&str> {
    window["page"]["rows"].as_array().map(|rows| rows.iter().filter_map(|row| row["kind"].as_str()).collect()).unwrap_or_default()
}

/// The fixture agent gives every turn the same item ids, so a later turn redraws the first one's tool call and answer
/// rows: turns are counted by their prompts.
fn drew_turns(window: &Value, turns: usize) -> bool {
    let kinds = kinds(window);
    kinds.iter().filter(|kind| **kind == "user").count() == turns && kinds.contains(&"assistant") && window["idle"] == true
}

fn open(run: &Run, cwd: &Path, prompt: &str) -> String {
    let answer = run.ask(&json!({"open": {"cwd": cwd, "prompt": prompt}})).unwrap();
    answer["sessionId"].as_str().unwrap_or_else(|| panic!("no window opened: {answer}")).to_owned()
}

fn text(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned() + &String::from_utf8_lossy(&output.stderr)
}

#[test]
fn runs_several_session_windows_in_one_process_each_on_its_own_worker() {
    let Some(mut run) = Run::new("several") else { return };
    let (first, second) = (run.folder("first"), run.folder("second"));
    run.start(&["--cwd", first.to_str().unwrap(), "first prompt"]);

    open(&run, &second, "second prompt");

    let report = run.wait_for(|report| windows(report).len() == 2 && windows(report).iter().all(|window| drew_turns(window, 1)));
    let cwds: Vec<&str> = windows(&report).iter().map(|window| window["cwd"].as_str().unwrap()).collect();
    assert_eq!(cwds, [first.to_str().unwrap(), second.to_str().unwrap()]);
    assert!(windows(&report).iter().all(|window| window["visible"] == false), "a check never shows a window");
    assert_eq!(run.worker_pids().len(), 2, "each session has its own worker");
}

#[test]
fn forwards_a_second_launch_to_the_running_app() {
    let Some(mut run) = Run::new("forward") else { return };
    let (first, second) = (run.folder("first"), run.folder("second"));
    run.start(&["--cwd", first.to_str().unwrap()]);

    let launched = run.cli(&["--cwd", second.to_str().unwrap(), "from the command line"]);

    assert!(launched.status.success(), "{}", text(&launched));
    let report = run.wait_for(|report| windows(report).iter().any(|window| window["cwd"] == second.to_str().unwrap() && drew_turns(window, 1)));
    assert_eq!(report["pid"], run.app.as_ref().unwrap().id(), "the window opened in the app already running");
    assert_eq!(windows(&report).len(), 2);
}

#[test]
fn finds_its_sessions_again_after_the_app_is_killed() {
    let Some(mut run) = Run::new("restart") else { return };
    let folder = run.folder("kept");
    run.start(&["--cwd", folder.to_str().unwrap(), "before the crash"]);
    let before = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    run.kill_app();

    run.start(&[]);

    let after = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    assert_eq!(windows(&after)[0]["sessionId"], windows(&before)[0]["sessionId"]);
    assert_eq!(windows(&after)[0]["cwd"], folder.to_str().unwrap());
}

#[test]
fn runs_its_sessions_on_the_rust_worker_and_finds_them_again_after_a_crash() {
    let Some(worker) = rust_worker() else {
        return eprintln!("skipped: no Rust worker; build it with cargo build -p vcx-worker");
    };
    let mut run = Run::on("rustworker", &worker);
    let folder = run.folder("rust");
    run.start(&["--cwd", folder.to_str().unwrap(), "on the rust worker"]);
    let before = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    let socket = PathBuf::from(windows(&before)[0]["socket"].as_str().unwrap());
    let build = Client::connect(&socket, |_| {}).unwrap().hello().unwrap().build;
    run.kill_app();

    run.start(&[]);

    let after = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    assert!(build.starts_with("rust-"), "the session runs on {build}");
    assert_eq!((&windows(&after)[0]["sessionId"], &windows(&after)[0]["cwd"]), (&windows(&before)[0]["sessionId"], &json!(folder)));
}

#[test]
fn becomes_the_newly_installed_build_when_asked_and_reopens_its_window_on_the_same_session() {
    let Some(mut run) = Run::new("relaunch") else { return };
    let folder = run.folder("relaunch");
    run.start(&["--cwd", folder.to_str().unwrap(), "before the update"]);
    let before = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    let control = vcx_config::Homes::under(&run.root).control();
    let listening = fs::metadata(&control).unwrap().ino();
    let pid = run.app.as_ref().unwrap().id();
    let taken = run.root.join("probe.taken");
    let mut probe = Command::new("/usr/bin/python3").args(["-c", LOCK_PROBE]).arg(vcx_config::Homes::under(&run.root).lock()).arg(&taken).spawn().unwrap();
    while !taken.exists() {
        thread::sleep(POLL);
    }

    // SAFETY: the pid is this run's own app, as build-rust.sh --install signals the installed one.
    unsafe { libc::kill(pid as i32, libc::SIGUSR1) };

    // The new image binds a fresh control socket once it runs; its report, which waits on the reopened page, is the
    // next wait, so a loaded Mac's slow page never eats into the exec's own time.
    let deadline = Instant::now() + WAIT;
    while fs::metadata(&control).map(|info| info.ino()).ok() == Some(listening) {
        assert!(Instant::now() < deadline, "the app never came back as the new build");
        thread::sleep(POLL);
    }
    let after = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    let _ = probe.kill();
    let _ = probe.wait();
    assert_eq!(after["pid"], json!(pid));
    assert_eq!(windows(&after)[0]["sessionId"], windows(&before)[0]["sessionId"]);
    assert_eq!(fs::read_to_string(&taken).unwrap(), "0", "another process took the state folder's lock during the relaunch");
}

/// A second launch in the same moment, at its most eager: takes the state folder's lock whenever it is free and holds
/// it long enough for the relaunched image to find it taken; writes how many times it got it.
const LOCK_PROBE: &str = "import fcntl, sys, time
lock, taken = open(sys.argv[1], 'a'), sys.argv[2]
got = 0
open(taken, 'w').write('0')
while True:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        time.sleep(0.0005)
        continue
    got += 1
    open(taken, 'w').write(str(got))
    time.sleep(0.05)
    fcntl.flock(lock, fcntl.LOCK_UN)
";

#[test]
fn keeps_its_window_through_a_live_update_of_the_rust_worker() {
    let Some(worker) = rust_worker() else {
        return eprintln!("skipped: no Rust worker; build it with cargo build -p vcx-worker");
    };
    let mut run = Run::on("swap", &worker);
    let folder = run.folder("swap");
    run.start(&["--cwd", folder.to_str().unwrap(), "before the update"]);
    let before = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    let (id, socket) = (windows(&before)[0]["sessionId"].as_str().unwrap().to_owned(), PathBuf::from(windows(&before)[0]["socket"].as_str().unwrap()));
    let old = Client::connect(&socket, |_| {}).unwrap().hello().unwrap();

    // SAFETY: the pid was named by this run's own worker on its socket.
    unsafe { libc::kill(old.pid as i32, libc::SIGUSR1) };

    let deadline = Instant::now() + WAIT;
    let new = loop {
        if let Some(hello) = Client::connect(&socket, |_| {}).ok().and_then(|client| client.hello().ok()).filter(|hello| hello.instance_id != old.instance_id) {
            break hello;
        }
        assert!(Instant::now() < deadline, "the worker never came back as a new instance");
        thread::sleep(POLL);
    };
    let sent = run.ask(&json!({"send": {"to": id, "text": "after the update", "from": id}})).unwrap();
    let after = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 2));
    assert_eq!(new.pid, old.pid, "the update runs in the same process");
    assert_eq!(windows(&after)[0]["sessionId"], json!(id), "{sent}");
}

#[test]
fn finishes_at_launch_a_close_the_last_run_left_unconfirmed_instead_of_reopening_it() {
    let Some(mut run) = Run::new("closing") else { return };
    let folder = run.folder("closing");
    run.start(&["--cwd", folder.to_str().unwrap(), "closed as the app crashed"]);
    let before = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    let id = windows(&before)[0]["sessionId"].as_str().unwrap().to_owned();
    run.kill_app();
    let list = run.root.join("state/windows.json");
    let mut saved: Value = serde_json::from_str(&fs::read_to_string(&list).unwrap()).unwrap();
    saved[0]["closing"] = json!(true);
    fs::write(&list, saved.to_string()).unwrap();

    run.start(&[]);

    let homes = vcx_config::Homes::under(&run.root);
    let deadline = Instant::now() + WAIT;
    while vcx_app::worker::running(&homes).iter().any(|session| session.session_id == id) || fs::read_to_string(&list).unwrap().trim() != "[]" {
        assert!(Instant::now() < deadline, "the close was never finished: {}", fs::read_to_string(&list).unwrap());
        thread::sleep(POLL);
    }
    assert_eq!(windows(&run.report().unwrap()).len(), 0);
}

#[test]
fn reattaches_a_running_session_even_without_its_window_list() {
    let Some(mut run) = Run::new("unlisted") else { return };
    let folder = run.folder("unlisted");
    run.start(&["--cwd", folder.to_str().unwrap(), "left running"]);
    let before = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    run.kill_app();
    fs::remove_file(run.root.join("state/windows.json")).unwrap();

    run.start(&[]);

    let after = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    assert_eq!(windows(&after)[0]["sessionId"], windows(&before)[0]["sessionId"]);
}

/// The worker gone too: a new one is started on the window's socket and the window comes back in its folder. Which
/// conversation it resumes is `app::plan`'s test: a Swift worker on a fixture agent ignores `resume`.
#[test]
fn starts_a_new_worker_for_a_saved_window_whose_worker_ended_too() {
    let Some(mut run) = Run::new("cold") else { return };
    let folder = run.folder("cold");
    run.start(&["--cwd", folder.to_str().unwrap(), "saved before the reboot"]);
    let before = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1) && !windows(report)[0]["recordID"].is_null());
    let old_workers = run.worker_pids();
    run.kill_app();
    run.kill_workers();

    run.start(&[]);

    let after = run.wait_for(|report| windows(report).len() == 1 && windows(report)[0]["state"] != "pending" && windows(report)[0]["threadId"].is_string());
    let (old, new) = (&windows(&before)[0], &windows(&after)[0]);
    assert_eq!((&new["sessionId"], &new["socket"], &new["cwd"]), (&old["sessionId"], &old["socket"], &json!(folder)));
    let new_workers = run.worker_pids();
    assert!(new_workers.len() == 1 && !old_workers.contains(&new_workers[0]), "{old_workers:?} then {new_workers:?}");
}

#[test]
fn restores_each_window_frame_on_the_next_launch() {
    let Some(mut run) = Run::new("frames") else { return };
    let folder = run.folder("framed");
    run.start(&["--cwd", folder.to_str().unwrap()]);
    let id = run.wait_for(|report| windows(report).len() == 1)["windows"][0]["sessionId"].as_str().unwrap().to_owned();
    let placed = run.ask(&json!({"frame": {"to": id, "frame": [120.0, 140.0, 1020.0, 640.0]}})).unwrap();
    let saved = || fs::read_to_string(run.root.join("state/windows.json")).ok().and_then(|text| serde_json::from_str::<Value>(&text).ok());
    let deadline = Instant::now() + WAIT;
    while saved().is_none_or(|list| list[0]["frame"] != placed["frame"]) {
        assert!(Instant::now() < deadline, "the frame was never saved: {placed} {:?}", saved());
        thread::sleep(POLL);
    }
    run.kill_app();

    run.start(&[]);

    let after = run.wait_for(|report| windows(report).len() == 1);
    assert_eq!(windows(&after)[0]["frame"], placed["frame"]);
    assert_eq!(placed["frame"].as_array().unwrap()[2..], [json!(1020.0), json!(640.0)]);
}

/// What Fleet's tile and Watcher's inbox post to raise a VCX window, sent here as they send it.
fn post_focus(session_id: &str) {
    let script = format!("ObjC.import('Foundation'); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('com.mr.vcx.focus', undefined, $({{sessionId: '{session_id}'}}), true)");
    let posted = Command::new("osascript").args(["-l", "JavaScript", "-e", &script]).output().unwrap();
    assert!(posted.status.success(), "{}", String::from_utf8_lossy(&posted.stderr));
}

#[test]
fn raises_the_window_fleet_or_watcher_asks_for() {
    let Some(mut run) = Run::new("raise") else { return };
    let (first, second) = (run.folder("first"), run.folder("second"));
    run.start(&["--cwd", first.to_str().unwrap()]);
    run.wait_for(|report| windows(report).len() == 1);
    assert!(run.cli(&["--cwd", second.to_str().unwrap()]).status.success());
    let report = run.wait_for(|report| windows(report).len() == 2);
    let wanted = windows(&report).iter().find(|window| window["cwd"] == json!(second)).unwrap()["sessionId"].as_str().unwrap().to_owned();
    let presence = run.root.join(format!("state/fleet/{}.json", report["pid"]));
    let in_front = |done: &dyn Fn(&Value) -> bool, what: &str| {
        let deadline = Instant::now() + WAIT;
        while !fs::read_to_string(&presence).ok().and_then(|text| serde_json::from_str::<Value>(&text).ok()).is_some_and(|record| done(&record)) {
            assert!(Instant::now() < deadline, "Fleet never saw {what}");
            thread::sleep(POLL);
        }
    };
    in_front(&|record| record["sessions"].as_array().is_some_and(|sessions| sessions.len() == 2) && record["sessionId"] != json!(wanted), "the first window in front");

    post_focus(&wanted);

    in_front(&|record| record["sessionId"] == json!(wanted), "the asked window in front");
}

#[test]
fn lists_its_windows_and_publishes_them_to_fleet_under_its_own_folder() {
    let Some(mut run) = Run::new("sessions") else { return };
    let folder = run.folder("listed");
    run.start(&["--cwd", folder.to_str().unwrap(), "list me please"]);
    let report = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    let id = windows(&report)[0]["sessionId"].as_str().unwrap().to_owned();
    let presence = run.root.join(format!("state/fleet/{}.json", report["pid"]));
    let deadline = Instant::now() + WAIT;
    while !fs::read_to_string(&presence).is_ok_and(|text| text.contains("ready")) {
        assert!(Instant::now() < deadline, "no ready presence in {}", presence.display());
        thread::sleep(POLL);
    }

    let listed = run.cli(&["--sessions"]);

    let record: Value = serde_json::from_str(&fs::read_to_string(&presence).unwrap()).unwrap();
    assert_eq!((record["sessionId"].as_str(), record["state"].as_str(), record["cwd"].as_str()), (Some(id.as_str()), Some("ready"), folder.to_str()));
    let line = text(&listed);
    assert!(line.contains(&id[..8]) && line.contains("list me please") && line.contains(folder.to_str().unwrap()), "{line}");
}

/// The run panel's heading and output, read in the page.
const RUN_PANEL: &str = "[document.querySelector('#run .bar p')?.textContent, document.querySelector('#run pre.output')?.textContent].join('|')";

#[test]
fn runs_a_command_offered_in_the_run_panel_and_shows_its_output_and_exit_code() {
    let Some(mut run) = Run::new("panel") else { return };
    let folder = run.folder("panel");
    run.start(&["--cwd", folder.to_str().unwrap(), "run something"]);
    let id = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1))["windows"][0]["sessionId"].as_str().unwrap().to_owned();
    let evaluate = |script: &str| run.ask(&json!({"evaluate": {"to": id, "script": script}})).unwrap();

    let offered = evaluate("vcxRun.offer('echo vcx-run-ok'); document.querySelector('#run .ub.primary').click(); vcxRun.open");

    assert_eq!(offered["result"], "true", "{offered}");
    let deadline = Instant::now() + WAIT;
    let mut panel = String::new();
    while !panel.starts_with("Done") {
        assert!(Instant::now() < deadline, "the run never finished: {panel}");
        thread::sleep(POLL);
        panel = serde_json::from_str(evaluate(RUN_PANEL)["result"].as_str().unwrap()).unwrap();
    }
    assert_eq!(panel.trim_end(), "Done \u{b7} exit 0|vcx-run-ok");
}

fn copy_folder(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let path = entry.unwrap().path();
        let target = to.join(path.file_name().unwrap());
        if path.is_dir() { copy_folder(&path, &target) } else { fs::copy(&path, &target).map(drop).unwrap() }
    }
}

/// The installed page's own mark, read in the page; `none` on the built-in copy.
const PAGE_MARK: &str = "document.querySelector('meta[name=vcx-page]')?.content ?? 'none'";

#[test]
fn shows_the_installed_page_and_reloads_it_in_place_when_the_folder_changes() {
    let Some(mut run) = Run::new("page") else { return };
    let page = vcx_config::Homes::under(&run.root).page();
    copy_folder(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../../template"), &page);
    let index = fs::read_to_string(page.join("index.html")).unwrap();
    let marked = |mark: &str| index.replacen("<head>", &format!("<head>\n<meta name=\"vcx-page\" content=\"{mark}\">"), 1);
    fs::write(page.join("index.html"), marked("one")).unwrap();
    let folder = run.folder("page");
    run.start(&["--cwd", folder.to_str().unwrap(), "show the page"]);
    let before = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    let id = windows(&before)[0]["sessionId"].as_str().unwrap().to_owned();
    // A page still loading answers no script: that read counts as no mark yet.
    let mark = || -> String { run.ask(&json!({"evaluate": {"to": id, "script": PAGE_MARK}})).and_then(|answer| serde_json::from_str(answer["result"].as_str()?).ok()).unwrap_or_default() };
    let shown = mark();

    fs::write(page.join("index.html"), marked("two")).unwrap();

    let deadline = Instant::now() + WAIT;
    while mark() != "two" {
        assert!(Instant::now() < deadline, "the window never showed the edited page");
        thread::sleep(POLL);
    }
    let after = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    assert_eq!(shown, "one");
    assert_eq!((&after["pid"], &windows(&after)[0]["sessionId"]), (&before["pid"], &windows(&before)[0]["sessionId"]));
}

/// The status bar's progress chip, read in the page; empty while none shows.
const PROGRESS_CHIP: &str = "document.querySelector('[data-chip=progress]')?.textContent ?? ''";

#[test]
fn shows_what_the_agent_waits_on_in_the_status_bar_and_hides_it_once_the_file_goes() {
    let Some(mut run) = Run::new("progress") else { return };
    let folder = run.folder("progress");
    run.start(&["--cwd", folder.to_str().unwrap(), "wait for something"]);
    let report = run.wait_for(|report| windows(report).len() == 1 && windows(report)[0]["progressFile"].is_string() && drew_turns(&windows(report)[0], 1));
    let (id, file) = (windows(&report)[0]["sessionId"].as_str().unwrap().to_owned(), PathBuf::from(windows(&report)[0]["progressFile"].as_str().unwrap()));
    let chip = || -> String { serde_json::from_str(run.ask(&json!({"evaluate": {"to": id, "script": PROGRESS_CHIP}})).unwrap()["result"].as_str().unwrap()).unwrap() };
    let until = |done: &dyn Fn(&str) -> bool| {
        let deadline = Instant::now() + WAIT;
        loop {
            let shown = chip();
            if done(&shown) {
                return shown;
            }
            assert!(Instant::now() < deadline, "the progress chip stayed at {shown:?}");
            thread::sleep(POLL);
        }
    };
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    fs::create_dir_all(file.parent().unwrap()).unwrap();

    fs::write(&file, format!("Fetching weights\t{now}\t600\n")).unwrap();
    let shown = until(&|shown| shown.contains("Fetching weights"));
    fs::remove_file(&file).unwrap();
    let hidden = until(&|shown| shown.is_empty());

    assert!(shown.contains("min left"), "{shown}");
    assert_eq!(hidden, "");
}

/// The status bar's updating chip, read in the page; empty while none shows.
const UPDATE_CHIP: &str = "document.querySelector('[data-chip=update]')?.textContent ?? ''";

#[test]
fn shows_the_update_being_built_in_every_window_and_hides_it_once_the_build_ends() {
    let Some(mut run) = Run::new("update") else { return };
    let folder = run.folder("update");
    let state = run.root.join("update");
    fs::create_dir_all(&state).unwrap();
    run.start(&["--cwd", folder.to_str().unwrap()]);
    let report = run.wait_for(|report| windows(report).len() == 1);
    let id = windows(&report)[0]["sessionId"].as_str().unwrap().to_owned();
    let chip = || -> String { serde_json::from_str(run.ask(&json!({"evaluate": {"to": id, "script": UPDATE_CHIP}})).unwrap()["result"].as_str().unwrap()).unwrap() };
    let until = |done: &dyn Fn(&str) -> bool| {
        let deadline = Instant::now() + WAIT;
        loop {
            let shown = chip();
            if done(&shown) {
                return shown;
            }
            assert!(Instant::now() < deadline, "the updating chip stayed at {shown:?}");
            thread::sleep(POLL);
        }
    };
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();

    fs::write(state.join("building"), format!("{now}\tfix: the task bar\n")).unwrap();
    let shown = until(&|shown| !shown.is_empty());
    fs::remove_file(state.join("building")).unwrap();
    let hidden = until(&|shown| shown.is_empty());

    assert!(shown.contains("fix: the task bar"), "{shown}");
    assert_eq!(hidden, "");
}

/// Each action fold of the transcript: open or not.
const ACTION_FOLDS: &str = "[...document.querySelectorAll('details.action')].map(fold => fold.open).join(',')";

#[test]
fn opens_every_action_on_details_and_folds_them_again_on_focus_without_asking_the_agent() {
    let Some(mut run) = Run::new("details") else { return };
    let folder = run.folder("details");
    run.start(&["--cwd", folder.to_str().unwrap(), "show the details"]);
    let id = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1))["windows"][0]["sessionId"].as_str().unwrap().to_owned();
    let evaluate = |script: &str| -> String { serde_json::from_str(run.ask(&json!({"evaluate": {"to": id, "script": script}})).unwrap()["result"].as_str().unwrap()).unwrap() };
    let command = |text: &str| evaluate(&format!("vcx.post({{type: 'command', text: '{text}'}}); ''"));
    let wait_for_folds = |wanted: bool| -> String {
        let deadline = Instant::now() + WAIT;
        loop {
            let folds = evaluate(ACTION_FOLDS);
            if !folds.is_empty() && folds.split(',').all(|open| open == wanted.to_string()) {
                return folds;
            }
            assert!(Instant::now() < deadline, "the action folds never turned open={wanted}: {folds}");
            thread::sleep(POLL);
        }
    };
    let before = evaluate(ACTION_FOLDS);

    command("/details");
    let opened = wait_for_folds(true);
    command("/focus");
    let folded = wait_for_folds(false);

    let report = run.report().unwrap();
    assert!(before.contains("false"), "the actions start folded: {before}");
    assert_eq!((opened.matches("true").count(), folded.matches("false").count()), (before.split(',').count(), before.split(',').count()));
    assert!(drew_turns(&windows(&report)[0], 1), "a command reached the agent: {report:#}");
}

/// Control-held mouse events on words of the fixture's answer ("Done with **bold** text."), each at the middle of its
/// word, as WebKit hands a Control-click to the page; the drag's last event is the release.
fn control_mouse(steps: &[(&str, &str)]) -> String {
    let steps: Vec<String> = steps.iter().map(|(kind, word)| format!("['{kind}', '{word}']")).collect();
    format!("(() => {{
        const at = word => {{
            const walker = document.createTreeWalker(document.getElementById('rows'), NodeFilter.SHOW_TEXT);
            for (let node; (node = walker.nextNode());) {{
                const index = node.data.indexOf(word);
                if (index < 0) continue;
                node.parentElement.scrollIntoView({{block: 'center'}});
                const range = document.createRange();
                range.setStart(node, index);
                range.setEnd(node, index + word.length);
                const box = range.getBoundingClientRect();
                return [box.x + box.width / 2, box.y + box.height / 2];
            }}
        }};
        for (const [kind, word] of [{}]) {{
            const [x, y] = at(word);
            document.elementFromPoint(x, y).dispatchEvent(new MouseEvent(kind, {{bubbles: true, cancelable: true, ctrlKey: true, button: 0, clientX: x, clientY: y}}));
        }}
        return '';
    }})()", steps.join(", "))
}

const LAST_PROMPT: &str = "[...document.querySelectorAll('.row[data-kind=\"user\"] .message')].pop()?.innerText ?? ''";

fn asked_after_control(name: &str, steps: &[(&str, &str)]) -> Option<String> {
    let mut run = Run::new(name)?;
    let folder = run.folder(name);
    run.start(&["--cwd", folder.to_str().unwrap(), "explain the answer"]);
    let id = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1))["windows"][0]["sessionId"].as_str().unwrap().to_owned();
    let evaluate = |script: &str| -> String { serde_json::from_str(run.ask(&json!({"evaluate": {"to": id, "script": script}})).unwrap()["result"].as_str().unwrap()).unwrap() };

    evaluate(&control_mouse(steps));

    run.wait_for(|report| drew_turns(&windows(report)[0], 2));
    Some(evaluate(LAST_PROMPT))
}

#[test]
fn asks_the_agent_to_define_the_word_control_clicked_in_the_answer() {
    let Some(asked) = asked_after_control("define", &[("mousedown", "Done"), ("mouseup", "Done")]) else { return };

    assert!(asked == "Define \"Done\" as used here, in at most 3 short lines.", "{asked}");
}

#[test]
fn asks_about_every_word_a_control_drag_crosses() {
    let Some(asked) = asked_after_control("definedrag", &[("mousedown", "Done"), ("mousemove", "bold"), ("mouseup", "bold")]) else { return };

    assert!(asked == "Define \"Done with bold\" as used here, in at most 3 short lines.", "{asked}");
}

#[test]
fn closes_the_front_session_on_command_q_and_offers_the_file_menu() {
    let Some(mut run) = Run::new("menus") else { return };
    run.start(&[]);

    let menus = run.wait_for(|report| report["menus"].is_array())["menus"].clone();

    let items = |title: &str| menus.as_array().unwrap().iter().find(|menu| menu["title"] == title).map(|menu| menu["items"].as_array().unwrap().clone()).unwrap_or_default();
    let application = menus[0]["items"].as_array().unwrap();
    let on_q: Vec<&Value> = application.iter().filter(|item| item["key"] == "q").collect();
    assert_eq!(on_q, [&json!({"title": "Close Session", "key": "q", "action": "closeWindow:"})], "{menus}");
    let on_k: Vec<&Value> = application.iter().filter(|item| item["key"] == "k").collect();
    assert_eq!(on_k, [&json!({"title": "Close Session", "key": "k", "action": "closeNow:", "hidden": true})], "{menus}");
    assert_eq!(application[0], json!({"title": "About VCX Rust", "key": "", "action": "orderFrontStandardAboutPanel:"}), "{menus}");
    assert!(application.iter().all(|item| item["action"] != "terminate:"), "{menus}");
    let file = items("File");
    let file: Vec<(&str, &str)> = file.iter().map(|item| (item["title"].as_str().unwrap(), item["action"].as_str().unwrap())).collect();
    assert_eq!(file, [("New Window", "newWindow:"), ("Open Project…", "openProject:"), ("Close Window", "closeWindow:")]);
}

#[test]
fn says_no_window_is_open_when_no_app_runs() {
    let Some(run) = Run::new("none") else { return };

    let listed = run.cli(&["--sessions"]);
    let sent = run.cli(&["--send", "anyone", "hello"]);

    assert_eq!(text(&listed).trim(), "No VCX Rust window is open.");
    assert!(!sent.status.success() && text(&sent).contains("No VCX Rust app is running."), "{}", text(&sent));
}

#[test]
fn delivers_a_message_from_one_window_to_another_naming_its_sender() {
    let Some(mut run) = Run::new("send") else { return };
    let (sender, receiver) = (run.folder("sender"), run.folder("receiver"));
    run.start(&["--cwd", sender.to_str().unwrap(), "sender window"]);
    let to = open(&run, &receiver, "receiver window");
    let from = run.wait_for(|report| windows(report).len() == 2 && windows(report).iter().all(|window| drew_turns(window, 1)))["windows"][0]["sessionId"].as_str().unwrap().to_owned();

    let sent = run.cli(&["--send", &to[..8], "--from", &from, "are", "you", "done?"]);

    assert!(sent.status.success(), "{}", text(&sent));
    let report = run.wait_for(|report| windows(report).iter().any(|window| window["sessionId"] == to.as_str() && drew_turns(window, 2)));
    let window = windows(&report).iter().find(|window| window["sessionId"] == to.as_str()).unwrap();
    let message = window["page"]["rows"].as_array().unwrap().iter().rfind(|row| row["kind"] == "user").unwrap()["text"].as_str().unwrap();
    assert!(message.contains("sender window") && message.contains("are you done?"), "{message}");
}

#[test]
fn moves_a_window_to_another_folder() {
    let Some(mut run) = Run::new("setdir") else { return };
    let (before, after) = (run.folder("before"), run.folder("after"));
    run.start(&["--cwd", before.to_str().unwrap(), "move me"]);
    let id = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1))["windows"][0]["sessionId"].as_str().unwrap().to_owned();

    let moved = run.cli(&["--set-dir", &id, after.to_str().unwrap()]);

    assert!(moved.status.success(), "{}", text(&moved));
    run.wait_for(|report| windows(report)[0]["cwd"] == after.to_str().unwrap());
    let deadline = Instant::now() + WAIT;
    while !fs::read_to_string(run.root.join("state/windows.json")).unwrap_or_default().contains(after.to_str().unwrap()) {
        assert!(Instant::now() < deadline, "the new folder was never saved");
        thread::sleep(POLL);
    }
}

#[test]
fn shows_each_window_its_task_and_marks_its_own_card_current() {
    let Some(mut run) = Run::new("tasks") else { return };
    let folder = run.folder("tasked");
    run.start(&["--cwd", folder.to_str().unwrap(), "give me a task"]);
    let report = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1) && windows(report)[0]["taskFile"].is_string());
    let task_file = PathBuf::from(windows(&report)[0]["taskFile"].as_str().unwrap());
    // A worker with no Fleet folder handed in gives the session a temporary one of its own (Swift `Session.fleetContextFile`).
    let own = task_file.parent().and_then(Path::file_name).is_some_and(|folder| folder.to_string_lossy().starts_with("vcx-fleet-"));
    assert!(own && !task_file.exists(), "{} is not this session's own new task file", task_file.display());

    fs::write(&task_file, "Add a task bar to VCX\n").unwrap();

    let report = run.wait_for(|report| windows(report)[0]["page"]["tasks"].as_array().is_some_and(|cards| !cards.is_empty()));
    fs::remove_file(&task_file).unwrap();
    let card = &windows(&report)[0]["page"]["tasks"][0];
    assert!(card["text"].as_str().unwrap().contains("Add a task bar to VCX"), "{card}");
    assert_eq!((card["state"].as_str(), card["current"].as_bool()), (Some("question"), Some(true)), "an answer without his Done line waits on him");
}

#[test]
fn ends_its_sessions_and_clears_its_list_when_asked_to_quit() {
    let Some(mut run) = Run::new("quit") else { return };
    let folder = run.folder("quit");
    run.start(&["--cwd", folder.to_str().unwrap(), "then quit"]);
    run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));

    run.ask(&json!({"quit": {}}));

    assert!(run.wait_for_exit(), "the app did not end");
    assert_eq!(fs::read_to_string(run.root.join("state/windows.json")).unwrap().trim(), "[]");
    assert!(!run.root.join("state/control.sock").exists());
}

/// A worker that holds its sessions in state `{state}` and refuses to close any, as one that cannot save the
/// conversation does.
const REFUSING_WORKER: &str = r#"#!/usr/bin/python3
import json, os, socket, sys, threading
path = sys.argv[sys.argv.index('--runtime-worker') + 1]
server = socket.socket(socket.AF_UNIX)
server.bind(path)
os.chmod(path, 0o600)
server.listen()
def answer(request):
    method, params = request.get('method'), request.get('params', {})
    if method == 'hello':
        return {'result': {'protocol': 1, 'build': 'refusing', 'pid': os.getpid()}}
    if method == 'attach':
        return {'result': {'sessionId': params['sessionId'], 'lease': 'L', 'revision': 1, 'state': {'cwd': params['cwd'], 'ready': True, **json.loads(sys.argv[-1])}}}
    if method == 'perform' and params.get('action') == 'close':
        return {'error': {'code': 'actionFailed', 'message': 'Could not save the current conversation.'}}
    return {'result': {}}
def serve(connection):
    for line in connection.makefile():
        request = json.loads(line)
        connection.sendall((json.dumps({**answer(request), 'id': request['id']}) + '\n').encode())
while True:
    threading.Thread(target=serve, args=(server.accept()[0],), daemon=True).start()
"#;

/// The app on a refusing worker whose sessions hold `state`, started on one window.
fn on_refusing_worker(name: &str, state: Value) -> (Run, PathBuf) {
    let script = PathBuf::from(format!("/tmp/vcx-rust-{}-{name}.py", std::process::id()));
    fs::write(&script, REFUSING_WORKER).unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(EXECUTABLE)).unwrap();
    let mut run = Run::on(name, &script);
    let mut settings: Value = serde_json::from_str(&fs::read_to_string(run.root.join("config/settings.json")).unwrap()).unwrap();
    settings["workerArguments"] = json!([state.to_string()]);
    fs::write(run.root.join("config/settings.json"), settings.to_string()).unwrap();
    let folder = run.folder(name);
    run.start(&["--cwd", folder.to_str().unwrap()]);
    (run, script)
}

#[test]
fn refuses_to_close_the_callers_own_window_or_one_holding_a_draft() {
    let (run, script) = on_refusing_worker("draft", json!({"threadID": "codex:T", "draft": [{"type": "text", "text": "unsent"}]}));
    let report = run.wait_for(|report| windows(report).len() == 1 && windows(report)[0]["threadId"] == "codex:T");
    let id = windows(&report)[0]["sessionId"].clone();

    let own = run.ask(&json!({"close": {"to": id, "threads": ["codex:T"]}})).unwrap();
    let drafted = run.ask(&json!({"close": {"to": id}})).unwrap();

    let _ = fs::remove_file(&script);
    assert!(own["error"].as_str().unwrap().ends_with("stays open: it is the calling session."), "{own}");
    assert!(drafted["error"].as_str().unwrap().ends_with("stays open: the composer holds a draft."), "{drafted}");
    assert_eq!(windows(&run.report().unwrap()).len(), 1);
}

#[test]
fn refuses_to_close_a_window_whose_agent_waits_on_a_permission() {
    let (run, script) = on_refusing_worker("permission", json!({"permissions": [{"id": "P"}]}));
    let report = run.wait_for(|report| windows(report).len() == 1);

    let asked = run.ask(&json!({"close": {"to": windows(&report)[0]["sessionId"]}})).unwrap();

    let _ = fs::remove_file(&script);
    assert!(asked["error"].as_str().unwrap().ends_with("stays open: a decision is pending."), "{asked}");
}

#[test]
fn keeps_a_window_whose_worker_cannot_save_its_session_and_says_why() {
    let (run, script) = on_refusing_worker("refusing", json!({}));
    let report = run.wait_for(|report| windows(report).len() == 1);
    let id = windows(&report)[0]["sessionId"].clone();

    let asked = run.ask(&json!({"close": {"to": id}}));

    let report = run.wait_for(|report| windows(report).len() == 1 && windows(report)[0]["page"]["notice"].as_str().is_some_and(|notice| notice.starts_with("Cannot close")));
    let _ = fs::remove_file(&script);
    assert_eq!(asked.unwrap()["closed"], json!(true));
    assert_eq!(windows(&report)[0]["sessionId"], id);
    assert_eq!(windows(&report)[0]["page"]["notice"], json!("Cannot close before saving the draft: Could not save the current conversation."));
}

/// What the Dock's Quit and a logout send: a quit Apple event, which AppKit turns into `terminate:`.
fn send_quit_event(pid: u32) {
    let script = format!("ObjC.import('AppKit'); $.NSRunningApplication.runningApplicationWithProcessIdentifier({pid}).terminate");
    let sent = Command::new("osascript").args(["-l", "JavaScript", "-e", &script]).output().unwrap();
    assert!(sent.status.success(), "{}", String::from_utf8_lossy(&sent.stderr));
}

#[test]
fn ends_its_sessions_and_clears_its_list_when_quit_from_the_dock_or_at_logout() {
    let Some(mut run) = Run::new("dockquit") else { return };
    let folder = run.folder("dockquit");
    run.start(&["--cwd", folder.to_str().unwrap(), "then quit from the dock"]);
    run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));

    send_quit_event(run.app.as_ref().unwrap().id());

    assert!(run.wait_for_exit(), "the app did not end");
    assert_eq!(fs::read_to_string(run.root.join("state/windows.json")).unwrap().trim(), "[]");
    assert!(!run.root.join("state/control.sock").exists());
}

#[test]
fn reads_its_settings_file_and_says_what_is_wrong_in_it() {
    let Some(mut run) = Run::new("settings") else { return };
    let folder = run.folder("settings");
    let mut settings: Value = serde_json::from_str(&fs::read_to_string(run.root.join("config/settings.json")).unwrap()).unwrap();
    settings["windowSize"] = json!([1040, 600]);
    settings["template"] = json!(run.root.join("no-such-template"));
    fs::write(run.root.join("config/settings.json"), settings.to_string()).unwrap();

    run.start(&["--cwd", folder.to_str().unwrap()]);

    let report = run.wait_for(|report| windows(report).len() == 1 && windows(report)[0]["page"]["notice"].is_string());
    assert_eq!(windows(&report)[0]["frame"].as_array().unwrap()[2..], [json!(1040.0), json!(600.0)]);
    assert!(windows(&report)[0]["page"]["notice"].as_str().unwrap().contains("built-in template"), "{:#}", windows(&report)[0]["page"]);
}

#[test]
fn hands_print_mode_to_the_background_runner_with_its_own_homes() {
    let Some(run) = Run::new("print") else { return };
    let runner = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../background.py");

    let printed = run.command().env("VCX_RUST_BACKGROUND", runner).args(["-p", "--help"]).output().unwrap();

    assert!(printed.status.success() && text(&printed).contains("usage: vcx -p"), "{}", text(&printed));
}

/// The measure the design rests on: thirteen windows in one process, two turns each, with the threads, memory and
/// delay from a worker revision to the page drawing it. Run with `--ignored --nocapture`.
#[test]
#[ignore = "a measure, not a check: about a minute of thirteen sessions"]
fn measures_thirteen_windows_in_one_process() {
    let Some(mut run) = Run::new("thirteen") else { return };
    let folders: Vec<PathBuf> = (0..THIRTEEN).map(|index| run.folder(&format!("window-{index}"))).collect();
    run.start(&[]);
    let idle = run.report().unwrap();
    let ids: Vec<String> = folders.iter().map(|folder| open(&run, folder, "first round")).collect();
    run.wait_for(|report| windows(report).len() == THIRTEEN && windows(report).iter().all(|window| drew_turns(window, 1)));

    for id in &ids {
        run.ask(&json!({"send": {"to": id, "from": id, "text": "second round"}})).unwrap();
    }
    let report = run.wait_for(|report| windows(report).iter().all(|window| drew_turns(window, 2)));

    println!("idle app: {:#}", idle["metrics"]);
    println!("thirteen windows: {:#}", json!({"metrics": report["metrics"], "delays": report["delays"]}));
    assert!(report["metrics"]["webContent"]["processes"].as_u64().unwrap() >= THIRTEEN as u64, "{:#}", report["metrics"]);
}

/// A headless Swift frontend holding `id` in a window of its own (its `--frontend-handoff-fixture`), as when he
/// leaves the Swift app with windows open; its recovery entry is what the switch reads.
fn swift_frontend(worker: &vcx_testkit::SwiftWorker, id: &str) -> Child {
    keep_build_lock_out();
    let runtime = worker.directory.join(vcx_testkit::RUNTIME);
    fs::create_dir_all(&runtime).unwrap();
    fs::set_permissions(&runtime, fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
    let ticket = runtime.join(format!("{}.restore.json", vcx_testkit::session_id()));
    let windows = json!({"windows": [{"cwd": worker.directory, "sessionId": id, "socket": worker.socket, "windowState": {}}]});
    fs::write(&ticket, windows.to_string()).unwrap();
    fs::set_permissions(&ticket, fs::Permissions::from_mode(0o600)).unwrap();
    worker.app().args(["--frontend-handoff-fixture", ticket.to_str().unwrap(), "success"]).stdin(Stdio::null()).spawn().unwrap()
}

#[test]
fn takes_over_a_window_the_swift_app_left_and_keeps_it_on_that_worker_after_a_relaunch() {
    let Some(worker) = vcx_testkit::SwiftWorker::start("takeover-app") else {
        return eprintln!("skipped: no Swift VCX binary (VCX_SWIFT_BINARY or the installed app)");
    };
    let id = vcx_testkit::session_id();
    let request = vcx_proto::AttachRequest { session_id: id.clone(), cwd: worker.directory.to_string_lossy().into_owned(), prompt: "left in the swift app".into(), ..Default::default() };
    let client = Client::connect(&worker.socket, |_| {}).unwrap();
    client.hello().unwrap();
    client.attach(&request).unwrap();
    drop(client);
    let mut frontend = swift_frontend(&worker, &id);
    let entry = worker.directory.join(vcx_testkit::RUNTIME).join("recovery").join(format!("{id}.window.json"));
    let deadline = Instant::now() + WAIT;
    let owner = || serde_json::from_slice::<Value>(&fs::read(&entry).ok()?).ok().map(|listed| listed["ownerPID"].clone());
    while owner() != Some(json!(frontend.id())) {
        assert!(Instant::now() < deadline, "the Swift frontend never listed its window for recovery");
        thread::sleep(POLL);
    }
    frontend.kill().unwrap();
    frontend.wait().unwrap();
    let mut run = Run::new("takeover").unwrap();
    run.start(&[]);

    let taken = run.ask(&json!({"takeOver": {"from": entry.parent().unwrap()}})).unwrap();

    let after = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    run.kill_app();
    run.start(&[]);
    let relaunched = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    assert_eq!(taken, json!({"taken": [{"sessionId": id, "cwd": worker.directory}]}));
    for window in [&windows(&after)[0], &windows(&relaunched)[0]] {
        assert_eq!((&window["sessionId"], &window["socket"]), (&json!(id), &json!(worker.socket)));
    }
    assert!(run.worker_pids().is_empty(), "the app started a worker of its own for a session the Swift worker holds");
}
