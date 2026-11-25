//! The workers of the app's sessions: one per session, each on its own socket in the app's runtime folder. A worker
//! outlives the app (it calls `setsid`), so a restarted app finds its sessions there again.

use vcx_config::Homes;
use crate::settings::Settings;
use std::fs::{self, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::Duration;
use vcx_proto::Client;

/// Unix socket paths are capped near 104 bytes: a socket is named by part of its session id, not all of it.
const SOCKET_NAME_CHARS: usize = 16;
const SOCKET_SUFFIX: &str = ".sock";
/// A worker the app started is reaped when it ends, checked this often.
const REAP_INTERVAL: Duration = Duration::from_secs(5);
/// The start lock is held until the new worker answers, so a second launch does not start another.
const START_WAIT: Duration = Duration::from_secs(15);
const START_POLL: Duration = Duration::from_millis(50);

#[derive(Debug, Clone, PartialEq)]
pub struct Running {
    pub socket: PathBuf,
    pub session_id: String,
    /// Another frontend holds it.
    pub attached: bool,
}

pub fn socket_for(homes: &Homes, session_id: &str) -> PathBuf {
    let name: String = session_id.chars().filter(char::is_ascii_hexdigit).take(SOCKET_NAME_CHARS).collect::<String>().to_lowercase();
    homes.runtime().join(name + SOCKET_SUFFIX)
}

/// Starts the worker of `socket` unless one already answers there. Two launches racing for it start one worker.
pub fn ensure(settings: &Settings, homes: &Homes, socket: &Path, cwd: &str) -> Result<Option<Child>, String> {
    if UnixStream::connect(socket).is_ok() {
        return Ok(None);
    }
    vcx_config::private_folder(&homes.runtime())?;
    let lock_path = PathBuf::from(format!("{}.launch.lock", socket.display()));
    let lock = OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).custom_flags(libc::O_NOFOLLOW).open(&lock_path).map_err(|error| format!("Cannot lock the worker's start: {error}."))?;
    // SAFETY: the descriptor is open for as long as `lock` lives; LOCK_NB never blocks.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        // Another launch is starting it: the link waits for the socket.
        return Ok(None);
    }
    if UnixStream::connect(socket).is_ok() {
        return Ok(None);
    }
    let _ = fs::remove_file(socket);
    let folder = if Path::new(cwd).is_dir() { cwd } else { "/" };
    let child = Command::new(&settings.worker)
        .arg("--runtime-worker")
        .arg(socket)
        .args(&settings.worker_arguments)
        .env("VCX_RUNTIME_HOME", homes.runtime())
        .env("VCX_STATE_HOME", homes.worker_state())
        .env("VCX_CONFIG_HOME", homes.worker_config())
        .env_remove("BUILD_STACK_FD")
        .current_dir(folder)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("Cannot start the session worker {}: {error}.", settings.worker.display()))?;
    let socket = socket.to_owned();
    thread::spawn(move || {
        let polls = START_WAIT.as_millis() / START_POLL.as_millis();
        for _ in 0..polls {
            if UnixStream::connect(&socket).is_ok() {
                break;
            }
            thread::sleep(START_POLL);
        }
        drop(lock);
    });
    Ok(Some(child))
}

/// Every session the app's workers hold, read by asking each socket in the runtime folder.
pub fn running(homes: &Homes) -> Vec<Running> {
    let Ok(entries) = fs::read_dir(homes.runtime()) else { return Vec::new() };
    let mut found = Vec::new();
    for entry in entries.flatten() {
        let socket = entry.path();
        if socket.extension().and_then(|extension| extension.to_str()) != Some(&SOCKET_SUFFIX[1..]) {
            continue;
        }
        let Ok(client) = Client::connect(&socket, |_| {}) else { continue };
        let Ok(sessions) = client.hello().and_then(|_| client.list()) else { continue };
        for session in sessions {
            let (Some(id), ended) = (session["sessionId"].as_str(), session["ended"].as_bool().unwrap_or(false)) else { continue };
            if !ended {
                found.push(Running { socket: socket.clone(), session_id: id.to_owned(), attached: session["attached"].as_bool().unwrap_or(false) });
            }
        }
    }
    found
}

/// Waits for the workers the app started, so one that ends leaves no zombie, on one thread for all of them.
pub struct Reaper(Sender<Child>);

impl Reaper {
    pub fn start() -> Self {
        let (sender, children) = mpsc::channel();
        thread::Builder::new().name("vcx-reaper".into()).spawn(move || reap(children)).expect("a thread for the reaper");
        Self(sender)
    }

    pub fn watch(&self, child: Child) {
        let _ = self.0.send(child);
    }
}

fn reap(children: Receiver<Child>) {
    let mut running: Vec<Child> = Vec::new();
    loop {
        match children.recv_timeout(REAP_INTERVAL) {
            Ok(child) => running.push(child),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }
        running.retain_mut(|child| matches!(child.try_wait(), Ok(None)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_a_socket_short_enough_for_a_unix_address() {
        let homes = Homes::under(Path::new("/Users/someone-with-a-long-name/.local/state/vcx-rust"));

        let socket = socket_for(&homes, "6A1F0C3E-9B2D-4E5F-8A7B-1C2D3E4F5A6B");

        assert_eq!(socket.file_name().unwrap(), "6a1f0c3e9b2d4e5f.sock");
        assert!(socket.as_os_str().len() < 104);
    }

    #[test]
    fn finds_no_session_where_no_worker_runs() {
        let homes = Homes::under(&std::env::temp_dir().join(format!("vcx-app-empty-{}", std::process::id())));

        assert_eq!(running(&homes), []);
    }
}
