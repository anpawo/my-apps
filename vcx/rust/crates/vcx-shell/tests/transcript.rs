//! The transcript in a window that is never shown: each test hands the page a session built by `vcx-model`, as the
//! core does, then reads what it drew and drives it with real clicks and keys. What the page asks of the core (open a
//! link, copy, answer) is read from its messages and parsed by the bridge; nothing is opened and the pasteboard is
//! never touched. Its own `main` on the main thread: AppKit and WebKit live there.

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

use bridge::{FromPage, Target};
use input::{COMMAND, Key, NONE, SHIFT};
use objc2_app_kit::{NSEvent, NSEventType};
use objc2_foundation::{MainThreadMarker, NSDate, NSPoint, NSProcessInfo, NSRunLoop, NSString};
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::process::{Command, ExitCode};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tao::dpi::LogicalSize;
use tao::event_loop::{EventLoop, EventLoopBuilder};
use tao::window::{Window, WindowBuilder};
use vcx_model::SessionState;
use vcx_model::view;
use wry::{BackgroundThrottlingPolicy, WebView, WebViewBuilder, WebViewExtMacOS};

const WAIT: Duration = Duration::from_secs(10);
const SPIN_SECONDS: f64 = 0.005;
/// The size of a VCX window, so the transcript lays out as it does on screen.
// A question this tall is not folded, yet pinned it would cover a third of the transcript; it takes at most this share.
const PINNED_QUESTION_LINES: usize = 14;
const PINNED_SHARE: f64 = 0.2;
const WINDOW_SIZE: LogicalSize<f64> = LogicalSize { width: 980.0, height: 720.0 };
/// A 1×1 PNG.
const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const QUESTION_METHOD: &str = "item/tool/requestUserInput";
/// Enough paragraphs for an answer several screens tall.
const LONG_ANSWER_PARAGRAPHS: usize = 120;
/// The M10 thread: 5,000 rows, four to a section, with no virtual list.
const LONG_THREAD_SECTIONS: usize = 1250;
/// The key code of `f` on the ANSI layout.
const F_KEY: u16 = 3;
/// A hidden window draws no frames, so its motion never runs on its own: the test ends it.
/// How long the page says a copy was made, as Swift does, less a margin for the timers: the picture, the cell.
const COPIED_IMAGE_SHOWN: Duration = Duration::from_millis(1400);
const COPIED_CELL_SHOWN: Duration = Duration::from_millis(1100);
const FINISH_MOTION: &str = "document.getAnimations().forEach(motion => motion.finish())";
/// How far each streamed patch pushes the answer down, and how many patches carry the work block past the pointer.
const STREAM_STEP_LINES: usize = 3;
const STREAM_STEPS: usize = 12;
/// The resting pointer sits this far above the work block's header when the answer starts streaming.
const POINTER_ABOVE_BLOCK_PX: f64 = 60.0;

struct Page {
    webview: WebView,
    posts: Arc<Mutex<Vec<(String, String)>>>,
    scratch: PathBuf,
    _window: Window,
}

fn spin() {
    NSRunLoop::currentRunLoop().runUntilDate(&NSDate::dateWithTimeIntervalSinceNow(SPIN_SECONDS));
}

fn check(condition: bool, what: impl Into<String>) -> Result<(), String> {
    if condition { Ok(()) } else { Err(what.into()) }
}

/// The message the core sends for a saved session: the model's own view of it.
fn full(snapshot: Value) -> Value {
    let state = SessionState::from_snapshot(snapshot.as_object().expect("a snapshot is an object"));
    let mut message = view::full(&state);
    message["type"] = json!("full");
    message["serial"] = json!(1);
    message
}

fn user(id: &str, text: &str) -> Value {
    json!({"id": id, "kind": "user", "items": [{"id": format!("{id}u"), "type": "userMessage", "content": [{"type": "text", "text": text}]}]})
}

fn assistant(id: &str, text: &str, ended: bool) -> Value {
    json!({"id": id, "kind": "assistant", "items": [{"id": format!("{id}a"), "type": "agentMessage", "text": text, "provider": "Claude", "endedTurn": ended}]})
}

impl Page {
    fn open(event_loop: &EventLoop<()>) -> Page {
        let window = WindowBuilder::new().with_title("VCX transcript test").with_inner_size(WINDOW_SIZE).with_visible(false).build(event_loop).unwrap();
        let (store, problem) = template::Store::open(None);
        assert!(problem.is_none(), "{problem:?}");
        let posts = Arc::new(Mutex::new(Vec::new()));
        let received = posts.clone();
        let webview = WebViewBuilder::new()
            .with_custom_protocol(template::SCHEME.into(), move |_, request| store.respond(request.uri().host(), request.uri().path()))
            .with_ipc_handler(move |request| received.lock().unwrap().push((request.uri().to_string(), request.body().clone())))
            .with_navigation_handler(|url| bridge::may_load(&url))
            .with_background_throttling(BackgroundThrottlingPolicy::Disabled)
            .with_url(template::HOME)
            .build(&window)
            .unwrap();
        let scratch = std::env::temp_dir().join(format!("vcx-transcript-{}", std::process::id()));
        let _ = fs::remove_dir_all(&scratch);
        fs::create_dir_all(&scratch).unwrap();
        Page { webview, posts, scratch, _window: window }
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

    /// Runs `script` in the page and gives back what it evaluates to.
    fn eval(&self, script: &str) -> Result<Value, String> {
        let result = Arc::new(Mutex::new(None));
        let slot = result.clone();
        self.webview.evaluate_script_with_callback(&format!("JSON.stringify(({script}))"), move |value| *slot.lock().unwrap() = Some(value)).map_err(|error| error.to_string())?;
        self.wait(script, |_| result.lock().unwrap().is_some())?;
        let text = result.lock().unwrap().take().unwrap();
        if text.is_empty() {
            return Ok(Value::Null);
        }
        match serde_json::from_str(&text).map_err(|error| format!("{script}: {error}: {text}"))? {
            Value::String(json) => serde_json::from_str(&json).map_err(|error| format!("{script}: {error}: {json}")),
            other => Ok(other),
        }
    }

    /// Waits until `script` evaluates to something `accept` takes, and gives it back.
    fn until(&self, what: &str, script: &str, accept: impl Fn(&Value) -> bool) -> Result<Value, String> {
        let deadline = Instant::now() + WAIT;
        loop {
            let value = self.eval(script)?;
            if accept(&value) {
                return Ok(value);
            }
            if Instant::now() > deadline {
                return Err(format!("{what}: the page has {value}"));
            }
            spin();
        }
    }

    fn reload(&self) -> Result<(), String> {
        self.posts.lock().unwrap().clear();
        self.webview.load_url(template::HOME).map_err(|error| error.to_string())?;
        self.wait("the page to report ready", |page| !page.posted("ready").is_empty())?;
        input::focus(&self.webview)
    }

    fn show(&self, snapshot: Value) -> Result<(), String> {
        self.webview.evaluate_script(&bridge::deliver(&full(snapshot))).map_err(|error| error.to_string())?;
        self.until("the page to draw the session", "document.querySelectorAll('#rows .row').length", |count| count.as_u64() > Some(0)).map(drop)
    }

    /// The bodies the page posted of `kind`, oldest first.
    fn posted(&self, kind: &str) -> Vec<String> {
        let posts = self.posts.lock().unwrap();
        posts.iter().filter(|(_, body)| serde_json::from_str::<Value>(body).is_ok_and(|post| post["type"] == kind)).map(|(_, body)| body.clone()).collect()
    }

    /// What the core reads from the page's last message of `kind`, once it came.
    fn heard(&self, kind: &str) -> Result<FromPage, String> {
        self.wait(&format!("the page to post {kind}"), |page| !page.posted(kind).is_empty())?;
        let body = self.posted(kind).pop().unwrap();
        bridge::parse(&body).ok_or_else(|| format!("the core cannot read {body}"))
    }

    /// A real click on the middle of the first element `selector` names, once the page has handled it: the click
    /// reaches the page on its own way, after a script sent at the same time.
    fn click(&self, selector: &str) -> Result<(), String> {
        self.click_with(selector, NONE, 1)
    }

    /// `click`, with `modifiers` held, as the `count`th click of a run (2 for the second of a double-click).
    fn click_with(&self, selector: &str, modifiers: objc2_app_kit::NSEventModifierFlags, count: isize) -> Result<(), String> {
        let count_script = "(window.__clicks || (window.__clicks = 0, addEventListener('click', () => window.__clicks++, true), 0), window.__clicks)";
        let before = self.eval(count_script)?;
        let place = self.eval(&format!("(() => {{ const node = document.querySelector({selector:?}); if (!node) return null; node.scrollIntoView({{block: 'center'}}); const box = node.getBoundingClientRect(); const x = box.x + box.width / 2, y = box.y + box.height / 2; const hit = document.elementFromPoint(x, y); return [x, y, node.contains(hit), hit && hit.outerHTML.slice(0, 120)]; }})()"))?;
        let (Some(x), Some(y)) = (place[0].as_f64(), place[1].as_f64()) else { return Err(format!("{selector} is not on the page")) };
        if place[2] != true {
            return Err(format!("a click on {selector} would land on {}", place[3]));
        }
        input::click_with(&self.webview, x, y, modifiers, count)?;
        self.until(&format!("the click on {selector}"), count_script, |now| now.as_u64() > before.as_u64()).map(drop)
    }

    fn press(&self, key: Key, modifiers: objc2_app_kit::NSEventModifierFlags) -> Result<(), String> {
        input::press(&self.webview, key, modifiers)
    }

    /// ⌘F as AppKit hands it to the key window: the window is never shown, so never key, and the application would
    /// drop a key equivalent sent through it.
    fn find(&self) -> Result<(), String> {
        let window = self.webview.ns_window();
        let letter = NSString::from_str("f");
        let uptime = NSProcessInfo::processInfo().systemUptime();
        let event = NSEvent::keyEventWithType_location_modifierFlags_timestamp_windowNumber_context_characters_charactersIgnoringModifiers_isARepeat_keyCode(NSEventType::KeyDown, NSPoint::ZERO, COMMAND, uptime, window.windowNumber(), None, &letter, &letter, false, F_KEY);
        let event = event.ok_or("AppKit made no key event.")?;
        if !window.performKeyEquivalent(&event) {
            window.sendEvent(&event);
        }
        self.until("the find bar", "!document.getElementById('find').hidden && document.activeElement.id", |focused| focused != false).map(drop)
    }

    fn file(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.scratch.join(name);
        fs::write(&path, bytes).unwrap();
        path
    }

    fn picture(&self) -> PathBuf {
        let encoded = self.file("shot.b64", PNG.as_bytes());
        let picture = self.scratch.join("shot.png");
        let status = Command::new("/usr/bin/base64").arg("-D").arg("-i").arg(&encoded).arg("-o").arg(&picture).status().unwrap();
        assert!(status.success());
        picture
    }
}

impl Drop for Page {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.scratch);
    }
}

fn shows_a_pasted_picture_served_by_the_core_and_previews_it(page: &Page) -> Result<(), String> {
    let picture = page.picture();
    let item = json!({"id": "u1", "type": "userMessage", "content": [{"type": "text", "text": "look "}, {"type": "localImage", "path": picture}, {"type": "localImage", "path": "/no/such.png"}]});
    page.show(json!({"rows": [{"id": "R1", "kind": "user", "items": [item]}]}))?;

    let drawn = page.until("the picture to load", "[...document.querySelectorAll('.picture')].map(p => ({text: p.innerText.trim(), loaded: p.querySelector('img') ? p.querySelector('img').naturalWidth : -1}))", |pictures| pictures[0]["loaded"] == 1 && pictures[1]["loaded"] == -1)?;
    page.click(".picture")?;
    page.eval(FINISH_MOTION)?;
    let opened = page.eval("({shown: !document.getElementById('preview').hidden, glass: document.querySelector('#preview .glass').classList.contains('open'), src: document.querySelector('#preview img').src})")?;
    page.press(Key::Escape, NONE)?;
    page.eval(FINISH_MOTION)?;
    let closed = page.eval("document.getElementById('preview').hidden")?;
    let last = page.eval("vcx.previewLast()")?;
    page.eval(FINISH_MOTION)?;
    let reopened = page.eval("!document.getElementById('preview').hidden")?;
    page.show(json!({"rows": [{"id": "R2", "kind": "user", "items": [{"id": "u2", "type": "userMessage", "text": "no picture"}]}]}))?;
    let none = page.eval("vcx.previewLast()")?;

    check(drawn[0]["text"] == "Image #1\nClick to preview" && drawn[1]["text"].as_str().is_some_and(|text| text.contains("Image #2")), format!("the pictures read {drawn}"))?;
    check(drawn[1]["loaded"] == -1, "a picture with no file shows its placeholder")?;
    check(opened["shown"] == true && opened["glass"] == true && opened["src"].as_str().is_some_and(|src| src.starts_with("vcx://image/")), format!("the preview is {opened}"))?;
    check(closed == true, "Escape closes the preview")?;
    check(last == true && reopened == true, format!("/preview opened the last picture: {last}, shown: {reopened}"))?;
    check(none == false, "/preview finds no picture in a conversation without one")
}

fn shows_a_local_picture_of_an_answer_at_chat_width_and_enlarges_it(page: &Page) -> Result<(), String> {
    let picture = page.picture();
    let text = page.file("notes.txt", b"text");
    let answer = format!("Here: ![shot](file://{}) and ![notes](file://{})", picture.display(), text.display());
    page.show(json!({"rows": [assistant("R1", &answer, true)]}))?;

    let drawn = page.until("the answer's picture to load", "[...document.querySelectorAll('.prose img')].map(image => ({src: image.getAttribute('src'), loaded: image.naturalWidth, fits: image.getBoundingClientRect().width <= image.closest('.prose').getBoundingClientRect().width}))", |images| images[0]["loaded"] == 1)?;
    page.click(".prose img[src^='vcx://image/']")?;
    page.eval(FINISH_MOTION)?;
    let opened = page.eval("({shown: !document.getElementById('preview').hidden, src: document.querySelector('#preview img').getAttribute('src')})")?;
    page.press(Key::Escape, NONE)?;
    page.eval(FINISH_MOTION)?;

    check(drawn[0]["src"].as_str().is_some_and(|src| src.starts_with("vcx://image/")) && drawn[0]["fits"] == true, format!("the answer's picture is {drawn}"))?;
    check(drawn[1]["src"].as_str().is_some_and(|src| src.starts_with("file://")) && drawn[1]["loaded"] == 0, format!("a text file stays refused: {drawn}"))?;
    check(opened["shown"] == true && opened["src"] == drawn[0]["src"], format!("the preview is {opened}"))
}

fn draws_a_waiting_prompt_and_a_message_from_another_window(page: &Page) -> Result<(), String> {
    let queued = json!({"id": "u1", "type": "userMessage", "queued": true, "recalled": ["24/11: one rule"], "content": [{"type": "text", "text": "next step"}]});
    let peer = json!({"id": "u2", "type": "userMessage", "content": [{"type": "text", "text": "claude from [Rust app]: \"rebuilt\""}]});
    page.show(json!({"rows": [{"id": "R1", "kind": "user", "items": [queued]}, {"id": "R2", "kind": "user", "items": [peer]}]}))?;

    let drawn = page.eval("[...document.querySelectorAll('.question')].map(q => ({text: q.querySelector('.message').innerText, from: q.querySelector('.from') && q.querySelector('.from').textContent, unread: q.querySelector('.unread') && q.querySelector('.unread').innerText, queued: q.querySelector('.bubble').classList.contains('queued'), shown: !!q.querySelector('.recalled') && q.querySelector('.recalled').getBoundingClientRect().height}))")?;
    page.click(".bubble.recall .message")?;
    page.eval(FINISH_MOTION)?;
    let recall = page.eval("document.querySelector('.recalled').open && document.querySelector('.recall-note').textContent")?;

    check(drawn[0]["queued"] == true && drawn[0]["unread"].as_str().is_some_and(|text| text.starts_with("Not read yet")), format!("the waiting prompt reads {}", drawn[0]))?;
    check(drawn[0]["shown"] == 0, format!("the recall note shows before a click: {}", drawn[0]))?;
    check(recall == "VCX note, not part of the request: past mistakes from Marius's ERRORS files that may apply to it.\n- 24/11: one rule", format!("the recall note reads {recall}"))?;
    check(drawn[1]["from"] == "from claude-Rust app" && drawn[1]["text"] == "rebuilt", format!("the message from another window reads {}", drawn[1]))
}

fn answers_a_question_card_by_click_and_by_number(page: &Page) -> Result<(), String> {
    let questions = json!([
        {"id": "style", "header": "Button", "question": "Which style?", "options": [{"label": "Shared", "description": "Follows the theme."}, {"label": "Fixed"}]},
        {"id": "extras", "question": "Anything else?", "multiSelect": true, "options": [{"label": "Dark"}, {"label": "Wide"}, {"label": "Loud"}]}
    ]);
    let permissions = json!([{"id": "P1", "rpcID": 7, "method": QUESTION_METHOD, "params": {"questions": questions}}]);
    page.show(json!({"permissions": permissions, "rows": [user("R1", "pick one")]}))?;

    let first = page.eval("document.getElementById('question').innerText")?;
    page.click("#question .option[data-number='1']")?;
    let second = page.eval("document.querySelector('.question-title').textContent")?;
    page.press(Key::Char('3'), NONE)?;
    page.press(Key::Char('1'), NONE)?;
    page.press(Key::Return, NONE)?;
    let answer = page.heard("answer")?;
    let hidden = page.eval("document.getElementById('question').hidden")?;

    check(first.as_str().is_some_and(|text| text.starts_with("Question 1 of 2 · Button")), format!("the card reads {first}"))?;
    check(first.as_str().is_some_and(|text| text.contains("Which style?") && text.contains("Follows the theme.")), format!("the card reads {first}"))?;
    check(second == "Question 2 of 2", format!("after a choice the card reads {second}"))?;
    let expected = json!({"rpcID": 7, "method": QUESTION_METHOD, "result": {"answers": {"style": {"answers": ["Shared"]}, "extras": {"answers": ["Dark", "Loud"]}}}});
    check(answer == FromPage::Answer { params: expected }, format!("the core read {answer:?}"))?;
    check(hidden == true, "the card goes once answered")
}

fn cancels_a_question_with_no_answer(page: &Page) -> Result<(), String> {
    let permissions = json!([{"id": "P2", "rpcID": "q", "method": QUESTION_METHOD, "params": {"questions": [{"question": "Go?", "options": [{"label": "Yes"}]}]}}]);
    page.show(json!({"permissions": permissions, "rows": [user("R1", "ask me")]}))?;

    page.click(".question-cancel")?;
    let answer = page.heard("answer")?;

    check(answer == FromPage::Answer { params: json!({"rpcID": "q", "method": QUESTION_METHOD, "result": {"answers": {}}}) }, format!("the core read {answer:?}"))
}

fn draws_notes_as_thoughts_and_the_answer_being_written_as_the_answer_with_its_bands(page: &Page) -> Result<(), String> {
    let rows = |busy: bool| json!({"busy": busy, "rows": [user("R1", "go"), assistant("R2", "Reading the code.", false), assistant("R3", "⟶ It works.\n\nDetails.\n\n✓ Done: shipped.\n\n⟶ Next: ship it?", !busy)]});
    let bands = "[...document.querySelectorAll('.row[data-kind=assistant]')].map(row => ({thought: row.classList.contains('thought'), label: getComputedStyle(row.querySelector('.label')).display, bands: [...row.querySelectorAll('.prose > p')].map(p => getComputedStyle(p).backgroundColor)}))";
    page.show(rows(true))?;
    let working = page.eval(bands)?;
    page.show(rows(false))?;
    let done = page.eval(bands)?;
    let command = json!([{"id": "t1", "type": "commandExecution", "command": "ls", "status": "inProgress"}]);
    page.show(json!({"busy": true, "rows": [user("R1", "go"), assistant("R2", "Checking those now.", false), {"id": "R3", "kind": "activity", "items": command}]}))?;
    let checking = page.eval(bands)?;

    let (thought, clear) = ("rgb(238, 234, 247)", "rgba(0, 0, 0, 0)");
    let (green, orange, blue) = ("rgb(214, 245, 214)", "rgb(255, 225, 195)", "rgb(214, 230, 255)");
    check(working[0]["thought"] == true && working[0]["bands"] == json!([thought]), format!("a note is a thought: {}", working[0]))?;
    check(working[1]["thought"] == false && working[1]["bands"] == json!([green, clear, orange, blue]), format!("the answer being written is no thought: {}", working[1]))?;
    check(working[1]["label"] == "none" && working[0]["label"] == "block", "only the first message of the exchange names its provider")?;
    check(done[0]["thought"] == true && done[1]["thought"] == false, format!("the finished answer is no thought: {done}"))?;
    check(done[1]["bands"] == json!([green, clear, orange, blue]), format!("the finished answer's bands are {}", done[1]))?;
    check(checking[0]["thought"] == true, format!("a last message that work follows is a thought: {checking}"))
}

fn draws_a_debate_round_with_each_model_in_its_colour(page: &Page) -> Result<(), String> {
    let output = "<<debate claude>>\nmy point\n<<debate codex gpt-6.2>>\nits answer";
    let item = json!({"id": "d1", "type": "commandExecution", "command": "~/bin/ask-codex.sh brief.md", "aggregatedOutput": output, "exitCode": 0, "status": "completed"});
    page.show(json!({"model": "claude-fable-5-2", "ready": true, "rows": [user("R1", "debate it"), {"id": "R2", "kind": "activity", "items": [item]}, assistant("R3", "Settled.", true)]}))?;

    let turns = page.eval("[...document.querySelectorAll('.debate .turn-bubble')].map(turn => ({name: turn.querySelector('.speaker').textContent, right: turn.classList.contains('right'), color: getComputedStyle(turn.querySelector('.speaker')).color, text: turn.querySelector('.prose').innerText.trim()}))")?;
    let folded = page.eval("document.querySelectorAll('.work').length")?;

    check(turns.as_array().map(Vec::len) == Some(2), format!("the round shows {turns}"))?;
    check(turns[0]["name"] == "Fable 5.2" && turns[0]["right"] == true && turns[0]["text"] == "my point", format!("this session's turn is {}", turns[0]))?;
    check(turns[1]["name"] == "Codex gpt-6.2" && turns[1]["right"] == false && turns[1]["color"] == "rgb(10, 122, 102)", format!("Codex's turn is {}", turns[1]))?;
    check(folded == 0, "a debate stays out of the folded work")
}

fn folds_a_sections_actions_into_one_block_with_each_actions_detail(page: &Page) -> Result<(), String> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64();
    let items = json!([
        {"id": "t1", "type": "commandExecution", "command": "ls -la", "description": "List files", "aggregatedOutput": "a\nb", "exitCode": 0, "status": "completed", "seconds": 75},
        {"id": "t2", "type": "commandExecution", "command": "false", "exitCode": 1, "status": "failed"}
    ]);
    let running = json!([{"id": "t3", "type": "reasoning", "description": "Thinking", "status": "inProgress", "stepStartedAt": now - 5.0}]);
    page.show(json!({"rows": [user("R1", "look"), {"id": "R2", "kind": "activity", "items": items}, assistant("R3", "Looking.", false), {"id": "R4", "kind": "activity", "items": running}, assistant("R5", "Found it.", true)]}))?;

    let block = page.eval("({count: document.querySelectorAll('.work').length, title: document.querySelector('.work > summary').innerText.trim(), open: document.querySelector('.work').open})")?;
    page.click(".work > summary")?;
    // The block glides open: in a window that draws no frames, the test ends its motion.
    page.eval(FINISH_MOTION)?;
    page.click(".action > summary")?;
    let action = page.eval("[...document.querySelectorAll('.action')].map(a => ({title: a.querySelector('.title').textContent, failed: a.classList.contains('failed'), clock: a.querySelector('.clock') && a.querySelector('.clock').textContent, detail: [...a.querySelectorAll('pre')].map(p => p.textContent), open: a.open}))")?;
    let order = page.eval("[...document.querySelector('.turn:last-child').children].map(node => node.dataset.kind || node.className.split(' ')[0])")?;
    let ticked = page.until("the running step's clock to tick", "document.querySelectorAll('.action')[2].querySelector('.clock').textContent", |clock| clock.as_str().is_some_and(|clock| clock != action[2]["clock"]))?;

    check(block["count"] == 1 && block["title"] == "3 actions" && block["open"] == false, format!("the work block is {block}"))?;
    check(action[0]["open"] == true && action[0]["title"] == "List files" && action[0]["clock"] == "1:15" && action[0]["detail"] == json!(["ls -la", "a\nb\nExit: 0"]), format!("the first action is {}", action[0]))?;
    check(action[1]["failed"] == true && action[1]["title"] == "false", format!("the failed action is {}", action[1]))?;
    check(action[2]["clock"].as_str().is_some_and(|clock| clock.starts_with("0:0")) && ticked.as_str().is_some_and(|clock| clock.starts_with("0:")), format!("the running step shows {} then {ticked}", action[2]["clock"]))?;
    check(order == json!(["user", "work", "assistant", "assistant"]), format!("the section reads {order}"))
}

fn draws_a_notice_with_its_log_and_messages_between_sessions(page: &Page) -> Result<(), String> {
    let home = std::env::var("HOME").unwrap();
    let notice = json!({"id": "n1", "type": "notice", "text": "The worker restarted.", "link": format!("{home}/Library/Logs/vcx.log")});
    let sent = json!({"id": "p1", "type": "peerMessage", "direction": "sent", "name": "Rust app", "text": "rebuilt\nmore"});
    let received = json!({"id": "p2", "type": "peerMessage", "direction": "received", "name": "Rust report", "text": "thanks"});
    page.show(json!({"rows": [user("R1", "tell them"), assistant("R2", "Told.", true), {"id": "R3", "kind": "peer", "items": [sent]}, {"id": "R4", "kind": "notice", "items": [notice]}, {"id": "R5", "kind": "peer", "items": [received]}]}))?;

    let drawn = page.eval("({notice: document.querySelector('.notice-text').textContent, link: document.querySelector('.notice-link').textContent, sent: document.querySelector('.work.sent > summary').innerText.trim(), peers: [...document.querySelectorAll('.peer-line')].map(p => p.dataset.direction + ' ' + p.textContent), sections: document.querySelectorAll('.turn').length})")?;
    page.click(".notice-link")?;
    let opened = page.heard("open")?;

    check(drawn["notice"] == "The worker restarted." && drawn["link"] == "~/Library/Logs/vcx.log", format!("the notice reads {drawn}"))?;
    check(drawn["sent"] == "1 message sent" && drawn["peers"] == json!(["sent Sent to Rust app · rebuilt", "received Message from Rust report · thanks"]), format!("the messages read {drawn}"))?;
    check(drawn["sections"] == 2, "a message from another session opens its own section")?;
    check(opened == FromPage::Open { href: format!("{home}/Library/Logs/vcx.log") }, format!("the log link asks for {opened:?}"))
}

fn closes_the_picture_preview_with_its_close_button(page: &Page) -> Result<(), String> {
    let picture = page.picture();
    let item = json!({"id": "u1", "type": "userMessage", "content": [{"type": "text", "text": "look "}, {"type": "localImage", "path": picture}]});
    page.show(json!({"rows": [{"id": "R1", "kind": "user", "items": [item]}]}))?;
    page.click(".picture")?;
    page.eval(FINISH_MOTION)?;
    let label = page.eval("document.querySelector('#preview button.close').getAttribute('aria-label')")?;

    page.click("#preview button.close")?;
    page.eval(FINISH_MOTION)?;

    check(label == "Close image", format!("the button is named {label}"))?;
    page.until("the preview to close", "document.getElementById('preview').hidden", |hidden| *hidden == true).map(drop)?;
    check(page.posted("copyImage").is_empty(), "the close button copied the picture")
}

fn asks_for_the_window_of_the_session_a_message_came_from(page: &Page) -> Result<(), String> {
    let received = json!({"id": "p2", "type": "peerMessage", "direction": "received", "name": "Rust report", "text": "thanks", "pid": 4242, "startedAt": 1_700_000_000_000_u64});
    page.show(json!({"rows": [user("R1", "tell them"), assistant("R2", "Told.", true), {"id": "R3", "kind": "peer", "items": [received]}]}))?;

    page.click(".peer-line[data-direction=received]")?;

    let asked = page.heard("focusPeer")?;
    check(asked == FromPage::FocusPeer { pid: 4242, started_at: 1_700_000_000_000.0 }, format!("the core read {asked:?}"))
}

fn finds_in_questions_and_answers_ignoring_case_and_accents(page: &Page) -> Result<(), String> {
    page.show(json!({"rows": [user("R1", "Où est le café ?"), assistant("R2", "cafe in a note", false), assistant("R3", "Le **CAFE** est ici, cafe encore.", true)]}))?;

    page.find()?;
    let focused = page.eval("document.activeElement.id")?;
    input::type_text(&page.webview, "cafe")?;
    let found = page.until("the matches", "document.getElementById('find-count').textContent", |count| count == "1 of 3")?;
    let painted = page.eval("CSS.highlights.get('vcx-find').size")?;
    page.press(Key::Return, NONE)?;
    let next = page.eval("document.getElementById('find-count').textContent")?;
    page.press(Key::Return, SHIFT)?;
    let back = page.eval("document.getElementById('find-count').textContent")?;
    page.press(Key::Escape, NONE)?;
    let closed = page.eval("({hidden: document.getElementById('find').hidden, painted: CSS.highlights.has('vcx-find')})")?;

    check(focused == "find-input", format!("⌘F gives the keyboard to {focused}"))?;
    check(found == "1 of 3" && painted == 3, format!("found {found}, painted {painted}: the note is not searched"))?;
    check(next == "2 of 3" && back == "1 of 3", format!("Return went to {next}, Shift-Return back to {back}"))?;
    check(closed == json!({"hidden": true, "painted": false}), format!("Escape left {closed}"))
}

fn steps_through_the_matches_with_up_and_down_in_the_find_field(page: &Page) -> Result<(), String> {
    page.show(json!({"rows": [user("R1", "cafe one"), assistant("R2", "cafe two, cafe three", true)]}))?;
    page.find()?;
    input::type_text(&page.webview, "cafe")?;
    page.until("the matches", "document.getElementById('find-count').textContent", |count| count == "1 of 3")?;

    let count = "document.getElementById('find-count').textContent";

    page.press(Key::Down, NONE)?;
    page.until("Down to the second match", count, |shown| shown == "2 of 3")?;
    page.press(Key::Up, NONE)?;
    page.until("Up back to the first", count, |shown| shown == "1 of 3")?;
    page.press(Key::Up, NONE)?;

    page.until("Up from the first to the last", count, |shown| shown == "3 of 3").map(drop)
}

fn tells_no_match_and_keeps_its_matches_as_rows_arrive(page: &Page) -> Result<(), String> {
    page.show(json!({"rows": [user("R1", "alpha"), assistant("R2", "beta", true)]}))?;
    page.find()?;
    input::type_text(&page.webview, "gamma")?;
    let none = page.until("the count", "document.getElementById('find-count').textContent", |count| count != "")?;

    page.show(json!({"rows": [user("R1", "alpha"), assistant("R2", "gamma", true)]}))?;
    let later = page.until("the new match", "document.getElementById('find-count').textContent", |count| count == "1 of 1")?;
    page.press(Key::Escape, NONE)?;

    check(none == "No match", format!("an absent word reads {none}"))?;
    check(later == "1 of 1", "a row that arrives is searched")
}

fn hands_each_link_to_the_core_which_opens_only_what_is_safe(page: &Page) -> Result<(), String> {
    let notes = page.file("notes.md", b"notes");
    let script = page.file("run.command", b"#!/bin/sh");
    let text = format!("[web](https://example.com/a) [notes]({}) [script]({}) [relative](docs/a.md) [bad](javascript:alert(1))", notes.display(), script.display());
    page.show(json!({"rows": [user("R1", "links"), assistant("R2", &text, true)]}))?;

    let mut targets = Vec::new();
    for index in 1..=5 {
        page.posts.lock().unwrap().clear();
        page.click(&format!(".prose a:nth-of-type({index})"))?;
        let FromPage::Open { href } = page.heard("open")? else { return Err("a link click posted another message".into()) };
        targets.push(bridge::target(&href, None));
    }
    let still = page.eval("location.href")?;

    check(targets[0] == Some(Target::Web("https://example.com/a".into())), format!("the web link opens {:?}", targets[0]))?;
    check(targets[1] == Some(Target::File(notes)), format!("the notes open {:?}", targets[1]))?;
    check(targets[2] == Some(Target::Reveal(script)), format!("the script is {:?}", targets[2]))?;
    check(targets[3].is_none() && targets[4].is_none(), format!("a relative path and javascript: open {:?} and {:?}", targets[3], targets[4]))?;
    check(still == template::HOME, format!("the page stayed on {still}"))
}

fn copies_a_code_block_through_the_core_and_shows_it_was_copied(page: &Page) -> Result<(), String> {
    page.show(json!({"rows": [user("R1", "code"), assistant("R2", "```sh\necho \"hi\"\n```\n\n````\n# Plan\n\n```js\nx()\n```\n````", true)]}))?;

    let heads = page.eval("[...document.querySelectorAll('figure.code')].map(f => f.querySelector('.language').textContent)")?;
    // The whole header band copies, as Swift's.
    page.click("figure.code > figcaption > .language")?;
    let copied = page.heard("copy")?;
    let marked = page.eval("document.querySelector('figure.code button.copy').classList.contains('copied')")?;
    page.posts.lock().unwrap().clear();
    page.click("figure.code.markdown > figcaption > .language")?;
    let source = page.heard("copy")?;

    check(heads == json!(["sh", "Markdown", "js"]), format!("the code blocks are labelled {heads}"))?;
    check(copied == FromPage::Copy { text: "echo \"hi\"\n".into() } && marked == true, format!("the core read {copied:?}, the button shows copied: {marked}"))?;
    check(source == FromPage::Copy { text: "# Plan\n\n```js\nx()\n```\n".into() }, format!("a Markdown block copies its source: {source:?}"))
}

fn copies_the_previewed_picture_on_a_click_and_shows_it_was_copied(page: &Page) -> Result<(), String> {
    let picture = page.picture();
    let item = json!({"id": "u1", "type": "userMessage", "content": [{"type": "localImage", "path": picture}]});
    page.show(json!({"rows": [{"id": "R1", "kind": "user", "items": [item]}]}))?;
    page.until("the picture to load", "document.querySelector('.picture img')?.naturalWidth", |width| width == 1)?;
    page.click(".picture")?;
    page.eval(FINISH_MOTION)?;

    let clicked = Instant::now();
    page.click("#preview img")?;
    let copied = page.heard("copyImage")?;
    let shown = page.eval("({label: document.querySelector('#preview .copied')?.innerText.trim(), open: !document.getElementById('preview').hidden, hint: document.querySelector('#preview img').title})")?;
    page.until("the Copied label to go", &format!("({FINISH_MOTION}, !document.querySelector('#preview .copied'))"), |gone| gone == true)?;
    let held = clicked.elapsed();
    page.press(Key::Escape, NONE)?;

    check(copied == FromPage::CopyImage { path: picture }, format!("the core read {copied:?}"))?;
    check(shown["label"] == "Copied" && shown["open"] == true && shown["hint"] == "Click to copy the image", format!("after the click the preview shows {shown}"))?;
    check(held >= COPIED_IMAGE_SHOWN, format!("the Copied label went after {held:?}"))
}

fn copies_a_cell_on_command_click_and_its_row_on_command_double_click(page: &Page) -> Result<(), String> {
    let table = "| Name | Site |\n|---|---|\n| alpha | [web](https://example.com/a) |\n| beta | two |";
    page.show(json!({"rows": [user("R1", "table"), assistant("R2", table, true)]}))?;

    page.click(".prose tbody tr:nth-child(2) td")?;
    let plain = page.posted("copy").len();
    let clicked = Instant::now();
    page.click_with(".prose td a", COMMAND, 1)?;
    let cell = page.heard("copy")?;
    let cell_marked = page.eval("document.querySelector('.prose td:has(a)').classList.contains('copied')")?;
    page.posts.lock().unwrap().clear();
    page.click_with(".prose tbody tr:nth-child(2) td", COMMAND, 1)?;
    page.click_with(".prose tbody tr:nth-child(2) td", COMMAND, 2)?;
    page.wait("the row copy", |page| page.posted("copy").len() == 2)?;
    let row = page.heard("copy")?;
    let marked = page.eval("[...document.querySelectorAll('.prose .copied')].map(node => node.tagName)")?;
    page.until("the veil to go", "document.querySelectorAll('.prose .copied').length", |count| count == 0)?;
    let held = clicked.elapsed();

    check(plain == 0, "a click without ⌘ copies nothing")?;
    check(cell == FromPage::Copy { text: "web".into() } && cell_marked == true, format!("a ⌘-click on a link's cell copied {cell:?}, veiled: {cell_marked}"))?;
    check(page.posted("open").is_empty(), "a ⌘-click on a link in a cell does not open it")?;
    check(row == FromPage::Copy { text: "beta\ttwo".into() } && marked == json!(["TR"]), format!("a ⌘-double-click copied {row:?}, veiled {marked}"))?;
    check(held >= COPIED_CELL_SHOWN, format!("the veil went after {held:?}"))
}

/// A cell one line tall measures a line plus a rounded border, never a second line.
const ONE_LINE_SLACK: f64 = 1.5;

fn scrolls_a_wide_table_sideways_keeping_its_short_columns_whole(page: &Page) -> Result<(), String> {
    let long = "Each run recomputes the whole Break history inside the run's lock, so as history grows other runs give up.";
    let table = format!("| Finding | Severity | My view |\n|---|---|---|\n| {long} | medium | {long} |\n| {long} | low | {long} |");
    page.show(json!({"rows": [user("R1", "table"), assistant("R2", &table, true)]}))?;

    let laid = page.eval("(() => { const card = document.querySelector('.prose .table'); const severity = card.querySelectorAll('thead th')[2]; return {line: parseFloat(getComputedStyle(severity).lineHeight), height: severity.getBoundingClientRect().height - parseFloat(getComputedStyle(severity).paddingTop) - parseFloat(getComputedStyle(severity).paddingBottom), scrolls: card.scrollWidth > card.clientWidth, bar: card.offsetHeight - card.clientHeight - 2, overflow: getComputedStyle(card).overflowX}; })()")?;

    check(laid["height"].as_f64().unwrap_or(f64::MAX) < laid["line"].as_f64().unwrap_or(0.0) * ONE_LINE_SLACK, format!("the Severity header wraps: {laid}"))?;
    check(laid["scrolls"] == true && laid["overflow"] == "auto", format!("the table does not scroll sideways: {laid}"))?;
    check(laid["bar"].as_f64() == Some(0.0), format!("the table shows a scroll bar: {laid}"))
}

fn keeps_a_chart_frame_in_place_while_its_answer_streams(page: &Page) -> Result<(), String> {
    let snapshot = json!({"rows": [user("R1", "chart it"), assistant("R2", "Here:\n\n```chart\n<p>cards</p>\n```\n", false)]});
    let html = full(snapshot.clone())["rows"][1]["items"][0]["html"].as_str().unwrap_or_default().to_owned();
    page.show(snapshot)?;
    page.eval("(() => { window.__frame = document.querySelector('[data-row=R2] iframe'); window.__watch = new MutationObserver(() => {}); window.__watch.observe(document.getElementById('rows'), {subtree: true, childList: true}); return 0; })()")?;

    let streamed = json!({"type": "patch", "serial": 2, "rows": [{"id": "R2", "kind": "assistant", "items": [{"id": "R2a", "type": "agentMessage", "html": format!("{html}<p>And more.</p>"), "provider": "Claude", "endedTurn": true}]}]});
    page.webview.evaluate_script(&bridge::deliver(&streamed)).map_err(|error| error.to_string())?;
    let kept = page.until("the streamed text", "(() => { const removed = window.__watch.takeRecords().flatMap(record => [...record.removedNodes]).filter(node => node.nodeType === 1 && (node.matches('.chart, iframe, .answer-item, .prose') || node.querySelector('iframe'))).length; return {same: document.querySelector('[data-row=R2] iframe') === window.__frame, removed, last: document.querySelector('[data-row=R2] .prose').lastElementChild.textContent}; })()", |state| state["last"] == "And more.")?;

    check(kept["same"] == true && kept["removed"] == 0, format!("the chart frame was replaced or moved: {kept}"))
}

fn keeps_the_question_on_top_of_its_exchange_and_offers_the_way_back(page: &Page) -> Result<(), String> {
    let long = (0..LONG_ANSWER_PARAGRAPHS).map(|line| format!("Paragraph {line} of a long answer.")).collect::<Vec<_>>().join("\n\n");
    let second = (0..PINNED_QUESTION_LINES).map(|line| format!("second, line {line}")).collect::<Vec<_>>().join("\n");
    page.show(json!({"rows": [user("R1", "first"), assistant("R2", "short", true), user("R3", &second), assistant("R4", &long, true)]}))?;

    // A window never shown runs no animation frames: the rows would stay at the first frame of their entry.
    page.eval("(() => { document.getAnimations().filter(rise => rise.animationName === 'rise').forEach(rise => rise.finish()); const t = document.getElementById('transcript'); t.scrollTop = t.scrollHeight; t.dispatchEvent(new WheelEvent('wheel', {deltaY: -1})); t.scrollTop = t.scrollHeight - t.clientHeight * 3; t.dispatchEvent(new Event('scroll')); return 0; })()")?;
    let pinned = page.until("the way back", "({top: Math.round(document.querySelector('[data-row=R3]').getBoundingClientRect().top - document.getElementById('transcript').getBoundingClientRect().top), latest: !document.getElementById('latest').hidden, share: document.querySelector('[data-row=R3] .bubble').getBoundingClientRect().height / document.getElementById('transcript').clientHeight})", |state| state["latest"] == true)?;
    page.click("#latest")?;
    let back = page.until("the end", "(() => { const t = document.getElementById('transcript'); return t.scrollHeight - t.scrollTop - t.clientHeight; })()", |gap| gap.as_f64().is_some_and(|gap| gap < 2.0))?;

    check(pinned["top"].as_i64().is_some_and(|top| top.abs() <= 1), format!("the question sits {} px from the top", pinned["top"]))?;
    check(pinned["share"].as_f64().is_some_and(|share| share <= PINNED_SHARE + 0.005), format!("the pinned question takes {} of the transcript", pinned["share"]))?;
    check(back.as_f64().is_some_and(|gap| gap < 2.0), "Back to latest goes to the end")
}

fn keeps_following_the_answer_as_its_work_block_slides_under_a_resting_pointer(page: &Page) -> Result<(), String> {
    let long = (0..LONG_ANSWER_PARAGRAPHS).map(|line| format!("Paragraph {line} of an earlier answer.")).collect::<Vec<_>>().join("\n\n");
    let actions = json!([{"id": "t1", "type": "commandExecution", "command": "ls", "aggregatedOutput": "a\nb\nc\nd\ne\nf", "exitCode": 0, "status": "completed"}]);
    page.show(json!({"rows": [user("R1", "first"), assistant("R2", &long, true), user("R3", "second"), {"id": "R4", "kind": "activity", "items": actions}, assistant("R5", "Starting.", false)]}))?;
    // A hidden window gets no mouse moves: the page is handed the events WebKit makes up at a resting pointer after
    // each scroll, an enter when the header sweeps across it and a leave when the block has gone past it.
    page.eval(&format!("(() => {{ {FINISH_MOTION}; const t = document.getElementById('transcript'); t.scrollTop = t.scrollHeight; t.dispatchEvent(new Event('scroll')); const title = document.querySelector('.work > summary').firstElementChild, box = title.getBoundingClientRect(); const at = {{clientX: box.x + 5, clientY: box.y - {POINTER_ABOVE_BLOCK_PX}}}; window.__opened = false; new MutationObserver(() => {{ if (document.querySelector('.work.opened')) window.__opened = true; }}).observe(document.getElementById('rows'), {{subtree: true, attributes: true, attributeFilter: ['class']}}); document.dispatchEvent(new PointerEvent('pointermove', at)); window.__replay = before => {{ const block = document.querySelector('.work'), now = title.getBoundingClientRect(); if (now.top <= at.clientY && before.bottom >= at.clientY) title.dispatchEvent(new PointerEvent('pointerenter', at)); if (block.getBoundingClientRect().bottom < at.clientY && block.dataset.hovered === 'true') block.dispatchEvent(new PointerEvent('pointerleave', at)); }}; return 0; }})()"))?;

    let mut text = String::from("Starting.");
    for step in 0..STREAM_STEPS {
        for line in 0..STREAM_STEP_LINES {
            text.push_str(&format!("\n\nStreamed line {step}.{line}."));
        }
        let row = full(json!({"rows": [assistant("R5", &text, false)]}))["rows"][0].clone();
        let patch = json!({"type": "patch", "serial": step + 2, "rows": [row]});
        page.eval("(window.__before = document.querySelector('.work > summary').firstElementChild.getBoundingClientRect().toJSON(), 0)")?;
        page.webview.evaluate_script(&bridge::deliver(&patch)).map_err(|error| error.to_string())?;
        page.until("the streamed line", "document.querySelector('[data-row=R5]').textContent", |drawn| drawn.as_str().is_some_and(|drawn| drawn.contains(&format!("Streamed line {step}."))))?;
        page.eval(&format!("(() => {{ window.__replay(window.__before); {FINISH_MOTION}; document.getElementById('transcript').dispatchEvent(new Event('scroll')); return 0; }})()"))?;
    }
    let state = page.until("the view to settle", "(() => { const t = document.getElementById('transcript'); return {opened: window.__opened, latest: !document.getElementById('latest').hidden, top: Math.round(t.scrollTop), end: Math.round(t.scrollHeight - t.clientHeight)}; })()", |_| true)?;

    check(state["opened"] == false, format!("the work block opened as it slid under a resting pointer: {state}"))?;
    check(state["latest"] == false && state["top"] == state["end"], format!("the view left the streaming answer: {state}"))
}

/// Grows the last row by a screen with no frame drawn, as a picture loading in a hidden window does, then hands the
/// page a new row; answers how far the view ends above the transcript's end.
const GROW_THEN_DELIVER: &str = "(() => { const t = document.getElementById('transcript'); const tall = document.createElement('div'); tall.style.height = `${t.clientHeight}px`; document.querySelector('[data-row=R4]').append(tall); return 0; })()";
const GAP_TO_END: &str = "(() => { const t = document.getElementById('transcript'); return Math.round(t.scrollHeight - t.scrollTop - t.clientHeight); })()";

fn deliver_new_row(page: &Page) -> Result<Value, String> {
    let patch = json!({"type": "patch", "serial": 2, "rows": [full(json!({"rows": [user("R5", "third")]}))["rows"][0].clone()], "order": ["R1", "R2", "R3", "R4", "R5"]});
    page.webview.evaluate_script(&bridge::deliver(&patch)).map_err(|error| error.to_string())?;
    page.until("the new row", "Boolean(document.querySelector('[data-row=R5]'))", |drawn| drawn == &json!(true))?;
    page.eval(GAP_TO_END)
}

fn follows_new_rows_after_the_transcript_grew_in_a_window_drawing_no_frames(page: &Page) -> Result<(), String> {
    let long = (0..LONG_ANSWER_PARAGRAPHS).map(|line| format!("Paragraph {line} of a long answer.")).collect::<Vec<_>>().join("\n\n");
    page.show(json!({"rows": [user("R1", "first"), assistant("R2", "short", true), user("R3", "second"), assistant("R4", &long, true)]}))?;
    page.eval(&format!("(() => {{ {FINISH_MOTION}; const t = document.getElementById('transcript'); t.scrollTop = t.scrollHeight; t.dispatchEvent(new Event('scroll')); return 0; }})()"))?;
    page.eval(GROW_THEN_DELIVER)?;
    page.eval("(document.getElementById('transcript').dispatchEvent(new Event('scroll')), 0)")?;

    let gap = deliver_new_row(page)?;

    check(gap.as_f64().is_some_and(|gap| gap < 2.0), format!("the view stopped {gap} px above the end"))
}

fn stays_where_the_reader_scrolled_up_as_new_rows_arrive(page: &Page) -> Result<(), String> {
    let long = (0..LONG_ANSWER_PARAGRAPHS).map(|line| format!("Paragraph {line} of a long answer.")).collect::<Vec<_>>().join("\n\n");
    page.show(json!({"rows": [user("R1", "first"), assistant("R2", "short", true), user("R3", "second"), assistant("R4", &long, true)]}))?;
    page.eval(&format!("(() => {{ {FINISH_MOTION}; const t = document.getElementById('transcript'); t.scrollTop = t.scrollHeight; t.dispatchEvent(new WheelEvent('wheel', {{deltaY: -1}})); t.scrollTop = t.scrollHeight - t.clientHeight * 3; t.dispatchEvent(new Event('scroll')); return 0; }})()"))?;

    let gap = deliver_new_row(page)?;

    check(gap.as_f64().is_some_and(|gap| gap > 2.0), "a new row pulled the reader back to the end")
}

fn streams_into_a_thread_of_five_thousand_rows_touching_only_its_row(page: &Page) -> Result<(), String> {
    let mut rows = Vec::new();
    for section in 0..LONG_THREAD_SECTIONS {
        rows.push(user(&format!("U{section}"), &format!("question {section}")));
        rows.push(json!({"id": format!("T{section}"), "kind": "activity", "items": [{"id": format!("T{section}c"), "type": "commandExecution", "command": "ls", "aggregatedOutput": "a", "status": "completed"}]}));
        rows.push(assistant(&format!("N{section}"), "a note with **bold** text", false));
        rows.push(assistant(&format!("A{section}"), "the final answer, with a [link](https://example.com).", true));
    }
    page.show(json!({"rows": rows}))?;
    let last = format!("A{}", LONG_THREAD_SECTIONS - 1);

    let touched = page.eval(&format!("(() => {{ const watch = new MutationObserver(() => {{}}); watch.observe(document.getElementById('rows'), {{subtree: true, childList: true, attributes: true, characterData: true}}); vcx.receive({{type: 'patch', serial: 2, rows: [{{id: '{last}', kind: 'assistant', items: [{{id: '{last}a', type: 'agentMessage', html: '<p>streamed</p>', endedTurn: true}}]}}]}}); const own = document.querySelector('[data-row={last}]'); const outside = watch.takeRecords().filter(record => !own.contains(record.target)).map(record => record.target.className || record.target.nodeName); watch.disconnect(); return outside.slice(0, 5); }})()"))?;
    let drawn = page.eval(&format!("({{rows: document.querySelectorAll('#rows .row').length, text: document.querySelector('[data-row={last}] .prose').textContent}})"))?;

    check(drawn == json!({"rows": LONG_THREAD_SECTIONS * 4, "text": "streamed"}), format!("the thread reads {drawn}"))?;
    check(touched == json!([]), format!("a streamed patch also rewrote {touched}: each of the {} rows is laid out again", LONG_THREAD_SECTIONS * 4))
}

type Test = fn(&Page) -> Result<(), String>;

const TESTS: [(&str, Test); 25] = [
    ("shows_a_local_picture_of_an_answer_at_chat_width_and_enlarges_it", shows_a_local_picture_of_an_answer_at_chat_width_and_enlarges_it),
    ("shows_a_pasted_picture_served_by_the_core_and_previews_it", shows_a_pasted_picture_served_by_the_core_and_previews_it),
    ("draws_a_waiting_prompt_and_a_message_from_another_window", draws_a_waiting_prompt_and_a_message_from_another_window),
    ("answers_a_question_card_by_click_and_by_number", answers_a_question_card_by_click_and_by_number),
    ("cancels_a_question_with_no_answer", cancels_a_question_with_no_answer),
    ("draws_notes_as_thoughts_and_the_answer_being_written_as_the_answer_with_its_bands", draws_notes_as_thoughts_and_the_answer_being_written_as_the_answer_with_its_bands),
    ("draws_a_debate_round_with_each_model_in_its_colour", draws_a_debate_round_with_each_model_in_its_colour),
    ("folds_a_sections_actions_into_one_block_with_each_actions_detail", folds_a_sections_actions_into_one_block_with_each_actions_detail),
    ("draws_a_notice_with_its_log_and_messages_between_sessions", draws_a_notice_with_its_log_and_messages_between_sessions),
    ("asks_for_the_window_of_the_session_a_message_came_from", asks_for_the_window_of_the_session_a_message_came_from),
    ("closes_the_picture_preview_with_its_close_button", closes_the_picture_preview_with_its_close_button),
    ("finds_in_questions_and_answers_ignoring_case_and_accents", finds_in_questions_and_answers_ignoring_case_and_accents),
    ("steps_through_the_matches_with_up_and_down_in_the_find_field", steps_through_the_matches_with_up_and_down_in_the_find_field),
    ("tells_no_match_and_keeps_its_matches_as_rows_arrive", tells_no_match_and_keeps_its_matches_as_rows_arrive),
    ("hands_each_link_to_the_core_which_opens_only_what_is_safe", hands_each_link_to_the_core_which_opens_only_what_is_safe),
    ("copies_a_code_block_through_the_core_and_shows_it_was_copied", copies_a_code_block_through_the_core_and_shows_it_was_copied),
    ("copies_the_previewed_picture_on_a_click_and_shows_it_was_copied", copies_the_previewed_picture_on_a_click_and_shows_it_was_copied),
    ("copies_a_cell_on_command_click_and_its_row_on_command_double_click", copies_a_cell_on_command_click_and_its_row_on_command_double_click),
    ("scrolls_a_wide_table_sideways_keeping_its_short_columns_whole", scrolls_a_wide_table_sideways_keeping_its_short_columns_whole),
    ("keeps_a_chart_frame_in_place_while_its_answer_streams", keeps_a_chart_frame_in_place_while_its_answer_streams),
    ("keeps_the_question_on_top_of_its_exchange_and_offers_the_way_back", keeps_the_question_on_top_of_its_exchange_and_offers_the_way_back),
    ("keeps_following_the_answer_as_its_work_block_slides_under_a_resting_pointer", keeps_following_the_answer_as_its_work_block_slides_under_a_resting_pointer),
    ("follows_new_rows_after_the_transcript_grew_in_a_window_drawing_no_frames", follows_new_rows_after_the_transcript_grew_in_a_window_drawing_no_frames),
    ("stays_where_the_reader_scrolled_up_as_new_rows_arrive", stays_where_the_reader_scrolled_up_as_new_rows_arrive),
    ("streams_into_a_thread_of_five_thousand_rows_touching_only_its_row", streams_into_a_thread_of_five_thousand_rows_touching_only_its_row),
];

fn main() -> ExitCode {
    MainThreadMarker::new().expect("the transcript test runs on the main thread");
    let event_loop = EventLoopBuilder::new().build();
    let page = Page::open(&event_loop);
    let filter: Vec<String> = std::env::args().skip(1).filter(|argument| !argument.starts_with('-')).collect();
    let mut failed = 0;
    for (name, test) in TESTS {
        if !filter.is_empty() && !filter.iter().any(|wanted| name.contains(wanted.as_str())) {
            continue;
        }
        match page.reload().and_then(|()| test(&page)) {
            Ok(()) => println!("test {name} ... ok"),
            Err(problem) => {
                failed += 1;
                println!("test {name} ... FAILED: {problem}");
            }
        }
    }
    if failed == 0 { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
