//! One session as the window sees it: a replica kept in step with the worker, turned into messages for the page.

use crate::link::{self, Command};
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::Duration;
use vcx_model::{Applied, Object, Replica, view};
use vcx_proto::{AttachRequest, Attachment, Event};

const CLOSE_WAIT: Duration = Duration::from_secs(3);
const CONNECTING: &str = "Connecting to the session runtime…";
const SWAPPING: &str = "The session runtime is moving to a new build…";
const TAKEN: &str = "This session was opened in another window.";
const DEMO: &str = "This is a saved session: nothing is connected.";

pub enum Source {
    /// A saved session state, shown with no worker behind it.
    Demo(PathBuf),
    Worker { socket: PathBuf, request: AttachRequest },
}

pub enum Message {
    PageReady,
    /// The page is reloading: nothing reaches it until it reports ready again.
    PageGone,
    Act { action: &'static str, params: Value },
    Connecting(u64),
    Worker(u64, Event),
    Attached(u64, Result<Attachment, String>),
    ActionFailed(String),
    Close,
}

#[derive(Debug, PartialEq)]
pub enum Output {
    /// A message for the page, numbered so the page can say which one it has drawn.
    Page(Value),
    /// The session reached the state a check waits for, as of this page message.
    Settled(u64),
    Closed(String),
}

pub struct Handle {
    sender: Sender<Message>,
    closed: Receiver<()>,
}

impl Handle {
    pub fn send(&self, message: Message) {
        let _ = self.sender.send(message);
    }

    /// Gives the session back to its worker, without waiting long on a worker that stopped answering.
    pub fn close(self) {
        self.send(Message::Close);
        let _ = self.closed.recv_timeout(CLOSE_WAIT);
    }
}

pub fn spawn(source: Source, wait_for_answer: bool, emit: impl Fn(Output) + Send + 'static) -> Result<Handle, String> {
    let (sender, messages) = mpsc::channel();
    let mut session = Session::new(None, wait_for_answer, emit);
    let mut link_thread = None;
    match source {
        Source::Demo(path) => session.show(&saved_state(&path)?),
        Source::Worker { socket, request } => {
            let (link, thread) = link::spawn(socket, request, sender.clone());
            let _ = link.send(Command::Connect);
            session.link = Some(link);
            link_thread = Some(thread);
        }
    }
    let (done, closed) = mpsc::channel();
    let run = move || {
        for message in messages {
            if matches!(message, Message::Close) {
                break;
            }
            session.handle(message);
        }
        if let (Some(link), Some(thread)) = (session.link.take(), link_thread) {
            let _ = link.send(Command::Close);
            let _ = thread.join();
        }
        let _ = done.send(());
    };
    thread::Builder::new().name("vcx-session".into()).spawn(run).map_err(|error| error.to_string())?;
    Ok(Handle { sender, closed })
}

fn saved_state(path: &PathBuf) -> Result<Object, String> {
    let text = fs::read_to_string(path).map_err(|error| format!("Cannot read {}: {error}.", path.display()))?;
    serde_json::from_str(&text).map_err(|error| format!("{} is not a session state: {error}.", path.display()))
}

struct Session<E> {
    emit: E,
    replica: Replica,
    link: Option<Sender<Command>>,
    /// The connection in use, as the link numbers them.
    connection: u64,
    attached: bool,
    /// A connection that closed before its attach was known here.
    dropped: Option<u64>,
    page_ready: bool,
    serial: u64,
    link_state: Option<Value>,
    wait_for_answer: bool,
    settled: bool,
}

impl<E: Fn(Output)> Session<E> {
    fn new(link: Option<Sender<Command>>, wait_for_answer: bool, emit: E) -> Self {
        Self { emit, replica: Replica::default(), link, connection: 0, attached: false, dropped: None, page_ready: false, serial: 0, link_state: None, wait_for_answer, settled: false }
    }

    fn show(&mut self, state: &Object) {
        self.replica.snapshot(0, state);
    }

    fn handle(&mut self, message: Message) {
        match message {
            Message::PageReady => {
                self.page_ready = true;
                self.full();
            }
            Message::PageGone => self.page_ready = false,
            Message::Act { action, params } => match &self.link {
                Some(link) => drop(link.send(Command::Perform { action, params })),
                None => self.page(json!({"type": "notice", "text": DEMO})),
            },
            Message::Connecting(connection) => {
                self.connection = connection;
                self.attached = false;
                self.replica.detach();
                self.link_is("reconnecting", CONNECTING);
            }
            Message::Worker(connection, event) if connection == self.connection => self.worker(event),
            Message::Worker(..) => {}
            Message::Attached(connection, _) if connection != self.connection => {}
            Message::Attached(connection, Ok(_)) if self.dropped == Some(connection) => self.ask(Command::Connect),
            Message::Attached(_, Ok(attachment)) => self.attach(&attachment),
            Message::Attached(_, Err(problem)) => self.link_is("lost", &problem),
            Message::ActionFailed(problem) => self.page(json!({"type": "notice", "text": problem})),
            Message::Close => {}
        }
    }

    fn worker(&mut self, event: Event) {
        match event {
            Event::Update { revision, patch, .. } => match self.replica.update(revision, patch) {
                Applied::Changed(changes) => {
                    let state = self.replica.state().expect("a replica that applied a patch holds a state");
                    let view = view::patch(state, &changes);
                    if view.as_object().is_some_and(|fields| !fields.is_empty()) {
                        self.page(typed("patch", view));
                    }
                    self.settle();
                }
                Applied::Gap => self.resync(),
                Applied::Early | Applied::Stale => {}
            },
            Event::LeaseLost { .. } => (self.emit)(Output::Closed(TAKEN.into())),
            Event::Swapping => self.link_is("reconnecting", SWAPPING),
            Event::Disconnected if self.attached => {
                self.attached = false;
                self.replica.detach();
                self.ask(Command::Connect);
            }
            Event::Disconnected => self.dropped = Some(self.connection),
        }
    }

    fn attach(&mut self, attachment: &Attachment) {
        self.attached = true;
        if !self.replica.snapshot(attachment.revision, &attachment.state) {
            return self.resync();
        }
        self.link_is("connected", "");
        self.full();
    }

    /// The replica missed a revision: only a new snapshot puts it back in step.
    fn resync(&mut self) {
        self.replica.detach();
        self.ask(Command::Attach);
    }

    fn ask(&self, command: Command) {
        if let Some(link) = &self.link {
            let _ = link.send(command);
        }
    }

    fn link_is(&mut self, state: &str, detail: &str) {
        let message = json!({"type": "link", "state": state, "detail": detail});
        self.link_state = (state != "connected").then(|| message.clone());
        self.page(message);
    }

    fn full(&mut self) {
        if let Some(state) = self.replica.state() {
            self.page(typed("full", view::full(state)));
        }
        if let Some(message) = self.link_state.clone() {
            self.page(message);
        }
        self.settle();
    }

    fn page(&mut self, mut message: Value) {
        if !self.page_ready {
            return;
        }
        self.serial += 1;
        message["serial"] = json!(self.serial);
        (self.emit)(Output::Page(message));
    }

    fn settle(&mut self) {
        let Some(state) = self.replica.state() else { return };
        let answered = state.meta.get("busy") != Some(&Value::Bool(true)) && state.rows.iter().any(|row| row.kind == "assistant");
        if self.settled || !self.page_ready || (self.wait_for_answer && !answered) {
            return;
        }
        self.settled = true;
        (self.emit)(Output::Settled(self.serial));
    }
}

fn typed(kind: &str, mut view: Value) -> Value {
    view["type"] = json!(kind);
    view
}

#[cfg(test)]
mod tests {
    use super::*;

    type Outputs = Receiver<Output>;

    fn session(wait_for_answer: bool) -> (Session<impl Fn(Output)>, Outputs, Receiver<Command>) {
        let (outputs, emitted) = mpsc::channel();
        let (link, commands) = mpsc::channel();
        (Session::new(Some(link), wait_for_answer, move |output| drop(outputs.send(output))), emitted, commands)
    }

    fn object(value: Value) -> Object {
        value.as_object().unwrap().clone()
    }

    fn attachment(revision: u64) -> Attachment {
        let state = object(json!({"busy": true, "rows": [{"id": "R1", "kind": "user", "items": [{"id": "u1", "type": "userMessage", "content": [{"type": "text", "text": "hi"}]}]}]}));
        Attachment { session_id: "S".into(), lease: "L".into(), revision, last_sequence: 0, state }
    }

    fn answer(revision: u64, busy: bool) -> Message {
        let patch = object(json!({
            "meta": {"busy": busy},
            "items": [{"id": "a1", "type": "agentMessage", "text": "yes"}],
            "rowUpdates": [{"id": "R2", "kind": "assistant", "itemIDs": ["a1"]}],
            "rowOrder": ["R1", "R2"]
        }));
        Message::Worker(1, Event::Update { session_id: "S".into(), revision, patch })
    }

    fn attached(session: &mut Session<impl Fn(Output)>, revision: u64) {
        session.handle(Message::Connecting(1));
        session.handle(Message::Attached(1, Ok(attachment(revision))));
        session.handle(Message::PageReady);
    }

    fn pages(outputs: &Outputs) -> Vec<Value> {
        outputs.try_iter().filter_map(|output| if let Output::Page(page) = output { Some(page) } else { None }).collect()
    }

    #[test]
    fn sends_the_whole_session_once_the_page_is_ready() {
        let (mut session, outputs, _commands) = session(false);
        session.handle(Message::Connecting(1));
        session.handle(Message::Attached(1, Ok(attachment(4))));
        let before_ready = pages(&outputs);

        session.handle(Message::PageReady);

        let sent = pages(&outputs);
        assert_eq!(before_ready, Vec::<Value>::new());
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0]["type"], "full");
        assert_eq!(sent[0]["serial"], 1);
        assert_eq!(sent[0]["rows"][0]["items"][0]["text"], "hi");
    }

    #[test]
    fn sends_only_what_an_update_changed() {
        let (mut session, outputs, _commands) = session(false);
        attached(&mut session, 4);
        pages(&outputs);

        session.handle(answer(5, true));

        let sent = pages(&outputs);
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0]["type"], "patch");
        assert_eq!(sent[0]["order"], json!(["R1", "R2"]));
        assert_eq!(sent[0]["rows"].as_array().unwrap().len(), 1);
        assert_eq!(sent[0]["rows"][0]["items"][0]["html"], "<p>yes</p>\n");
    }

    #[test]
    fn asks_for_a_fresh_snapshot_when_a_revision_is_missing() {
        let (mut session, _outputs, commands) = session(false);
        attached(&mut session, 4);

        session.handle(answer(6, true));

        assert!(matches!(commands.try_recv(), Ok(Command::Attach)));
    }

    #[test]
    fn reconnects_when_the_connection_in_use_closes() {
        let (mut session, _outputs, commands) = session(false);
        attached(&mut session, 4);

        session.handle(Message::Worker(1, Event::Disconnected));

        assert!(matches!(commands.try_recv(), Ok(Command::Connect)));
    }

    #[test]
    fn ignores_the_closing_of_a_connection_already_replaced() {
        let (mut session, _outputs, commands) = session(false);
        attached(&mut session, 4);
        session.handle(Message::Connecting(2));

        session.handle(Message::Worker(1, Event::Disconnected));

        assert!(commands.try_recv().is_err());
    }

    #[test]
    fn reconnects_when_the_connection_closed_before_its_attach_arrived() {
        let (mut session, _outputs, commands) = session(false);
        session.handle(Message::Connecting(1));
        session.handle(Message::Worker(1, Event::Disconnected));

        session.handle(Message::Attached(1, Ok(attachment(4))));

        assert!(matches!(commands.try_recv(), Ok(Command::Connect)));
    }

    #[test]
    fn reports_the_answer_only_once_the_turn_is_over() {
        let (mut session, outputs, _commands) = session(true);
        attached(&mut session, 4);
        session.handle(answer(5, true));
        let while_busy: Vec<Output> = outputs.try_iter().filter(|output| matches!(output, Output::Settled(_))).collect();

        session.handle(answer(6, false));

        let after: Vec<Output> = outputs.try_iter().filter(|output| matches!(output, Output::Settled(_))).collect();
        assert_eq!(while_busy, []);
        assert_eq!(after, [Output::Settled(3)]);
    }

    #[test]
    fn closes_when_another_window_takes_the_session() {
        let (mut session, outputs, _commands) = session(false);
        attached(&mut session, 4);

        session.handle(Message::Worker(1, Event::LeaseLost { session_id: "S".into() }));

        assert!(outputs.try_iter().any(|output| output == Output::Closed(TAKEN.into())));
    }

    #[test]
    fn tells_the_page_when_an_action_has_no_worker_behind_it() {
        let (outputs, emitted) = mpsc::channel();
        let mut session = Session::new(None, false, move |output| drop(outputs.send(output)));
        session.show(&attachment(0).state);
        session.handle(Message::PageReady);
        pages(&emitted);

        session.handle(Message::Act { action: "send", params: json!({"text": "hi", "images": []}) });

        assert_eq!(pages(&emitted)[0]["text"], DEMO);
    }
}
