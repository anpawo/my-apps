//! The commands the app runs itself (Swift `Session.command`'s frontend verbs): sign-in, a new window, closing.

use crate::app::{App, AppEvent, Open};
use crate::login;
use serde_json::Value;
use std::path::{Path, PathBuf};
use tao::event_loop::EventLoopWindowTarget;

#[derive(Debug, PartialEq)]
pub enum Local {
    SignIn(String),
    CancelSignIn,
    DismissSignIn,
    Window(PathBuf),
    Close,
    /// Said in the window's notice: a wrong use, or a command the page has no part for yet.
    Notice(String),
}

/// What `text` asks of the app in a session whose folder is `cwd`.
pub fn read(text: &str, cwd: &str, home: &str) -> Local {
    let (token, argument) = text.trim().split_once(char::is_whitespace).map_or((text.trim(), ""), |(token, argument)| (token, argument.trim()));
    let verb = format!("/{}", token.to_lowercase().rsplit(':').next().unwrap_or_default().trim_matches('/'));
    match verb.as_str() {
        "/login" => match argument {
            "cancel" => Local::CancelSignIn,
            "dismiss" => Local::DismissSignIn,
            provider if login::PROVIDERS.contains(&provider) => Local::SignIn(provider.to_owned()),
            _ => Local::Notice("Use /login claude, /login codex or /login cancel.".into()),
        },
        "/window" => {
            let folder = if argument.is_empty() { PathBuf::from(cwd) } else { resolved(argument, cwd, home) };
            if folder.is_dir() { Local::Window(folder) } else { Local::Notice("Directory does not exist.".into()) }
        }
        "/quit" | "/exit" => Local::Close,
        _ => Local::Notice(format!("{verb} is not in VCX Rust yet.")),
    }
}

/// `~` is his home, a relative path the session's folder.
fn resolved(path: &str, cwd: &str, home: &str) -> PathBuf {
    match path.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => Path::new(home).join(rest.trim_start_matches('/')),
        _ => Path::new(cwd).join(path),
    }
}

/// Runs it in window `key`; the app's exit code once its last window closed.
pub(crate) fn run(app: &mut App, target: &EventLoopWindowTarget<AppEvent>, key: u64, text: &str) -> Option<i32> {
    let win = app.windows.get(&key)?;
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
    match read(text, &win.cwd, &home) {
        Local::SignIn(provider) => {
            if app.login.as_ref().is_some_and(login::Running::is_running) {
                return None;
            }
            let proxy = app.proxy.clone();
            let start = login::Start { provider: &provider, shared: &app.homes.shared, home: Path::new(&home), program: None };
            match login::start(start, move |message| drop(proxy.send_event(AppEvent::Login(message)))) {
                Ok(running) => app.login = Some(running),
                Err(problem) => app.windows.get_mut(&key)?.pane.note(problem),
            }
        }
        Local::CancelSignIn => {
            if let Some(running) = &app.login {
                running.cancel();
            }
            app.show_login(login::message("", false));
        }
        Local::DismissSignIn => app.show_login(login::message("", false)),
        Local::Window(folder) => drop(app.new_session(target, Open { cwd: folder.to_string_lossy().into_owned(), focus: true, ..Open::default() })),
        Local::Close => return app.close_window(key),
        Local::Notice(text) => app.windows.get_mut(&key)?.pane.note(text),
    }
    None
}

/// The sign-in panel is the app's, shown in every window.
pub(crate) fn shown(message: &Value) -> bool {
    message["text"].as_str().is_some_and(|text| !text.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_sign_in_commands_and_says_how_to_use_them() {
        let read = |text: &str| read(text, "/", "/");

        let commands = [read("/login claude"), read("/login codex"), read("/login cancel"), read("/login dismiss"), read("/login")];

        assert_eq!(commands[..4], [Local::SignIn("claude".into()), Local::SignIn("codex".into()), Local::CancelSignIn, Local::DismissSignIn]);
        assert_eq!(commands[4], Local::Notice("Use /login claude, /login codex or /login cancel.".into()));
    }

    #[test]
    fn opens_a_window_in_the_folder_named_from_home_or_the_session_folder() {
        let root = std::env::temp_dir().join(format!("vcx-app-local-{}", std::process::id()));
        std::fs::create_dir_all(root.join("home/p")).unwrap();
        std::fs::create_dir_all(root.join("cwd/sub")).unwrap();
        let (home, cwd) = (root.join("home").to_string_lossy().into_owned(), root.join("cwd").to_string_lossy().into_owned());

        let opened = [read("/window ~/p", &cwd, &home), read("/window sub", &cwd, &home), read("/window", &cwd, &home), read("/window missing", &cwd, &home)];

        std::fs::remove_dir_all(&root).unwrap();
        assert_eq!(opened[..3], [Local::Window(root.join("home/p")), Local::Window(root.join("cwd/sub")), Local::Window(root.join("cwd"))]);
        assert_eq!(opened[3], Local::Notice("Directory does not exist.".into()));
    }

    #[test]
    fn closes_on_quit_and_exit_and_names_what_is_not_here_yet() {
        let read = |text: &str| read(text, "/", "/");

        assert_eq!([read("/quit"), read("/EXIT"), read("/vcx:quit")], [Local::Close, Local::Close, Local::Close]);
        assert_eq!(read("/preview"), Local::Notice("/preview is not in VCX Rust yet.".into()));
    }
}
