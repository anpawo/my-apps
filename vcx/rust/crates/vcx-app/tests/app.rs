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
    }
}

impl Drop for Run {
    fn drop(&mut self) {
        self.kill_app();
        self.kill_workers();
        let _ = fs::remove_dir_all(&self.root);
    }
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

    // SAFETY: the pid is this run's own app, as build-rust.sh --install signals the installed one.
    unsafe { libc::kill(pid as i32, libc::SIGUSR1) };

    let deadline = Instant::now() + WAIT;
    while fs::metadata(&control).map(|info| info.ino()).ok() == Some(listening) || run.ask(&json!({"report": {}})).is_none() {
        assert!(Instant::now() < deadline, "the app never came back as the new build");
        thread::sleep(POLL);
    }
    let after = run.wait_for(|report| windows(report).len() == 1 && drew_turns(&windows(report)[0], 1));
    assert_eq!(after["pid"], json!(pid));
    assert_eq!(windows(&after)[0]["sessionId"], windows(&before)[0]["sessionId"]);
}

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
