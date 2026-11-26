//! The close confirmation (Swift `windowShouldClose`, `runningWork`, `closeAlert`): a window asks first while its agent
//! or a background task still runs.

use block2::RcBlock;
use objc2_app_kit::{NSAlert, NSAlertFirstButtonReturn, NSModalResponse, NSWindow};
use objc2_foundation::{MainThreadMarker, NSString};
use std::cell::Cell;
use tao::platform::macos::WindowExtMacOS;

pub const CLOSE_BUTTON: &str = "Close";
pub const QUIT_TITLE: &str = "Quit VCX Rust?";
pub const QUIT_BUTTON: &str = "Quit";
const CANCEL_BUTTON: &str = "Cancel";

/// Why closing a session would cut work short; none when it is idle.
pub fn running_work(busy: bool, background_tasks: usize) -> Option<String> {
    match background_tasks {
        0 if busy => Some("The agent is still working.".to_owned()),
        0 => None,
        1 => Some("A background task is still running.".to_owned()),
        count => Some(format!("{count} background tasks are still running.")),
    }
}

pub fn close_title(folder: &str) -> String {
    format!("Close {folder}?")
}

/// Whether a sheet (a close or quit question) waits on `window`.
pub fn asking(window: &tao::window::Window) -> bool {
    // SAFETY: tao hands the NSWindow it owns for as long as `window` lives, which outlasts this call.
    unsafe { (window.ns_window() as *const NSWindow).as_ref() }.is_some_and(|ns_window| ns_window.attachedSheet().is_some())
}

/// Shows the alert as a sheet on `window` without blocking the event loop; `then(true)` once `button` is chosen.
pub fn ask(window: &tao::window::Window, title: &str, detail: &str, button: &str, then: impl FnOnce(bool) + 'static) {
    let Some(mtm) = MainThreadMarker::new() else {
        eprintln!("vcx-rust: the confirmation needs the main thread");
        return then(false);
    };
    // SAFETY: tao hands the NSWindow it owns for as long as `window` lives, which outlasts this call.
    let Some(ns_window) = (unsafe { (window.ns_window() as *const NSWindow).as_ref() }) else { return then(false) };
    let alert = NSAlert::new(mtm);
    alert.setMessageText(&NSString::from_str(title));
    alert.setInformativeText(&NSString::from_str(detail));
    alert.addButtonWithTitle(&NSString::from_str(button));
    alert.addButtonWithTitle(&NSString::from_str(CANCEL_BUTTON));
    // AppKit types the handler as `Fn`, but it runs once: the cell hands `then` over on that call.
    let then = Cell::new(Some(then));
    let handler = RcBlock::new(move |response: NSModalResponse| {
        if let Some(then) = then.take() {
            then(response == NSAlertFirstButtonReturn);
        }
    });
    alert.beginSheetModalForWindow_completionHandler(ns_window, Some(&handler));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_no_work_when_the_session_is_idle() {
        let (busy, tasks) = (false, 0);

        let work = running_work(busy, tasks);

        assert_eq!(work, None);
    }

    #[test]
    fn says_the_agent_is_working_when_busy_without_background_tasks() {
        let (busy, tasks) = (true, 0);

        let work = running_work(busy, tasks);

        assert_eq!(work.as_deref(), Some("The agent is still working."));
    }

    #[test]
    fn names_one_background_task_in_the_singular_even_while_busy() {
        let (busy, tasks) = (true, 1);

        let work = running_work(busy, tasks);

        assert_eq!(work.as_deref(), Some("A background task is still running."));
    }

    #[test]
    fn counts_several_background_tasks() {
        let (busy, tasks) = (false, 3);

        let work = running_work(busy, tasks);

        assert_eq!(work.as_deref(), Some("3 background tasks are still running."));
    }

    #[test]
    fn titles_the_close_alert_with_the_folder() {
        let folder = "my-apps";

        let title = close_title(folder);

        assert_eq!(title, "Close my-apps?");
    }
}
