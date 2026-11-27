//! The window's chrome (session panel, status line, status bar and its popovers, permission prompt, task bar, notices,
//! title) in a window that is never shown, fed the session state the core builds with `vcx-model` and clicked with
//! real `NSEvent`s.
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
/// Longer than the page waits before a card under the pointer opens its list.
const HOVER_PASSED: Duration = Duration::from_millis(250);

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

    /// Ends every animation running: a hidden window draws no frames, so none would end on its own.
    fn settle(&self) -> Result<(), String> {
        self.eval("document.getAnimations().forEach(motion => { try { motion.finish(); } catch { /* an endless one */ } })").map(drop)
    }

    /// Types `text` into the field `selector` finds, as a keystroke would leave it.
    fn type_into(&self, selector: &str, text: &str) -> Result<(), String> {
        self.eval(&format!("(() => {{ const field = document.querySelector({selector:?}); field.value = {text:?}; field.dispatchEvent(new Event('input')); }})()")).map(drop)
    }

    /// Waits for `script` to evaluate to `expected`: a pill swaps its word in after its fade.
    fn until(&self, script: &str, expected: Value) -> Result<(), String> {
        self.wait(script, |page| page.eval(script).is_ok_and(|value| value == expected))
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

    /// A real mouse click in the middle of the element `selector` finds, once the page's motion has ended: a hidden
    /// window draws no frames, so an animation (the task bar growing to its cards) would otherwise never end.
    fn click(&self, selector: &str) -> Result<(), String> {
        self.settle()?;
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
    same(&dump["chips"][0]["color"], json!("rgb(71 92 179)"), "the directory's colour")
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
    page.until("window.vcxChrome.dump().status", json!("Ready"))?;
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

fn puts_the_model_command_in_the_composer_from_the_model_chip(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;

    page.click("[data-chip=model]")?;

    same(&page.eval("document.getElementById('input').value")?, json!("/model claude "), "the composer's command")?;
    same(&page.eval("!document.getElementById('palette').hidden")?, json!(true), "the palette open on it")?;
    same(&page.dump()?["popover"], Value::Null, "no popover")
}

fn puts_the_perms_command_in_the_composer_from_the_mode_chip(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;

    page.click("[data-chip=mode]")?;

    same(&page.eval("document.getElementById('input').value")?, json!("/perms "), "the composer's command")?;
    same(&page.eval("!document.getElementById('palette').hidden")?, json!(true), "the palette open on it")
}

fn asks_the_core_for_the_quota_and_draws_it(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;
    page.open_popover("tokens", "quota")?;
    page.wait_post("quota")?;
    check(page.dump()?["popover"]["text"].as_str().is_some_and(|text| text.contains("Loading…")), "the quota says it is loading")?;

    page.deliver(json!({"type": "quota", "lines": [{"agent": "Claude", "fiveHour": "12%", "week": "40%"}, {"agent": "Codex", "fiveHour": "3%", "week": "9%"}]}))?;

    let cells = page.eval("[...document.querySelectorAll('#popover .vcx-table th, #popover .vcx-table td')].map(node => node.textContent)")?;
    same(&cells, json!(["Agent", "5 hours", "Week", "Claude", "12%", "40%", "Codex", "3%", "9%"]), "the quota grid")
}

fn shows_the_progress_file_and_drops_it_when_done(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;

    page.deliver(json!({"type": "progress", "label": "Downloading the Qwen model weights for the PC", "fraction": 0.42, "detail": "42% · 1.2 of 2.9 GB · 30 MB/s · 57 s left"}))?;

    let dump = page.dump()?;
    same(&dump["chips"][0]["kind"], json!("progress"), "the first chip")?;
    same(&dump["chips"][0]["text"], json!("Downloading the Qwen model weights for … · 42% · 1.2 of 2.9 GB · 30 MB/s · 57 s left"), "the progress chip")?;
    same(&page.eval("document.querySelector('[data-chip=progress] .pg').style.getPropertyValue('--value')")?, json!("42"), "the bar")?;
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
        {"text": "Rust chrome", "state": "working", "current": true},
        {"text": "Rust composer", "state": "done", "current": false},
        {"text": "Fix Fleet names", "state": "question", "current": false}
    ]), "the rows")?;

    page.click("#tasks .card[data-state=question]")?;

    same(&page.wait_post("focus")?, json!({"type": "focus", "id": "W2"}), "the focus post")
}

fn says_when_there_is_no_task_yet(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;

    page.deliver(json!({"type": "tasks", "entries": []}))?;

    same(&page.eval("document.querySelector('#tasks .empty').textContent")?, json!("No session yet."), "the empty words")?;
    same(&page.dump()?["empty"], json!(true), "the empty task bar shown")
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

const THREAD: &str = "019a7c3e-thread";

/// What a Claude session reports it loaded, as the worker's snapshot carries it; the view passes it to the page.
fn loaded(page: &Page) -> Result<(), String> {
    let mut snapshot = demo()?;
    let reported = json!({"threadID": THREAD,
        "hooks": ["gateguard.py · PreToolUse · trusted · Checks a tool call before it runs.", "gateguard.py · UserPromptSubmit · configured · Checks a prompt before it is sent.",
            "memory.sh · SessionStart · disabled · Loads context when a session starts."],
        "skills": ["deep", "council"], "mcp": ["lightpanda · connected · Tools: goto"], "instructions": ["~/.claude/CLAUDE.md", "~/self/my-apps/CLAUDE.md"],
        "recalledRules": ["24/11: An S3 HeadObject 403 does not prove denied uploads."],
        "providerCommands": [{"name": "/council", "detail": "Convenes a council"}, {"name": "/deep", "detail": "Deep mode"}], "builtinCommands": []});
    for (key, value) in reported.as_object().ok_or("the report is an object")? {
        snapshot[key] = value.clone();
    }
    page.show(&snapshot).map(drop)
}

fn names(rows: &Value) -> Value {
    json!(rows.as_array().into_iter().flatten().map(|row| row[0].clone()).collect::<Vec<_>>())
}

/// Widens the Settings box at once, clicks one of its rows for real and waits for its list: the page may take the
/// click after the next read.
fn open_list(page: &Page, card: &str) -> Result<(), String> {
    page.eval("(() => { const fold = document.getElementById('fold'); fold.style.setProperty('--open', '0ms'); fold.classList.add('open'); return true; })()")?;
    page.click(&format!("#fold .fold-row[data-card={card}]"))?;
    page.until("window.vcxChrome.dump().capability?.title ?? null", json!(card))
}

fn counts_what_the_session_loaded_on_its_cards(page: &Page) -> Result<(), String> {
    loaded(page)?;

    let cards = page.dump()?["capabilities"].clone();

    let counts: Vec<(Value, Value)> = cards.as_array().into_iter().flatten().map(|card| (card["title"].clone(), card["count"].clone())).collect();
    same(&json!(counts[..3]), json!([["Hooks", 2], ["Skills", 2], ["Commands", counts[2].1]]), "the first counts")?;
    check(counts[2].1.as_u64().is_some_and(|commands| commands > 0), "the composer's commands are counted")?;
    same(&json!(counts[3..]), json!([["MCP", 1], ["Instructions", 2], ["RAG", 1]]), "the last counts")
}

fn opens_a_capability_list_and_narrows_it_to_what_is_typed(page: &Page) -> Result<(), String> {
    loaded(page)?;
    open_list(page, "Hooks")?;
    let opened = page.dump()?;

    page.type_into("#capability input", "memory")?;
    let narrowed = page.dump()?["capability"].clone();
    page.type_into("#capability input", "nothing like it")?;
    let none = page.dump()?["capability"]["none"].clone();
    page.eval("document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}))")?;

    same(&opened["capability"]["title"], json!("Hooks"), "the list opened")?;
    same(&names(&opened["capability"]["rows"]), json!(["gateguard.py", "memory.sh"]), "a hook's events under its one name")?;
    check(opened["capabilities"][0]["open"] == true, "the glass on the Hooks card")?;
    same(&names(&narrowed["rows"]), json!(["memory.sh"]), "the list narrowed")?;
    same(&none, json!("No matches"), "nothing left")?;
    same(&page.dump()?["capability"], Value::Null, "the list after Escape")
}

fn keeps_a_list_closed_under_the_card_the_pointer_just_reached(page: &Page) -> Result<(), String> {
    loaded(page)?;
    // In one script, so that all of it happens before the hover delay ends.
    let reached_clicked_closed = "(() => { const card = document.querySelector('#fold .fold-row[data-card=Hooks]'); card.dispatchEvent(new PointerEvent('pointerenter')); card.click(); \
        const opened = window.vcxChrome.dump().capability?.title ?? null; document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true})); return opened; })()";

    let opened = page.eval(reached_clicked_closed)?;
    let hover_passed = Instant::now() + HOVER_PASSED;
    while Instant::now() < hover_passed {
        spin();
    }

    same(&opened, json!("Hooks"), "the list the click opened")?;
    same(&page.dump()?["capability"], Value::Null, "the list once the hover delay passed")
}

fn leaves_the_providers_skills_out_of_the_commands(page: &Page) -> Result<(), String> {
    loaded(page)?;

    open_list(page, "Commands")?;

    let rows = names(&page.dump()?["capability"]["rows"]);
    check(!rows.as_array().unwrap().iter().any(|name| name == "council" || name == "deep"), format!("no skill among the commands: {rows}"))?;
    check(rows.as_array().unwrap().iter().any(|name| name == "compact"), format!("the provider's own commands are there: {rows}"))
}

fn opens_an_md_file_from_its_list(page: &Page) -> Result<(), String> {
    loaded(page)?;
    open_list(page, "Instructions")?;

    page.click("#capability .item")?;

    same(&page.wait_post("open")?, json!({"type": "open", "href": "~/.claude/CLAUDE.md"}), "the file opened")
}

fn names_a_recalled_line_after_its_errors_section(page: &Page) -> Result<(), String> {
    let rules = ["24/11: An S3 HeadObject 403 does not prove denied uploads.", "A line with no date and no known section."];
    page.show(&demo()?)?;
    page.deliver(json!({"type": "patch", "meta": {"ready": true, "recalledRules": rules, "recalledRuleSections": {rules[0]: "Before I say it"}}}))?;

    open_list(page, "RAG")?;

    same(&page.dump()?["capability"]["rows"], json!([["Before I say it"], ["ERRORS line"]]), "each line named after its section")
}

fn copies_the_session_id_through_the_core(page: &Page) -> Result<(), String> {
    loaded(page)?;

    page.click("#session-id")?;

    same(&page.wait_post("copy")?, json!({"type": "copy", "text": THREAD}), "the copy")?;
    page.until("(document.getAnimations().forEach(motion => motion.finish()), window.vcxChrome.dump().sessionID.label)", json!("COPIED"))
}

fn escape(page: &Page) -> Result<(), String> {
    page.eval("document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}))").map(drop)
}

/// What the core answers a `settings` post with: vcx-config's `Settings::page`, plus what the session runs in the background.
fn settings() -> Value {
    json!({"type": "settings", "home": "/Users/demo", "account": "Work Claude", "routeAccount": "Work Claude", "rateLimitRetries": [30, 90], "fallbacks": ["Default Codex"],
        "provider": "claude", "mode": "bypass",
        "accounts": [{"id": "claude-work", "name": "Work Claude", "provider": "claude", "enabled": true, "home": "~/.claude-work", "availableAfter": null},
            {"id": "codex-default", "name": "Default Codex", "provider": "codex", "enabled": false, "home": null, "availableAfter": 4_102_444_800_u64}],
        "qwen": {"host": "pc", "url": "http://pc.local:11434/api/chat", "proxy": "", "model": "qwen3.5-9b-abl", "wake": false}})
}

fn tab(page: &Page, name: &str) -> Result<Value, String> {
    let index = ["Session", "Accounts", "Qwen", "Background", "Keys"].iter().position(|tab| *tab == name).ok_or("no such tab")? + 1;
    page.click(&format!("#settings .tb-trigger:nth-child({index})"))?;
    page.settle()?;
    Ok(page.dump()?["settings"].clone())
}

fn opens_the_settings_on_the_session_tab_and_asks_the_core_for_the_rest(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;

    page.click("#settings-button")?;

    same(&page.wait_post("settings")?, json!({"type": "settings"}), "the settings post")?;
    let shown = page.dump()?["settings"].clone();
    same(&shown["tab"], json!("Session"), "the first tab")?;
    same(&shown["rows"], json!([["Provider", "Claude"], ["Model", "Fable 5.2"], ["Effort", "high"], ["Permissions", "Ask for approval"], ["Working directory", "/Users/demo/projects/vcx"]]), "the session's settings")
}

fn shows_the_accounts_and_qwen_the_core_sends(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;
    page.click("#settings-button")?;
    let waiting = tab(page, "Accounts")?["rows"].clone();

    page.deliver(settings())?;

    let accounts = tab(page, "Accounts")?["rows"].clone();
    let qwen = tab(page, "Qwen")?["rows"].clone();
    same(&waiting[0], json!(["Reading the accounts…"]), "the accounts before the core answers")?;
    same(&names(&accounts), json!(["Work Claude", "Profile", "Default Codex", "Available after", "Add account", "Import profile"]), "the accounts")?;
    same(&json!([&accounts[0][1], &accounts[1][1], &accounts[2][1]]), json!(["Claude · enabled", "~/.claude-work", "Codex · disabled"]), "each account's line")?;
    same(&qwen, json!([["Runs on", "Windows PC"], ["Endpoint", "http://pc.local:11434/api/chat"], ["Proxy", "None"], ["Model", "qwen3.5-9b-abl"]]), "the Qwen settings")
}

fn says_what_runs_in_the_background_and_on_which_account(page: &Page) -> Result<(), String> {
    let mut snapshot = demo()?;
    snapshot["backgroundTasks"] = json!(2);
    snapshot["cwd"] = json!("/Users/demo");
    snapshot["rows"] = json!([]);
    page.show(&snapshot)?;
    page.click("#settings-button")?;
    page.deliver(settings())?;

    let rows = tab(page, "Background")?["rows"].clone();

    let states: Vec<Value> = rows.as_array().into_iter().flatten().skip(1).map(|row| json!([row[0], row[1]])).collect();
    same(&json!(states), json!([["Agent background tasks", "2 running"], ["Project routing", "Armed in this window"], ["Rate limit retries", "2 at most"],
        ["Network resume", "3 at most"], ["Usage limit fallback", "Default Codex"], ["Resume recovery", "When needed"]]), "each job's state")?;
    check(rows[1][2].as_str().is_some_and(|detail| detail.contains("Work Claude's tokens")), "the account the tasks spend")?;
    check(rows[3][2].as_str().is_some_and(|detail| detail.ends_with("after 30 s, 90 s.")), "the retry delays")
}

fn lists_the_keyboard_shortcuts(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;
    page.click("#settings-button")?;

    let rows = tab(page, "Keys")?["rows"].clone();

    same(&json!(rows.as_array().map(Vec::len)), json!(16), "the shortcuts")?;
    same(&rows[1], json!(["⇧", "↩", "New line; on an empty composer, send the waiting prompt now"]), "a shortcut's keys and action")
}

fn puts_a_settings_command_in_the_composer_and_closes(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;
    page.click("#settings-button")?;

    page.click("#settings .tb-panel.on dl:nth-child(4) .fact")?;

    same(&page.dump()?["settings"], Value::Null, "the sheet after the choice")?;
    same(&page.eval("document.getElementById('input').value")?, json!("/perms "), "the composer's command")?;
    same(&page.eval("!document.getElementById('palette').hidden")?, json!(true), "the palette open on it")
}

fn opens_the_settings_with_command_comma_and_closes_them_on_escape(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;

    page.eval("document.dispatchEvent(new KeyboardEvent('keydown', {key: ',', metaKey: true, bubbles: true}))")?;
    let opened = page.dump()?["settings"]["tab"].clone();
    escape(page)?;

    same(&opened, json!("Session"), "the sheet ⌘, opens")?;
    same(&page.dump()?["settings"], Value::Null, "the sheet after Escape")
}

fn keeps_the_sheet_480_by_520_and_each_value_inside_its_block(page: &Page) -> Result<(), String> {
    let mut snapshot = demo()?;
    snapshot["cwd"] = json!("/Users/demo/projects/a-folder-name-long-enough-to-run-past-the-block-it-sits-in/and-deeper-still");
    page.show(&snapshot)?;

    page.click("#settings-button")?;

    let size = page.eval("(r => [r.width, r.height])(document.getElementById('settings').getBoundingClientRect())")?;
    let inside = page.eval("[...document.querySelectorAll('#settings .tb-panel.on .fact')].every(block => { const b = block.getBoundingClientRect(), v = block.querySelector('.val').getBoundingClientRect(); return v.right <= b.right && v.left >= b.left; })")?;
    same(&size, json!([480, 520]), "the sheet's size")?;
    same(&inside, json!(true), "every value inside its block")
}

fn opens_the_settings_when_the_core_asks(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;

    page.deliver(json!({"type": "openSettings"}))?;

    same(&page.dump()?["settings"]["tab"], json!("Session"), "the sheet the core opened")?;
    same(&page.wait_post("settings")?, json!({"type": "settings"}), "the settings asked of the core")
}

fn shows_the_sign_in_and_cancels_it(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;
    page.deliver(json!({"type": "login", "text": "Complete sign-in in your browser.", "signingIn": true}))?;
    let shown = page.dump()?["login"].clone();

    page.click("#login .foot button")?;

    same(&shown, json!({"title": "Account sign-in", "text": "Complete sign-in in your browser.", "button": "Cancel"}), "the sign-in panel")?;
    same(&page.wait_post("command")?, json!({"type": "command", "text": "/login cancel"}), "the cancel")?;
    same(&page.dump()?["login"], Value::Null, "the panel after Cancel")
}

fn dismisses_the_account_status(page: &Page) -> Result<(), String> {
    page.show(&demo()?)?;
    page.deliver(json!({"type": "login", "text": "Account added. Enable the accounts to use for fallback.", "signingIn": false}))?;
    let shown = page.dump()?["login"].clone();

    page.click("#login .foot button")?;

    same(&json!([&shown["title"], &shown["button"]]), json!(["Account status", "Dismiss"]), "the status panel")?;
    same(&page.wait_post("command")?, json!({"type": "command", "text": "/login dismiss"}), "the dismiss")
}

const TESTS: [(&str, Test); 34] = [
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
    ("puts the model command in the composer from the model chip", puts_the_model_command_in_the_composer_from_the_model_chip),
    ("puts the perms command in the composer from the mode chip", puts_the_perms_command_in_the_composer_from_the_mode_chip),
    ("asks the core for the quota and draws it", asks_the_core_for_the_quota_and_draws_it),
    ("shows the progress file and drops it when done", shows_the_progress_file_and_drops_it_when_done),
    ("lists every window's task by project and brings one up", lists_every_windows_task_by_project_and_brings_one_up),
    ("says when there is no task yet", says_when_there_is_no_task_yet),
    ("tells the link and the last problem apart", tells_the_link_and_the_last_problem_apart),
    ("counts what the session loaded on its cards", counts_what_the_session_loaded_on_its_cards),
    ("opens a capability list and narrows it to what is typed", opens_a_capability_list_and_narrows_it_to_what_is_typed),
    ("keeps a list closed under the card the pointer just reached", keeps_a_list_closed_under_the_card_the_pointer_just_reached),
    ("leaves the provider's skills out of the commands", leaves_the_providers_skills_out_of_the_commands),
    ("opens an MD file from its list", opens_an_md_file_from_its_list),
    ("names a recalled line after its ERRORS section", names_a_recalled_line_after_its_errors_section),
    ("copies the session ID through the core", copies_the_session_id_through_the_core),
    ("opens the settings on the session tab and asks the core for the rest", opens_the_settings_on_the_session_tab_and_asks_the_core_for_the_rest),
    ("shows the accounts and Qwen the core sends", shows_the_accounts_and_qwen_the_core_sends),
    ("says what runs in the background and on which account", says_what_runs_in_the_background_and_on_which_account),
    ("lists the keyboard shortcuts", lists_the_keyboard_shortcuts),
    ("puts a settings command in the composer and closes", puts_a_settings_command_in_the_composer_and_closes),
    ("opens the settings with command comma and closes them on Escape", opens_the_settings_with_command_comma_and_closes_them_on_escape),
    ("keeps the sheet 480 by 520 and each value inside its block", keeps_the_sheet_480_by_520_and_each_value_inside_its_block),
    ("opens the settings when the core asks", opens_the_settings_when_the_core_asks),
    ("shows the sign-in and cancels it", shows_the_sign_in_and_cancels_it),
    ("dismisses the account status", dismisses_the_account_status),
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
