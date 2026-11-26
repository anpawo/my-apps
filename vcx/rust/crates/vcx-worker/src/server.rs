//! Protocol v1 as the Swift `RuntimeServer` serves it: the handshake, sessions held under a lease, actions admitted
//! once by sequence number with a receipt, and updates sent to the lease holder only.

use crate::channel::{self, Channel};
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::future::Future;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::pin::Pin;
use std::rc::{Rc, Weak};
use std::time::Duration;
use tokio::sync::watch;
use vcx_proto::Object;

pub const MAX_SESSIONS: usize = 256;
const MAX_PEERS: usize = MAX_SESSIONS * 2 + 32;
const MAX_SESSIONS_EVER: usize = 65_536;
pub const IDLE_GRACE: Duration = Duration::from_secs(5);
const MAX_ID_BYTES: usize = 128;
const MAX_METHOD_BYTES: usize = 64;
const MAX_ACTION_BYTES: usize = 64;
const MAX_CONTROL_BYTES: usize = 65_536;
const MAX_CONTROLS: usize = 8;
const MAX_REQUESTS: usize = 64;
const MAX_RECEIPTS: usize = 128;
const MAX_RECEIPT_BYTES: usize = 8 * 1024 * 1024;
const CONTROL_ACTIONS: [&str; 4] = ["answer", "stop", "close", "checkpoint"];
/// Actions that skip the queue of ordered ones: they must reach a session that is busy with the previous action.
const INTERRUPTING_ACTIONS: [&str; 3] = ["answer", "stop", "checkpoint"];

pub type Outcome = Result<Object, Fault>;
pub type Action = Pin<Box<dyn Future<Output = Result<Object, String>>>>;

#[derive(Debug, Clone, PartialEq)]
pub struct Fault {
    pub code: &'static str,
    pub message: String,
}

fn fault(code: &'static str, message: &str) -> Fault {
    Fault { code, message: message.to_owned() }
}

/// A session's runtime: the server owns its lease and receipts, the backend its conversation.
pub trait Backend {
    fn snapshot(&self) -> Object;
    fn perform(self: Rc<Self>, action: String, params: Object) -> Action;
    fn close(&self);
    fn set_on_change(&self, on_change: Option<Rc<dyn Fn(Object)>>);
    /// What the next image of the worker needs to go on with the session (a live update, `swap.rs`), or `None`
    /// while the session cannot leave this image. It changes nothing.
    fn freeze(&self) -> Option<Value> {
        None
    }
}

pub type Factory = Box<dyn Fn(&Object) -> Result<Rc<dyn Backend>, String>>;

struct Peer {
    channel: Rc<Channel>,
    ready: Cell<bool>,
    requests: Cell<usize>,
    controls: Cell<usize>,
}

struct Receipt {
    fingerprint: u64,
    control: bool,
    completed: Cell<bool>,
    bytes: Cell<usize>,
    outcome: watch::Sender<Option<Outcome>>,
}

impl Receipt {
    async fn wait(&self) -> Outcome {
        let mut receiver = self.outcome.subscribe();
        let value = receiver.wait_for(Option::is_some).await.map(|value| value.clone());
        value.ok().flatten().unwrap_or_else(|| Err(fault("actionFailed", "The action ended without a result.")))
    }
}

struct Entry {
    id: String,
    /// The runtime made for the session; `backend` once an attach bound it.
    creation: RefCell<Option<Rc<dyn Backend>>>,
    backend: RefCell<Option<Rc<dyn Backend>>>,
    writer: RefCell<Option<Rc<Channel>>>,
    lease: RefCell<String>,
    attachment: Cell<u64>,
    revision: Cell<u64>,
    last_sequence: Cell<u64>,
    receipts: RefCell<BTreeMap<u64, Rc<Receipt>>>,
    ordered: RefCell<Option<Rc<Receipt>>>,
    ended: Cell<bool>,
    close_sequence: Cell<Option<u64>>,
    close_completed: Cell<bool>,
}

impl Entry {
    fn new(id: String) -> Self {
        Self {
            id,
            creation: RefCell::default(),
            backend: RefCell::default(),
            writer: RefCell::default(),
            lease: RefCell::default(),
            attachment: Cell::new(0),
            revision: Cell::new(0),
            last_sequence: Cell::new(0),
            receipts: RefCell::default(),
            ordered: RefCell::default(),
            ended: Cell::new(false),
            close_sequence: Cell::new(None),
            close_completed: Cell::new(false),
        }
    }

    fn held_by(&self, channel: &Rc<Channel>) -> bool {
        self.writer.borrow().as_ref().is_some_and(|writer| Rc::ptr_eq(writer, channel))
    }
}

pub struct Server {
    build: String,
    instance_id: String,
    factory: Factory,
    on_empty: Box<dyn Fn()>,
    stopped: Cell<bool>,
    next_peer: Cell<u64>,
    peers: RefCell<HashMap<u64, Rc<Peer>>>,
    entries: RefCell<HashMap<String, Rc<Entry>>>,
    closed_ids: RefCell<HashSet<String>>,
    request_bytes: Cell<usize>,
    idle: Cell<u64>,
}

fn session_uuid(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?;
    uuid::Uuid::parse_str(text).ok().filter(|_| text.len() == 36).map(|id| id.to_string().to_uppercase())
}

fn fingerprint(action: &str, params: &Object) -> u64 {
    // serde_json keeps object keys sorted, so equal actions give equal bytes.
    let payload = serde_json::to_vec(&json!({"action": action, "params": params})).unwrap_or_default();
    let mut hasher = DefaultHasher::new();
    payload.hash(&mut hasher);
    hasher.finish()
}

impl Server {
    pub fn new(build: String, instance_id: String, factory: Factory, on_empty: Box<dyn Fn()>) -> Rc<Self> {
        Rc::new(Self {
            build,
            instance_id,
            factory,
            on_empty,
            stopped: Cell::new(false),
            next_peer: Cell::new(1),
            peers: RefCell::default(),
            entries: RefCell::default(),
            closed_ids: RefCell::default(),
            request_bytes: Cell::new(0),
            idle: Cell::new(0),
        })
    }

    /// What the next image of this worker needs to go on serving, or `None` while a request, an action or a frame
    /// is on its way: none of them survives an exec. Leases and receipts stay behind, as on the Swift worker: its
    /// frontends attach again, and a sequence already accepted is refused. It changes nothing.
    pub fn freeze(&self) -> Option<Value> {
        let idle = self.peers.borrow().values().all(|peer| peer.requests.get() == 0 && peer.channel.drained());
        if self.stopped.get() || !idle {
            return None;
        }
        let mut sessions = Vec::new();
        for entry in self.entries.borrow().values().filter(|entry| !entry.close_completed.get()) {
            let settled = !entry.ended.get() && entry.receipts.borrow().values().all(|receipt| receipt.completed.get());
            let backend = entry.backend.borrow().clone().filter(|_| settled)?;
            sessions.push(json!({"sessionId": entry.id, "revision": entry.revision.get(), "lastSequence": entry.last_sequence.get(), "backend": backend.freeze()?}));
        }
        let closed: Vec<String> = self.closed_ids.borrow().iter().cloned().collect();
        Some(json!({"sessions": sessions, "closedIDs": closed}))
    }

    /// Tells every frontend that the worker is about to continue in a new image, as the Swift worker does: told
    /// before its socket closes, a frontend attaches again without reporting a stopped runtime.
    pub fn announce_swap(&self) {
        let swapping = json!({"method": "runtime/swapping", "params": {}});
        for peer in self.peers.borrow().values() {
            peer.channel.send_now(swapping.as_object().expect("an object literal"));
        }
    }

    /// Closes every connection and keeps the sessions: frontends told of a swap that did not happen attach again.
    pub fn close_peers(&self) {
        let peers: Vec<Rc<Peer>> = self.peers.borrow().values().cloned().collect();
        for peer in peers {
            peer.channel.close();
        }
    }

    /// Takes over what a previous image froze. `backend` rebuilds a session's runtime; one it cannot rebuild is
    /// left out, and its frontend, finding it unknown, reopens it from its checkpoint.
    pub fn adopt(self: &Rc<Self>, state: &Value, backend: impl Fn(&str, &Value) -> Option<Rc<dyn Backend>>) {
        let closed = state["closedIDs"].as_array().into_iter().flatten().filter_map(Value::as_str);
        self.closed_ids.borrow_mut().extend(closed.map(str::to_owned));
        for session in state["sessions"].as_array().into_iter().flatten() {
            let id = session["sessionId"].as_str().unwrap_or_default();
            let Some(backend) = backend(id, &session["backend"]) else { continue };
            let entry = Rc::new(Entry::new(id.to_owned()));
            entry.revision.set(session["revision"].as_u64().unwrap_or(0));
            entry.last_sequence.set(session["lastSequence"].as_u64().unwrap_or(0));
            *entry.creation.borrow_mut() = Some(Rc::clone(&backend));
            self.bind(&backend, &entry);
            self.entries.borrow_mut().insert(id.to_owned(), entry);
        }
    }

    /// Accepts frontends until the server stops. A connection from another user is dropped before any read.
    pub async fn serve(self: Rc<Self>, listener: channel::Listener) {
        self.retire_when_idle();
        while !self.stopped.get() {
            let Ok((stream, _)) = listener.listener.accept().await else { continue };
            if self.stopped.get() {
                return;
            }
            if channel::peer_user(&stream).ok() != Some(unsafe { libc::geteuid() }) || self.peers.borrow().len() >= MAX_PEERS {
                continue;
            }
            self.accept(stream);
        }
    }

    fn accept(self: &Rc<Self>, stream: tokio::net::UnixStream) {
        let id = self.next_peer.replace(self.next_peer.get() + 1);
        let (receiving, closing) = (Rc::downgrade(self), Rc::downgrade(self));
        let channel = channel::start(
            stream,
            id,
            move |channel, message| {
                let Some(server) = receiving.upgrade() else { return };
                let peer = server.peers.borrow().get(&channel.id).cloned();
                if let Some(peer) = peer.filter(|_| !server.stopped.get()) {
                    server.receive(&peer, message);
                }
            },
            move |channel| {
                let Some(server) = closing.upgrade() else { return };
                server.peers.borrow_mut().remove(&channel.id);
                let entries: Vec<Rc<Entry>> = server.entries.borrow().values().cloned().collect();
                for entry in entries.iter().filter(|entry| entry.held_by(channel)) {
                    entry.writer.borrow_mut().take();
                    server.release_closed(entry);
                }
                server.check_empty();
            },
        );
        self.peers.borrow_mut().insert(id, Rc::new(Peer { channel, ready: Cell::new(false), requests: Cell::new(0), controls: Cell::new(0) }));
    }

    fn receive(self: &Rc<Self>, peer: &Rc<Peer>, message: Object) {
        let (Some(id), Some(method), Some(Value::Object(params))) = (message.get("id").and_then(Value::as_str), message.get("method").and_then(Value::as_str), message.get("params")) else {
            peer.channel.close();
            return;
        };
        if id.is_empty() || id.len() > MAX_ID_BYTES || method.len() > MAX_METHOD_BYTES {
            peer.channel.close();
            return;
        }
        let (id, method, params) = (id.to_owned(), method.to_owned(), params.clone());
        let bytes = serde_json::to_vec(&message).map_or(0, |data| data.len());
        let action = params.get("action").and_then(Value::as_str).unwrap_or_default();
        let control = method == "perform" && CONTROL_ACTIONS.contains(&action) && bytes <= MAX_CONTROL_BYTES;
        let room = if control { peer.controls.get() < MAX_CONTROLS } else { peer.requests.get() - peer.controls.get() < MAX_REQUESTS };
        let reserve = if control { 0 } else { MAX_CONTROL_BYTES };
        if !room || self.request_bytes.get() + bytes > channel::MAX_BUFFERED_BYTES - reserve {
            Self::fail(peer, &id, fault("busy", "Too many pending runtime requests."));
            return;
        }
        peer.requests.set(peer.requests.get() + 1);
        peer.controls.set(peer.controls.get() + usize::from(control));
        self.request_bytes.set(self.request_bytes.get() + bytes);
        let (server, peer) = (Rc::clone(self), Rc::clone(peer));
        tokio::task::spawn_local(async move {
            let outcome = server.handle(&peer, &method, params).await;
            match outcome {
                Ok(result) => {
                    if peer.channel.send(&json!({"id": id, "result": result}).as_object().cloned().unwrap_or_default()).is_err() {
                        peer.channel.close();
                    }
                }
                Err(error) => Self::fail(&peer, &id, error),
            }
            peer.requests.set(peer.requests.get() - 1);
            peer.controls.set(peer.controls.get() - usize::from(control));
            server.request_bytes.set(server.request_bytes.get() - bytes);
        });
    }

    fn fail(peer: &Peer, id: &str, error: Fault) {
        let message = json!({"id": id, "error": {"code": error.code, "message": error.message}});
        if peer.channel.send(message.as_object().expect("an object literal")).is_err() {
            peer.channel.close();
        }
    }

    async fn handle(self: &Rc<Self>, peer: &Rc<Peer>, method: &str, params: Object) -> Outcome {
        if self.stopped.get() {
            return Err(fault("closed", "The runtime is stopping."));
        }
        if method == "hello" {
            if params.get("protocol").and_then(Value::as_i64) != Some(1) {
                return Err(fault("protocolMismatch", "This frontend uses an incompatible runtime protocol."));
            }
            peer.ready.set(true);
            let hello = json!({
                "protocol": 1, "build": self.build, "instanceID": self.instance_id, "pid": std::process::id(),
                "maximumFrameBytes": vcx_proto::frame::MAX_FRAME_BYTES, "maximumBufferedBytes": channel::MAX_BUFFERED_BYTES,
                "maximumQueuedFrames": channel::MAX_QUEUED_FRAMES,
            });
            return Ok(hello.as_object().cloned().unwrap_or_default());
        }
        if !peer.ready.get() {
            return Err(fault("handshakeRequired", "Runtime hello must succeed before session requests."));
        }
        match method {
            "attach" => self.attach(peer, &params),
            "perform" => self.perform(peer, &params).await,
            "detach" => {
                let entry = self.writable(peer, &params)?;
                entry.writer.borrow_mut().take();
                entry.lease.borrow_mut().clear();
                self.release_closed(&entry);
                Ok(Object::new())
            }
            "list" => {
                let sessions: Vec<Value> = self
                    .entries
                    .borrow()
                    .values()
                    .map(|entry| json!({"sessionId": entry.id, "revision": entry.revision.get(), "lastSequence": entry.last_sequence.get(), "attached": entry.writer.borrow().is_some(), "ended": entry.ended.get()}))
                    .collect();
                Ok(json!({"sessions": sessions}).as_object().cloned().unwrap_or_default())
            }
            _ => Err(fault("unknownMethod", "Unknown runtime method.")),
        }
    }

    fn attach(self: &Rc<Self>, peer: &Rc<Peer>, params: &Object) -> Outcome {
        let invalid = || fault("invalidAttach", "Attach requires a session UUID and absolute working directory.");
        let session_id = session_uuid(params.get("sessionId")).ok_or_else(invalid)?;
        let cwd = params.get("cwd").and_then(Value::as_str).filter(|cwd| cwd.starts_with('/')).ok_or_else(invalid)?;
        if self.closed_ids.borrow().contains(&session_id) {
            return Err(fault("closed", "This runtime session has ended and cannot be reopened."));
        }
        let existing = self.entries.borrow().get(&session_id).cloned();
        let entry = match existing {
            Some(entry) => entry,
            None => {
                if params.get("existingOnly") == Some(&Value::Bool(true)) {
                    return Err(fault("unknownSession", "The running session is no longer available."));
                }
                let active = self.entries.borrow().values().filter(|entry| !entry.ended.get()).count();
                if active >= MAX_SESSIONS || active + self.closed_ids.borrow().len() >= MAX_SESSIONS_EVER {
                    return Err(fault("busy", "Runtime session capacity reached. Existing sessions remain available."));
                }
                if !std::path::Path::new(cwd).is_dir() {
                    return Err(fault("invalidAttach", "Session working directory is unavailable."));
                }
                let mut params = params.clone();
                params.insert("sessionId".into(), json!(session_id));
                let backend = (self.factory)(&params).map_err(|message| fault("actionFailed", &message))?;
                let entry = Rc::new(Entry::new(session_id.clone()));
                *entry.creation.borrow_mut() = Some(backend);
                self.entries.borrow_mut().insert(session_id.clone(), Rc::clone(&entry));
                entry
            }
        };
        entry.attachment.set(entry.attachment.get() + 1);
        let backend = entry.creation.borrow().clone().ok_or_else(|| fault("closed", "This runtime session has ended."))?;
        if self.stopped.get() || !self.peers.borrow().contains_key(&peer.channel.id) {
            if entry.backend.borrow().is_none() {
                self.release_unclaimed(&entry, backend, entry.attachment.get());
            }
            return Err(fault("superseded", "This attachment was superseded or disconnected."));
        }
        let lease = uuid::Uuid::new_v4().to_string().to_uppercase();
        let reply = json!({"sessionId": entry.id, "lease": lease, "revision": entry.revision.get(), "state": backend.snapshot(), "lastSequence": entry.last_sequence.get()});
        let size = serde_json::to_vec(&json!({"id": "", "result": reply})).map_or(usize::MAX, |data| data.len());
        if size > vcx_proto::frame::MAX_FRAME_BYTES {
            return Err(fault("snapshotTooLarge", "This conversation is too large to attach. Its current frontend remains connected."));
        }
        if entry.backend.borrow().is_none() {
            self.bind(&backend, &entry);
        }
        let previous = entry.writer.borrow().clone();
        if let Some(previous) = previous.filter(|previous| !Rc::ptr_eq(previous, &peer.channel)) {
            let _ = previous.send(json!({"method": "session/leaseLost", "params": {"sessionId": entry.id}}).as_object().expect("an object literal"));
        }
        *entry.writer.borrow_mut() = Some(Rc::clone(&peer.channel));
        *entry.lease.borrow_mut() = lease;
        // The reply is queued by the caller before this task yields, so no update can overtake the attachment.
        Ok(reply.as_object().cloned().unwrap_or_default())
    }

    // Its frontend left while the session started: unless an attach claims it within the grace, it closes.
    fn release_unclaimed(self: &Rc<Self>, entry: &Rc<Entry>, backend: Rc<dyn Backend>, attachment: u64) {
        let (server, entry) = (Rc::downgrade(self), Rc::clone(entry));
        tokio::task::spawn_local(async move {
            tokio::time::sleep(IDLE_GRACE).await;
            let Some(server) = server.upgrade() else { return };
            let current = server.entries.borrow().get(&entry.id).is_some_and(|current| Rc::ptr_eq(current, &entry));
            if server.stopped.get() || !current || entry.backend.borrow().is_some() || entry.attachment.get() != attachment {
                return;
            }
            server.entries.borrow_mut().remove(&entry.id);
            backend.close();
            server.check_empty();
        });
    }

    fn bind(self: &Rc<Self>, backend: &Rc<dyn Backend>, entry: &Rc<Entry>) {
        *entry.backend.borrow_mut() = Some(Rc::clone(backend));
        let (server, entry): (Weak<Self>, Weak<Entry>) = (Rc::downgrade(self), Rc::downgrade(entry));
        backend.set_on_change(Some(Rc::new(move |patch| {
            let (Some(server), Some(entry)) = (server.upgrade(), entry.upgrade()) else { return };
            if server.stopped.get() {
                return;
            }
            entry.revision.set(entry.revision.get() + 1);
            let writer = entry.writer.borrow().clone();
            if let Some(writer) = writer {
                let update = json!({"method": "session/update", "params": {"sessionId": entry.id, "revision": entry.revision.get(), "patch": patch}});
                if writer.send(update.as_object().expect("an object literal")).is_err() {
                    writer.close();
                }
            }
        })));
    }

    fn writable(&self, peer: &Peer, params: &Object) -> Result<Rc<Entry>, Fault> {
        let unknown = || fault("unknownSession", "Runtime session does not exist.");
        let session_id = session_uuid(params.get("sessionId")).ok_or_else(unknown)?;
        let Some(entry) = self.entries.borrow().get(&session_id).cloned() else {
            if self.closed_ids.borrow().contains(&session_id) {
                return Err(fault("closed", "This runtime session has ended."));
            }
            return Err(unknown());
        };
        let lease = params.get("lease").and_then(Value::as_str).unwrap_or_default();
        if !entry.held_by(&peer.channel) || lease.is_empty() || *entry.lease.borrow() != lease {
            return Err(fault("staleLease", "Another frontend owns this session. Reattach before writing."));
        }
        Ok(entry)
    }

    async fn perform(self: &Rc<Self>, peer: &Rc<Peer>, params: &Object) -> Outcome {
        let entry = self.writable(peer, params)?;
        let invalid = || fault("invalidAction", "Invalid runtime action.");
        let sequence = params.get("sequence").and_then(Value::as_u64).filter(|sequence| *sequence > 0).ok_or_else(invalid)?;
        let action = params.get("action").and_then(Value::as_str).filter(|action| !action.is_empty() && action.len() <= MAX_ACTION_BYTES).ok_or_else(invalid)?.to_owned();
        let arguments = params.get("params").and_then(Value::as_object).cloned().ok_or_else(invalid)?;
        let print = fingerprint(&action, &arguments);
        if entry.ended.get() && !(action == "close" && Some(sequence) == entry.close_sequence.get()) {
            return Err(fault("closed", "This runtime session has ended."));
        }
        if sequence <= entry.last_sequence.get() {
            let receipt = entry.receipts.borrow().get(&sequence).cloned();
            let receipt = receipt.ok_or_else(|| fault("alreadyAccepted", "This sequence was already accepted and its receipt has expired. It will not execute again."))?;
            if receipt.fingerprint != print {
                return Err(fault("sequenceConflict", "This sequence was already used for a different action."));
            }
            return receipt.wait().await;
        }
        if sequence != entry.last_sequence.get() + 1 {
            return Err(fault("sequenceGap", "Runtime actions must use the next sequence number."));
        }
        let backend = entry.backend.borrow().clone().filter(|_| !entry.ended.get()).ok_or_else(|| fault("closed", "This runtime session has ended."))?;
        let interrupts = INTERRUPTING_ACTIONS.contains(&action.as_str());
        let payload_bytes = serde_json::to_vec(&arguments).map_or(usize::MAX, |data| data.len());
        let small_control = (interrupts || action == "close") && payload_bytes <= MAX_CONTROL_BYTES;
        let pending = entry.receipts.borrow().values().filter(|receipt| !receipt.completed.get() && receipt.control == small_control).count();
        if pending >= if small_control { MAX_CONTROLS } else { MAX_REQUESTS } {
            return Err(fault("busy", "Too many pending session actions."));
        }
        let receipt = Rc::new(Receipt { fingerprint: print, control: small_control, completed: Cell::new(false), bytes: Cell::new(0), outcome: watch::channel(None).0 });
        let previous = if interrupts { None } else { entry.ordered.borrow().clone() };
        entry.last_sequence.set(sequence);
        entry.receipts.borrow_mut().insert(sequence, Rc::clone(&receipt));
        if action == "close" {
            entry.ended.set(true);
            entry.close_sequence.set(Some(sequence));
            self.closed_ids.borrow_mut().insert(entry.id.clone());
        }
        if !interrupts {
            *entry.ordered.borrow_mut() = Some(Rc::clone(&receipt));
        }
        // An admitted action belongs to the session, even when the socket that asked for it goes away.
        let (server, running, task_entry) = (Rc::clone(self), Rc::clone(&receipt), Rc::clone(&entry));
        tokio::task::spawn_local(async move {
            if let Some(previous) = previous {
                let _ = previous.wait().await;
            }
            let result = backend.perform(action.clone(), arguments).await;
            running.completed.set(true);
            let outcome = match result {
                Ok(result) => {
                    running.bytes.set(serde_json::to_vec(&result).map_or(0, |data| data.len()));
                    if action == "close" {
                        server.complete_close(&task_entry);
                    }
                    Ok(result)
                }
                Err(message) => {
                    if action == "close" {
                        task_entry.ended.set(false);
                        task_entry.close_sequence.set(None);
                        server.closed_ids.borrow_mut().remove(&task_entry.id);
                    }
                    Err(fault("actionFailed", &message))
                }
            };
            Self::prune(&task_entry);
            running.outcome.send_replace(Some(outcome));
        });
        receipt.wait().await
    }

    fn prune(entry: &Entry) {
        let mut receipts = entry.receipts.borrow_mut();
        let mut bytes: usize = receipts.values().map(|receipt| receipt.bytes.get()).sum();
        let sequences: Vec<u64> = receipts.keys().copied().collect();
        for sequence in sequences {
            if receipts.len() <= MAX_RECEIPTS && bytes <= MAX_RECEIPT_BYTES {
                break;
            }
            if receipts[&sequence].completed.get() {
                bytes -= receipts[&sequence].bytes.get();
                receipts.remove(&sequence);
            }
        }
    }

    fn complete_close(self: &Rc<Self>, entry: &Rc<Entry>) {
        let backend = entry.backend.borrow_mut().take();
        entry.creation.borrow_mut().take();
        if let Some(backend) = backend {
            backend.set_on_change(None);
            backend.close();
        }
        entry.ordered.borrow_mut().take();
        entry.close_completed.set(true);
        let keep = entry.close_sequence.get();
        entry.receipts.borrow_mut().retain(|sequence, _| Some(*sequence) == keep);
        self.release_closed(entry);
        self.check_empty();
    }

    fn release_closed(&self, entry: &Entry) {
        if entry.close_completed.get() && entry.writer.borrow().is_none() {
            self.entries.borrow_mut().remove(&entry.id);
        }
    }

    fn empty(&self) -> bool {
        !self.stopped.get() && self.peers.borrow().is_empty() && self.entries.borrow().values().all(|entry| entry.ended.get() && entry.close_completed.get())
    }

    fn check_empty(self: &Rc<Self>) {
        if !self.empty() {
            return;
        }
        if self.closed_ids.borrow().is_empty() {
            self.retire_when_idle();
        } else {
            (self.on_empty)();
        }
    }

    // A worker that never closed a session may be just spawned or between a frontend's attach retries: it retires
    // only once it has stayed without a session and a client for the whole grace.
    fn retire_when_idle(self: &Rc<Self>) {
        let generation = self.idle.get() + 1;
        self.idle.set(generation);
        let server = Rc::downgrade(self);
        tokio::task::spawn_local(async move {
            tokio::time::sleep(IDLE_GRACE).await;
            if let Some(server) = server.upgrade().filter(|server| server.idle.get() == generation && server.empty()) {
                (server.on_empty)();
            }
        });
    }

    /// Closes every connection and session; agents stop with their sessions.
    pub fn stop(&self) {
        if self.stopped.replace(true) {
            return;
        }
        for peer in self.peers.borrow_mut().drain().map(|(_, peer)| peer) {
            peer.channel.close();
        }
        for entry in self.entries.borrow_mut().drain().map(|(_, entry)| entry) {
            entry.backend.borrow_mut().take();
            if let Some(backend) = entry.creation.borrow_mut().take() {
                backend.set_on_change(None);
                backend.close();
            }
        }
    }
}
