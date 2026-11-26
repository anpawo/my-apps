//! The app run windowless in its own state and config folders, its sessions on Swift workers that talk to the fixture
//! agent: nothing here touches a window or session someone works in.

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use vcx_cli::control;
use vcx_proto::Client;

const INSTALLED: &str = "Applications/Vibe Code X.app/Contents/MacOS/VCX";
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
        Some(Self { root, app: None })
    }

    fn folder(&self, name: &str) -> PathBuf {
        let folder = self.root.join("work").join(name);
        fs::create_dir_all(&folder).unwrap();
        folder.canonicalize().unwrap()
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_vcx-rust"));
        command.envs(vcx_config::Homes::under(&self.root).environment());
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
    let placed = run.ask(&json!({"frame": {"to": id, "frame": [120.0, 140.0, 900.0, 640.0]}})).unwrap();
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
    assert_eq!(placed["frame"].as_array().unwrap()[2..], [json!(900.0), json!(640.0)]);
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
    settings["windowSize"] = json!([700, 500]);
    settings["template"] = json!(run.root.join("no-such-template"));
    fs::write(run.root.join("config/settings.json"), settings.to_string()).unwrap();

    run.start(&["--cwd", folder.to_str().unwrap()]);

    let report = run.wait_for(|report| windows(report).len() == 1 && windows(report)[0]["page"]["notice"].is_string());
    assert_eq!(windows(&report)[0]["frame"].as_array().unwrap()[2..], [json!(700.0), json!(500.0)]);
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
