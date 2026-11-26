//! The worker's live update: it replaces its own image with a newer build while its sessions and their agents go
//! on. The agents stay children of the same process, on the same pipes; the socket stays bound and locked, so a
//! frontend only loses its connection and attaches again.
//!
//! Between the freeze and the exec nothing else runs: the worker has one thread, and `attempt` never yields. What
//! was frozen is therefore exactly what the next image adopts, and an attempt that fails leaves this image as it
//! was. The next image is asked first whether it can adopt the manifest (`--adopt-check`): past the exec there is no
//! way back.

use crate::backend::carry;
use crate::channel::{self, Listener};
use crate::server::Server;
use serde_json::{Value, json};
use std::convert::Infallible;
use std::ffi::{CString, OsString};
use std::fs;
use std::io::Write;
use std::os::fd::RawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The manifest's format. An image adopts only the version it writes; a session's own fields may still differ
/// between two builds (`Session` starts a field it does not find at its default).
pub const MANIFEST_VERSION: u64 = 1;
pub const ADOPT: &str = "--adopt";
pub const ADOPT_CHECK: &str = "--adopt-check";
/// Under `--runtime-test`, the image to swap to instead of this worker's own path, as on the Swift worker.
const TEST_IMAGE: &str = "VCX_RUNTIME_SWAP_EXECUTABLE";
const CHECK_TIMEOUT: Duration = Duration::from_secs(10);
const CHECK_POLL: Duration = Duration::from_millis(2);
const PRIVATE_FILE: u32 = 0o600;
/// Signals this worker handles. Left to their default action between the exec and the next image's handlers, one
/// of them would end the worker with every agent.
const HELD_SIGNALS: [libc::c_int; 3] = [libc::SIGUSR1, libc::SIGTERM, libc::SIGINT];

/// Why an attempt did not replace this image.
#[derive(Debug, PartialEq)]
pub enum Attempt {
    /// Something is in flight that an exec would lose: worth trying again shortly.
    Busy,
    /// The next image cannot take over; this one goes on serving.
    Refused(String),
}

pub fn manifest_path(socket: &Path) -> PathBuf {
    PathBuf::from(format!("{}.swap.json", socket.display()))
}

/// Replaces this image with the newer build, or says why not. It returns only when it did not.
pub fn attempt(server: &Server, descriptors: (RawFd, RawFd), socket: &Path, test: bool) -> Attempt {
    let Some(mut state) = server.freeze() else { return Attempt::Busy };
    state["version"] = json!(MANIFEST_VERSION);
    state["listener"] = json!(descriptors.0);
    state["lock"] = json!(descriptors.1);
    let manifest = manifest_path(socket);
    let failed = write(&manifest, &state).and_then(|()| image(test)).and_then(|image| {
        asked(&image, &manifest)?;
        server.announce_swap();
        let failed = exec(&image, &manifest, &kept(&state, descriptors));
        server.close_peers();
        failed
    });
    let _ = fs::remove_file(&manifest);
    match failed {
        Err(reason) => Attempt::Refused(reason),
        Ok(never) => match never {},
    }
}

fn write(manifest: &Path, state: &Value) -> Result<(), String> {
    let _ = fs::remove_file(manifest);
    let written = fs::OpenOptions::new().write(true).create_new(true).mode(PRIVATE_FILE).open(manifest).and_then(|mut file| file.write_all(state.to_string().as_bytes()));
    written.map_err(|error| format!("Cannot write the update manifest: {error}"))
}

fn image(test: bool) -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os(TEST_IMAGE).filter(|_| test) {
        return Ok(PathBuf::from(path));
    }
    std::env::current_exe().map_err(|error| format!("Cannot find this worker's own image: {error}"))
}

/// This image's arguments without the ones a previous update added.
fn arguments() -> Vec<OsString> {
    let mut kept = Vec::new();
    let mut given = std::env::args_os();
    while let Some(argument) = given.next() {
        if argument == ADOPT || argument == ADOPT_CHECK {
            given.next();
        } else {
            kept.push(argument);
        }
    }
    kept
}

/// Asks the next image whether it can adopt the manifest. The wait is a blocking one on purpose (see the module).
fn asked(image: &Path, manifest: &Path) -> Result<(), String> {
    let refused = |reason: String| format!("{} cannot take over: {reason}", image.display());
    let mut check = Command::new(image);
    check.args(arguments().into_iter().skip(1)).arg(ADOPT_CHECK).arg(manifest).stdin(Stdio::null()).stdout(Stdio::null());
    let mut check = check.spawn().map_err(|error| refused(error.to_string()))?;
    let deadline = Instant::now() + CHECK_TIMEOUT;
    loop {
        match check.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => return Err(refused(status.to_string())),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(CHECK_POLL),
            outcome => {
                let _ = check.kill();
                let _ = check.wait();
                return Err(refused(outcome.err().map_or("it did not answer in time".to_owned(), |error| error.to_string())));
            }
        }
    }
}

/// The descriptors the next image goes on with: the socket, its lock and every carried agent's pipes.
fn kept(state: &Value, descriptors: (RawFd, RawFd)) -> Vec<RawFd> {
    let sessions = state["sessions"].as_array().into_iter().flatten();
    [descriptors.0, descriptors.1].into_iter().chain(sessions.flat_map(|session| carry::descriptors(&session["backend"]))).collect()
}

fn inherit(descriptors: &[RawFd], inherited: bool) {
    for descriptor in descriptors {
        // SAFETY: a flag change on a descriptor this worker holds open.
        unsafe { libc::fcntl(*descriptor, libc::F_SETFD, if inherited { 0 } else { libc::FD_CLOEXEC }) };
    }
}

fn hold_signals(held: bool) {
    // SAFETY: a signal set built and applied on this thread; the mask outlives the exec, which is the point.
    unsafe {
        let mut signals: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut signals);
        for signal in HELD_SIGNALS {
            libc::sigaddset(&mut signals, signal);
        }
        libc::pthread_sigmask(if held { libc::SIG_BLOCK } else { libc::SIG_UNBLOCK }, &signals, std::ptr::null_mut());
    }
}

/// Lets through the signals an exec held back, once this image has its handlers. Harmless when none was held.
pub fn release_signals() {
    hold_signals(false);
}

fn exec(image: &Path, manifest: &Path, kept: &[RawFd]) -> Result<Infallible, String> {
    let invalid = |_| "An argument of this worker holds a NUL byte.".to_owned();
    let mut arguments = arguments();
    arguments.extend([OsString::from(ADOPT), manifest.as_os_str().to_owned()]);
    let arguments: Vec<CString> = arguments.iter().map(|argument| CString::new(argument.as_bytes())).collect::<Result<_, _>>().map_err(invalid)?;
    let program = CString::new(image.as_os_str().as_bytes()).map_err(invalid)?;
    let mut pointers: Vec<*const libc::c_char> = arguments.iter().map(|argument| argument.as_ptr()).collect();
    pointers.push(std::ptr::null());
    hold_signals(true);
    inherit(kept, true);
    // SAFETY: `program` and `pointers` are NUL-terminated and outlive the call, which returns only on failure.
    unsafe { libc::execv(program.as_ptr(), pointers.as_ptr()) };
    let error = std::io::Error::last_os_error();
    inherit(kept, false);
    hold_signals(false);
    Err(format!("Cannot start {}: {error}", image.display()))
}

fn read(manifest: &Path) -> Result<Value, String> {
    let data = fs::read(manifest).map_err(|error| format!("Cannot read the update manifest: {error}"))?;
    let state: Value = serde_json::from_slice(&data).map_err(|error| format!("Invalid update manifest: {error}"))?;
    if state["version"] != MANIFEST_VERSION {
        return Err(format!("Update manifest version {} is not {MANIFEST_VERSION}.", state["version"]));
    }
    Ok(state)
}

/// `--adopt-check`: whether this image could adopt the manifest, as an exit status.
pub fn check(manifest: &Path) -> i32 {
    let checked = read(manifest).and_then(|state| state["sessions"].as_array().into_iter().flatten().try_for_each(|session| carry::check(&session["backend"])));
    match checked {
        Ok(()) => 0,
        Err(reason) => {
            eprintln!("{reason}");
            1
        }
    }
}

/// In the next image: the socket it goes on listening on, and what the previous image froze.
pub fn resume(manifest: &Path, socket: &Path) -> Result<(Listener, Value), String> {
    let state = read(manifest);
    let _ = fs::remove_file(manifest);
    let state = state?;
    let descriptor = |key: &str| state[key].as_i64().and_then(|value| RawFd::try_from(value).ok()).unwrap_or(-1);
    let listener = channel::adopt(socket, descriptor("listener"), descriptor("lock")).map_err(|error| format!("Cannot adopt the runtime socket: {error}"))?;
    Ok((listener, state))
}
