//! The app moving to a newly installed build (Swift `replaceFrontend`): `build-rust.sh --install` sends SIGUSR1, and
//! the app, its windows saved, execs the binary now at its own path. The workers outlive the old image, so the new one
//! reopens every window from `windows.json` on the same sessions, drafts included (the workers keep them).

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::sync::atomic::{AtomicBool, Ordering};

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

/// Replaces this image with the build at its own path; it returns only when that failed. No window or prompt is
/// passed on: the new image reopens the saved windows.
pub fn exec(windowless: bool) -> String {
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
    // SAFETY: `program` and `pointers` are NUL-terminated and outlive the call, which returns only on failure.
    unsafe { libc::execv(program.as_ptr(), pointers.as_ptr()) };
    format!("Cannot start {}: {}.", image.display(), std::io::Error::last_os_error())
}
