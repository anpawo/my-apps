use crate::channel;
use crate::frame::{self, FrameDecoder, FrameError, Object};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fmt;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

pub const PROTOCOL_VERSION: i64 = 1;
pub const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
/// A window that closes does not wait on a worker that stopped answering.
pub const DETACH_TIMEOUT: Duration = Duration::from_secs(2);
const READ_CHUNK_BYTES: usize = 65_536;
/// Fault codes the worker raises before it records a sequence number: the same number is still free.
const NOT_ADMITTED: [&str; 7] = ["staleLease", "invalidAction", "closed", "sequenceGap", "busy", "unknownSession", "handshakeRequired"];

#[derive(Debug, Clone, PartialEq)]
pub struct Fault {
    pub code: String,
    pub message: String,
}

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    Frame(FrameError),
    Fault(Fault),
    Timeout,
    Disconnected,
    Invalid(&'static str),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "{error}"),
            Self::Frame(error) => write!(f, "{error}"),
            Self::Fault(fault) => write!(f, "{}", fault.message),
            Self::Timeout => write!(f, "The runtime did not answer in time."),
            Self::Disconnected => write!(f, "Runtime is disconnected."),
            Self::Invalid(what) => write!(f, "{what}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<FrameError> for Error {
    fn from(error: FrameError) -> Self {
        Self::Frame(error)
    }
}

/// What a worker sends without being asked.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Update { session_id: String, revision: u64, patch: Object },
    LeaseLost { session_id: String },
    Swapping,
    Disconnected,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Hello {
    pub build: String,
    pub instance_id: String,
    pub pid: i64,
}

#[derive(Debug, Clone, Default)]
pub struct AttachRequest {
    pub session_id: String,
    pub cwd: String,
    pub prompt: String,
    pub resume: Option<String>,
    pub existing_only: bool,
}

#[derive(Debug, Clone)]
pub struct Attachment {
    pub session_id: String,
    pub lease: String,
    pub revision: u64,
    pub last_sequence: u64,
    pub state: Object,
}

type Reply = Result<Object, Fault>;
type Pending = Arc<Mutex<HashMap<String, Sender<Reply>>>>;

pub struct Client {
    writer: Mutex<UnixStream>,
    pending: Pending,
    next_id: AtomicU64,
}

impl Client {
    pub fn connect(path: &Path, on_event: impl Fn(Event) + Send + 'static) -> Result<Self, Error> {
        Ok(Self::over(channel::connect(path)?, on_event)?)
    }

    /// Speaks the protocol over an already connected stream.
    pub fn over(stream: UnixStream, on_event: impl Fn(Event) + Send + 'static) -> io::Result<Self> {
        let reader = stream.try_clone()?;
        let pending = Pending::default();
        let routed = pending.clone();
        thread::Builder::new().name("vcx-runtime-reader".into()).spawn(move || read_loop(reader, routed, on_event))?;
        Ok(Self { writer: Mutex::new(stream), pending, next_id: AtomicU64::new(1) })
    }

    pub fn request(&self, method: &str, params: Value, timeout: Duration) -> Result<Object, Error> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed).to_string();
        let message = json!({"id": id, "method": method, "params": params});
        let data = frame::encode(message.as_object().expect("a JSON object literal"))?;
        let (sender, receiver) = mpsc::channel();
        self.pending.lock().unwrap().insert(id.clone(), sender);
        if let Err(error) = self.writer.lock().unwrap().write_all(&data) {
            self.pending.lock().unwrap().remove(&id);
            return Err(error.into());
        }
        match receiver.recv_timeout(timeout) {
            Ok(reply) => reply.map_err(Error::Fault),
            Err(RecvTimeoutError::Timeout) => {
                self.pending.lock().unwrap().remove(&id);
                Err(Error::Timeout)
            }
            Err(RecvTimeoutError::Disconnected) => Err(Error::Disconnected),
        }
    }

    pub fn hello(&self) -> Result<Hello, Error> {
        let reply = self.request("hello", json!({"protocol": PROTOCOL_VERSION}), HELLO_TIMEOUT)?;
        if reply.get("protocol").and_then(Value::as_i64) != Some(PROTOCOL_VERSION) {
            return Err(Error::Invalid("The frontend and runtime use incompatible protocols."));
        }
        Ok(Hello {
            build: text(&reply, "build").unwrap_or_default(),
            instance_id: text(&reply, "instanceID").unwrap_or_default(),
            pid: reply.get("pid").and_then(Value::as_i64).unwrap_or_default(),
        })
    }

    pub fn attach(&self, request: &AttachRequest) -> Result<Attachment, Error> {
        let mut params = json!({"sessionId": request.session_id, "cwd": request.cwd, "prompt": request.prompt, "existingOnly": request.existing_only});
        if let Some(resume) = &request.resume {
            params["resume"] = json!(resume);
        }
        let mut reply = self.request("attach", params, REQUEST_TIMEOUT)?;
        let invalid = Error::Invalid("The runtime returned an invalid session snapshot.");
        let (Some(lease), Some(revision), Some(Value::Object(state))) = (text(&reply, "lease"), reply.get("revision").and_then(Value::as_u64), reply.remove("state")) else {
            return Err(invalid);
        };
        Ok(Attachment {
            session_id: text(&reply, "sessionId").unwrap_or_else(|| request.session_id.clone()),
            lease,
            revision,
            last_sequence: reply.get("lastSequence").and_then(Value::as_u64).unwrap_or_default(),
            state,
        })
    }

    pub fn list(&self) -> Result<Vec<Value>, Error> {
        let mut reply = self.request("list", json!({}), REQUEST_TIMEOUT)?;
        match reply.remove("sessions") {
            Some(Value::Array(sessions)) => Ok(sessions),
            _ => Err(Error::Invalid("The runtime returned an invalid session list.")),
        }
    }
}

impl Drop for Client {
    /// The reader thread holds its own handle on the stream: without this it would wait on a connection nobody uses.
    fn drop(&mut self) {
        if let Ok(stream) = self.writer.lock() {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
    }
}

/// The right to write to one session, held by the last frontend that attached.
#[derive(Debug, Clone)]
pub struct Lease {
    pub session_id: String,
    pub lease: String,
    pub sequence: u64,
}

impl Lease {
    pub fn of(attachment: &Attachment) -> Self {
        Self { session_id: attachment.session_id.clone(), lease: attachment.lease.clone(), sequence: attachment.last_sequence }
    }

    pub fn perform(&mut self, client: &Client, action: &str, params: Value) -> Result<Object, Error> {
        let sequence = self.sequence + 1;
        let request = json!({"sessionId": self.session_id, "lease": self.lease, "sequence": sequence, "action": action, "params": params});
        let result = client.request("perform", request, REQUEST_TIMEOUT);
        let admitted = !matches!(&result, Err(Error::Fault(fault)) if NOT_ADMITTED.contains(&fault.code.as_str()));
        if admitted {
            self.sequence = sequence;
        }
        result
    }

    pub fn detach(self, client: &Client) -> Result<(), Error> {
        client.request("detach", json!({"sessionId": self.session_id, "lease": self.lease}), DETACH_TIMEOUT).map(|_| ())
    }
}

fn text(object: &Object, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn read_loop(mut stream: UnixStream, pending: Pending, on_event: impl Fn(Event)) {
    let mut decoder = FrameDecoder::default();
    let mut chunk = vec![0; READ_CHUNK_BYTES];
    'connection: loop {
        let count = match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(count) => count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        let Ok(frames) = decoder.push(&chunk[..count]) else { break 'connection };
        for message in frames {
            route(message, &pending, &on_event);
        }
    }
    let _ = stream.shutdown(std::net::Shutdown::Both);
    // Dropping every sender wakes each waiting request with Disconnected.
    pending.lock().unwrap().clear();
    on_event(Event::Disconnected);
}

fn route(mut message: Object, pending: &Pending, on_event: &impl Fn(Event)) {
    if let Some(id) = text(&message, "id") {
        let Some(sender) = pending.lock().unwrap().remove(&id) else { return };
        let reply = match message.remove("error") {
            Some(error) => Err(Fault {
                code: error.get("code").and_then(Value::as_str).unwrap_or("actionFailed").to_owned(),
                message: error.get("message").and_then(Value::as_str).unwrap_or("Runtime request failed.").to_owned(),
            }),
            None => Ok(match message.remove("result") {
                Some(Value::Object(result)) => result,
                _ => Object::new(),
            }),
        };
        let _ = sender.send(reply);
        return;
    }
    if let Some(event) = notification(message) {
        on_event(event);
    }
}

fn notification(mut message: Object) -> Option<Event> {
    let method = text(&message, "method")?;
    if method == "runtime/swapping" {
        return Some(Event::Swapping);
    }
    let Some(Value::Object(mut params)) = message.remove("params") else { return None };
    let session_id = text(&params, "sessionId")?;
    match method.as_str() {
        "session/leaseLost" => Some(Event::LeaseLost { session_id }),
        "session/update" => {
            let revision = params.get("revision").and_then(Value::as_u64)?;
            let Some(Value::Object(patch)) = params.remove("patch") else { return None };
            Some(Event::Update { session_id, revision, patch })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::sync::mpsc::Receiver;

    const WAIT: Duration = Duration::from_secs(5);

    /// A client wired to a scripted worker: the script answers each request it reads with the reply it returns.
    fn scripted(reply: impl Fn(&Object) -> Value + Send + 'static) -> (Client, Receiver<Event>) {
        let (near, far) = UnixStream::pair().unwrap();
        thread::spawn(move || {
            let mut writer = far.try_clone().unwrap();
            for line in BufReader::new(far).lines() {
                let Ok(line) = line else { break };
                let request: Object = serde_json::from_str(&line).unwrap();
                let mut answer = reply(&request);
                answer["id"] = request["id"].clone();
                writer.write_all(format!("{answer}\n").as_bytes()).unwrap();
            }
        });
        let (sender, events) = mpsc::channel();
        (Client::over(near, move |event| drop(sender.send(event))).unwrap(), events)
    }

    fn lease() -> Lease {
        Lease { session_id: "S".into(), lease: "L".into(), sequence: 7 }
    }

    #[test]
    fn returns_the_result_of_the_request_that_asked() {
        let (client, _events) = scripted(|request| json!({"result": {"echo": request["method"]}}));

        let reply = client.request("list", json!({}), WAIT).unwrap();

        assert_eq!(reply["echo"], "list");
    }

    #[test]
    fn turns_an_error_reply_into_a_fault() {
        let (client, _events) = scripted(|_| json!({"error": {"code": "unknownMethod", "message": "No such method."}}));

        let error = client.request("nope", json!({}), WAIT).unwrap_err();

        assert!(matches!(error, Error::Fault(fault) if fault.code == "unknownMethod" && fault.message == "No such method."));
    }

    #[test]
    fn refuses_a_worker_that_speaks_another_protocol() {
        let (client, _events) = scripted(|_| json!({"result": {"protocol": 2}}));

        let error = client.hello().unwrap_err();

        assert!(matches!(error, Error::Invalid(_)));
    }

    #[test]
    fn spends_the_sequence_number_once_the_worker_admitted_the_action() {
        let (client, _events) = scripted(|_| json!({"error": {"code": "actionFailed", "message": "The agent refused."}}));
        let mut lease = lease();

        let result = lease.perform(&client, "send", json!({"text": "hi"}));

        assert!(result.is_err());
        assert_eq!(lease.sequence, 8);
    }

    #[test]
    fn keeps_the_sequence_number_when_the_worker_did_not_admit_the_action() {
        let (client, _events) = scripted(|_| json!({"error": {"code": "busy", "message": "Too many actions."}}));
        let mut lease = lease();

        let result = lease.perform(&client, "send", json!({"text": "hi"}));

        assert!(result.is_err());
        assert_eq!(lease.sequence, 7);
    }

    #[test]
    fn hands_over_updates_then_reports_the_lost_connection() {
        let (near, mut far) = UnixStream::pair().unwrap();
        let (sender, events) = mpsc::channel();
        let _client = Client::over(near, move |event| drop(sender.send(event))).unwrap();

        far.write_all(b"{\"method\":\"session/update\",\"params\":{\"sessionId\":\"S\",\"revision\":3,\"patch\":{\"meta\":{\"busy\":true}}}}\n").unwrap();
        drop(far);

        let update = events.recv_timeout(WAIT).unwrap();
        assert!(matches!(update, Event::Update { ref session_id, revision: 3, ref patch } if session_id == "S" && patch["meta"]["busy"] == true));
        assert_eq!(events.recv_timeout(WAIT).unwrap(), Event::Disconnected);
    }

    #[test]
    fn stops_its_reader_when_dropped() {
        let (near, _far) = UnixStream::pair().unwrap();
        let (sender, events) = mpsc::channel();
        let client = Client::over(near, move |event| drop(sender.send(event))).unwrap();

        drop(client);

        assert_eq!(events.recv_timeout(WAIT).unwrap(), Event::Disconnected);
    }
}
