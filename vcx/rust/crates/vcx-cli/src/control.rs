//! The client side of the app's control socket (`<state>/control.sock`): one JSON line each way. The app serves it
//! (`vcx-app`'s `control::serve`).

use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

/// The app may read every window's page before it answers a report.
const CLIENT_WAIT: Duration = Duration::from_secs(90);

/// Asks the running app; `None` when no app answers on the socket.
pub fn ask(socket: &Path, body: &Value) -> Option<Value> {
    let mut stream = UnixStream::connect(socket).ok()?;
    stream.set_read_timeout(Some(CLIENT_WAIT)).ok()?;
    stream.write_all(format!("{body}\n").as_bytes()).ok()?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

/// The answer, or the app's own `error`, or that no app runs.
pub fn request(socket: &Path, body: &Value) -> Result<Value, String> {
    let answer = ask(socket, body).ok_or("No VCX Rust app is running.")?;
    match answer["error"].as_str() {
        Some(problem) => Err(problem.to_owned()),
        None => Ok(answer),
    }
}
