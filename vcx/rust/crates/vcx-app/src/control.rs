//! The app's control socket (`<state>/control.sock`): the command line and the tests ask the running app to open a
//! window, pass a message, move a window or report what it shows, one JSON line each way.

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::mpsc::{self, Sender};
use std::thread;
use std::time::Duration;

/// A report reads every window's page, so it may take a while with many windows.
const ANSWER_WAIT: Duration = Duration::from_secs(60);
const MAX_REQUEST_BYTES: u64 = 1_048_576;

pub struct Request {
    pub body: Value,
    pub answer: Sender<Value>,
}

/// Serves the socket on its own thread; each request goes to the event loop through `deliver`.
pub fn serve(socket: &Path, deliver: impl Fn(Request) + Send + Sync + 'static) -> Result<(), String> {
    let _ = std::fs::remove_file(socket);
    let listener = UnixListener::bind(socket).map_err(|error| format!("Cannot open {}: {error}.", socket.display()))?;
    std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600)).map_err(|error| error.to_string())?;
    let deliver = std::sync::Arc::new(deliver);
    thread::Builder::new()
        .name("vcx-control".into())
        .spawn(move || {
            for stream in listener.incoming().flatten() {
                let deliver = deliver.clone();
                // One thread per caller: a report that waits on pages never holds up a quick question.
                thread::spawn(move || answer(stream, &*deliver));
            }
        })
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn answer(stream: UnixStream, deliver: &dyn Fn(Request)) {
    let mut line = String::new();
    let Ok(reader) = stream.try_clone() else { return };
    if BufReader::new(reader.take(MAX_REQUEST_BYTES)).read_line(&mut line).is_err() {
        return;
    }
    let reply = match serde_json::from_str::<Value>(&line) {
        Ok(body) => {
            let (answer, answered) = mpsc::channel();
            deliver(Request { body, answer });
            answered.recv_timeout(ANSWER_WAIT).unwrap_or_else(|_| json!({"error": "The app did not answer in time."}))
        }
        Err(error) => json!({"error": format!("Not a JSON request: {error}.")}),
    };
    let mut stream = stream;
    let _ = stream.write_all(format!("{reply}\n").as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;
    use vcx_cli::control::ask;

    #[test]
    fn carries_a_request_to_the_app_and_its_answer_back() {
        let socket = std::env::temp_dir().join(format!("vcx-app-control-{}.sock", std::process::id()));
        serve(&socket, |request| drop(request.answer.send(json!({"echo": request.body["open"]["cwd"]})))).unwrap();

        let answer = ask(&socket, &json!({"open": {"cwd": "/tmp"}}));

        let _ = std::fs::remove_file(&socket);
        assert_eq!(answer, Some(json!({"echo": "/tmp"})));
    }

    #[test]
    fn says_no_app_answers_when_none_listens() {
        assert_eq!(ask(Path::new("/tmp/vcx-app-nobody.sock"), &json!({})), None);
    }
}
