//! What the cases share: a frontend connection, and one that holds a session.

use crate::Target;
use serde_json::{Value, json};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};
use vcx_model::{Applied, Replica, SessionState, view};
use vcx_proto::{AttachRequest, Attachment, Client, Error, Event, Lease, Object};
use vcx_testkit::session_id;

pub const WAIT: Duration = Duration::from_secs(30);
/// Long enough for a worker to send what it had in flight, short enough to wait for nothing on purpose.
pub const QUIET: Duration = Duration::from_millis(400);
const NOTICE: &str = "notice";

pub struct Peer {
    pub client: Client,
    pub events: Receiver<Event>,
}

impl Peer {
    /// Connected, `hello` not sent.
    pub fn connect(target: &Target) -> Self {
        let (sender, events) = mpsc::channel();
        let client = Client::connect(&target.socket, move |event| drop(sender.send(event))).expect("the worker accepts a connection");
        Self { client, events }
    }

    pub fn greeted(target: &Target) -> Self {
        let peer = Self::connect(target);
        peer.client.hello().expect("the worker answers hello");
        peer
    }

    pub fn request(&self, method: &str, params: Value) -> Result<Object, Error> {
        self.client.request(method, params, WAIT)
    }

    pub fn perform(&self, lease: &Lease, sequence: u64, action: &str, params: Value) -> Result<Object, Error> {
        self.request("perform", json!({"sessionId": lease.session_id, "lease": lease.lease, "sequence": sequence, "action": action, "params": params}))
    }

    /// The session's line in the worker's `list`.
    pub fn listed(&self, session_id: &str) -> Option<Value> {
        self.client.list().expect("the worker lists its sessions").into_iter().find(|session| session["sessionId"] == session_id)
    }

    /// Every event received until the worker stayed quiet.
    pub fn drain(&self) -> Vec<Event> {
        let mut events = Vec::new();
        while let Ok(event) = self.events.recv_timeout(QUIET) {
            events.push(event);
        }
        events
    }
}

/// The fault code a request was refused with.
pub fn fault<T: std::fmt::Debug>(result: Result<T, Error>) -> String {
    match result {
        Err(Error::Fault(fault)) => fault.code,
        other => panic!("expected a fault, got {other:?}"),
    }
}

pub fn request_for(target: &Target, session_id: &str) -> AttachRequest {
    AttachRequest { session_id: session_id.to_owned(), cwd: target.directory.to_str().expect("a UTF-8 folder").to_owned(), ..AttachRequest::default() }
}

/// A frontend holding one session, with its replica of the session's state.
pub struct Held {
    pub peer: Peer,
    pub attachment: Attachment,
    pub lease: Lease,
    pub replica: Replica,
}

impl Held {
    /// A new session, followed until its agent is ready.
    pub fn open(target: &Target) -> Self {
        let mut held = Self::attach(Peer::greeted(target), &request_for(target, &session_id()));
        held.follow(|state| state.meta.get("ready") == Some(&Value::Bool(true)));
        held
    }

    pub fn attach(peer: Peer, request: &AttachRequest) -> Self {
        let attachment = peer.client.attach(request).expect("the worker attaches the session");
        let mut replica = Replica::default();
        assert!(replica.snapshot(attachment.revision, &attachment.state), "the attach snapshot is a session state");
        Self { lease: Lease::of(&attachment), peer, attachment, replica }
    }

    pub fn id(&self) -> &str {
        &self.attachment.session_id
    }

    /// Applies updates in order until the state is the wanted one. An update that skips a revision fails the case.
    pub fn follow(&mut self, reached: impl Fn(&SessionState) -> bool) {
        let deadline = Instant::now() + WAIT;
        while !reached(self.replica.state().expect("a snapshot")) {
            let event = self.peer.events.recv_timeout(deadline.saturating_duration_since(Instant::now())).expect("the session never reached the wanted state");
            let Event::Update { revision, patch, .. } = event else { panic!("unexpected event: {event:?}") };
            assert!(matches!(self.replica.update(revision, patch), Applied::Changed(_)), "revision {revision} did not follow {}", self.replica.revision());
        }
    }

    /// Applies whatever the worker still sends until it stays quiet.
    pub fn settle(&mut self) {
        for event in self.peer.drain() {
            if let Event::Update { revision, patch, .. } = event {
                self.replica.update(revision, patch);
            }
        }
    }

    /// Sends a prompt with the next sequence and follows the fixture's turn to its answer.
    pub fn turn(&mut self, text: &str) {
        self.lease.perform(&self.peer.client, "send", prompt(text)).expect("the worker takes the prompt");
        self.follow(answered);
    }

    /// The kinds of the turn's rows. A notice is the worker's remark about its surroundings, not part of a turn:
    /// under a loaded machine the Swift worker adds one when its conversation refresh fails.
    pub fn kinds(&self) -> Vec<String> {
        let page = view::full(self.replica.state().expect("a snapshot"));
        let kinds = page["rows"].as_array().expect("rows").iter().map(|row| row["kind"].as_str().expect("a row kind").to_owned());
        kinds.filter(|kind| kind != NOTICE).collect()
    }
}

pub fn prompt(text: &str) -> Value {
    json!({"text": text, "images": []})
}

pub fn answered(state: &SessionState) -> bool {
    state.meta.get("busy") == Some(&Value::Bool(false)) && state.rows.iter().any(|row| row.kind == "assistant")
}

pub fn user_rows(state: &SessionState) -> usize {
    state.rows.iter().filter(|row| row.kind == "user").count()
}
