//! The folder chip's panel (Swift `Views.setting` for `/dir `): a folder picked from the session's own folder moves the
//! session there.

use block2::RcBlock;
use objc2_app_kit::{NSModalResponse, NSModalResponseOK, NSOpenPanel};
use objc2_foundation::{MainThreadMarker, NSString, NSURL};
use std::path::PathBuf;

/// What the worker is asked once a folder is picked, as the Swift status bar asks it.
pub fn command(folder: &std::path::Path) -> String {
    format!("/dir {}", folder.display())
}

/// Shows the panel without blocking the event loop; `then` gets the folder picked, never a cancel.
pub fn choose(start: &str, then: impl Fn(PathBuf) + 'static) {
    let Some(mtm) = MainThreadMarker::new() else { return eprintln!("vcx-rust: the folder panel needs the main thread") };
    let panel = NSOpenPanel::openPanel(mtm);
    panel.setCanChooseDirectories(true);
    panel.setCanChooseFiles(false);
    panel.setDirectoryURL(Some(&NSURL::fileURLWithPath_isDirectory(&NSString::from_str(start), true)));
    let picked = panel.clone();
    let handler = RcBlock::new(move |response: NSModalResponse| {
        if response != NSModalResponseOK {
            return;
        }
        if let Some(path) = picked.URL().and_then(|url| url.path()) {
            then(PathBuf::from(path.to_string()));
        }
    });
    panel.beginWithCompletionHandler(&handler);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asks_the_worker_to_move_with_the_status_bar_command() {
        assert_eq!(command(std::path::Path::new("/Users/demo/projects/vcx")), "/dir /Users/demo/projects/vcx");
    }
}
