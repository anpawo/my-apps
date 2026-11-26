//! Many session windows in one process: one tao event loop, one pane per window, each pane with its own session and
//! worker link on plain threads. The window list, Fleet presence and the control socket live here too.

use crate::control::{self, Request};
use crate::settings::{self, Settings};
use crate::windows::{self, Frame, Saved};
use crate::worker::{self, Reaper};
use crate::menus::MenuAction;
use crate::{confirm, fleet, focus, folder, local, login, menus, metrics, progress, quota, relaunch, requests, sheet, takeover, tasks, update};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::convert::Infallible;
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::Sender;
use std::thread;
use std::time::{Duration, Instant, SystemTime};
use tao::dpi::{LogicalPosition, LogicalSize};
use tao::event::{Event, StartCause, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy, EventLoopWindowTarget};
use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
use tao::window::{Window, WindowBuilder, WindowId};
use vcx_config::Homes;
use vcx_proto::AttachRequest;
use vcx_shell::pane::{self, Note, Pane, PaneEvent};
use vcx_shell::session::{Message, Source};
use vcx_shell::summary::Summary;

/// Moves and resizes come in bursts: the window list is written once they stop.
const SAVE_DELAY: Duration = Duration::from_millis(500);
/// Fleet reads presence a few times a second at most (the Swift app throttles it the same way).
const PRESENCE_DELAY: Duration = Duration::from_millis(250);
/// How often a window on screen reads its usage and repository again (Swift `startRefresh`).
const REFRESH_EVERY: Duration = Duration::from_secs(60);
pub const ALREADY_RUNNING: &str = "Another VCX Rust app holds this state folder.";
const TITLE_SUFFIX: &str = " · VCX Rust";
/// Swift `main.swift`: 780 for the transcript and the composer, 200 for the task bar, which always shows.
const MIN_WINDOW_SIZE: (f64, f64) = (980.0, 560.0);
const EXIT_FAILED: i32 = 1;
/// A page still loading never answers a script: a report gives up on it after this long and says so.
const PAGE_READ_WAIT: Duration = Duration::from_secs(2);

/// What a page shows, read for a report: enough to tell what it drew, without the whole document.
const PAGE_REPORT: &str = r#"(() => JSON.stringify({
  visibility: document.visibilityState,
  location: location.href,
  ready: document.readyState,
  status: document.getElementById('status-text')?.textContent ?? null,
  notice: document.getElementById('notice')?.hidden === false ? document.getElementById('notice').textContent : null,
  rows: [...document.querySelectorAll('[data-row]')].map(row => ({ kind: row.dataset.kind, text: row.innerText })),
  tasks: [...document.querySelectorAll('#tasks .card:not([data-ghost])')].map(card => ({ text: card.textContent, state: card.dataset.state, current: card.hasAttribute('aria-current') })),
}))()"#;

pub struct Options {
    pub homes: Homes,
    /// Windows that are never shown, no Dock icon, no activation: checks and tests.
    pub windowless: bool,
    pub open: Option<Open>,
}

pub use vcx_cli::Open;

pub enum AppEvent {
    Pane(u64, PaneEvent),
    Control(Request),
    Dumped(u64, String),
    Save,
    Publish,
    ReportDue(u64),
    /// Time to read the task files again.
    Tasks,
    /// The folder picked in window `key`'s panel.
    Chosen(u64, PathBuf),
    /// The sign-in panel's new text.
    Login(Value),
    /// The quota popover's lines, read off the main thread.
    Quota(Value),
    /// Whether window `key`'s page had a picture to preview.
    Previewed(u64, bool),
    /// A File menu item chosen.
    Menu(MenuAction),
    /// The folder picked in the Open Project panel.
    OpenProject(PathBuf),
    /// He chose Close on window `key` while its agent was at work.
    CloseConfirmed(u64),
    /// Fleet or Watcher asked for the window of this session.
    Focus(String),
}

pub(crate) struct Win {
    pub window: Window,
    pub pane: Pane,
    pub session_id: String,
    pub socket: PathBuf,
    pub cwd: String,
    pub record_id: Option<String>,
    pub summary: Option<Summary>,
    /// Page messages carrying a worker revision, by serial, with when the revision arrived.
    arrived: BTreeMap<u64, Instant>,
    /// Logical height of the title bar, read while tao still measures the content (see `frame`).
    titlebar: f64,
    /// The task bar message the page has, so an unchanged list is not sent again.
    tasks_shown: Value,
    /// The progress line the page has, and the file sizes read for its rate.
    progress_shown: Value,
    progress_samples: Vec<(f64, f64)>,
}

struct Spec {
    socket: PathBuf,
    request: AttachRequest,
    frame: Option<Frame>,
    record_id: Option<String>,
    focus: bool,
}

struct Reopen {
    spec: Spec,
    start_worker: bool,
}

/// What a launch reopens: each saved window, on its live worker or, the worker gone, cold from its saved conversation
/// on a new one; then each running session no frontend holds that the list lost.
fn plan(saved: &[Saved], running: &[worker::Running]) -> Vec<Reopen> {
    let mut reopened = Vec::new();
    for entry in saved {
        let live = running.iter().any(|session| session.session_id == entry.session_id);
        let resume = entry.record_id.as_ref().map(|record| format!("native:{record}"));
        if !live && resume.is_none() {
            eprintln!("vcx-rust: the session of {} ended with its worker and left nothing to reopen.", entry.cwd);
            continue;
        }
        let request = AttachRequest { session_id: entry.session_id.clone(), cwd: entry.cwd.clone(), prompt: String::new(), resume: if live { None } else { resume }, existing_only: live };
        reopened.push(Reopen { spec: Spec { socket: entry.socket.clone(), request, frame: entry.frame, record_id: entry.record_id.clone(), focus: false }, start_worker: !live });
    }
    for session in running.iter().filter(|session| !session.attached && !saved.iter().any(|entry| entry.session_id == session.session_id)) {
        let request = AttachRequest { session_id: session.session_id.clone(), cwd: "/".into(), existing_only: true, ..AttachRequest::default() };
        reopened.push(Reopen { spec: Spec { socket: session.socket.clone(), request, frame: None, record_id: None, focus: false }, start_worker: false });
    }
    reopened
}

fn on_screen(window: &Window) -> bool {
    use objc2_app_kit::{NSWindow, NSWindowOcclusionState};
    use tao::platform::macos::WindowExtMacOS;
    // SAFETY: tao hands the NSWindow it owns for as long as `window` lives, which outlasts this call.
    let Some(ns_window) = (unsafe { (window.ns_window() as *const NSWindow).as_ref() }) else { return false };
    window.is_visible() && ns_window.occlusionState().contains(NSWindowOcclusionState::Visible)
}

fn answers(socket: &std::path::Path) -> bool {
    vcx_proto::Client::connect(socket, |_| {}).and_then(|client| client.hello()).is_ok()
}

pub(crate) struct Queued {
    pub session_id: String,
    pub text: String,
    pub at: Instant,
}

struct Report {
    number: u64,
    answer: Sender<Value>,
    waiting: HashSet<u64>,
    pages: HashMap<u64, Value>,
}

pub(crate) struct App {
    pub homes: Homes,
    settings: Settings,
    pub(crate) windowless: bool,
    pub(crate) proxy: EventLoopProxy<AppEvent>,
    reaper: Reaper,
    pub windows: BTreeMap<u64, Win>,
    keys: HashMap<WindowId, u64>,
    next: u64,
    focused: Option<u64>,
    /// From a worker revision's arrival to the page saying it drew it, for every patch of every window.
    delays: Vec<Duration>,
    pub queue: Vec<Queued>,
    report: Option<Report>,
    reports: u64,
    save_due: bool,
    publish_due: bool,
    started_at: u64,
    first: Option<Open>,
    notice: Option<String>,
    pub(crate) login: Option<login::Running>,
    login_message: Value,
    /// The last quota read and when it was made.
    quota: Option<(Instant, Value)>,
    /// The windows waiting for the quota read under way.
    quota_waiting: Option<Vec<u64>>,
    refreshed_at: Instant,
    /// The updating chip every window shows.
    update_shown: Value,
    _lock: File,
}

pub fn run(options: Options) -> Result<Infallible, String> {
    worker::keep_build_lock_out();
    let lock = lock(&options.homes)?;
    let (settings, notice) = settings::read(&options.homes.settings());
    let mut event_loop = EventLoopBuilder::<AppEvent>::with_user_event().build();
    if options.windowless {
        event_loop.set_activation_policy(ActivationPolicy::Accessory);
        event_loop.set_activate_ignoring_other_apps(false);
    }
    // The Edit menu is what carries ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z to the web view.
    let mtm = objc2_foundation::MainThreadMarker::new().ok_or("VCX Rust runs on the main thread.")?;
    vcx_shell::menu::install(mtm);
    let proxy = event_loop.create_proxy();
    let to_menu = proxy.clone();
    menus::install(mtm, move |action| drop(to_menu.send_event(AppEvent::Menu(action))));
    let to_loop = proxy.clone();
    control::serve(&options.homes.control(), move |request| drop(to_loop.send_event(AppEvent::Control(request))))?;
    relaunch::listen();
    let to_focus = proxy.clone();
    focus::listen(move |id| drop(to_focus.send_event(AppEvent::Focus(id))));
    let pid = std::process::id();
    let started_at = vcx_config::process::start_time(pid as i32).unwrap_or_default();
    let mut app = App {
        homes: options.homes,
        settings,
        windowless: options.windowless,
        proxy,
        reaper: Reaper::start(),
        windows: BTreeMap::new(),
        keys: HashMap::new(),
        next: 0,
        focused: None,
        delays: Vec::new(),
        queue: Vec::new(),
        report: None,
        reports: 0,
        save_due: false,
        publish_due: false,
        started_at,
        first: options.open,
        notice,
        login: None,
        login_message: Value::Null,
        quota: None,
        quota_waiting: None,
        refreshed_at: Instant::now(),
        update_shown: Value::Null,
        _lock: lock,
    };
    event_loop.run(move |event, target, flow| {
        *flow = ControlFlow::Wait;
        let exit = match event {
            Event::NewEvents(StartCause::Init) => app.start(target),
            Event::UserEvent(event) => app.on(event, target),
            Event::WindowEvent { window_id, event, .. } => app.window_event(window_id, event),
            _ => None,
        };
        if let Some(code) = exit {
            *flow = ControlFlow::ExitWithCode(code);
        }
    })
}

/// One app per state folder: the lock is held for the life of the process and dropped by the kernel with it.
fn lock(homes: &Homes) -> Result<File, String> {
    vcx_config::private_folder(&homes.state)?;
    let file = OpenOptions::new().create(true).truncate(false).write(true).open(homes.lock()).map_err(|error| format!("Cannot lock {}: {error}.", homes.lock().display()))?;
    // SAFETY: the descriptor is open for as long as `file` lives; LOCK_NB never blocks.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(ALREADY_RUNNING.into());
    }
    Ok(file)
}

impl App {
    fn start(&mut self, target: &EventLoopWindowTarget<AppEvent>) -> Option<i32> {
        self.restore(target);
        match self.first.take() {
            Some(open) => drop(self.new_session(target, open)),
            None if self.windows.is_empty() && !self.windowless => {
                let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
                drop(self.new_session(target, Open { cwd: home, focus: true, ..Open::default() }));
            }
            None => {}
        }
        self.save_now();
        let proxy = self.proxy.clone();
        thread::spawn(move || {
            while proxy.send_event(AppEvent::Tasks).is_ok() {
                thread::sleep(tasks::TICK);
            }
        });
        None
    }

    /// Reopens the windows of the last run, and any session its workers still hold that no frontend shows.
    fn restore(&mut self, target: &EventLoopWindowTarget<AppEvent>) {
        let saved = windows::read(&self.homes.windows());
        for mut reopen in plan(&saved, &worker::running(&self.homes)) {
            // A window taken from the Swift app keeps its worker's socket, which `running` does not list: still answering,
            // it is live; gone, the cold reopen runs on one of the app's own, never in the Swift app's folders.
            if reopen.start_worker && !reopen.spec.socket.starts_with(self.homes.runtime()) {
                if answers(&reopen.spec.socket) {
                    reopen.start_worker = false;
                    reopen.spec.request.resume = None;
                    reopen.spec.request.existing_only = true;
                } else {
                    reopen.spec.socket = worker::socket_for(&self.homes, &reopen.spec.request.session_id);
                }
            }
            if reopen.start_worker {
                self.start_worker(&reopen.spec.socket, &reopen.spec.request.cwd);
            }
            self.open_window(target, reopen.spec);
        }
    }

    /// Reopens a window the Swift app left (`takeover`): on its live worker and session, or, that worker gone, cold
    /// from its saved conversation in a new session of the app's own. The session id it runs as, none when skipped.
    pub(crate) fn adopt(&mut self, target: &EventLoopWindowTarget<AppEvent>, entry: takeover::Entry) -> Option<String> {
        if self.windows.values().any(|win| win.session_id == entry.session_id) {
            return None;
        }
        if answers(&entry.socket) {
            let request = AttachRequest { session_id: entry.session_id.clone(), cwd: entry.cwd, prompt: String::new(), resume: None, existing_only: true };
            self.open_window(target, Spec { socket: entry.socket, request, frame: None, record_id: entry.record_id, focus: false });
            self.schedule_save();
            return Some(entry.session_id);
        }
        let resume = entry.record_id.map(|record| format!("native:{record}"))?;
        Some(self.new_session(target, Open { cwd: entry.cwd, resume: Some(resume), ..Open::default() }))
    }

    pub(crate) fn new_session(&mut self, target: &EventLoopWindowTarget<AppEvent>, open: Open) -> String {
        let session_id = uuid::Uuid::new_v4().to_string().to_uppercase();
        let socket = worker::socket_for(&self.homes, &session_id);
        self.start_worker(&socket, &open.cwd);
        let request = AttachRequest { session_id: session_id.clone(), cwd: open.cwd, prompt: open.prompt, resume: open.resume, existing_only: false };
        self.open_window(target, Spec { socket, request, frame: None, record_id: None, focus: open.focus });
        self.schedule_save();
        session_id
    }

    fn start_worker(&mut self, socket: &std::path::Path, cwd: &str) {
        match worker::ensure(&self.settings, &self.homes, socket, cwd) {
            Ok(Some(child)) => self.reaper.watch(child),
            Ok(None) => {}
            // The link keeps trying the socket and the window says it is not connected.
            Err(problem) => eprintln!("vcx-rust: {problem}"),
        }
    }

    fn open_window(&mut self, target: &EventLoopWindowTarget<AppEvent>, spec: Spec) {
        let (width, height) = spec.frame.map_or(self.settings.window_size, |frame| (frame.width, frame.height));
        let builder = WindowBuilder::new().with_title(title(&spec.request.cwd)).with_inner_size(LogicalSize::new(width, height)).with_min_inner_size(LogicalSize::new(MIN_WINDOW_SIZE.0, MIN_WINDOW_SIZE.1)).with_visible(!self.windowless).with_focused(spec.focus && !self.windowless);
        let window = match builder.build(target) {
            Ok(window) => window,
            Err(error) => return eprintln!("vcx-rust: cannot open a window: {error}"),
        };
        let scale = window.scale_factor();
        let titlebar = window.outer_size().to_logical::<f64>(scale).height - window.inner_size().to_logical::<f64>(scale).height;
        // The builder's position is the content's corner, the saved one the frame's: set it the way it is read.
        if let Some(frame) = spec.frame {
            window.set_outer_position(LogicalPosition::new(frame.x, frame.y));
        }
        let key = self.next;
        self.next += 1;
        let proxy = self.proxy.clone();
        let emit: pane::Emit = Arc::new(move |event| drop(proxy.send_event(AppEvent::Pane(key, event))));
        let options = pane::Options { template: self.settings.template.clone(), wait_for_answer: false, quiet: self.windowless };
        let (session_id, cwd) = (spec.request.session_id.clone(), spec.request.cwd.clone());
        let mut pane = match Pane::new(&window, Source::Worker { socket: spec.socket.clone(), request: spec.request }, &options, emit) {
            Ok(pane) => pane,
            Err(problem) => return eprintln!("vcx-rust: cannot draw the window: {problem}"),
        };
        if let Some(notice) = &self.notice {
            pane.note(notice.clone());
        }
        self.keys.insert(window.id(), key);
        self.windows.insert(key, Win { window, pane, session_id, socket: spec.socket, cwd, record_id: spec.record_id, summary: None, arrived: BTreeMap::new(), titlebar, tasks_shown: Value::Null, progress_shown: Value::Null, progress_samples: Vec::new() });
        self.schedule_publish();
    }

    fn on(&mut self, event: AppEvent, target: &EventLoopWindowTarget<AppEvent>) -> Option<i32> {
        match event {
            AppEvent::Pane(key, event) => {
                let notes = self.windows.get_mut(&key).map(|win| win.pane.on(event)).unwrap_or_default();
                let mut exit = None;
                for note in notes {
                    match note {
                        Note::Local(text) => exit = exit.or(local::run(self, target, key, &text)),
                        note => self.noted(key, note),
                    }
                }
                exit
            }
            AppEvent::Control(request) => requests::handle(self, target, request),
            AppEvent::Dumped(key, page) => {
                self.dumped(key, &page);
                None
            }
            AppEvent::Save => {
                self.save_due = false;
                self.save_now();
                None
            }
            AppEvent::Publish => {
                self.publish_due = false;
                self.publish_now();
                None
            }
            AppEvent::ReportDue(number) => {
                if let Some(report) = self.report.as_mut().filter(|report| report.number == number) {
                    report.waiting.clear();
                }
                self.finish_report();
                None
            }
            AppEvent::Tasks => {
                self.show_tasks();
                self.show_progress();
                self.show_update();
                self.refresh_on_screen();
                if relaunch::requested() {
                    self.relaunch();
                }
                None
            }
            AppEvent::Menu(action) => self.menu(target, action),
            AppEvent::Focus(id) => {
                self.bring(&id);
                None
            }
            AppEvent::OpenProject(path) => {
                drop(self.new_session(target, Open { cwd: path.to_string_lossy().into_owned(), focus: true, ..Open::default() }));
                None
            }
            AppEvent::CloseConfirmed(key) => self.close_window(key),
            AppEvent::Previewed(key, false) => {
                if let Some(win) = self.windows.get_mut(&key) {
                    win.pane.note(local::NO_PICTURE.into());
                }
                None
            }
            AppEvent::Previewed(_, true) => None,
            AppEvent::Login(message) => {
                self.show_login(message);
                None
            }
            AppEvent::Quota(message) => {
                for key in self.quota_waiting.take().unwrap_or_default() {
                    if let Some(win) = self.windows.get(&key) {
                        win.pane.to_page(&message);
                    }
                }
                self.quota = Some((Instant::now(), message));
                None
            }
            AppEvent::Chosen(key, path) => {
                if let Some(win) = self.windows.get(&key) {
                    win.pane.tell(Message::Act { action: "command", params: json!({"text": folder::command(&path)}) });
                }
                None
            }
        }
    }

    fn noted(&mut self, key: u64, note: Note) {
        let Some(win) = self.windows.get_mut(&key) else { return };
        match note {
            Note::Arrived { serial, at } => drop(win.arrived.insert(serial, at)),
            Note::Rendered(serial) => {
                let drawn = Instant::now();
                let later = win.arrived.split_off(&(serial + 1));
                self.delays.extend(std::mem::replace(&mut win.arrived, later).into_values().map(|at| drawn - at));
            }
            Note::Summary(summary) => self.summarized(key, summary),
            Note::Closed(reason) => {
                eprintln!("vcx-rust: {reason}");
                self.drop_window(key, false);
            }
            // The page has just been given the whole state: it gets the task bar and the progress line again.
            Note::Shown(_) => {
                win.tasks_shown = Value::Null;
                win.progress_shown = Value::Null;
                if local::shown(&self.login_message) {
                    win.pane.to_page(&self.login_message);
                }
                self.show_tasks();
                self.show_progress();
                if let Some(win) = self.windows.get(&key).filter(|_| self.update_shown["words"].as_str().is_some_and(|words| !words.is_empty())) {
                    win.pane.to_page(&self.update_shown);
                }
            }
            Note::Title(text) => win.window.set_title(&text),
            Note::Focus(id) => self.bring(&id),
            // A check never opens a panel.
            Note::ChooseDirectory if self.windowless => {}
            Note::ChooseDirectory => {
                let proxy = self.proxy.clone();
                folder::choose(&win.cwd, move |path| drop(proxy.send_event(AppEvent::Chosen(key, path))));
            }
            Note::Settings => match self.homes.shared_settings().load() {
                Ok(settings) => {
                    let (home, now) = (std::env::var("HOME").unwrap_or_else(|_| "/".into()), SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map_or(0.0, |since| since.as_secs_f64()));
                    win.pane.to_page(&sheet::message(&settings, win.summary.as_ref().and_then(|summary| summary.account.as_ref()), &home, now));
                }
                Err(problem) => win.pane.note(problem),
            },
            // A check reads none of his accounts: the popover stays empty.
            Note::Quota if self.windowless => win.pane.to_page(&quota::message(&[])),
            Note::Quota => {
                // A stale read shows until the new one arrives, as the Swift popover shows its cache.
                if let Some((at, message)) = &self.quota {
                    win.pane.to_page(message);
                    if at.elapsed() < quota::CACHE_LIFE {
                        return;
                    }
                }
                if let Some(waiting) = &mut self.quota_waiting {
                    return waiting.push(key);
                }
                self.quota_waiting = Some(vec![key]);
                let (settings, proxy) = (self.homes.shared_settings().load().unwrap_or_default(), self.proxy.clone());
                thread::spawn(move || {
                    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into()));
                    let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map_or(0.0, |since| since.as_secs_f64());
                    drop(proxy.send_event(AppEvent::Quota(quota::message(&quota::read(&settings, &home, now)))));
                });
            }
            Note::Settled(_) | Note::Sent | Note::Edited | Note::Reloading | Note::Local(_) => {}
        }
    }

    pub(crate) fn show_login(&mut self, message: Value) {
        for win in self.windows.values() {
            win.pane.to_page(&message);
        }
        self.login_message = message;
    }

    /// Closes window `key`, asking first while its agent or a background task still runs (Swift `windowShouldClose`).
    fn ask_close(&mut self, key: u64) -> Option<i32> {
        let win = self.windows.get(&key)?;
        let work = win.summary.as_ref().and_then(|summary| confirm::running_work(summary.busy, summary.background_tasks as usize));
        let Some(work) = work.filter(|_| !self.windowless) else { return self.close_window(key) };
        let folder = std::path::Path::new(&win.cwd).file_name().map_or_else(|| win.cwd.clone(), |name| name.to_string_lossy().into_owned());
        let proxy = self.proxy.clone();
        confirm::ask(&win.window, &confirm::close_title(&folder), &work, confirm::CLOSE_BUTTON, move |close| {
            if close {
                drop(proxy.send_event(AppEvent::CloseConfirmed(key)));
            }
        });
        None
    }

    /// The File menu (Swift `newWindow`, `openProject`, and `performClose:` on the front window).
    fn menu(&mut self, target: &EventLoopWindowTarget<AppEvent>, action: MenuAction) -> Option<i32> {
        let front = self.focused.filter(|key| self.windows.contains_key(key));
        let cwd = front.map_or_else(|| std::env::var("HOME").unwrap_or_else(|_| "/".into()), |key| self.windows[&key].cwd.clone());
        match action {
            MenuAction::NewWindow => drop(self.new_session(target, Open { cwd, focus: true, ..Open::default() })),
            // A check never opens a panel.
            MenuAction::OpenProject if self.windowless => {}
            MenuAction::OpenProject => {
                let proxy = self.proxy.clone();
                folder::choose(&cwd, move |path| drop(proxy.send_event(AppEvent::OpenProject(path))));
            }
            MenuAction::CloseWindow => return front.and_then(|key| self.ask_close(key)),
        }
        None
    }

    /// Ends the window's session; the app's exit code once its last window closed.
    pub(crate) fn close_window(&mut self, key: u64) -> Option<i32> {
        self.drop_window(key, true);
        (self.windows.is_empty() && !self.windowless).then(|| self.quit())
    }

    fn summarized(&mut self, key: u64, summary: Summary) {
        let Some(win) = self.windows.get_mut(&key) else { return };
        let moved = !summary.cwd.is_empty() && summary.cwd != win.cwd;
        if moved {
            win.cwd = summary.cwd.clone();
            win.window.set_title(&title(&win.cwd));
        }
        let recorded = summary.record_id.is_some() && summary.record_id != win.record_id;
        if recorded {
            win.record_id = summary.record_id.clone();
        }
        win.summary = Some(summary);
        // Rare and needed to reopen the conversation after a crash: written at once, not after the save delay.
        if moved || recorded {
            self.save_now();
        }
        self.schedule_publish();
        requests::deliver_queue(self);
    }

    fn window_event(&mut self, id: WindowId, event: WindowEvent) -> Option<i32> {
        let key = *self.keys.get(&id)?;
        match event {
            WindowEvent::CloseRequested => return self.ask_close(key),
            WindowEvent::Moved(_) | WindowEvent::Resized(_) => self.schedule_save(),
            WindowEvent::Focused(true) => {
                self.focused = Some(key);
                self.schedule_publish();
            }
            _ => {}
        }
        None
    }

    /// Every minute, the windows he can see read their usage and repository again; a hidden or covered one waits.
    fn refresh_on_screen(&mut self) {
        if self.windowless || self.refreshed_at.elapsed() < REFRESH_EVERY {
            return;
        }
        self.refreshed_at = Instant::now();
        for win in self.windows.values().filter(|win| on_screen(&win.window)) {
            win.pane.tell(Message::Act { action: "refreshUsage", params: json!({"force": false}) });
            win.pane.tell(Message::Act { action: "refreshRepository", params: json!({}) });
        }
    }

    /// Reads what each window's agent waits on ($VCX_PROGRESS_FILE) and gives the page the line that changed.
    fn show_progress(&mut self) {
        let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map_or(0.0, |since| since.as_secs_f64());
        for win in self.windows.values_mut() {
            let file = win.summary.as_ref().and_then(|summary| summary.progress_file.clone());
            let read = file.and_then(|file| progress::read(std::path::Path::new(&file), now, &mut win.progress_samples));
            if read.is_none() {
                win.progress_samples.clear();
            }
            let message = progress::message(read.as_ref());
            if message != win.progress_shown {
                win.pane.to_page(&message);
                win.progress_shown = message;
            }
        }
    }

    /// The build `auto-update.sh` has under way, in every window's updating chip (Swift `UpdateBuild`).
    fn show_update(&mut self) {
        let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map_or(0.0, |since| since.as_secs_f64());
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into()));
        let message = update::message(update::read(&update::folder(&home), now).as_ref(), now);
        if message != self.update_shown {
            for win in self.windows.values() {
                win.pane.to_page(&message);
            }
            self.update_shown = message;
        }
    }

    /// Reads every window's task file and gives each page the list that changed for it.
    fn show_tasks(&mut self) {
        let entries: Vec<tasks::Entry> = self.windows.values().filter_map(|win| {
            let summary = win.summary.as_ref()?;
            let task = tasks::task(std::path::Path::new(summary.task_file.as_ref()?))?;
            Some(tasks::Entry { id: win.session_id.clone(), group: tasks::group(&win.cwd), task, state: summary.task_state })
        }).collect();
        for win in self.windows.values_mut() {
            let message = tasks::message(&entries, &win.session_id);
            if message != win.tasks_shown {
                win.pane.to_page(&message);
                win.tasks_shown = message;
            }
        }
    }

    /// Brings up the window of `session_id`, as a click on its task card asks; a windowless app only marks it focused.
    fn bring(&mut self, session_id: &str) {
        let Some((&key, win)) = self.windows.iter().find(|(_, win)| win.session_id.eq_ignore_ascii_case(session_id)) else { return };
        if !self.windowless {
            win.window.set_minimized(false);
            win.window.set_visible(true);
            win.window.set_focus();
        }
        self.focused = Some(key);
        self.schedule_publish();
    }

    /// Takes a window away. `end` also ends its session, as closing it does; a session taken by another frontend
    /// is left to that one.
    pub(crate) fn drop_window(&mut self, key: u64, end: bool) {
        let Some(mut win) = self.windows.remove(&key) else { return };
        self.keys.remove(&win.window.id());
        if end {
            win.pane.tell(Message::Act { action: "close", params: json!({}) });
        }
        win.pane.release();
        if let Some(report) = &mut self.report {
            report.waiting.remove(&key);
        }
        self.finish_report();
        self.save_now();
        self.publish_now();
    }

    /// Ends every session, waiting a little for each worker to save it, then lets the process end.
    pub(crate) fn quit(&mut self) -> i32 {
        for win in self.windows.values() {
            win.pane.tell(Message::Act { action: "close", params: json!({}) });
        }
        for win in self.windows.values_mut() {
            win.pane.close();
        }
        self.windows.clear();
        let saved = windows::write(&self.homes.windows(), &[]);
        let _ = fleet::publish(&self.homes.fleet(), std::process::id(), None);
        let _ = std::fs::remove_file(self.homes.control());
        match saved {
            Ok(()) => 0,
            Err(problem) => {
                eprintln!("vcx-rust: {problem}");
                EXIT_FAILED
            }
        }
    }

    pub(crate) fn schedule_save(&mut self) {
        if !self.save_due {
            self.save_due = true;
            self.after(SAVE_DELAY, AppEvent::Save);
        }
    }

    fn schedule_publish(&mut self) {
        if !self.publish_due {
            self.publish_due = true;
            self.after(PRESENCE_DELAY, AppEvent::Publish);
        }
    }

    fn after(&self, delay: Duration, event: AppEvent) {
        let proxy = self.proxy.clone();
        thread::spawn(move || {
            thread::sleep(delay);
            let _ = proxy.send_event(event);
        });
    }

    /// A new build was installed: the windows are saved and the app becomes that build, which reopens them.
    fn relaunch(&mut self) {
        self.save_now();
        let problem = relaunch::exec(self.windowless);
        eprintln!("vcx-rust: {problem}");
        for win in self.windows.values_mut() {
            win.pane.note(format!("Automatic update paused: {problem}"));
        }
    }

    fn save_now(&self) {
        let saved: Vec<Saved> = self.windows.values().map(|win| Saved { session_id: win.session_id.clone(), socket: win.socket.clone(), cwd: win.cwd.clone(), frame: Some(frame(win)), record_id: win.record_id.clone() }).collect();
        if let Err(problem) = windows::write(&self.homes.windows(), &saved) {
            eprintln!("vcx-rust: {problem}");
        }
    }

    fn publish_now(&self) {
        let focused = self.focused.and_then(|key| self.windows.get(&key)).map(|win| win.session_id.as_str());
        let listed: Vec<fleet::Window> = self.windows.values().map(|win| fleet::Window { session_id: &win.session_id, cwd: &win.cwd, summary: win.summary.as_ref(), window_number: None }).collect();
        let pid = std::process::id();
        if let Err(problem) = fleet::publish(&self.homes.fleet(), pid, fleet::record(pid, self.started_at, &listed, focused)) {
            eprintln!("vcx-rust: {problem}");
        }
    }

    pub(crate) fn begin_report(&mut self, answer: Sender<Value>) {
        if self.report.is_some() {
            return drop(answer.send(json!({"error": "A report is already being read."})));
        }
        self.reports += 1;
        self.report = Some(Report { number: self.reports, answer, waiting: self.windows.keys().copied().collect(), pages: HashMap::new() });
        self.after(PAGE_READ_WAIT, AppEvent::ReportDue(self.reports));
        for (&key, win) in &self.windows {
            let proxy = self.proxy.clone();
            win.pane.read(PAGE_REPORT, move |page| drop(proxy.send_event(AppEvent::Dumped(key, page))));
        }
        self.finish_report();
    }

    fn dumped(&mut self, key: u64, page: &str) {
        let Some(report) = &mut self.report else { return };
        if report.waiting.remove(&key) {
            report.pages.insert(key, vcx_shell::check::unwrap(page).unwrap_or_else(|problem| json!({"error": problem})));
        }
        self.finish_report();
    }

    fn finish_report(&mut self) {
        if self.report.as_ref().is_none_or(|report| !report.waiting.is_empty()) {
            return;
        }
        let Some(mut report) = self.report.take() else { return };
        let windows: Vec<Value> = self.windows.iter().map(|(key, win)| describe(win, report.pages.remove(key))).collect();
        let pid = std::process::id();
        let _ = report.answer.send(json!({"pid": pid, "windows": windows, "metrics": metrics::report(pid as i32), "delays": metrics::spread(&self.delays), "menus": objc2_foundation::MainThreadMarker::new().map(menus::outline)}));
    }
}

fn describe(win: &Win, page: Option<Value>) -> Value {
    let frame = frame(win);
    let summary = win.summary.clone().unwrap_or_default();
    json!({
        "sessionId": win.session_id, "socket": win.socket, "cwd": win.cwd, "recordID": win.record_id,
        "frame": [frame.x, frame.y, frame.width, frame.height], "visible": win.window.is_visible(),
        "state": summary.state, "idle": summary.idle, "taskFile": summary.task_file, "progressFile": summary.progress_file, "taskState": summary.task_state, "prompt": summary.prompt, "threadId": summary.thread_id,
        "name": vcx_cli::fleet::name(summary.context.as_deref(), summary.prompt.as_deref()),
        "page": page.unwrap_or(Value::Null),
    })
}

/// The window's frame corner and content size. wry gives the window a content view of its own, so tao's inner size
/// keeps the size the window was made with: the content is the frame less the title bar.
fn frame(win: &Win) -> Frame {
    let scale = win.window.scale_factor();
    let position: LogicalPosition<f64> = win.window.outer_position().map(|position| position.to_logical(scale)).unwrap_or(LogicalPosition::new(0.0, 0.0));
    let outer: LogicalSize<f64> = win.window.outer_size().to_logical(scale);
    Frame { x: position.x, y: position.y, width: outer.width, height: outer.height - win.titlebar }
}

fn title(cwd: &str) -> String {
    let folder = std::path::Path::new(cwd).file_name().map_or_else(|| cwd.to_owned(), |name| name.to_string_lossy().into_owned());
    folder + TITLE_SUFFIX
}

#[cfg(test)]
mod tests {
    use super::*;
    use worker::Running;

    fn saved(id: &str, record: Option<&str>) -> Saved {
        Saved { session_id: id.into(), socket: format!("/r/{id}.sock").into(), cwd: format!("/work/{id}"), frame: None, record_id: record.map(str::to_owned) }
    }

    fn running(id: &str, attached: bool) -> Running {
        Running { socket: format!("/r/{id}.sock").into(), session_id: id.into(), attached }
    }

    #[test]
    fn reattaches_live_sessions_and_reopens_dead_ones_cold_from_their_record() {
        let list = [saved("LIVE", Some("R1")), saved("DEAD", Some("R2")), saved("LOST", None)];

        let plan = plan(&list, &[running("LIVE", false), running("UNLISTED", false), running("ELSEWHERE", true)]);

        let shown: Vec<(&str, Option<&str>, bool, bool)> = plan.iter().map(|reopen| (reopen.spec.request.session_id.as_str(), reopen.spec.request.resume.as_deref(), reopen.spec.request.existing_only, reopen.start_worker)).collect();
        assert_eq!(shown, [("LIVE", None, true, false), ("DEAD", Some("native:R2"), false, true), ("UNLISTED", None, true, false)]);
        assert_eq!(plan[1].spec.request.cwd, "/work/DEAD");
    }
}
