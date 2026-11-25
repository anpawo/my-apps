//! The window: tao owns the event loop and the window, wry the system web view that draws the template.

use crate::bridge::{self, FromPage};
use crate::check::{self, Check};
use crate::input;
use crate::session::{self, Message, Output, Source};
use crate::snapshot;
use crate::template::{self, Change, Store};
use serde_json::{Value, json};
use std::convert::Infallible;
use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy};
use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
use tao::window::{Window, WindowBuilder};
use vcx_model::view::CONTRACT_VERSION;
use wry::{BackgroundThrottlingPolicy, WebView, WebViewBuilder};

const WINDOW_SIZE: LogicalSize<f64> = LogicalSize { width: 980.0, height: 720.0 };
/// How long a freshly loaded page has to report ready before the last template that worked comes back.
const READY_WAIT: Duration = Duration::from_secs(3);
/// How often a check looks whether the keys it pressed have reached the composer.
const TYPED_POLL: Duration = Duration::from_millis(40);
const EXIT_FAILED: i32 = 1;
const LAST_GOOD: &str = "Showing the last template that worked.";

pub struct Options {
    pub source: Source,
    pub template: Option<PathBuf>,
    pub check: Option<check::Options>,
}

pub enum UserEvent {
    FromPage(String),
    Session(Output),
    TemplateEdited,
    ReadyDeadline(u64),
    Dump(String),
    Picture(Result<Vec<u8>, String>),
    Aimed(String),
    Typed(String),
    ReadTyped,
    CheckTimeout,
}

struct App {
    webview: WebView,
    store: Arc<Store>,
    session: Option<session::Handle>,
    check: Option<Check>,
    proxy: EventLoopProxy<UserEvent>,
    /// Counts page loads, so a ready deadline knows which load it was set for.
    load: u64,
    ready: bool,
    /// Counts style swaps: each one needs an address the web view has not fetched yet.
    styles: u64,
    notice: Option<String>,
    /// Where a check clicks once the text it typed is in the composer.
    send_button: Option<(f64, f64)>,
    _window: Window,
    _watcher: Option<notify::RecommendedWatcher>,
}

pub fn run(options: Options) -> Result<Infallible, String> {
    let mut event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    if options.check.is_some() {
        // A check is never seen: no Dock icon, no activation, and a window that is never shown.
        event_loop.set_activation_policy(ActivationPolicy::Accessory);
        event_loop.set_activate_ignoring_other_apps(false);
    }
    let proxy = event_loop.create_proxy();
    let (store, problem) = Store::open(options.template.as_deref());
    let store = Arc::new(store);
    let window = WindowBuilder::new().with_title("VCX").with_inner_size(WINDOW_SIZE).with_visible(options.check.is_none()).build(&event_loop).map_err(|error| error.to_string())?;
    let webview = web_view(&window, &store, &proxy)?;
    let wait_for_answer = options.check.as_ref().is_some_and(|check| check.wait_for_answer);
    let to_window = proxy.clone();
    let session = session::spawn(options.source, wait_for_answer, move |output| drop(to_window.send_event(UserEvent::Session(output))))?;
    let watcher = match &options.template {
        Some(folder) => {
            let edited = proxy.clone();
            Some(template::watch(folder, move || drop(edited.send_event(UserEvent::TemplateEdited))).map_err(|error| error.to_string())?)
        }
        None => None,
    };
    if let Some(check) = &options.check {
        after(check.timeout, &proxy, UserEvent::CheckTimeout);
    }
    let notice = problem.map(|problem| format!("{problem} Showing the built-in template."));
    let mut app = App { webview, store, session: Some(session), check: options.check.map(Check::new), proxy, load: 0, ready: false, styles: 0, notice, send_button: None, _window: window, _watcher: watcher };
    after(READY_WAIT, &app.proxy, UserEvent::ReadyDeadline(app.load));
    event_loop.run(move |event, _, flow| {
        *flow = ControlFlow::Wait;
        let exit = match event {
            Event::UserEvent(event) => app.on(event),
            Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => Some(0),
            _ => None,
        };
        if let Some(code) = exit {
            app.close();
            *flow = ControlFlow::ExitWithCode(code);
        }
    })
}

fn web_view(window: &Window, store: &Arc<Store>, proxy: &EventLoopProxy<UserEvent>) -> Result<WebView, String> {
    let files = store.clone();
    let from_page = proxy.clone();
    WebViewBuilder::new()
        .with_custom_protocol(template::SCHEME.into(), move |_, request| files.respond(request.uri().host(), request.uri().path()))
        .with_ipc_handler(move |request| {
            if bridge::is_template(&request.uri().to_string()) {
                let _ = from_page.send_event(UserEvent::FromPage(request.into_body()));
            }
        })
        .with_navigation_handler(|url| bridge::is_template(&url))
        // A window that is covered or on another desktop keeps following its session at full speed.
        .with_background_throttling(BackgroundThrottlingPolicy::Disabled)
        .with_url(template::HOME)
        .build(window)
        .map_err(|error| error.to_string())
}

fn exit_code(outcome: Result<(), String>) -> i32 {
    match outcome {
        Ok(()) => 0,
        Err(problem) => {
            eprintln!("vcx-shell: {problem}");
            EXIT_FAILED
        }
    }
}

fn after(delay: Duration, proxy: &EventLoopProxy<UserEvent>, event: UserEvent) {
    let proxy = proxy.clone();
    thread::spawn(move || {
        thread::sleep(delay);
        let _ = proxy.send_event(event);
    });
}

impl App {
    /// Handles one event. A returned code ends the process with it.
    fn on(&mut self, event: UserEvent) -> Option<i32> {
        match event {
            UserEvent::FromPage(body) => self.from_page(bridge::parse(&body)?),
            UserEvent::Session(Output::Page(message)) => {
                if let (Some(check), "full", Some(serial)) = (&mut self.check, message["type"].as_str().unwrap_or_default(), message["serial"].as_u64()) {
                    check.shows(serial);
                }
                self.to_page(&message);
            }
            UserEvent::Session(Output::Settled(serial)) => {
                if self.check.as_mut().is_some_and(|check| check.settled(serial)) {
                    self.dump();
                }
            }
            UserEvent::Session(Output::Closed(reason)) => {
                eprintln!("vcx-shell: {reason}");
                return Some(if self.check.is_some() { EXIT_FAILED } else { 0 });
            }
            UserEvent::TemplateEdited => self.template_edited(),
            UserEvent::ReadyDeadline(load) if load == self.load && !self.ready => self.fall_back("The template's page did not start."),
            UserEvent::ReadyDeadline(_) => {}
            UserEvent::Dump(dump) => return self.reported(&dump),
            UserEvent::Picture(picture) => return Some(exit_code(self.picture_path().map_or(Ok(()), |path| check::save_picture(path, picture)))),
            UserEvent::Aimed(aim) => return self.type_text(&aim).err().map(|problem| exit_code(Err(problem))),
            UserEvent::Typed(text) => return self.click_send(&text).err().map(|problem| exit_code(Err(problem))),
            UserEvent::ReadTyped => self.read(input::TYPED, UserEvent::Typed),
            UserEvent::CheckTimeout => {
                let progress = self.check.as_ref().map(Check::progress).unwrap_or_default();
                eprintln!("vcx-shell: the check timed out: {progress}.");
                return Some(EXIT_FAILED);
            }
        }
        None
    }

    fn from_page(&mut self, message: FromPage) {
        match message {
            FromPage::Ready { contract } if contract == u64::from(CONTRACT_VERSION) => self.page_ready(),
            FromPage::Ready { contract } => self.fall_back(&format!("The template's page speaks contract {contract}; this build speaks contract {CONTRACT_VERSION}.")),
            FromPage::Send { text } => {
                self.tell(Message::Act { action: "send", params: json!({"text": text, "images": []}) });
                if self.check.as_mut().is_some_and(Check::sent) {
                    self.dump();
                }
            }
            FromPage::Stop => self.tell(Message::Act { action: "stop", params: json!({}) }),
            FromPage::Rendered { serial } => {
                if self.check.as_mut().is_some_and(|check| check.rendered(serial)) {
                    self.dump();
                }
                if self.check.as_mut().is_some_and(Check::begin_typing) {
                    self.read(input::AIM, UserEvent::Aimed);
                }
            }
            FromPage::Restyled { .. } => self.edited(),
            FromPage::Open { href } => self.open(&href),
        }
    }

    fn page_ready(&mut self) {
        self.ready = true;
        self.store.confirm();
        if let Some(text) = self.notice.take() {
            self.to_page(&json!({"type": "notice", "text": text}));
        }
        self.tell(Message::PageReady);
    }

    fn tell(&self, message: Message) {
        if let Some(session) = &self.session {
            session.send(message);
        }
    }

    fn evaluate(&self, script: &str) {
        if let Err(error) = self.webview.evaluate_script(script) {
            eprintln!("vcx-shell: the page refused a script: {error}");
        }
    }

    fn to_page(&self, message: &Value) {
        self.evaluate(&bridge::deliver(message));
    }

    fn note(&mut self, text: String) {
        if self.ready {
            self.to_page(&json!({"type": "notice", "text": text}));
        } else {
            self.notice = Some(text);
        }
    }

    fn template_edited(&mut self) {
        match self.store.reload() {
            Ok(Change::None) => {}
            Ok(Change::Styles) => {
                self.styles += 1;
                self.evaluate(&format!("window.vcx&&vcx.restyle({})", self.styles));
            }
            Ok(Change::Page) => {
                self.reload();
                self.edited();
            }
            Err(problem) => self.note(format!("{problem} {LAST_GOOD}")),
        }
    }

    fn reload(&mut self) {
        self.ready = false;
        self.tell(Message::PageGone);
        if let Some(check) = &mut self.check {
            check.reloading();
        }
        self.load += 1;
        if let Err(error) = self.webview.load_url(template::HOME) {
            eprintln!("vcx-shell: the page could not be reloaded: {error}");
        }
        after(READY_WAIT, &self.proxy, UserEvent::ReadyDeadline(self.load));
    }

    fn fall_back(&mut self, reason: &str) {
        if !self.store.revert() {
            eprintln!("vcx-shell: {reason} There is no earlier template to return to.");
            return;
        }
        self.notice = Some(format!("{reason} {LAST_GOOD}"));
        self.reload();
    }

    fn open(&self, href: &str) {
        if self.check.is_some() || !bridge::is_external(href) {
            return;
        }
        if let Err(error) = Command::new("/usr/bin/open").arg(href).spawn() {
            eprintln!("vcx-shell: cannot open {href}: {error}");
        }
    }

    fn dump(&self) {
        self.read(check::DUMP, UserEvent::Dump);
    }

    /// Runs `script` in the page and hands its result to the event loop as `event`.
    fn read(&self, script: &str, event: fn(String) -> UserEvent) {
        let proxy = self.proxy.clone();
        let asked = self.webview.evaluate_script_with_callback(script, move |result| drop(proxy.send_event(event(result))));
        if let Err(error) = asked {
            eprintln!("vcx-shell: the page could not be read: {error}");
        }
    }

    /// The composer has the caret: presses the keys of the check's text.
    fn type_text(&mut self, aim: &str) -> Result<(), String> {
        let aim = check::unwrap(aim)?;
        let (Some(true), Some(x), Some(y)) = (aim["focused"].as_bool(), aim["send"][0].as_f64(), aim["send"][1].as_f64()) else {
            return Err(format!("The composer could not be aimed at: {aim}."));
        };
        self.send_button = Some((x, y));
        let text = self.check.as_ref().and_then(|check| check.options.typed.as_deref()).unwrap_or_default();
        input::type_text(&self.webview, text)?;
        self.read(input::TYPED, UserEvent::Typed);
        Ok(())
    }

    /// `composer` is what the composer holds, as the web view hands a text over: once it is the typed text, clicks send.
    fn click_send(&mut self, composer: &str) -> Result<(), String> {
        let typed = self.check.as_ref().and_then(|check| check.options.typed.as_deref());
        if serde_json::from_str::<String>(composer).ok().as_deref() != typed {
            after(TYPED_POLL, &self.proxy, UserEvent::ReadTyped);
            return Ok(());
        }
        match self.send_button.take() {
            Some((x, y)) => input::click(&self.webview, x, y),
            None => Ok(()),
        }
    }

    fn edited(&mut self) {
        if self.check.as_mut().is_some_and(Check::edited) {
            self.dump();
        }
    }

    /// The page's dump arrived: writes the report, then ends the check unless it waits for more template edits.
    fn reported(&mut self, dump: &str) -> Option<i32> {
        let check = self.check.as_mut()?;
        if let Err(problem) = check.write(dump, &self.store.current().name, self.load) {
            return Some(exit_code(Err(problem)));
        }
        if !check.written() {
            if check.due() {
                self.dump();
            }
            return None;
        }
        if self.picture_path().is_some() {
            self.take_picture();
            return None;
        }
        Some(0)
    }

    fn picture_path(&self) -> Option<&PathBuf> {
        self.check.as_ref()?.options.picture.as_ref()
    }

    fn take_picture(&self) {
        let proxy = self.proxy.clone();
        snapshot::take(&self.webview, move |picture| drop(proxy.send_event(UserEvent::Picture(picture))));
    }

    fn close(&mut self) {
        if let Some(session) = self.session.take() {
            session.close();
        }
    }
}
