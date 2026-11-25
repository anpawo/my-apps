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
}
