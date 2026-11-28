//! One window's page and session: the web view drawing the template, the session feeding it, template edits applied
//! live with the last good template kept. The owner (one window in `vcx-shell`, many in `vcx-app`) hears back notes.

use crate::bridge::{self, FromPage};
use crate::chart;
use crate::composer;
use crate::progress::{self, Progress};
use crate::run;
use crate::session::{self, Message, Output, Source};
use crate::summary::Summary;
use crate::template::{self, Change, Store};
use serde_json::{Value, json};
use std::cell::Cell;
use std::path::PathBuf;
use std::sync::{Arc, Weak};
use std::thread;
use std::time::{Duration, Instant, SystemTime};
use tao::window::Window;
use vcx_model::view::CONTRACT_VERSION;
use wry::{BackgroundThrottlingPolicy, DragDropEvent, WebView, WebViewBuilder};

/// How long a freshly loaded page has to report ready before the last template that worked comes back.
const READY_WAIT: Duration = Duration::from_secs(3);
const LAST_GOOD: &str = "Showing the last template that worked.";
/// What VCX runs itself, never the worker, which refuses them (Swift `RuntimeSession`'s frontend verbs).
const FRONTEND_COMMANDS: [&str; 9] = ["/window", "/settings", "/login", "/attach", "/preview", "/quit", "/exit", "/details", "/focus"];

/// Hands an event to the event loop, addressed to the pane it came from.
pub type Emit = Arc<dyn Fn(PaneEvent) + Send + Sync>;

pub enum PaneEvent {
    FromPage(String),
    Session(Output),
    TemplateEdited,
    ReadyDeadline(u64),
    /// A script for the page from another thread: a chart feed's data.
    Script(String),
    /// Time to read the progress file again.
    ProgressTick,
}

/// What the owner hears of a pane.
#[derive(Debug, PartialEq)]
pub enum Note {
    /// Page message `serial` carries the session's whole state.
    Shown(u64),
    Rendered(u64),
    Settled(u64),
    Arrived { serial: u64, at: Instant },
    Summary(Summary),
    Sent,
    /// The page took a template edit.
    Edited,
    /// The page is loading again: what it drew before no longer counts.
    Reloading,
    /// The page names the window: the window's title.
    Title(String),
    /// A click on another session's task card: bring that window up.
    Focus(String),
    /// The folder chip: ask for the session's new folder.
    ChooseDirectory,
    /// The Settings sheet opened: it asks for his accounts and what the session runs on.
    Settings,
    /// The quota popover opened: it asks for every agent's quota.
    Quota,
    /// A command the app runs, as typed: `/login claude`, `/window ~/projects`.
    Local(String),
    Closed(String),
    /// The session `end` asked for ended: none; or why the worker kept it.
    Ended(Option<String>),
}

pub struct Options {
    pub template: Option<PathBuf>,
    pub wait_for_answer: bool,
    /// A check opens no link the page asks for.
    pub quiet: bool,
}

pub struct Pane {
    webview: WebView,
    store: Arc<Store>,
    session: Option<session::Handle>,
    emit: Emit,
    /// Counts page loads, so a ready deadline knows which load it was set for.
    load: u64,
    ready: bool,
    /// Counts style swaps: each one needs an address the web view has not fetched yet.
    styles: u64,
    notice: Option<String>,
    quiet: bool,
    feeds: chart::Feeds,
    progress: Progress,
    progress_file: Option<PathBuf>,
    /// The progress message the page has, so an unchanged read is not sent again.
    progress_shown: Value,
    /// The session's working folder: where an `@` word looks and what a dropped file is named from.
    cwd: PathBuf,
    /// The progress ticker runs while this lives.
    _alive: Arc<()>,
    _watcher: Option<notify::RecommendedWatcher>,
}

impl Pane {
    pub fn new(window: &Window, source: Source, options: &Options, emit: Emit) -> Result<Self, String> {
        let (store, problem) = Store::open(options.template.as_deref());
        let store = Arc::new(store);
        let webview = web_view(window, &store, &emit)?;
        let to_pane = emit.clone();
        let session = session::spawn(source, options.wait_for_answer, move |output| to_pane(PaneEvent::Session(output)))?;
        let watcher = match &options.template {
            // A folder that is not there shows the built-in template and its notice, without a watch.
            Some(folder) if folder.is_dir() => {
                let edited = emit.clone();
                Some(template::watch(folder, move || edited(PaneEvent::TemplateEdited)).map_err(|error| error.to_string())?)
            }
            _ => None,
        };
        let notice = problem.map(|problem| format!("{problem} Showing the built-in template."));
        let to_page = emit.clone();
        let feeds = chart::Feeds::new(Arc::new(move |script| to_page(PaneEvent::Script(script))));
        let alive = Arc::new(());
        tick_progress(Arc::downgrade(&alive), emit.clone());
        let pane = Self {
            webview, store, session: Some(session), emit, load: 0, ready: false, styles: 0, notice, quiet: options.quiet, feeds,
            progress: Progress::default(), progress_file: None, progress_shown: Value::Null, cwd: PathBuf::new(), _alive: alive, _watcher: watcher,
        };
        pane.after_ready_wait();
        Ok(pane)
    }

    pub fn webview(&self) -> &WebView {
        &self.webview
    }

    pub fn template_name(&self) -> String {
        self.store.current().name.clone()
    }

    pub fn loads(&self) -> u64 {
        self.load
    }

    pub fn on(&mut self, event: PaneEvent) -> Vec<Note> {
        match event {
            PaneEvent::FromPage(body) if self.feeds.handle(&body) => Vec::new(),
            PaneEvent::FromPage(body) => bridge::parse(&body).map(|message| self.from_page(message)).unwrap_or_default(),
            PaneEvent::Session(output) => self.from_session(output),
            PaneEvent::TemplateEdited => self.template_edited(),
            PaneEvent::ReadyDeadline(load) if load == self.load && !self.ready => self.fall_back("The template's page did not start."),
            PaneEvent::ReadyDeadline(_) => Vec::new(),
            PaneEvent::Script(script) => {
                self.evaluate(&script);
                Vec::new()
            }
            PaneEvent::ProgressTick => {
                self.read_progress();
                Vec::new()
            }
        }
    }

    // Swift `Session.readProgress`, every `progress::TICK`; the page hears only a change.
    fn read_progress(&mut self) {
        let Some(path) = &self.progress_file else { return };
        let message = self.progress.read(path, SystemTime::now());
        if self.ready && message != self.progress_shown {
            self.to_page(&message);
            self.progress_shown = message;
        }
    }

    fn from_session(&mut self, output: Output) -> Vec<Note> {
        match output {
            Output::Page(message) => {
                let shown = (message["type"] == "full").then(|| message["serial"].as_u64()).flatten();
                self.to_page(&message);
                shown.map(Note::Shown).into_iter().collect()
            }
            Output::Settled(serial) => vec![Note::Settled(serial)],
            Output::Arrived { serial, at } => vec![Note::Arrived { serial, at }],
            Output::Summary(summary) => {
                self.cwd = PathBuf::from(&summary.cwd);
                if let Some(file) = &summary.progress_file {
                    self.progress_file = Some(PathBuf::from(file));
                }
                vec![Note::Summary(summary)]
            }
            Output::Closed(reason) => vec![Note::Closed(reason)],
            Output::Ended(problem) => vec![Note::Ended(problem)],
        }
    }

    fn from_page(&mut self, message: FromPage) -> Vec<Note> {
        match message {
            FromPage::Ready { contract } if contract == u64::from(CONTRACT_VERSION) => {
                self.page_ready();
                Vec::new()
            }
            FromPage::Ready { contract } => self.fall_back(&format!("The template's page speaks contract {contract}; this build speaks contract {CONTRACT_VERSION}.")),
            FromPage::Send { text, images, draft, generation } if images.is_empty() && is_frontend(&text) => {
                if let (Some(draft), Some(generation)) = (draft, generation) {
                    self.tell(Message::Act { action: "checkpoint", params: json!({"draft": draft, "generation": generation}) });
                }
                vec![Note::Local(text)]
            }
            FromPage::Send { text, images, draft, generation } => {
                let mut params = json!({"text": text, "images": images});
                if let (Some(draft), Some(generation)) = (draft, generation) {
                    params["draft"] = draft;
                    params["generation"] = json!(generation);
                }
                self.tell(Message::Act { action: "send", params });
                vec![Note::Sent]
            }
            FromPage::Stop => {
                self.tell(Message::Act { action: "stop", params: json!({}) });
                Vec::new()
            }
            FromPage::Rendered { serial } => vec![Note::Rendered(serial)],
            FromPage::Restyled { .. } => vec![Note::Edited],
            FromPage::Open { href } => {
                self.open(&href);
                Vec::new()
            }
            FromPage::Answer { params } => {
                self.tell(Message::Act { action: "answer", params });
                Vec::new()
            }
            // A check never writes Marius's pasteboard.
            FromPage::Copy { text } => {
                if !self.quiet {
                    bridge::copy(&text);
                }
                Vec::new()
            }
            FromPage::CopyImage { path } => {
                if !self.quiet {
                    bridge::copy_image(&path);
                }
                Vec::new()
            }
            FromPage::Composer(message) => {
                match message["type"].as_str() {
                    Some("draft") => self.tell(Message::Act { action: "checkpoint", params: json!({"draft": message["draft"], "generation": message["generation"]}) }),
                    Some("sendNow") => self.tell(Message::Act { action: "sendNow", params: json!({}) }),
                    Some("run" | "runInput" | "runStop") => {
                        let emit = self.emit.clone();
                        run::handle(&message, &self.cwd, Arc::new(move |reply| emit(PaneEvent::Script(bridge::deliver(&reply)))));
                    }
                    // `files`, `image` and `dropped` read or write the disk: off the main thread, back as a script.
                    _ => {
                        let (emit, cwd) = (self.emit.clone(), self.cwd.clone());
                        thread::spawn(move || {
                            if let Some(reply) = composer::answer(&message, &cwd, &composer::attachments_folder()) {
                                emit(PaneEvent::Script(bridge::deliver(&reply)));
                            }
                        });
                    }
                }
                Vec::new()
            }
            FromPage::Command { text } if is_frontend(&text) => vec![Note::Local(text)],
            FromPage::Command { text } => {
                self.tell(Message::Act { action: "command", params: json!({"text": text}) });
                Vec::new()
            }
            FromPage::Refresh { action } => {
                self.tell(Message::Act { action, params: json!({}) });
                Vec::new()
            }
            // The window's own business, wired by Rust app: its title, another window, the quota sheet, the folder panel.
            FromPage::Title { text } => vec![Note::Title(text)],
            FromPage::Focus { id } => vec![Note::Focus(id)],
            // A check never brings up another window.
            FromPage::FocusPeer { pid, started_at } => {
                if !self.quiet {
                    bridge::focus_peer(pid, started_at);
                }
                Vec::new()
            }
            FromPage::ChooseDirectory => vec![Note::ChooseDirectory],
            FromPage::Quota => vec![Note::Quota],
            FromPage::Settings => vec![Note::Settings],
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

    pub fn tell(&self, message: Message) {
        if let Some(session) = &self.session {
            session.send(message);
        }
    }

    fn evaluate(&self, script: &str) {
        if let Err(error) = self.webview.evaluate_script(script) {
            eprintln!("vcx: the page refused a script: {error}");
        }
    }

    pub fn to_page(&self, message: &Value) {
        self.evaluate(&bridge::deliver(message));
    }

    /// Shows a notice now, or once the page is ready.
    pub fn note(&mut self, text: String) {
        if self.ready {
            self.to_page(&json!({"type": "notice", "text": text}));
        } else {
            self.notice = Some(text);
        }
    }

    /// Runs `script` in the page and hands its result, as the web view encodes it, to `then`.
    pub fn read(&self, script: &str, then: impl Fn(String) + Send + 'static) {
        if let Err(error) = self.webview.evaluate_script_with_callback(script, then) {
            eprintln!("vcx: the page could not be read: {error}");
        }
    }

    fn template_edited(&mut self) -> Vec<Note> {
        match self.store.reload() {
            Ok(Change::None) => Vec::new(),
            Ok(Change::Styles) => {
                self.styles += 1;
                self.evaluate(&format!("window.vcx&&vcx.restyle({})", self.styles));
                Vec::new()
            }
            Ok(Change::Page) => {
                let mut notes = self.reload();
                notes.push(Note::Edited);
                notes
            }
            Err(problem) => {
                self.note(format!("{problem} {LAST_GOOD}"));
                Vec::new()
            }
        }
    }

    fn reload(&mut self) -> Vec<Note> {
        self.ready = false;
        self.progress_shown = Value::Null;
        self.feeds.stop_all();
        self.tell(Message::PageGone);
        self.load += 1;
        if let Err(error) = self.webview.load_url(template::HOME) {
            eprintln!("vcx: the page could not be reloaded: {error}");
        }
        self.after_ready_wait();
        vec![Note::Reloading]
    }

    fn after_ready_wait(&self) {
        let (emit, load) = (self.emit.clone(), self.load);
        thread::spawn(move || {
            thread::sleep(READY_WAIT);
            emit(PaneEvent::ReadyDeadline(load));
        });
    }

    fn fall_back(&mut self, reason: &str) -> Vec<Note> {
        if !self.store.revert() {
            eprintln!("vcx: {reason} There is no earlier template to return to.");
            return Vec::new();
        }
        self.notice = Some(format!("{reason} {LAST_GOOD}"));
        self.reload()
    }

    fn open(&self, href: &str) {
        if self.quiet {
            return;
        }
        let home = std::env::var_os("HOME").map(PathBuf::from);
        if let Some(target) = bridge::target(href, home.as_deref()) {
            bridge::open(&target);
        }
    }

    /// Asks the worker to end the session; `Note::Ended` tells how it went.
    pub fn end(&self) {
        self.tell(Message::End);
    }

    /// Gives the session back to its worker without waiting for it.
    pub fn release(&mut self) {
        if let Some(session) = self.session.take() {
            session.release();
        }
    }

    /// Gives the session back to its worker.
    pub fn close(&mut self) {
        if let Some(session) = self.session.take() {
            session.close();
        }
    }
}

fn tick_progress(alive: Weak<()>, emit: Emit) {
    thread::spawn(move || {
        while alive.upgrade().is_some() {
            emit(PaneEvent::ProgressTick);
            thread::sleep(progress::TICK);
        }
    });
}

fn web_view(window: &Window, store: &Arc<Store>, emit: &Emit) -> Result<WebView, String> {
    let files = store.clone();
    let from_page = emit.clone();
    let dropped = emit.clone();
    // Files dragged over the window are the composer's: WebKit would put their URL in the text or open them.
    let carrying_files = Cell::new(false);
    WebViewBuilder::new()
        .with_custom_protocol(template::SCHEME.into(), move |_, request| files.respond(request.uri().host(), request.uri().path()))
        .with_ipc_handler(move |request| {
            if bridge::is_template(&request.uri().to_string()) {
                from_page(PaneEvent::FromPage(request.into_body()));
            }
        })
        .with_drag_drop_handler(move |event| match event {
            DragDropEvent::Enter { paths, .. } => {
                carrying_files.set(!paths.is_empty());
                carrying_files.get()
            }
            DragDropEvent::Over { .. } => carrying_files.get(),
            DragDropEvent::Drop { paths, .. } if carrying_files.replace(false) => {
                let paths: Vec<String> = paths.iter().map(|path| path.to_string_lossy().into_owned()).collect();
                dropped(PaneEvent::FromPage(json!({"type": "dropped", "paths": paths}).to_string()));
                true
            }
            _ => carrying_files.replace(false),
        })
        .with_navigation_handler(|url| bridge::may_load(&url))
        // A window that is covered or on another desktop keeps following its session at full speed.
        .with_background_throttling(BackgroundThrottlingPolicy::Disabled)
        .with_url(template::HOME)
        .build(window)
        .map_err(|error| error.to_string())
}

/// The verb as the worker reads it: the first word, lower-cased, a plugin's `name:` prefix dropped.
pub fn is_frontend(text: &str) -> bool {
    let token = text.split_whitespace().next().unwrap_or_default().to_lowercase();
    let verb = format!("/{}", token.rsplit(':').next().unwrap_or_default().trim_matches('/'));
    text.starts_with('/') && FRONTEND_COMMANDS.contains(&verb.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_app_commands_from_the_worker() {
        let texts = ["/login claude", "/WINDOW ~/p", "/quit", "/vcx:exit", "/details", "/model claude", "/loginx", "login claude", "/compact"];

        let frontend: Vec<bool> = texts.iter().map(|text| is_frontend(text)).collect();

        assert_eq!(frontend, [true, true, true, true, true, false, false, false, false]);
    }
}
