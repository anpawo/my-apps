//! The app moving to a newly installed build (Swift `replaceFrontend`): `build-rust.sh --install` sends SIGUSR1, and
//! the app, its windows saved, execs the binary now at its own path. The workers outlive the old image, so the new one
//! reopens every window from `windows.json` on the same sessions, drafts included (the workers keep them).

use std::ffi::{CString, OsStr};
use std::fs::File;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

/// The state folder's lock goes through the exec, open and held, under this name. Closed by the exec and taken again,
/// it was still held for a few milliseconds after the new image asked for it (3.8 and 6.3 ms measured under load, no
/// other process holding it): the new image quit as if another app ran, and every window stayed closed.
pub const LOCK_VARIABLE: &str = "VCX_RUST_APP_LOCK_FD";

static ASKED: AtomicBool = AtomicBool::new(false);

extern "C" fn asked(_: libc::c_int) {
    ASKED.store(true, Ordering::SeqCst);
}

/// From now on SIGUSR1 asks for a relaunch, which the app's next tick runs.
pub fn listen() {
    let handler: extern "C" fn(libc::c_int) = asked;
    // SAFETY: the handler only stores to an atomic, which is async-signal-safe.
    unsafe { libc::signal(libc::SIGUSR1, handler as libc::sighandler_t) };
}

pub fn requested() -> bool {
    ASKED.swap(false, Ordering::SeqCst)
}

/// Replaces this image with the build at its own path, handing it `lock`; it returns only when that failed. No window
/// or prompt is passed on: the new image reopens the saved windows.
pub fn exec(windowless: bool, lock: &File) -> String {
    let image = match std::env::current_exe() {
        Ok(image) => image,
        Err(error) => return format!("Cannot find the installed build: {error}."),
    };
    let Ok(program) = CString::new(image.as_os_str().as_bytes()) else { return "The app's path holds a NUL byte.".into() };
    let mut arguments = vec![program.clone()];
    if windowless {
        arguments.push(c"--windowless".to_owned());
    }
    let mut pointers: Vec<*const libc::c_char> = arguments.iter().map(|argument| argument.as_ptr()).collect();
    pointers.push(std::ptr::null());
    let descriptor = lock.as_raw_fd();
    let mut environment: Vec<CString> = std::env::vars_os()
        .filter(|(name, _)| name != OsStr::new(LOCK_VARIABLE))
        .filter_map(|(name, value)| CString::new([name.into_vec(), b"=".to_vec(), value.into_vec()].concat()).ok())
        .collect();
    environment.push(CString::new(format!("{LOCK_VARIABLE}={descriptor}")).unwrap());
    let mut variables: Vec<*const libc::c_char> = environment.iter().map(|variable| variable.as_ptr()).collect();
    variables.push(std::ptr::null());
    // SAFETY: F_SETFD only changes the flags of the app's own lock, kept open for the exec alone.
    unsafe { libc::fcntl(descriptor, libc::F_SETFD, 0) };
    // SAFETY: `program`, `pointers` and `variables` are NUL-terminated and outlive the call, which returns only on failure.
    unsafe { libc::execve(program.as_ptr(), pointers.as_ptr(), variables.as_ptr()) };
    let error = std::io::Error::last_os_error();
    // SAFETY: as above; the lock stays this image's.
    unsafe { libc::fcntl(descriptor, libc::F_SETFD, libc::FD_CLOEXEC) };
    format!("Cannot start {}: {error}.", image.display())
}

/// The lock the previous image handed over, still held, when this image is its relaunch and the descriptor is the
/// lock at `path`; called before the app starts any thread.
pub fn inherited_lock(path: &Path) -> Option<File> {
    let descriptor: RawFd = std::env::var(LOCK_VARIABLE).ok()?.parse().ok()?;
    // SAFETY: `run` calls this before it starts a thread, so nothing reads the environment meanwhile; the app's
    // children never see the number.
    unsafe { std::env::remove_var(LOCK_VARIABLE) };
    let expected = std::fs::metadata(path).ok()?;
    // SAFETY: fstat writes only into `status`; a descriptor that is not open fails.
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(descriptor, &mut status) } != 0 || status.st_dev as u64 != expected.dev() || status.st_ino != expected.ino() {
        return None;
    }
    // SAFETY: the descriptor is open on the lock file and nothing else in this image owns it.
    unsafe { libc::fcntl(descriptor, libc::F_SETFD, libc::FD_CLOEXEC) };
    Some(unsafe { File::from_raw_fd(descriptor) })
}
