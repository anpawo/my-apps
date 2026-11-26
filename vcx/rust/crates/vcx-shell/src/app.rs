//! One window and its check: tao owns the event loop and the window, the pane its page and session.

use crate::check::{self, Check};
use crate::input;
use crate::pane::{self, Note, Pane, PaneEvent};
use crate::session::Source;
use crate::snapshot;
use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy};
use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
use tao::window::{Window, WindowBuilder};

const WINDOW_SIZE: LogicalSize<f64> = LogicalSize { width: 980.0, height: 720.0 };
/// How often a check looks whether the keys it pressed have reached the composer.
const TYPED_POLL: Duration = Duration::from_millis(40);
const EXIT_FAILED: i32 = 1;

pub struct Options {
    pub source: Source,
    pub template: Option<PathBuf>,
    pub check: Option<check::Options>,
}

pub enum UserEvent {
    Pane(PaneEvent),
    Dump(String),
    Picture(Result<Vec<u8>, String>),
    Aimed(String),
    Typed(String),
    ReadTyped,
    CheckTimeout,
}

struct App {
    pane: Pane,
    check: Option<Check>,
    proxy: EventLoopProxy<UserEvent>,
    /// Where a check clicks once the text it typed is in the composer.
    send_button: Option<(f64, f64)>,
    window: Window,
}

pub fn run(options: Options) -> Result<Infallible, String> {
    let mut event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    if options.check.is_some() {
        // A check is never seen: no Dock icon, no activation, and a window that is never shown.
        event_loop.set_activation_policy(ActivationPolicy::Accessory);
        event_loop.set_activate_ignoring_other_apps(false);
    }
    crate::menu::install(objc2_foundation::MainThreadMarker::new().ok_or("VCX runs on the main thread.")?);
    let proxy = event_loop.create_proxy();
    let window = WindowBuilder::new().with_title("VCX").with_inner_size(WINDOW_SIZE).with_visible(options.check.is_none()).build(&event_loop).map_err(|error| error.to_string())?;
    let wait_for_answer = options.check.as_ref().is_some_and(|check| check.wait_for_answer);
    let to_loop = proxy.clone();
    let emit: pane::Emit = Arc::new(move |event| drop(to_loop.send_event(UserEvent::Pane(event))));
    let pane_options = pane::Options { template: options.template, wait_for_answer, quiet: options.check.is_some() };
    let pane = Pane::new(&window, options.source, &pane_options, emit)?;
    if let Some(check) = &options.check {
        after(check.timeout, &proxy, UserEvent::CheckTimeout);
    }
    let mut app = App { pane, check: options.check.map(Check::new), proxy, send_button: None, window };
    event_loop.run(move |event, _, flow| {
        *flow = ControlFlow::Wait;
        let exit = match event {
            Event::UserEvent(event) => app.on(event),
            Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => Some(0),
            _ => None,
        };
        if let Some(code) = exit {
            app.pane.close();
            *flow = ControlFlow::ExitWithCode(code);
        }
    })
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
            UserEvent::Pane(event) => {
                for note in self.pane.on(event) {
                    if let Some(code) = self.noted(note) {
                        return Some(code);
                    }
                }
            }
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

    fn noted(&mut self, note: Note) -> Option<i32> {
        match note {
            Note::Shown(serial) => {
                if let Some(check) = &mut self.check {
                    check.shows(serial);
                }
            }
            Note::Rendered(serial) => {
                if self.check.as_mut().is_some_and(|check| check.rendered(serial)) {
                    self.dump();
                }
                if self.check.as_mut().is_some_and(Check::begin_typing) {
                    self.read(input::AIM, UserEvent::Aimed);
                }
            }
            Note::Settled(serial) => {
                if self.check.as_mut().is_some_and(|check| check.settled(serial)) {
                    self.dump();
                }
            }
            Note::Sent => {
                if self.check.as_mut().is_some_and(Check::sent) {
                    self.dump();
                }
            }
            Note::Edited => {
                if self.check.as_mut().is_some_and(Check::edited) {
                    self.dump();
                }
            }
            Note::Reloading => {
                if let Some(check) = &mut self.check {
                    check.reloading();
                }
            }
            Note::Closed(reason) => {
                eprintln!("vcx-shell: {reason}");
                return Some(if self.check.is_some() { EXIT_FAILED } else { 0 });
            }
            Note::Title(text) => self.window.set_title(&text),
            Note::Arrived { .. } | Note::Summary(_) | Note::Focus(_) | Note::ChooseDirectory | Note::Settings | Note::Quota | Note::Local(_) | Note::Ended(_) => {}
        }
        None
    }

    fn dump(&self) {
        self.read(check::DUMP, UserEvent::Dump);
    }

    /// Runs `script` in the page and hands its result to the event loop as `event`.
    fn read(&self, script: &str, event: fn(String) -> UserEvent) {
        let proxy = self.proxy.clone();
        self.pane.read(script, move |result| drop(proxy.send_event(event(result))));
    }

    /// The composer has the caret: presses the keys of the check's text.
    fn type_text(&mut self, aim: &str) -> Result<(), String> {
        let aim = check::unwrap(aim)?;
        let (Some(true), Some(x), Some(y)) = (aim["focused"].as_bool(), aim["send"][0].as_f64(), aim["send"][1].as_f64()) else {
            return Err(format!("The composer could not be aimed at: {aim}."));
        };
        self.send_button = Some((x, y));
        let text = self.check.as_ref().and_then(|check| check.options.typed.as_deref()).unwrap_or_default();
        input::type_text(self.pane.webview(), text)?;
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
            Some((x, y)) => input::click(self.pane.webview(), x, y),
            None => Ok(()),
        }
    }

    /// The page's dump arrived: writes the report, then ends the check unless it waits for more template edits.
    fn reported(&mut self, dump: &str) -> Option<i32> {
        let check = self.check.as_mut()?;
        if let Err(problem) = check.write(dump, &self.pane.template_name(), self.pane.loads()) {
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
        snapshot::take(self.pane.webview(), move |picture| drop(proxy.send_event(UserEvent::Picture(picture))));
    }
}
