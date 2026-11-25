//! The window's chrome (status line, status bar and its popovers, permission prompt, task bar, notices, title) in a
//! window that is never shown, fed the session state the core builds with `vcx-model` and clicked with real `NSEvent`s.
//! Its own `main` on the main thread: AppKit and WebKit live there, and the test harness runs tests elsewhere.

#[allow(dead_code, unused_imports)]
#[path = "../src/bridge.rs"]
mod bridge;
#[allow(dead_code, unused_imports)]
#[path = "../src/chart.rs"]
mod chart;
#[allow(dead_code, unused_imports)]
#[path = "../src/input.rs"]
mod input;
#[allow(dead_code, unused_imports)]
#[path = "../src/template.rs"]
mod template;

use objc2_foundation::{MainThreadMarker, NSDate, NSRunLoop};
use serde_json::{Value, json};
use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tao::dpi::LogicalSize;
use tao::event_loop::{EventLoop, EventLoopBuilder};
use tao::window::{Window, WindowBuilder};
use vcx_model::{SessionState, view};
use wry::{BackgroundThrottlingPolicy, WebView, WebViewBuilder};

/// The size the app opens a window at: the task bar and the column both fit, as in the Swift window's minimum.
const WINDOW_SIZE: LogicalSize<f64> = LogicalSize { width: 980.0, height: 720.0 };
const WAIT: Duration = Duration::from_secs(10);
const SPIN: f64 = 0.005;
/// A fixed moment for the page's clock, so the elapsed time of a turn is read, not raced.
const TURN_START_MS: u64 = 1_800_000_000_000;
const SEVENTY_FIVE_SECONDS_MS: u64 = 75_000;
const APPROVAL: &str = "item/commandExecution/requestApproval";

struct Page {
    webview: WebView,
    posts: Arc<Mutex<Vec<Value>>>,
    serial: Cell<u64>,
    _window: Window,
}

fn spin() {
    NSRunLoop::currentRunLoop().runUntilDate(&NSDate::dateWithTimeIntervalSinceNow(SPIN));
}

fn repo(relative: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join(relative)
}

impl Page {
    fn open(event_loop: &EventLoop<()>) -> Page {
        let window = WindowBuilder::new().with_title("VCX chrome test").with_inner_size(WINDOW_SIZE).with_visible(false).build(event_loop).unwrap();
        let (store, problem) = template::Store::open(Some(&repo("template")));
        assert!(problem.is_none(), "{problem:?}");
        let posts = Arc::new(Mutex::new(Vec::new()));
        let received = posts.clone();
        let webview = WebViewBuilder::new()
            .with_custom_protocol(template::SCHEME.into(), move |_, request| store.respond(request.uri().host(), request.uri().path()))
            .with_ipc_handler(move |request| received.lock().unwrap().push(serde_json::from_str(request.body()).unwrap_or(Value::Null)))
            .with_background_throttling(BackgroundThrottlingPolicy::Disabled)
            .with_url(template::HOME)
            .build(&window)
            .unwrap();
        Page { webview, posts, serial: 0.into(), _window: window }
    }

    fn wait(&self, what: &str, done: impl Fn(&Page) -> bool) -> Result<(), String> {
        let deadline = Instant::now() + WAIT;
        while !done(self) {
            if Instant::now() > deadline {
                return Err(format!("timed out waiting for {what}"));
            }
            spin();
        }
        Ok(())
    }

    /// Runs `script` in the page and gives back what it evaluates to, as JSON.
    fn eval(&self, script: &str) -> Result<Value, String> {
        let result = Arc::new(Mutex::new(None));
        let slot = result.clone();
        self.webview.evaluate_script_with_callback(&format!("JSON.stringify(({script}))"), move |value| *slot.lock().unwrap() = Some(value)).map_err(|error| error.to_string())?;
        self.wait(script, |_| result.lock().unwrap().is_some())?;
        let text = result.lock().unwrap().take().unwrap();
        if text.is_empty() {
            return Ok(Value::Null);
        }
        let inner: Value = serde_json::from_str(&text).map_err(|error| format!("{script}: {error}: {text}"))?;
        match inner {
            Value::String(json) => serde_json::from_str(&json).map_err(|error| format!("{script}: {error}: {json}")),
            other => Ok(other),
        }
    }

    fn dump(&self) -> Result<Value, String> {
        self.eval("window.vcxChrome.dump()")
    }

    fn posted(&self, kind: &str) -> Vec<Value> {
        self.posts.lock().unwrap().iter().filter(|post| post["type"] == kind).cloned().collect()
    }

    fn reload(&self) -> Result<(), String> {
        self.posts.lock().unwrap().clear();
        self.webview.load_url(template::HOME).map_err(|error| error.to_string())?;
        self.wait("the page to report ready", |page| !page.posted("ready").is_empty())
    }

    /// Hands the page a message as the core does: `vcx.receive`, numbered.
    fn deliver(&self, mut message: Value) -> Result<(), String> {
        self.serial.set(self.serial.get() + 1);
        message["serial"] = json!(self.serial.get());
        self.webview.evaluate_script(&format!("window.vcx.receive({message})")).map_err(|error| error.to_string())
    }

    /// The session's full state, built by `vcx-model` from a worker snapshot as the core builds it.
    fn show(&self, snapshot: &Value) -> Result<SessionState, String> {
        let state = SessionState::from_snapshot(snapshot.as_object().ok_or("a snapshot is an object")?);
        let mut message = view::full(&state);
        message["type"] = json!("full");
        self.deliver(message)?;
        Ok(state)
    }

    fn patch(&self, state: &mut SessionState, patch: Value) -> Result<(), String> {
        let changes = state.apply_patch(patch.as_object().ok_or("a patch is an object")?);
        let mut message = view::patch(state, &changes);
        message["type"] = json!("patch");
        self.deliver(message)
    }

    /// A real mouse click in the middle of the element `selector` finds.
    fn click(&self, selector: &str) -> Result<(), String> {
        let script = format!("(() => {{ const r = document.querySelector({selector:?}).getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; }})()");
        let point = self.eval(&script)?;
        let (x, y) = (point[0].as_f64().ok_or(format!("{selector} is not on the page"))?, point[1].as_f64().unwrap_or_default());
        input::click(&self.webview, x, y)?;
        spin();
        Ok(())
    }

    /// Clicks a status-bar chip for real and waits for the popover it opens.
    fn open_popover(&self, kind: &str, popover: &str) -> Result<(), String> {
        self.click(&format!("[data-chip={kind}]"))?;
        let deadline = Instant::now() + WAIT;
        while self.eval("window.vcxChrome.dump().popover?.kind ?? null")? != json!(popover) {
            if Instant::now() > deadline {
                return Err(format!("the {kind} chip opened no {popover} popover"));
            }
            spin();
        }
        Ok(())
    }

    fn wait_post(&self, kind: &str) -> Result<Value, String> {
        self.wait(&format!("a {kind} post"), |page| !page.posted(kind).is_empty())?;
        Ok(self.posted(kind).last().cloned().unwrap_or_default())
    }
}

fn check(condition: bool, what: impl Into<String>) -> Result<(), String> {
    if condition { Ok(()) } else { Err(what.into()) }
}

fn same(found: &Value, expected: Value, what: &str) -> Result<(), String> {
    check(*found == expected, format!("{what}: expected {expected}, the page has {found}"))
}

fn demo() -> Result<Value, String> {
    let text = std::fs::read_to_string(repo("fixtures/demo_state.json")).map_err(|error| error.to_string())?;
    serde_json::from_str(&text).map_err(|error| error.to_string())
}

fn chip<'a>(dump: &'a Value, kind: &str) -> &'a Value {
    dump["chips"].as_array().and_then(|chips| chips.iter().find(|chip| chip["kind"] == kind)).map_or(&Value::Null, |chip| &chip["text"])
}

fn kinds(dump: &Value) -> Value {
    json!(dump["chips"].as_array().into_iter().flatten().map(|chip| chip["kind"].clone()).collect::<Vec<_>>())
}

fn shows_ready_and_the_status_bar_of_a_connected_session(page: &Page) -> Result<(), String> {
    let snapshot = demo()?;

    page.show(&snapshot)?;

    let dump = page.dump()?;
    same(&dump["status"], json!("Ready"), "the status")?;
    same(&dump["tone"], json!("ready"), "the dot")?;
    same(&kinds(&dump), json!(["directory", "model", "mode", "tokens", "repo"]), "the chips")?;
    same(chip(&dump, "directory"), json!("~/projects/vcx"), "the directory")?;
    same(chip(&dump, "model"), json!("Fable 5.2 - high"), "the model and effort")?;
    same(chip(&dump, "mode"), json!("ask"), "the mode")?;
    same(chip(&dump, "tokens"), json!("21% token - 200K"), "the context")?;
    same(chip(&dump, "repo"), json!("@main"), "the repository")?;
    same(&dump["chips"][0]["color"], json!("rgb(71, 92, 179)"), "the directory's colour")
}

fn names_the_window_after_its_folder_and_tells_the_core(page: &Page) -> Result<(), String> {
    let mut state = page.show(&demo()?)?;

    page.patch(&mut state, json!({"meta": {"cwd": "/Users/demo/projects/fleet"}}))?;

    same(&page.dump()?["title"], json!("fleet · Vibe Code X"), "the title")?;
    let titles: Vec<Value> = page.posted("title").into_iter().map(|post| post["text"].clone()).collect();
    same(&json!(titles), json!(["Vibe Code X", "vcx · Vibe Code X", "fleet · Vibe Code X"]), "the titles posted")
}

fn shows_thinking_what_runs_and_the_elapsed_time_during_a_turn(page: &Page) -> Result<(), String> {
    page.eval(&format!("window.vcxChrome.setClock(() => {TURN_START_MS})"))?;
    let step = json!({"id": "t9", "type": "commandExecution", "command": "cargo build -p vcx-shell", "status": "inProgress"});
    let snapshot = json!({"model": "claude-fable-5-2", "providerLabel": "Claude", "ready": true, "busy": true, "status": "Working",
        "rows": [{"id": "R1", "kind": "activity", "items": [step]}]});
    let title = vcx_model::item::title(step.as_object().unwrap());

    let mut state = page.show(&snapshot)?;
    page.eval(&format!("window.vcxChrome.setClock(() => {})", TURN_START_MS + SEVENTY_FIVE_SECONDS_MS))?;

    let dump = page.dump()?;
    same(&dump["status"], json!("Thinking"), "the status")?;
    same(&dump["tone"], json!("busy"), "the dot")?;
    same(&dump["doing"], json!(format!("· {title}")), "what runs")?;
    same(&dump["elapsed"], json!("· 1:15"), "the elapsed time")?;
    page.patch(&mut state, json!({"meta": {"busy": false, "status": "Ready"}}))?;
    let dump = page.dump()?;
    same(&json!([&dump["status"], &dump["doing"], &dump["elapsed"]]), json!(["Ready", "", ""]), "the status once the turn ended")
}

fn says_not_connected_and_why(page: &Page) -> Result<(), String> {
    let snapshot = json!({"model": "Codex", "ready": false, "busy": false, "status": "Connecting to the worker…", "rows": []});

    page.show(&snapshot)?;

    let dump = page.dump()?;
    same(&json!([&dump["status"], &dump["tone"], &dump["note"]]), json!(["Not connected", "off", "Connecting to the worker…"]), "the status line")?;
    same(chip(&dump, "model"), json!("Not connected"), "the model chip")
}

fn shows_a_pending_action_while_background_tasks_run(page: &Page) -> Result<(), String> {
    let snapshot = json!({"model": "gpt-6.2", "providerLabel": "Codex", "ready": true, "busy": false, "backgroundTasks": 2, "rows": []});

    page.show(&snapshot)?;

    let dump = page.dump()?;
    same(&json!([&dump["status"], &dump["tone"]]), json!(["Pending action", "pending"]), "the status line")
}

fn approval(id: &str, rpc: &str, params: Value) -> Value {
    json!({"model": "claude-fable-5-2", "providerLabel": "Claude", "ready": true, "busy": true, "rows": [],
        "permissions": [{"id": id, "rpcID": rpc, "method": APPROVAL, "params": params}]})
}

fn asks_for_permission_and_answers_allow_through_a_real_click(page: &Page) -> Result<(), String> {
    page.show(&approval("P2", "a", json!({"command": "rm -rf build", "reason": "Cleans the build."})))?;
    let asked = page.dump()?;
    same(&asked["permission"]["request"], json!("P2"), "the request shown")?;
    same(&asked["note"], json!("Your answer is needed"), "the status line")?;
    check(asked["permission"]["text"].as_str().is_some_and(|text| text.contains("Cleans the build.") && text.contains("rm -rf build")), format!("the card says what it asks: {}", asked["permission"]))?;

    page.click("#permission [data-decision=accept]")?;

    let answer = page.wait_post("answer")?;
    same(&answer, json!({"type": "answer", "rpcID": "a", "method": APPROVAL, "result": {"decision": "accept"}}), "the answer")?;
    same(&page.dump()?["permission"]["disabled"], json!(["cancel", "decline", "accept"]), "the buttons once answered")
}

fn declines_and_cancels_through_the_answer_action(page: &Page) -> Result<(), String> {
    let mut state = page.show(&approval("P4", "d", json!({"command": "git push"})))?;

    page.click("#permission [data-decision=decline]")?;
    let declined = page.wait_post("answer")?;
    page.patch(&mut state, json!({"meta": {"permissions": [{"id": "P5", "rpcID": "e", "method": APPROVAL, "params": {"command": "rm x"}}]}}))?;
    page.click("#permission [data-decision=cancel]")?;
    page.wait("a second answer", |page| page.posted("answer").len() == 2)?;

    same(&declined["result"], json!({"decision": "decline"}), "the first answer")?;
    same(&page.posted("answer")[1], json!({"type": "answer", "rpcID": "e", "method": APPROVAL, "result": {"decision": "cancel"}}), "the second answer")?;
    page.patch(&mut state, json!({"meta": {"permissions": []}}))?;
    same(&page.dump()?["permission"], Value::Null, "the card once nothing is asked")
}

fn cannot_allow_an_empty_file_change(page: &Page) -> Result<(), String> {
    let mut snapshot = approval("P3", "b", json!({"changes": []}));
    snapshot["permissions"][0]["method"] = json!("item/fileChange/requestApproval");

    page.show(&snapshot)?;

    same(&page.dump()?["permission"]["disabled"], json!(["accept"]), "the disabled buttons")
}

fn leaves_a_question_to_the_question_card(page: &Page) -> Result<(), String> {
    let snapshot = json!({"model": "claude-fable-5-2", "ready": true, "rows": [], "permissions": [{"id": "Q1", "rpcID": 3, "method": "item/tool/requestUserInput",
        "params": {"questions": [{"question": "Which style?", "options": [{"label": "Shared"}]}]}}]});

    page.show(&snapshot)?;

    let dump = page.dump()?;
    same(&json!([&dump["permission"], &dump["note"]]), json!([null, null]), "the chrome for a question")
}

fn badges_the_models_of_a_debate_and_lists_them(page: &Page) -> Result<(), String> {
    let output = "<<debate claude>>\nmine\n<<debate codex gpt-6.2>>\ntheirs\n<<debate qwen>>\nlocal";
    let snapshot = json!({"model": "claude-fable-5-2", "providerLabel": "Claude", "ready": true,
        "rows": [{"id": "R1", "kind": "activity", "items": [{"id": "d1", "type": "commandExecution", "command": "ask-codex.sh brief", "aggregatedOutput": output, "exitCode": 0}]}]});
    page.show(&snapshot)?;
    same(chip(&page.dump()?, "models"), json!("3 models"), "the badge")?;

    page.open_popover("models", "models")?;

    let shown = page.dump()?["popover"].clone();
    same(&shown["kind"], json!("models"), "the popover")?;
    let lines: Vec<&str> = shown["text"].as_str().unwrap_or_default().lines().map(str::trim).filter(|line| !line.is_empty()).collect();
    same(&json!(lines), json!(["MODELS IN THIS CONVERSATION", "Fable 5.2", "this session", "Codex gpt-6.2", "Qwen"]), "the list")
}

fn switches_provider_from_the_model_popover(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;
    page.open_popover("model", "model")?;
    let current = page.eval("document.querySelector('#popover .option.current').textContent")?;

    page.click("#popover .option:nth-child(3)")?;

    same(&current, json!("claude"), "the provider shown as current")?;
    same(&page.wait_post("command")?, json!({"type": "command", "text": "/model codex"}), "the command")?;
    same(&page.dump()?["popover"], Value::Null, "the popover once chosen")
}

// `models`, `modelEfforts` and `modelDefaultEfforts` are what the worker reports; the view hands them to the page once
// its page keys include them (asked of Rust transcript), so this test gives them through the meta the page reads.
fn keeps_each_familys_newest_model_and_a_valid_effort(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;
    let meta = json!({"model": "claude-fable-5-2", "modelLabel": "fable-5-2", "providerLabel": "Claude", "ready": true, "effort": "max", "requests": [],
        "models": ["claude-fable-5-1", "claude-fable-5-2", "claude-haiku-5-5", "claude-haiku-4-5"],
        "modelEfforts": {"claude-fable-5-2": ["low", "high", "max"], "claude-haiku-5-5": ["low", "high"]},
        "modelDefaultEfforts": {"claude-haiku-5-5": "high"}});
    page.deliver(json!({"type": "patch", "meta": meta}))?;
    page.open_popover("model", "model")?;
    let names = page.eval("[...document.querySelectorAll('#popover > .option .name')].map(node => node.textContent)")?;

    page.click("#popover > .option:nth-of-type(2)")?;

    same(&names, json!(["Fable 5.2", "Haiku 5.5"]), "the models offered")?;
    same(&page.wait_post("command")?["text"], json!("/model claude claude-haiku-5-5 high"), "the command")
}

fn sets_the_permission_mode_and_closes_on_escape(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;
    page.open_popover("mode", "mode")?;
    page.eval("document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}))")?;
    same(&page.dump()?["popover"], Value::Null, "the popover after Escape")?;
    page.open_popover("mode", "mode")?;

    page.click("#popover .option:first-of-type")?;

    same(&page.wait_post("command")?, json!({"type": "command", "text": "/perms bypass"}), "the command")
}

fn asks_the_core_for_the_quota_and_draws_it(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;
    page.open_popover("tokens", "quota")?;
    page.wait_post("quota")?;
    check(page.dump()?["popover"]["text"].as_str().is_some_and(|text| text.contains("Loading…")), "the quota says it is loading")?;

    page.deliver(json!({"type": "quota", "lines": [{"agent": "Claude", "fiveHour": "12%", "week": "40%"}, {"agent": "Codex", "fiveHour": "3%", "week": "9%"}]}))?;

    let cells = page.eval("[...document.querySelectorAll('#popover .quota span')].map(node => node.textContent)")?;
    same(&cells, json!(["Agent", "5 hours", "Week", "Claude", "12%", "40%", "Codex", "3%", "9%"]), "the quota grid")
}

fn shows_the_progress_file_and_drops_it_when_done(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;

    page.deliver(json!({"type": "progress", "label": "Downloading the Qwen model weights for the PC", "fraction": 0.42, "detail": "42% · 1.2 of 2.9 GB · 30 MB/s · 57 s left"}))?;

    let dump = page.dump()?;
    same(&dump["chips"][0]["kind"], json!("progress"), "the first chip")?;
    same(&dump["chips"][0]["text"], json!("Downloading the Qwen model weights for …·42% · 1.2 of 2.9 GB · 30 MB/s · 57 s left"), "the progress chip")?;
    same(&page.eval("document.querySelector('[data-chip=progress] .bar').style.width")?, json!("42%"), "the bar")?;
    page.deliver(json!({"type": "progress"}))?;
    same(&kinds(&page.dump()?)[0], json!("directory"), "the first chip once done")
}

fn lists_every_windows_task_by_project_and_brings_one_up(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;
    let entries = json!([
        {"id": "W1", "group": "/Users/demo/self/my-apps", "task": "Rust chrome", "state": "working", "current": true},
        {"id": "W2", "group": "/Users/demo/self/fleet", "task": "Fix Fleet names", "state": "question", "current": false},
        {"id": "W3", "group": "/Users/demo/self/my-apps", "task": "Rust composer", "state": "done", "current": false}
    ]);
    page.deliver(json!({"type": "tasks", "entries": entries}))?;
    let dump = page.dump()?;
    same(&dump["groups"], json!(["my-apps", "fleet"]), "the groups")?;
    same(&dump["tasks"], json!([
        {"text": "…Rust chrome", "state": "working", "current": true},
        {"text": "✓Rust composer", "state": "done", "current": false},
        {"text": "?Fix Fleet names", "state": "question", "current": false}
    ]), "the rows")?;

    page.click("#tasks .task[data-state=question]")?;

    same(&page.wait_post("focus")?, json!({"type": "focus", "id": "W2"}), "the focus post")
}

fn says_when_there_is_no_task_yet(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;

    page.deliver(json!({"type": "tasks", "entries": []}))?;

    same(&page.eval("document.querySelector('#tasks .empty').textContent")?, json!("No task yet."), "the empty task bar")
}

fn tells_the_link_and_the_last_problem_apart(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;

    page.deliver(json!({"type": "notice", "text": "The worker stopped."}))?;
    let problem = page.dump()?["notice"].clone();
    page.deliver(json!({"type": "link", "state": "reconnecting", "detail": "Reconnecting to the worker…"}))?;
    let both = page.dump()?["notice"].clone();
    page.deliver(json!({"type": "notice", "text": ""}))?;
    let link = page.dump()?["notice"].clone();
    page.deliver(json!({"type": "link", "state": "connected"}))?;

    same(&json!([problem, both, link]), json!(["The worker stopped.", "Reconnecting to the worker… The worker stopped.", "Reconnecting to the worker…"]), "the notices")?;
    same(&page.dump()?["notice"], Value::Null, "the notice once connected")
}

type Test = fn(&Page) -> Result<(), String>;

const TESTS: [(&str, Test); 18] = [
    ("shows ready and the status bar of a connected session", shows_ready_and_the_status_bar_of_a_connected_session),
    ("names the window after its folder and tells the core", names_the_window_after_its_folder_and_tells_the_core),
    ("shows thinking, what runs and the elapsed time during a turn", shows_thinking_what_runs_and_the_elapsed_time_during_a_turn),
    ("says not connected and why", says_not_connected_and_why),
    ("shows a pending action while background tasks run", shows_a_pending_action_while_background_tasks_run),
    ("asks for permission and answers allow through a real click", asks_for_permission_and_answers_allow_through_a_real_click),
    ("declines and cancels through the answer action", declines_and_cancels_through_the_answer_action),
    ("cannot allow an empty file change", cannot_allow_an_empty_file_change),
    ("leaves a question to the question card", leaves_a_question_to_the_question_card),
    ("badges the models of a debate and lists them", badges_the_models_of_a_debate_and_lists_them),
    ("switches provider from the model popover", switches_provider_from_the_model_popover),
    ("keeps each family's newest model and a valid effort", keeps_each_familys_newest_model_and_a_valid_effort),
    ("sets the permission mode and closes on escape", sets_the_permission_mode_and_closes_on_escape),
    ("asks the core for the quota and draws it", asks_the_core_for_the_quota_and_draws_it),
    ("shows the progress file and drops it when done", shows_the_progress_file_and_drops_it_when_done),
    ("lists every window's task by project and brings one up", lists_every_windows_task_by_project_and_brings_one_up),
    ("says when there is no task yet", says_when_there_is_no_task_yet),
    ("tells the link and the last problem apart", tells_the_link_and_the_last_problem_apart),
];

fn main() -> ExitCode {
    MainThreadMarker::new().expect("the chrome test runs on the main thread");
    let event_loop = EventLoopBuilder::new().build();
    let page = Page::open(&event_loop);
    let filter: Vec<String> = std::env::args().skip(1).filter(|argument| !argument.starts_with('-')).collect();
    let mut failed = 0;
    for (name, test) in TESTS {
        if !filter.is_empty() && !filter.iter().any(|wanted| name.contains(wanted.as_str())) {
            continue;
        }
        let outcome = page.reload().and_then(|()| test(&page));
        match outcome {
            Ok(()) => println!("test {name} ... ok"),
            Err(problem) => {
                failed += 1;
                println!("test {name} ... FAILED: {problem}");
            }
        }
    }
    if failed > 0 { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}
