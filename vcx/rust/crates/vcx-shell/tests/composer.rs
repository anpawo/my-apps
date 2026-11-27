//! The composer in a window that is never shown, driven by real key events, real clicks and marked text.
//! Its own `main` on the main thread: AppKit and WebKit live there, and the test harness runs tests elsewhere.
//! Paste is a synthetic `ClipboardEvent` page-side, and the menu's Copy, Cut and Paste are caught before they act:
//! the test never reads or writes the general pasteboard.

#[allow(dead_code, unused_imports)]
#[path = "../src/chart.rs"]
mod chart;
#[allow(dead_code, unused_imports)]
#[path = "../src/input.rs"]
mod input;
#[allow(dead_code, unused_imports)]
#[path = "../src/menu.rs"]
mod menu;
#[allow(dead_code, unused_imports)]
#[path = "../src/template.rs"]
mod template;

use input::{COMMAND, Key, NONE, OPTION, SHIFT};
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject};
use objc2::{MainThreadOnly, define_class, msg_send};
use objc2_app_kit::{NSApplication, NSEventModifierFlags};
use objc2_foundation::{MainThreadMarker, NSDate, NSRunLoop};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tao::dpi::LogicalSize;
use tao::event_loop::{EventLoop, EventLoopBuilder};
use tao::window::{Window, WindowBuilder};
use wry::{BackgroundThrottlingPolicy, WebView, WebViewBuilder, WebViewExtMacOS};

const TEMPLATE_FOLDER: &str = "VCX_COMPOSER_TEMPLATE";
/// The Swift window's own size: smaller, the session panel and the task bar cover the composer.
const WINDOW_SIZE: LogicalSize<f64> = LogicalSize { width: 980.0, height: 720.0 };
const WAIT: Duration = Duration::from_secs(10);
/// How long an absence is watched before it counts: the page answers a key within a few milliseconds.
const QUIET: Duration = Duration::from_millis(400);
const SPIN_SECONDS: f64 = 0.005;
const LONG_PASTE: &str = "line one of a long paste\nline two\nline three";
/// A 1×1 PNG.
const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

/// What the composer shows, read from the live page.
const STATE: &str = r#"(() => {
  const input = document.getElementById('input');
  const panel = document.getElementById('palette');
  const strip = document.getElementById('attachments');
  return {
    value: input.value,
    focused: document.activeElement === input,
    selection: [input.selectionStart, input.selectionEnd],
    chips: strip.hidden ? [] : [...strip.querySelectorAll('.attachment-label')].map(chip => chip.textContent),
    previews: strip.querySelectorAll('img').length,
    palette: panel.classList.contains('open') ? {
      title: panel.querySelector('.palette-title').textContent,
      options: [...panel.querySelectorAll('.palette-option-name')].map(option => option.textContent),
      selected: [...panel.querySelectorAll('.palette-option')].findIndex(option => option.classList.contains('selected')),
    } : null,
    stop: !document.getElementById('stop').hidden,
  };
})()"#;

thread_local! {
    static CAUGHT: RefCell<Vec<&'static str>> = const { RefCell::new(Vec::new()) };
}

define_class!(
    // Takes the menu's Copy, Cut and Paste in place of the web view, which would use the general pasteboard.
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "VCXComposerTestCatcher"]
    struct Catcher;

    impl Catcher {
        #[unsafe(method(copy:))]
        fn copy(&self, _sender: Option<&AnyObject>) {
            CAUGHT.with(|caught| caught.borrow_mut().push("copy"));
        }

        #[unsafe(method(cut:))]
        fn cut(&self, _sender: Option<&AnyObject>) {
            CAUGHT.with(|caught| caught.borrow_mut().push("cut"));
        }

        #[unsafe(method(paste:))]
        fn paste(&self, _sender: Option<&AnyObject>) {
            CAUGHT.with(|caught| caught.borrow_mut().push("paste"));
        }
    }
);

struct Page {
    mtm: MainThreadMarker,
    webview: WebView,
    posts: Arc<Mutex<Vec<Value>>>,
    catcher: Retained<Catcher>,
    _window: Window,
}

fn spin() {
    NSRunLoop::currentRunLoop().runUntilDate(&NSDate::dateWithTimeIntervalSinceNow(SPIN_SECONDS));
}

fn check(condition: bool, what: impl Into<String>) -> Result<(), String> {
    if condition { Ok(()) } else { Err(what.into()) }
}

impl Page {
    fn open(mtm: MainThreadMarker, event_loop: &EventLoop<()>) -> Page {
        let window = WindowBuilder::new().with_title("VCX composer test").with_inner_size(WINDOW_SIZE).with_visible(false).build(event_loop).unwrap();
        // A folder named here is tested in place of the built-in template: the tree's page files hold other sessions' work in flight.
        let folder = std::env::var_os(TEMPLATE_FOLDER).map(std::path::PathBuf::from);
        let (store, problem) = template::Store::open(folder.as_deref());
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
        // SAFETY: `Catcher` is an `NSObject` subclass with no ivars, so `init` makes it whole.
        let catcher: Retained<Catcher> = unsafe { msg_send![Catcher::alloc(mtm), init] };
        Page { mtm, webview, posts, catcher, _window: window }
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

    /// Waits until the composer's state passes `done` and gives it back; says what it last was otherwise.
    fn state(&self, what: &str, done: impl Fn(&Value) -> bool) -> Result<Value, String> {
        let deadline = Instant::now() + WAIT;
        loop {
            let state = self.eval(STATE)?;
            if done(&state) {
                return Ok(state);
            }
            if Instant::now() > deadline {
                return Err(format!("{what}: the composer is {state}"));
            }
            spin();
        }
    }

    fn value(&self, expected: &str) -> Result<Value, String> {
        self.state(&format!("the composer to hold {expected:?}"), |state| state["value"] == expected)
    }

    /// Hands the page a message, as the core does.
    fn deliver(&self, message: Value) -> Result<(), String> {
        self.eval(&format!("vcx.receive({message})")).map(drop)
    }

    fn posted(&self, kind: &str) -> Vec<Value> {
        self.posts.lock().unwrap().iter().filter(|post| post["type"] == kind).cloned().collect()
    }

    /// The page's first message of `kind` that passes `wanted`, taken off the list with those before it.
    fn next_where(&self, kind: &str, wanted: impl Fn(&Value) -> bool) -> Result<Value, String> {
        let matches = |post: &Value| post["type"] == kind && wanted(post);
        self.wait(&format!("the page to post {kind}"), |page| page.posts.lock().unwrap().iter().any(matches))?;
        let mut posts = self.posts.lock().unwrap();
        let at = posts.iter().position(matches).unwrap();
        Ok(posts.drain(..=at).last().unwrap())
    }

    fn next(&self, kind: &str) -> Result<Value, String> {
        self.next_where(kind, |_| true)
    }

    /// True when the page posted nothing of `kind` for a while.
    fn quiet(&self, kind: &str) -> bool {
        let until = Instant::now() + QUIET;
        while Instant::now() < until {
            spin();
        }
        self.posted(kind).is_empty()
    }

    fn keys(&self, text: &str) -> Result<(), String> {
        input::type_text(&self.webview, text)
    }

    fn press(&self, key: Key, modifiers: NSEventModifierFlags) -> Result<(), String> {
        input::press(&self.webview, key, modifiers)
    }

    /// A real click on the middle of the first element `selector` names.
    fn click(&self, selector: &str) -> Result<(), String> {
        let place = self.eval(&format!("(() => {{ const node = document.querySelector({selector:?}); if (!node) return null; const box = node.getBoundingClientRect(); return [box.x + box.width / 2, box.y + box.height / 2]; }})()"))?;
        let (Some(x), Some(y)) = (place[0].as_f64(), place[1].as_f64()) else { return Err(format!("{selector} is not on the page")) };
        input::click(&self.webview, x, y)
    }

    /// A paste as the page gets it, with a clipboard made in the page: never the system pasteboard.
    fn paste(&self, text: &str, image: bool) -> Result<bool, String> {
        let file = if image { format!("data.items.add(new File([Uint8Array.from(atob({PNG:?}), c => c.charCodeAt(0))], 'shot.png', {{ type: 'image/png' }}));") } else { String::new() };
        let script = format!(
            "(() => {{ const data = new DataTransfer(); data.setData('text/plain', {text}); {file} const event = new ClipboardEvent('paste', {{ clipboardData: data, bubbles: true, cancelable: true }}); document.getElementById('input').dispatchEvent(event); return event.defaultPrevented; }})()",
            text = json!(text)
        );
        Ok(self.eval(&script)? == json!(true))
    }

    /// Sends the Edit item `title`'s action to `target` instead of the key window's first responder.
    fn aim(&self, title: &str, target: &AnyObject) -> Result<(), String> {
        let item = menu::edit_item(self.mtm, title).ok_or(format!("The Edit menu has no {title}."))?;
        // SAFETY: the target answers the item's action and outlives the menu bar; an item holds its target weakly.
        unsafe { item.setTarget(Some(target)) };
        Ok(())
    }

    /// A window that is never shown never becomes key, so an action sent to the first responder finds no one there:
    /// each item that edits is aimed where the responder chain of a key window takes it, Select All at the web view,
    /// Undo and Redo at the window that holds the undo manager.
    fn install_menu(&self) -> Result<(), String> {
        menu::install(self.mtm);
        let (view, window) = (self.webview.webview(), self.webview.ns_window());
        let (view, window): (&AnyObject, &AnyObject) = (&view, &window);
        self.aim("Select All", view)?;
        ["Undo", "Redo"].into_iter().try_for_each(|title| self.aim(title, window))
    }

    fn reset(&self) -> Result<(), String> {
        self.install_menu()?;
        CAUGHT.with(|caught| caught.borrow_mut().clear());
        self.posts.lock().unwrap().clear();
        self.webview.load_url(template::HOME).map_err(|error| error.to_string())?;
        self.wait("the page to report ready", |page| !page.posted("ready").is_empty())?;
        self.deliver(full(json!({"ready": true}), json!([])))?;
        input::focus(&self.webview)?;
        self.eval("document.getElementById('input').focus()").map(drop)
    }
}

/// What the run panel shows, read from the live page; `null` while it is closed.
const RUN_PANEL: &str = r#"(() => {
  const card = document.getElementById('run');
  if (!card) return null;
  const shown = node => !node.hidden;
  const field = card.querySelector('.line');
  return {
    title: card.querySelector('.bar p').textContent,
    command: card.querySelector('.command').textContent,
    output: card.querySelector('.output').textContent,
    note: shown(card.querySelector('.where')) ? card.querySelector('.where').textContent : null,
    field: shown(field) ? field.type : null,
    typed: field.value,
    focused: document.activeElement === field,
    buttons: [...card.querySelectorAll('.foot .ub')].filter(shown).map(button => button.textContent),
  };
})()"#;

/// A reply as markdown.rs draws it: a shell block, a block to paste and an inline sudo command.
const RUNNABLE_REPLY: &str = r#"<div class="prose"><figure class="code"><figcaption><span class="language">bash</span><button type="button" class="copy"></button></figcaption><pre><code class="language-bash">ls -la</code></pre></figure><figure class="code"><figcaption><span class="language">Code</span><button type="button" class="copy"></button></figcaption><pre><code>Dear Bas,</code></pre></figure><p>Then <code>sudo reboot</code>.</p></div>"#;

impl Page {
    /// Puts `html` in the transcript and scrolls the part `selector` names to the top: in the small test window the
    /// footer covers the rest.
    fn show(&self, html: &str, selector: &str) -> Result<(), String> {
        let script = format!("(() => {{ const rows = document.getElementById('rows'); rows.insertAdjacentHTML('beforeend', {} + '<div style=\"height: 2000px\"></div>'); rows.querySelector({selector:?}).scrollIntoView({{ block: 'start' }}); }})()", json!(html));
        self.eval(&script).map(drop)
    }

    fn run_panel(&self, what: &str, done: impl Fn(&Value) -> bool) -> Result<Value, String> {
        let deadline = Instant::now() + WAIT;
        loop {
            let panel = self.eval(RUN_PANEL)?;
            if done(&panel) {
                return Ok(panel);
            }
            if Instant::now() > deadline {
                return Err(format!("{what}: the run panel is {panel}"));
            }
            spin();
        }
    }
}

fn full(meta: Value, rows: Value) -> Value {
    json!({"type": "full", "serial": 1, "meta": meta, "rows": rows, "draft": []})
}

fn user_row(id: &str, text: &str, images: Value) -> Value {
    json!({"id": id, "kind": "user", "items": [{"id": format!("{id}-item"), "type": "userMessage", "text": text, "images": images, "queued": false}]})
}

fn sends_on_return_and_keeps_shift_return_as_a_new_line(page: &Page) -> Result<(), String> {
    page.keys("first")?;
    page.press(Key::Return, SHIFT)?;
    page.keys("second")?;
    page.value("first\nsecond")?;

    page.press(Key::Return, NONE)?;

    let sent = page.next("send")?;
    check(sent["text"] == "first\nsecond" && sent["images"] == json!([]), format!("sent {sent}"))?;
    check(sent["draft"] == json!([{"type": "text", "text": "first\nsecond"}]) && sent["generation"].is_u64(), format!("the send carries the draft it consumes: {sent}"))?;
    page.value("").map(drop)
}

fn glides_the_sent_message_from_the_composer_into_the_transcript(page: &Page) -> Result<(), String> {
    page.keys("glide")?;
    page.press(Key::Return, NONE)?;
    page.next("send")?;

    page.deliver(json!({"type": "full", "serial": 2, "meta": {"ready": true}, "rows": [user_row("u1", "glide", json!([]))], "draft": []}))?;

    page.wait("the sent bubble to glide", |page| page.eval("document.querySelector('[data-row=u1] .bubble')?.getAnimations().length > 0").is_ok_and(|gliding| gliding == true))?;
    let settle = Instant::now() + QUIET;
    while Instant::now() < settle {
        spin();
    }
    // The glide's transform stretches the transcript's scroll height; following that stretch threw the bubble off the top.
    let past = page.eval("(() => { const t = document.getElementById('transcript'), top = t.scrollTop; document.querySelector('[data-row=u1] .bubble').getAnimations().forEach(a => a.cancel()); return top - (t.scrollHeight - t.clientHeight); })()")?;
    check(past.as_f64().is_some_and(|past| past <= 1.0), format!("the transcript scrolled {past} px past its rows while the bubble glided"))
}

fn sends_with_a_real_click_and_keeps_the_caret_in_the_composer(page: &Page) -> Result<(), String> {
    page.keys("clicked")?;
    page.value("clicked")?;

    page.click("#send")?;

    check(page.next("send")?["text"] == "clicked", "the click sent the text")?;
    let state = page.value("")?;
    check(state["focused"] == true, "the click left the caret in the composer")
}

fn answers_an_open_question_card_instead_of_sending(page: &Page) -> Result<(), String> {
    page.eval("window.vcxQuestions = { open: true, reply: text => (window.answered = text, true) }")?;
    page.keys("option two")?;

    page.press(Key::Return, NONE)?;

    page.value("")?;
    check(page.eval("window.answered")? == "option two", "the card did not get the typed text")?;
    check(page.quiet("send"), "the answer was also sent as a message")
}

fn sends_nothing_for_an_empty_composer(page: &Page) -> Result<(), String> {
    page.keys("   ")?;
    page.value("   ")?;

    page.press(Key::Return, NONE)?;

    check(page.quiet("send"), "blank text was sent")
}

fn shift_return_on_an_empty_composer_sends_the_waiting_prompt_now(page: &Page) -> Result<(), String> {
    page.deliver(json!({"type": "patch", "meta": {"busy": true}}))?;

    page.press(Key::Return, SHIFT)?;

    page.next("sendNow")?;
    check(page.posted("send").is_empty(), "Shift-Return sent a message")?;
    page.value("").map(drop)
}

fn shows_the_stop_button_while_a_turn_runs(page: &Page) -> Result<(), String> {
    page.state("no stop button before a turn", |state| state["stop"] == false)?;
    page.deliver(json!({"type": "patch", "meta": {"busy": true}}))?;
    page.state("the stop button", |state| state["stop"] == true)?;

    page.click("#stop")?;

    page.next("stop")?;
    page.deliver(json!({"type": "patch", "meta": {"busy": false}}))?;
    page.state("the stop button gone once the turn ended", |state| state["stop"] == false).map(drop)
}

fn escape_with_nothing_open_stops_the_running_turn(page: &Page) -> Result<(), String> {
    page.deliver(json!({"type": "patch", "meta": {"busy": true}}))?;
    page.keys("/he")?;
    page.state("the palette", |state| state["palette"].is_object())?;
    page.press(Key::Escape, NONE)?;
    page.state("the palette closed", |state| state["palette"].is_null())?;
    check(page.quiet("stop"), "the Escape that closed the palette also stopped the turn")?;

    page.press(Key::Escape, NONE)?;

    page.next("stop")?;
    page.deliver(json!({"type": "patch", "meta": {"busy": false}}))?;
    page.press(Key::Escape, NONE)?;
    check(page.quiet("stop"), "Escape asked to stop with no turn running")
}

fn space_paste_and_option_typing_in_the_transcript_reach_the_composer(page: &Page) -> Result<(), String> {
    let blur = || page.eval("document.getElementById('input').blur()").map(drop);
    blur()?;
    page.press(Key::Char(' '), NONE)?;
    let spaced = page.state("Space to focus the composer", |state| state["focused"] == true)?;
    blur()?;

    page.eval("(() => { const data = new DataTransfer(); data.setData('text/plain', 'pasted '); document.body.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true })); })()")?;
    page.value("pasted ")?;
    blur()?;
    page.press(Key::Char('2'), OPTION)?;

    page.value("pasted 2")?;
    check(spaced["value"] == "", format!("Space typed into the composer: {spaced}"))
}

// Accepted with a space, an inline prediction left a double space (Swift `inlinePredictionType = .no`): WebKit offers
// none while its configuration does not allow them, which wry leaves at WebKit's default.
fn offers_no_inline_predictions_in_the_composer(page: &Page) -> Result<(), String> {
    let view = page.webview.webview();

    // SAFETY: a WKWebView answers `configuration`, whose `allowsInlinePredictions` is a BOOL on macOS 14 and later.
    let allowed: bool = unsafe {
        let configuration: Retained<AnyObject> = msg_send![&*view, configuration];
        msg_send![&*configuration, allowsInlinePredictions]
    };

    check(!allowed, "the web view allows inline predictions in the composer")
}

fn keeps_quotes_and_dashes_as_typed(page: &Page) -> Result<(), String> {
    page.keys("say \"hi\" -- it's ")?;

    page.value("say \"hi\" -- it's ").map(drop)
}

fn folds_a_long_paste_into_a_chip_and_sends_its_text(page: &Page) -> Result<(), String> {
    page.keys("see ")?;
    page.value("see ")?;

    let folded = page.paste(LONG_PASTE, false)?;

    check(folded, "the long paste was left to WebKit")?;
    let state = page.value("see [Paste #1]")?;
    check(state["chips"] == json!(["Paste #1 · 3 lines"]), format!("chips {}", state["chips"]))?;
    page.press(Key::Return, NONE)?;
    let sent = page.next("send")?;
    check(sent["text"] == format!("see {LONG_PASTE}"), format!("sent {}", sent["text"]))?;
    check(sent["draft"][1] == json!({"type": "paste", "text": LONG_PASTE, "number": 1}), format!("draft {}", sent["draft"]))
}

fn leaves_a_short_paste_to_webkit(page: &Page) -> Result<(), String> {
    let folded = page.paste("short", false)?;

    check(!folded, "a short paste was folded")?;
    check(page.eval(STATE)?["chips"] == json!([]), "a short paste made a chip")
}

fn tab_right_after_a_folded_paste_puts_its_text_back(page: &Page) -> Result<(), String> {
    page.paste(LONG_PASTE, false)?;
    page.value("[Paste #1]")?;

    page.press(Key::Tab, NONE)?;

    let state = page.value(LONG_PASTE)?;
    check(state["chips"] == json!([]), "the unfolded paste kept its chip")
}

fn undoes_and_redoes_typing_and_a_folded_paste_with_the_edit_menu(page: &Page) -> Result<(), String> {
    page.keys("abc ")?;
    page.value("abc ")?;
    page.paste(LONG_PASTE, false)?;
    page.value("abc [Paste #1]")?;

    page.press(Key::Char('z'), COMMAND)?;
    let undone = page.value("abc ")?;
    page.press(Key::Char('z'), COMMAND.union(SHIFT))?;
    let redone = page.value("abc [Paste #1]")?;

    check(undone["chips"] == json!([]), "the undone paste kept its chip")?;
    check(redone["chips"] == json!(["Paste #1 · 3 lines"]), format!("the redone paste has chips {}", redone["chips"]))?;
    page.press(Key::Return, NONE)?;
    check(page.next("send")?["text"] == format!("abc {LONG_PASTE}"), "the redone paste is sent as its text")
}

fn edit_shortcuts_reach_the_web_view_through_the_menu(page: &Page) -> Result<(), String> {
    page.keys("select me")?;
    page.value("select me")?;

    page.press(Key::Char('a'), COMMAND)?;
    let selected = page.state("⌘A to select everything", |state| state["selection"] == json!([0, 9]))?;
    for (title, key) in [("Copy", 'c'), ("Cut", 'x'), ("Paste", 'v')] {
        let target: &AnyObject = &page.catcher;
        page.aim(title, target)?;
        page.press(Key::Char(key), COMMAND)?;
    }

    page.wait("⌘C, ⌘X and ⌘V to reach the menu", |_| CAUGHT.with(|caught| caught.borrow().len() == 3))?;
    check(CAUGHT.with(|caught| caught.borrow().clone()) == ["copy", "cut", "paste"], "the shortcuts reached other items")?;
    let responder = page.webview.ns_window().firstResponder().map(|responder| format!("{responder:?}"));
    check(responder.as_deref().is_some_and(|name| name.contains("WebView")), format!("in a key window the menu's actions would go to {responder:?}, not the web view"))?;
    check(selected["value"] == "select me", "⌘A changed the text")
}

fn edit_shortcuts_do_nothing_without_the_menu(page: &Page) -> Result<(), String> {
    NSApplication::sharedApplication(page.mtm).setMainMenu(None);
    page.keys("no menu")?;
    page.value("no menu")?;

    page.press(Key::Char('a'), COMMAND)?;
    page.press(Key::Char('z'), COMMAND)?;

    let quiet = page.quiet("anything");
    let state = page.eval(STATE)?;
    page.install_menu()?;
    check(quiet && state["value"] == "no menu" && state["selection"] == json!([7, 7]), format!("⌘A or ⌘Z acted without a menu: {state}"))
}

fn opens_the_command_palette_on_a_slash_and_runs_a_value_chosen_with_tab(page: &Page) -> Result<(), String> {
    page.deliver(json!({"type": "patch", "meta": {"ready": true, "activeMode": "bypass"}}))?;
    page.keys("/per")?;
    let listed = page.state("the palette for /per", |state| state["value"] == "/per")?;
    check(listed["palette"]["title"] == "Commands" && listed["palette"]["options"][0] == "/perms", format!("palette {}", listed["palette"]))?;

    page.press(Key::Tab, NONE)?;
    let values = page.state("the values of /perms", |state| state["palette"]["options"] == json!(["bypass", "ask"]))?;
    page.press(Key::Down, NONE)?;
    page.state("ask highlighted", |state| state["palette"]["selected"] == 1)?;
    page.press(Key::Return, NONE)?;

    check(values["value"] == "/perms " && values["palette"]["selected"] == 0, format!("the current mode is highlighted first: {values}"))?;
    check(page.next("send")?["text"] == "/perms ask", "the chosen value ran")?;
    page.state("the palette closed", |state| state["palette"].is_null() && state["value"] == "").map(drop)
}

fn return_runs_a_command_typed_in_full_and_completes_a_partial_one(page: &Page) -> Result<(), String> {
    page.keys("/stat")?;
    page.state("the palette", |state| state["palette"]["options"][0] == "/status")?;
    page.press(Key::Return, NONE)?;
    page.value("/status")?;
    check(page.quiet("send"), "a partial command was sent")?;

    page.press(Key::Return, NONE)?;

    check(page.next("send")?["text"] == "/status", "the full command ran")
}

fn escape_closes_the_palette_until_the_query_changes(page: &Page) -> Result<(), String> {
    page.keys("/he")?;
    page.state("the palette", |state| state["palette"].is_object())?;

    page.press(Key::Escape, NONE)?;
    page.state("the palette closed", |state| state["palette"].is_null())?;
    page.keys("l")?;

    page.state("the palette open again for /hel", |state| state["palette"]["options"][0] == "/help").map(drop)
}

fn lists_provider_skills_beside_the_commands_of_vcx(page: &Page) -> Result<(), String> {
    let skill = json!({"name": "/sm", "detail": "Summarize briefly", "source": "Claude", "insert": "/sm"});
    page.deliver(json!({"type": "patch", "meta": {"providerLabel": "Claude", "providerCommands": [skill]}}))?;

    page.keys("/sm")?;

    let state = page.state("the skill listed", |state| state["palette"]["options"][0] == "/sm")?;
    page.press(Key::Return, NONE)?;
    check(page.next("send")?["text"] == "/sm", format!("/sm ran: {state}"))
}

fn completes_a_file_after_an_at_sign_from_the_list_the_core_gives(page: &Page) -> Result<(), String> {
    page.keys("read @mai")?;
    let asked = page.next_where("files", |post| post["query"] == "mai")?;
    let files = json!([{"path": "src/main.rs", "absolute": "/work/src/main.rs"}, {"path": "src", "absolute": "/work/src", "folder": true}]);
    page.deliver(json!({"type": "files", "id": asked["id"], "files": files}))?;
    page.state("the files", |state| state["palette"]["options"] == json!(["src/main.rs", "src/"]))?;

    page.press(Key::Return, NONE)?;

    let state = page.value("read @src/main.rs ")?;
    check(state["chips"] == json!(["main.rs"]) && state["palette"].is_null(), format!("{state}"))?;
    page.press(Key::Return, NONE)?;
    let sent = page.next("send")?;
    check(sent["text"] == "read @src/main.rs", format!("sent {}", sent["text"]))?;
    check(sent["draft"][1] == json!({"type": "text", "text": "@src/main.rs", "attachment": "file", "path": "/work/src/main.rs"}), format!("draft {}", sent["draft"]))
}

fn brings_back_sent_prompts_with_the_up_arrow(page: &Page) -> Result<(), String> {
    let rows = json!([user_row("R1", "first prompt", json!([])), user_row("R2", "look [Image #1]", json!(["/tmp/a.png"]))]);
    page.deliver(full(json!({"ready": true}), rows))?;

    page.press(Key::Up, NONE)?;
    let newest = page.value("look [Image #1]")?;
    page.press(Key::Up, NONE)?;
    page.value("first prompt")?;
    page.press(Key::Down, NONE)?;
    page.value("look [Image #1]")?;
    page.press(Key::Down, NONE)?;
    page.value("")?;

    check(newest["chips"] == json!(["Image #1 · a.png"]), format!("the recalled image came back as a chip: {}", newest["chips"]))?;
    page.keys("typed")?;
    page.value("typed")?;
    page.press(Key::Up, NONE)?;
    check(page.quiet("anything") && page.eval(STATE)?["value"] == "typed", "the up arrow replaced text he typed")
}

fn keeps_the_draft_of_the_session_and_takes_only_newer_ones(page: &Page) -> Result<(), String> {
    let draft = json!([{"type": "text", "text": "kept "}, {"type": "paste", "text": LONG_PASTE, "number": 2}, {"type": "localImage", "path": "/tmp/b.png"}]);
    page.deliver(json!({"type": "full", "meta": {"ready": true}, "rows": [], "draft": draft, "draftGeneration": 3}))?;
    let restored = page.value("kept [Paste #2][Image #1]")?;
    check(restored["chips"] == json!(["Paste #2 · 3 lines", "Image #1 · b.png"]), format!("chips {}", restored["chips"]))?;

    page.press(Key::Char('!'), SHIFT)?;
    let saved = page.next("draft")?;
    page.deliver(json!({"type": "patch", "draft": [{"type": "text", "text": "older"}], "draftGeneration": 2}))?;
    let kept = page.value("kept [Paste #2][Image #1]!")?;
    page.deliver(json!({"type": "patch", "draft": [{"type": "text", "text": "from another window"}], "draftGeneration": 9}))?;

    check(saved["generation"].as_u64().is_some_and(|generation| generation > 3), format!("saved {saved}"))?;
    let expected = json!([{"type": "text", "text": "kept "}, {"type": "paste", "text": LONG_PASTE, "number": 2}, {"type": "localImage", "path": "/tmp/b.png"}, {"type": "text", "text": "!"}]);
    check(saved["draft"] == expected, format!("saved {}", saved["draft"]))?;
    check(kept["chips"].as_array().is_some_and(|chips| chips.len() == 2), "an older draft replaced his")?;
    page.value("from another window").map(drop)
}

fn attaches_dropped_files_folders_and_images_as_chips(page: &Page) -> Result<(), String> {
    let items = json!([{"kind": "image", "path": "/tmp/c.png"}, {"kind": "file", "path": "/work/notes.md", "relative": "notes.md"}, {"kind": "folder", "path": "/work/my docs", "relative": "my docs"}]);

    page.deliver(json!({"type": "attach", "items": items}))?;

    let state = page.value("[Image #1] @notes.md @\"my docs/\" ")?;
    check(state["chips"] == json!(["Image #1 · c.png", "notes.md", "my docs/"]), format!("chips {}", state["chips"]))?;
    // As in the Swift composer, a chip goes with its token: no pill with a remove button shows above the text.
    page.eval("(() => { const input = document.getElementById('input'), at = input.value.indexOf('@notes.md '); input.setSelectionRange(at, at + '@notes.md '.length); document.execCommand('delete'); })()")?;
    let removed = page.value("[Image #1] @\"my docs/\" ")?;
    check(removed["chips"].as_array().is_some_and(|chips| chips.len() == 2) && removed["focused"] == true, format!("{removed}"))?;
    page.press(Key::Return, NONE)?;
    let sent = page.next("send")?;
    check(sent["text"] == "[Image #1] @\"my docs/\"" && sent["images"] == json!(["/tmp/c.png"]), format!("sent {sent}"))
}

fn pastes_an_image_through_the_core_and_shows_it_in_its_chip(page: &Page) -> Result<(), String> {
    let folded = page.paste("", true)?;

    let image = page.next("image")?;
    check(folded && image["data"] == PNG && image["name"] == "shot.png", format!("posted {image}"))?;
    page.deliver(json!({"type": "attach", "items": [{"kind": "image", "id": image["id"], "path": "/attachments/shot.png"}]}))?;

    let state = page.value("[Image #1]")?;
    check(state["chips"] == json!(["Image #1 · shot.png"]) && state["previews"] == 1, format!("{state}"))
}

// A drag of image data with no file reaches the page itself (wry hands the core file paths only); the drop here is made
// in the page, so the system pasteboard and a real drag are not exercised.
fn makes_a_chip_of_image_data_dropped_with_no_file(page: &Page) -> Result<(), String> {
    let script = format!("(() => {{ const data = new DataTransfer(); data.items.add(new File([Uint8Array.from(atob({PNG:?}), c => c.charCodeAt(0))], 'dragged.png', {{ type: 'image/png' }})); const event = new DragEvent('drop', {{ dataTransfer: data, bubbles: true, cancelable: true }}); document.getElementById('transcript').dispatchEvent(event); return event.defaultPrevented; }})()");

    let taken = page.eval(&script)?;

    let image = page.next("image")?;
    check(taken == json!(true) && image["data"] == PNG && image["name"] == "dragged.png", format!("taken {taken}, posted {image}"))?;
    page.deliver(json!({"type": "attach", "items": [{"kind": "image", "id": image["id"], "path": "/attachments/dragged.png"}]}))?;
    let state = page.value("[Image #1]")?;
    check(state["chips"] == json!(["Image #1 · dragged.png"]), format!("{state}"))
}

fn flies_the_sent_message_into_its_new_bubble_only(page: &Page) -> Result<(), String> {
    page.deliver(full(json!({"ready": true}), json!([user_row("R1", "Send this", json!([]))])))?;
    page.keys("Send this")?;
    page.press(Key::Return, NONE)?;
    page.next("send")?;

    page.deliver(json!({"type": "patch", "rows": [user_row("R2", "Send this", json!([]))]}))?;

    let flying = "(id => { const bubble = document.querySelector(`[data-row=\"${id}\"] .bubble`); return bubble ? bubble.getAnimations().map(motion => motion.effect.getKeyframes()[0].transform) : null; })";
    let deadline = Instant::now() + WAIT;
    let mut moved = page.eval(&format!("{flying}('R2')"))?;
    while moved.as_array().is_none_or(Vec::is_empty) && Instant::now() < deadline {
        spin();
        moved = page.eval(&format!("{flying}('R2')"))?;
    }
    let old = page.eval(&format!("{flying}('R1')"))?;
    check(moved.as_array().is_some_and(|motions| motions.len() == 1 && motions[0].as_str().is_some_and(|from| from.starts_with("translate("))), format!("the new bubble moved {moved}"))?;
    check(old == json!([]), format!("the bubble already there moved {old}"))
}

/// The report's stop rule for slice 3: marked text, paste, undo and focus in one run of the page composer.
fn keeps_marked_text_paste_undo_and_focus_together(page: &Page) -> Result<(), String> {
    page.eval("document.getElementById('input').blur()")?;
    page.keys("q")?;
    let refocused = page.value("q")?;
    input::mark(&page.webview, "かな");
    page.value("qかな")?;
    check(page.quiet("send"), "marked text sent the message")?;
    input::commit(&page.webview, "仮名");
    page.value("q仮名")?;

    page.paste(LONG_PASTE, false)?;
    page.value("q仮名[Paste #1]")?;
    page.press(Key::Char('z'), COMMAND)?;
    page.value("q仮名")?;
    page.eval("document.getElementById('input').blur()")?;
    page.click("#transcript")?;
    let clicked = page.state("the composer focused by a click on the blank transcript", |state| state["focused"] == true)?;

    check(refocused["focused"] == true, "a key typed outside the composer did not reach it")?;
    page.press(Key::Return, NONE)?;
    check(page.next("send")?["text"] == "q仮名", format!("sent other text: {clicked}"))
}

fn attach_asks_the_core_for_the_picture_instead_of_sending_the_command(page: &Page) -> Result<(), String> {
    page.keys("/attach shots/a.png")?;
    page.value("/attach shots/a.png")?;

    page.press(Key::Return, NONE)?;

    check(page.next("attachPath")?["path"] == "shots/a.png", "the path went to the core")?;
    page.value("")?;
    check(page.posted("send").is_empty(), "the command went out as a message")?;
    page.deliver(json!({"type": "attach", "items": [{"kind": "image", "path": "/work/shots/a.png"}]}))?;
    let state = page.value("[Image #1]")?;
    check(state["chips"] == json!(["Image #1 · a.png"]), format!("{state}"))
}

fn offers_a_shell_block_and_runs_it_only_once_run_is_clicked(page: &Page) -> Result<(), String> {
    page.deliver(full(json!({"ready": true, "cwd": "/Users/someone/work"}), json!([])))?;
    page.show(RUNNABLE_REPLY, "figure.code")?;
    page.wait("the shell block's Run button", |page| page.eval("document.querySelectorAll('#rows button.run').length").ok() == Some(json!(1)))?;

    page.click("#rows button.run")?;

    let offered = page.run_panel("the offer", |panel| !panel.is_null())?;
    check(offered["title"] == "Run this command?" && offered["command"] == "ls -la" && offered["note"] == "Runs in ~/work on its own terminal", format!("{offered}"))?;
    check(offered["buttons"] == json!(["Cancel", "Run"]) && page.quiet("run"), format!("ran before Run was clicked: {offered}"))?;
    page.click("#run .ub.primary")?;
    let run = page.next("run")?;
    check(run["command"] == "ls -la" && run["id"].is_string(), format!("posted {run}"))?;
    page.run_panel("the run to start", |panel| panel["buttons"] == json!(["Stop"]) && panel["field"] == "text").map(drop)
}

fn sends_a_password_line_to_the_run_only_and_masks_the_field(page: &Page) -> Result<(), String> {
    page.eval("vcxRun.offer('sudo -k true')")?;
    page.click("#run .ub.primary")?;
    let id = page.next("run")?["id"].clone();
    page.deliver(json!({"type": "run", "id": id, "state": "running", "output": "Password:", "hidden": true, "code": null}))?;
    let asking = page.run_panel("the password field", |panel| panel["field"] == "password")?;
    check(asking["title"] == "Running · the command asks for a password" && asking["focused"] == true, format!("{asking}"))?;

    page.keys("hunter2")?;
    page.press(Key::Return, NONE)?;

    let line = page.next("runInput")?;
    check(line["id"] == id && line["line"] == "hunter2", format!("posted {line}"))?;
    check(page.run_panel("the field to clear", |panel| panel["typed"] == "")?["focused"] == true, "the field kept the focus")?;
    let leaks: Vec<Value> = page.posts.lock().unwrap().iter().filter(|post| post.to_string().contains("hunter2")).cloned().collect();
    check(leaks.is_empty() && page.posted("send").is_empty(), format!("the password went out in {leaks:?}"))
}

fn shows_the_exit_status_and_closes_on_escape_once_finished(page: &Page) -> Result<(), String> {
    page.eval("vcxRun.offer('make test')")?;
    page.click("#run .ub.primary")?;
    let id = page.next("run")?["id"].clone();
    page.eval("vcxRun.offer('make clean')")?;
    check(page.run_panel("the running command", |panel| !panel.is_null())?["command"] == "make test", "an offer replaced a running command")?;

    page.deliver(json!({"type": "run", "id": id, "state": "finished", "output": "1 failed", "hidden": false, "code": 3}))?;

    let finished = page.run_panel("the exit status", |panel| panel["title"] == "Failed · exit 3")?;
    check(finished["buttons"] == json!(["Close"]) && finished["field"].is_null() && finished["output"] == "1 failed", format!("{finished}"))?;
    page.press(Key::Escape, NONE)?;
    page.run_panel("the panel to close", Value::is_null)?;
    check(page.state("the caret back in the composer", |state| state["focused"] == true).is_ok(), "the composer lost the focus")
}

fn opens_the_panel_from_an_inline_sudo_command_only(page: &Page) -> Result<(), String> {
    page.show(RUNNABLE_REPLY, "p")?;
    page.wait("the sudo link", |page| page.eval("document.querySelectorAll('#rows code.run-link').length").ok() == Some(json!(1)))?;

    page.click("#rows code.run-link")?;

    let offered = page.run_panel("the offer", |panel| !panel.is_null())?;
    check(offered["command"] == "sudo reboot", format!("{offered}"))?;
    check(page.eval("[...document.querySelectorAll('#rows figure.code')].map(figure => Boolean(figure.querySelector('button.run')))")? == json!([true, false]), "a block to paste got a Run button")
}

/// An answer as markdown.rs draws it: a shell block, a block to paste and a Markdown block.
const EDITABLE_REPLY: &str = "<figure class=\"code\"><figcaption><span class=\"language\">bash</span><button type=\"button\" class=\"copy b b-ghost icon sm\"></button></figcaption><pre><code class=\"language-bash\">ls -la\n</code></pre></figure><figure class=\"code\"><figcaption><span class=\"language\">Code</span><button type=\"button\" class=\"copy b b-ghost icon sm\"></button></figcaption><pre><code>Dear Bas,\n</code></pre></figure><figure class=\"code markdown\"><figcaption><span class=\"language\">Markdown</span><button type=\"button\" class=\"copy b b-ghost icon sm\"></button></figcaption><div class=\"prose\"><p>Plan</p></div><pre class=\"source\" hidden><code>Plan\n</code></pre></figure>";

/// Each code block of the transcript: its label, the code it shows, its buttons and whether its editor is open.
const CODE_BLOCKS: &str = "[...document.querySelectorAll('#rows figure.code')].map(figure => ({ label: figure.querySelector('.language').textContent, code: figure.querySelector('pre code').textContent, buttons: [...figure.querySelectorAll('figcaption button')].map(button => button.classList[0]), editing: Boolean(figure.querySelector('.edit-area')) }))";

/// The code block to paste, second in `EDITABLE_REPLY`.
const LETTER: &str = "#rows figure.code:nth-of-type(2)";

fn answer_row(id: &str, html: &str) -> Value {
    json!({"id": id, "kind": "assistant", "items": [{"id": format!("{id}-item"), "type": "agentMessage", "html": html, "provider": "Claude", "endedTurn": true}]})
}

impl Page {
    fn show_answer(&self) -> Result<(), String> {
        self.deliver(full(json!({"ready": true}), json!([user_row("R1", "Draft it", json!([])), answer_row("R2", EDITABLE_REPLY)])))?;
        self.wait("the pencils", |page| page.eval("document.querySelectorAll('#rows button.edit').length").ok() == Some(json!(2)))
    }

    /// Opens the editor of the block `figure` names with a real click, and puts the caret at the end of its text.
    fn edit(&self, figure: &str) -> Result<(), String> {
        self.eval(&format!("document.querySelector({figure:?}).scrollIntoView({{ block: 'start' }})"))?;
        self.click(&format!("{figure} button.edit"))?;
        self.wait("the editor to take the focus", |page| page.eval("document.activeElement.className").ok() == Some(json!("edit-area")))?;
        self.eval("(area => area.setSelectionRange(area.value.length, area.value.length))(document.activeElement)").map(drop)
    }

    fn blocks(&self) -> Result<Value, String> {
        self.eval(CODE_BLOCKS)
    }

    /// The code blocks once `done` takes them: a key lands after a script sent at the same time.
    fn until_blocks(&self, what: &str, done: impl Fn(&Value) -> bool) -> Result<Value, String> {
        let deadline = Instant::now() + WAIT;
        loop {
            let blocks = self.blocks()?;
            if done(&blocks) {
                return Ok(blocks);
            }
            if Instant::now() > deadline {
                return Err(format!("{what}: the code blocks are {blocks}"));
            }
            spin();
        }
    }
}

fn edits_a_code_block_in_place_and_copy_takes_the_edited_version(page: &Page) -> Result<(), String> {
    page.show_answer()?;
    let before = page.blocks()?;

    page.edit(LETTER)?;
    let opened = page.eval(&format!("document.querySelector({LETTER:?}).querySelector('.edit-area').value"))?;
    page.keys(" hi")?;
    let typing = page.until_blocks("the typed text", |blocks| blocks[1]["code"] == "Dear Bas, hi")?;
    page.press(Key::Escape, NONE)?;
    let done = page.until_blocks("Escape", |blocks| blocks[1]["editing"] == false)?;
    page.click(&format!("{LETTER} button.copy"))?;
    let copied = page.next("copy")?;

    let buttons: Vec<Value> = before.as_array().unwrap().iter().map(|block| block["buttons"].clone()).collect();
    check(buttons == vec![json!(["run", "edit", "copy"]), json!(["edit", "copy"]), json!(["copy"])], format!("the buttons are {buttons:?}"))?;
    check(opened == "Dear Bas," && typing[1]["editing"] == true && typing[1]["label"] == "Code · edited", format!("opened on {opened}, while typing {typing}"))?;
    check(done[1] == json!({"label": "Code · edited", "code": "Dear Bas, hi", "buttons": ["edit", "copy"], "editing": false}), format!("after Escape {done}"))?;
    check(copied["text"] == "Dear Bas, hi", format!("copied {copied}"))
}

fn sends_an_edited_block_once_with_the_next_prompt_in_swift_words(page: &Page) -> Result<(), String> {
    page.show_answer()?;
    page.edit(LETTER)?;
    page.keys(" hi")?;

    page.click("#input")?;
    page.wait("the editor to close on a click away", |page| page.eval("document.querySelector('.edit-area') === null").ok() == Some(json!(true)))?;
    page.eval("document.getElementById('input').focus()")?;
    page.keys("ok")?;
    page.press(Key::Return, NONE)?;
    let first = page.next("send")?;
    page.keys("again")?;
    page.press(Key::Return, NONE)?;
    let second = page.next("send")?;
    page.deliver(full(json!({"ready": true}), json!([])))?;
    page.show_answer()?;
    let redrawn = page.blocks()?;

    check(first["text"] == "I edited your code block. My version:\n```\nDear Bas, hi\n```\n\nok", format!("first sent {first}"))?;
    check(second["text"] == "again", format!("the edit went twice: {second}"))?;
    check(redrawn[1]["label"] == "Code · edited" && redrawn[1]["code"] == "Dear Bas, hi", format!("a block drawn again lost its edit: {redrawn}"))
}

fn fences_a_block_holding_a_fence_with_four_backticks_and_sends_each_edit_in_order(page: &Page) -> Result<(), String> {
    let replace = |text: &str| format!("(area => {{ area.value = {}; area.dispatchEvent(new Event('input')); }})(document.activeElement)", json!(text));
    page.show_answer()?;
    page.edit(LETTER)?;
    page.eval(&replace("x ```"))?;
    page.press(Key::Escape, NONE)?;
    page.edit("#rows figure.code:nth-of-type(1)")?;
    page.eval(&replace("ls"))?;
    page.press(Key::Escape, NONE)?;

    let command = page.eval("vcxCodeEdits.attach('/status')")?;
    page.eval("document.getElementById('input').focus()")?;
    page.keys("go")?;
    page.press(Key::Return, NONE)?;
    let sent = page.next("send")?;

    check(command == "/status", format!("a command took the edits: {command}"))?;
    let expected = "I edited your code block. My version:\n````\nx ```\n````\n\nI edited your code block. My version:\n```\nls\n```\n\ngo";
    check(sent["text"] == expected, format!("sent {sent}"))
}

fn sends_nothing_for_a_block_edited_back_to_its_original(page: &Page) -> Result<(), String> {
    page.show_answer()?;
    page.edit(LETTER)?;
    page.keys(" hi")?;
    for _ in 0..3 {
        page.press(Key::Delete, NONE)?;
    }
    let back = page.until_blocks("the third Delete", |blocks| blocks[1]["code"] == "Dear Bas,\n")?;
    page.press(Key::Escape, NONE)?;

    page.eval("document.getElementById('input').focus()")?;
    page.keys("ok")?;
    page.press(Key::Return, NONE)?;
    let sent = page.next("send")?;

    check(back[1]["label"] == "Code", format!("still marked edited: {back}"))?;
    check(sent["text"] == "ok", format!("sent {sent}"))
}

type Test = fn(&Page) -> Result<(), String>;

fn tints_a_typed_command_and_locks_it_once_a_space_follows(page: &Page) -> Result<(), String> {
    let marks = "[...document.querySelectorAll('#composer .marks span')].map(span => `${span.className}:${span.textContent}`)";

    page.keys("/status")?;
    page.value("/status")?;
    let typed = page.eval(marks)?;
    page.keys(" now /nothing")?;
    page.value("/status now /nothing")?;
    let locked = page.eval(marks)?;

    check(typed == json!(["command:/status"]), format!("typed {typed}"))?;
    check(locked == json!(["locked:/status"]), format!("locked {locked}"))
}

fn shows_the_draft_pictures_above_the_composer_with_their_numbers(page: &Page) -> Result<(), String> {
    let items = json!([{"kind": "image", "path": "/tmp/a.png"}, {"kind": "image", "path": "/tmp/b.png"}]);

    page.deliver(json!({"type": "attach", "items": items}))?;
    page.value("[Image #1] [Image #2]")?;

    let names = page.eval("(() => { const row = document.getElementById('draft-pictures'); return row.hidden ? null : [...row.querySelectorAll('.picture .name')].map(name => name.textContent); })()")?;
    check(names == json!(["Image #1", "Image #2"]), format!("pictures {names}"))
}

fn hides_the_placeholder_while_the_sent_message_flies(page: &Page) -> Result<(), String> {
    let flying = "document.getElementById('composer').classList.contains('flying')";
    page.keys("fly")?;
    page.value("fly")?;

    page.press(Key::Return, NONE)?;
    page.next("send")?;
    let during = page.eval(flying)?;
    page.deliver(json!({"type": "full", "serial": 2, "meta": {"ready": true}, "rows": [user_row("f1", "fly", json!([]))], "draft": []}))?;
    page.wait("the box to fly from the composer", |page| page.eval("document.querySelectorAll('.flight-box').length").ok() == Some(json!(1)))?;
    let start = page.eval("(() => { const box = document.querySelector('.flight-box').getBoundingClientRect(), field = document.querySelector('#composer .field').getBoundingClientRect(); return box.width > field.width; })()")?;
    page.wait("the box to land and go", |page| page.eval("document.querySelectorAll('.flight-box').length").ok() == Some(json!(0)))?;

    check(during == json!(true) && page.eval(flying)? == json!(false), format!("flying during the send: {during}"))?;
    check(start == json!(true), "the flying box did not start around the composer's text")
}

fn splits_resume_rows_with_no_detail_by_a_hairline(page: &Page) -> Result<(), String> {
    page.deliver(json!({"type": "patch", "meta": {"ready": true, "recent": [{"id": "a", "title": "First"}, {"id": "b", "title": "Second"}, {"id": "c", "title": "Third"}]}}))?;

    page.keys("/resume ")?;
    page.value("/resume ")?;
    page.state("the saved conversations", |state| state["palette"]["options"] == json!(["First", "Second", "Third"]))?;

    let dividers = page.eval("document.querySelectorAll('#palette .palette-divider').length")?;
    check(dividers == json!(2), format!("dividers {dividers}"))
}

fn names_what_a_model_alias_runs_in_the_model_palette_opened_from_its_chip(page: &Page) -> Result<(), String> {
    page.deliver(json!({"type": "patch", "meta": {"ready": true, "providerLabel": "Claude", "model": "claude-opus-5-5", "models": ["opus", "haiku"], "modelAliases": {"opus": "claude-opus-5-5"}}}))?;

    page.eval("window.composer.openCommand('/model ')")?;
    page.state("the providers", |state| state["value"] == "/model " && state["palette"]["options"][0] == "Claude")?;
    page.eval("window.composer.openCommand('/model claude ')")?;

    let models = page.state("the models", |state| state["palette"]["options"] == json!(["opus · Opus 5.5", "haiku"]))?;
    let detail = page.eval("document.querySelector('#palette .palette-option-detail').textContent")?;
    check(models["palette"]["selected"] == 0 && detail == "claude-opus-5-5", format!("{models}, detail {detail}"))
}

const TESTS: [(&str, Test); 43] = [
    ("sends on Return and keeps Shift-Return as a new line", sends_on_return_and_keeps_shift_return_as_a_new_line),
    ("glides the sent message from the composer into the transcript", glides_the_sent_message_from_the_composer_into_the_transcript),
    ("sends with a real click and keeps the caret in the composer", sends_with_a_real_click_and_keeps_the_caret_in_the_composer),
    ("answers an open question card instead of sending", answers_an_open_question_card_instead_of_sending),
    ("sends nothing for an empty composer", sends_nothing_for_an_empty_composer),
    ("Shift-Return on an empty composer sends the waiting prompt now", shift_return_on_an_empty_composer_sends_the_waiting_prompt_now),
    ("shows the stop button while a turn runs", shows_the_stop_button_while_a_turn_runs),
    ("Escape with nothing open stops the running turn", escape_with_nothing_open_stops_the_running_turn),
    ("Space, a paste and Option typing in the transcript reach the composer", space_paste_and_option_typing_in_the_transcript_reach_the_composer),
    ("offers no inline predictions in the composer", offers_no_inline_predictions_in_the_composer),
    ("keeps quotes and dashes as typed", keeps_quotes_and_dashes_as_typed),
    ("folds a long paste into a chip and sends its text", folds_a_long_paste_into_a_chip_and_sends_its_text),
    ("leaves a short paste to WebKit", leaves_a_short_paste_to_webkit),
    ("Tab right after a folded paste puts its text back", tab_right_after_a_folded_paste_puts_its_text_back),
    ("undoes and redoes typing and a folded paste with the Edit menu", undoes_and_redoes_typing_and_a_folded_paste_with_the_edit_menu),
    ("Edit shortcuts reach the web view through the menu", edit_shortcuts_reach_the_web_view_through_the_menu),
    ("Edit shortcuts do nothing without the menu", edit_shortcuts_do_nothing_without_the_menu),
    ("opens the command palette on a slash and runs a value chosen with Tab", opens_the_command_palette_on_a_slash_and_runs_a_value_chosen_with_tab),
    ("Return runs a command typed in full and completes a partial one", return_runs_a_command_typed_in_full_and_completes_a_partial_one),
    ("Escape closes the palette until the query changes", escape_closes_the_palette_until_the_query_changes),
    ("lists provider skills beside the commands of VCX", lists_provider_skills_beside_the_commands_of_vcx),
    ("completes a file after an at sign from the list the core gives", completes_a_file_after_an_at_sign_from_the_list_the_core_gives),
    ("brings back sent prompts with the up arrow", brings_back_sent_prompts_with_the_up_arrow),
    ("keeps the draft of the session and takes only newer ones", keeps_the_draft_of_the_session_and_takes_only_newer_ones),
    ("attaches dropped files, folders and images as chips", attaches_dropped_files_folders_and_images_as_chips),
    ("pastes an image through the core and shows it in its chip", pastes_an_image_through_the_core_and_shows_it_in_its_chip),
    ("makes a chip of image data dropped with no file", makes_a_chip_of_image_data_dropped_with_no_file),
    ("flies the sent message into its new bubble only", flies_the_sent_message_into_its_new_bubble_only),
    ("keeps marked text, paste, undo and focus together", keeps_marked_text_paste_undo_and_focus_together),
    ("/attach asks the core for the picture instead of sending the command", attach_asks_the_core_for_the_picture_instead_of_sending_the_command),
    ("offers a shell block and runs it only once Run is clicked", offers_a_shell_block_and_runs_it_only_once_run_is_clicked),
    ("sends a password line to the run only and masks the field", sends_a_password_line_to_the_run_only_and_masks_the_field),
    ("shows the exit status and closes on Escape once finished", shows_the_exit_status_and_closes_on_escape_once_finished),
    ("opens the panel from an inline sudo command only", opens_the_panel_from_an_inline_sudo_command_only),
    ("edits a code block in place and copy takes the edited version", edits_a_code_block_in_place_and_copy_takes_the_edited_version),
    ("sends an edited block once with the next prompt in Swift's words", sends_an_edited_block_once_with_the_next_prompt_in_swift_words),
    ("fences a block holding a fence with four backticks and sends each edit in order", fences_a_block_holding_a_fence_with_four_backticks_and_sends_each_edit_in_order),
    ("sends nothing for a block edited back to its original", sends_nothing_for_a_block_edited_back_to_its_original),
    ("tints a typed command and locks it once a space follows", tints_a_typed_command_and_locks_it_once_a_space_follows),
    ("shows the draft pictures above the composer with their numbers", shows_the_draft_pictures_above_the_composer_with_their_numbers),
    ("hides the placeholder while the sent message flies", hides_the_placeholder_while_the_sent_message_flies),
    ("splits resume rows with no detail by a hairline", splits_resume_rows_with_no_detail_by_a_hairline),
    ("names what a model alias runs in the model palette opened from its chip", names_what_a_model_alias_runs_in_the_model_palette_opened_from_its_chip),
];

fn main() -> ExitCode {
    let mtm = MainThreadMarker::new().expect("the composer test runs on the main thread");
    let event_loop = EventLoopBuilder::new().build();
    let page = Page::open(mtm, &event_loop);
    let filter: Vec<String> = std::env::args().skip(1).filter(|argument| !argument.starts_with('-')).collect();
    let mut failed = 0;
    for (name, test) in TESTS {
        if !filter.is_empty() && !filter.iter().any(|wanted| name.contains(wanted.as_str())) {
            continue;
        }
        match page.reset().and_then(|()| test(&page)) {
            Ok(()) => println!("test {name} ... ok"),
            Err(problem) => {
                failed += 1;
                println!("test {name} ... FAILED\n    {problem}");
            }
        }
    }
    println!("\ncomposer: {failed} failed");
    if failed > 0 { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}
