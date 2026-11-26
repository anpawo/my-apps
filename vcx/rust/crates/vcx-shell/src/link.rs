//! The connection to one session's runtime worker, on its own thread so a slow reply never holds up the display.

use crate::session::Message;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::{self, JoinHandle};
use std::time::Duration;
use vcx_proto::{AttachRequest, Attachment, Client, Error, Lease};

/// A worker that moves to a new build closes its socket and opens it again within a few seconds.
const CONNECT_ATTEMPTS: u32 = 50;
const CONNECT_RETRY: Duration = Duration::from_millis(200);
const DISCONNECTED: &str = "The session runtime is disconnected.";

pub enum Command {
    Connect,
    /// Asks for a fresh snapshot on the connection already open.
    Attach,
    Perform { action: &'static str, params: Value },
    /// Ends the session: the worker saves its conversation and closes it.
    End,
    Close,
}

pub fn spawn(socket: PathBuf, request: AttachRequest, session: Sender<Message>) -> (Sender<Command>, JoinHandle<()>) {
    let (sender, commands) = mpsc::channel();
    let link = Link { socket, request, session, client: None, lease: None, attempt: 0 };
    let thread = thread::Builder::new().name("vcx-link".into()).spawn(move || link.run(commands)).expect("a thread for the runtime link");
    (sender, thread)
}

struct Link {
    socket: PathBuf,
    request: AttachRequest,
    session: Sender<Message>,
    client: Option<Client>,
    lease: Option<Lease>,
    /// Numbers each connection, so the session can tell a dropped old connection from the one in use.
    attempt: u64,
}

impl Link {
    fn run(mut self, commands: Receiver<Command>) {
        for command in commands {
            match command {
                Command::Connect => self.connect(),
                Command::Attach => self.attach(),
                Command::Perform { action, params } => self.perform(action, params),
                Command::End => self.end(),
                Command::Close => break,
            }
        }
        if let (Some(client), Some(lease)) = (&self.client, self.lease.take()) {
            let _ = lease.detach(client);
        }
    }

    fn tell(&self, message: Message) {
        let _ = self.session.send(message);
    }

    fn connect(&mut self) {
        let mut failure = String::new();
        for _ in 0..CONNECT_ATTEMPTS {
            self.attempt += 1;
            // Announced before the old connection is dropped, so its closing is not taken for the new one's.
            self.tell(Message::Connecting(self.attempt));
            self.lease = None;
            self.client = None;
            match self.open() {
                Ok(attachment) => return self.attached(attachment),
                // The worker answered and refused: asking again gets the same answer.
                Err(Error::Fault(fault)) => {
                    failure = fault.message;
                    break;
                }
                Err(error) => failure = error.to_string(),
            }
            thread::sleep(CONNECT_RETRY);
        }
        self.tell(Message::Attached(self.attempt, Err(failure)));
    }

    fn open(&mut self) -> Result<Attachment, Error> {
        let (session, attempt) = (self.session.clone(), self.attempt);
        let client = Client::connect(&self.socket, move |event| drop(session.send(Message::Worker(attempt, event))))?;
        client.hello()?;
        let attachment = client.attach(&self.request)?;
        self.client = Some(client);
        Ok(attachment)
    }

    fn attach(&mut self) {
        let Some(client) = &self.client else { return self.tell(Message::Attached(self.attempt, Err(DISCONNECTED.into()))) };
        match client.attach(&self.request) {
            Ok(attachment) => self.attached(attachment),
            Err(error) => self.tell(Message::Attached(self.attempt, Err(error.to_string()))),
        }
    }

    fn attached(&mut self, attachment: Attachment) {
        self.lease = Some(Lease::of(&attachment));
        // The first prompt and the thread to resume belong to the first attach only.
        self.request.prompt.clear();
        self.request.resume = None;
        self.tell(Message::Attached(self.attempt, Ok(attachment)));
    }

    fn perform(&mut self, action: &'static str, params: Value) {
        let (Some(client), Some(lease)) = (&self.client, &mut self.lease) else { return self.tell(Message::ActionFailed(DISCONNECTED.into())) };
        if let Err(error) = lease.perform(client, action, params) {
            self.tell(Message::ActionFailed(error.to_string()));
        }
    }

    /// Only the worker's refusal, or no answer, keeps the session: a worker that is gone has nothing left to save
    /// (Swift `beginClose`).
    fn end(&mut self) {
        let problem = match (&self.client, &mut self.lease) {
            (Some(client), Some(lease)) => match lease.perform(client, "close", Value::Object(Default::default())) {
                Err(Error::Fault(fault)) => Some(fault.message),
                Err(Error::Timeout) => Some(Error::Timeout.to_string()),
                _ => None,
            },
            _ => None,
        };
        self.tell(Message::Ended(problem));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;
    use std::path::Path;

    const WAIT: Duration = Duration::from_secs(10);
    /// The client connects only to a socket in a folder of the user's own, closed to others.
    const PRIVATE_FOLDER: u32 = 0o700;
    const PRIVATE_SOCKET: u32 = 0o600;

    /// A worker on its own socket that answers hello and attach, and the close with `close`.
    fn worker(name: &str, close: Value) -> PathBuf {
        let folder = PathBuf::from(format!("/tmp/vcx-link-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir(&folder).unwrap();
        std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
        let socket = folder.join("worker.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(PRIVATE_SOCKET)).unwrap();
        thread::spawn(move || {
            let Ok((stream, _)) = listener.accept() else { return };
            let mut writer = stream.try_clone().unwrap();
            for line in BufReader::new(stream).lines() {
                let Ok(line) = line else { break };
                let request: Value = serde_json::from_str(&line).unwrap();
                let mut answer = match request["method"].as_str() {
                    Some("hello") => json!({"result": {"protocol": vcx_proto::client::PROTOCOL_VERSION}}),
                    Some("attach") => json!({"result": {"lease": "L", "revision": 1, "state": {}}}),
                    Some("perform") if request["params"]["action"] == "close" => close.clone(),
                    _ => json!({"result": {}}),
                };
                answer["id"] = request["id"].clone();
                if writer.write_all(format!("{answer}\n").as_bytes()).is_err() {
                    break;
                }
            }
        });
        socket
    }

    fn ended(socket: &Path) -> Option<String> {
        let (session, messages) = mpsc::channel();
        let (link, _thread) = spawn(socket.to_owned(), AttachRequest { session_id: "S".into(), ..Default::default() }, session);
        link.send(Command::Connect).unwrap();
        link.send(Command::End).unwrap();
        let deadline = std::time::Instant::now() + WAIT;
        loop {
            match messages.recv_timeout(deadline.saturating_duration_since(std::time::Instant::now())) {
                Ok(Message::Ended(problem)) => {
                    let _ = std::fs::remove_dir_all(socket.parent().unwrap());
                    return problem;
                }
                Ok(_) => {}
                Err(error) => panic!("the link never said the session ended: {error}"),
            }
        }
    }

    #[test]
    fn keeps_the_session_when_the_worker_refuses_to_close_it_and_says_why() {
        let socket = worker("refused", json!({"error": {"code": "actionFailed", "message": "Could not save the current conversation."}}));

        let problem = ended(&socket);

        assert_eq!(problem.as_deref(), Some("Could not save the current conversation."));
    }

    #[test]
    fn ends_the_session_once_the_worker_closed_it() {
        let socket = worker("closed", json!({"result": {}}));

        let problem = ended(&socket);

        assert_eq!(problem, None);
    }
}
