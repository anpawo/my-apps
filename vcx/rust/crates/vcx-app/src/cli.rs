//! The command line, in the words of the Swift `vcx`: `--cwd`, `--resume`, a first prompt, `--sessions`, `--send`,
//! `--set-dir`, `-p`; and `--windowless` for checks.

use crate::app::Open;
use std::path::{Path, PathBuf};

pub const USAGE: &str = "usage: vcx-rust [--cwd FOLDER] [--resume [ID]] [--focus] [--windowless] [PROMPT…]
       vcx-rust --sessions
       vcx-rust --send <window id or name> [--from <window id or name>] <message… | ->
       vcx-rust --set-dir <window id or name> <folder>
       vcx-rust -p [background options…] [PROMPT]";
const VERSION: &str = concat!("vcx-rust ", env!("CARGO_PKG_VERSION"), " (VCX Rust)");

#[derive(Debug, PartialEq)]
pub enum Command {
    /// Opens a window for `open`, in the running app or in a new one. `None`: only the last run's windows.
    App { open: Option<Open>, windowless: bool },
    Sessions,
    Send { to: String, from: Option<String>, text: String },
    SetDir { to: String, path: PathBuf },
    /// Runs the background job runner (`background.py`) with these arguments.
    Background(Vec<String>),
    Version,
    Help,
}

pub fn parse(arguments: &[String], cwd: &Path) -> Result<Command, String> {
    match arguments.first().map(String::as_str) {
        Some("--sessions") => return Ok(Command::Sessions),
        Some("--send") => return send(&arguments[1..]),
        Some("--set-dir") => return set_dir(&arguments[1..], cwd),
        Some("--version") => return Ok(Command::Version),
        Some("--help") => return Ok(Command::Help),
        _ => {}
    }
    if arguments.iter().any(|argument| matches!(argument.as_str(), "-p" | "--print" | "--headless")) {
        return Ok(Command::Background(arguments.to_vec()));
    }
    app(arguments, cwd)
}

fn app(arguments: &[String], cwd: &Path) -> Result<Command, String> {
    let (mut open, mut asked, mut windowless, mut words) = (Open { cwd: cwd.to_string_lossy().into_owned(), ..Open::default() }, false, false, Vec::new());
    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].as_str();
        match argument {
            "--cwd" | "-C" => {
                index += 1;
                let folder = arguments.get(index).ok_or("--cwd requires a folder.")?;
                open.cwd = absolute(folder, cwd).to_string_lossy().into_owned();
                asked = true;
            }
            "--resume" | "-r" => {
                let id = arguments.get(index + 1).filter(|next| !next.starts_with('-'));
                index += usize::from(id.is_some());
                open.resume = Some(id.cloned().unwrap_or_else(|| "last".into()));
                asked = true;
            }
            "--focus" => open.focus = true,
            "--windowless" => windowless = true,
            "--" => {
                words.extend(arguments[index + 1..].iter().cloned());
                break;
            }
            _ if argument.starts_with('-') => return Err(format!("Unknown option: {argument}")),
            _ => words.push(argument.to_owned()),
        }
        index += 1;
    }
    open.prompt = words.join(" ");
    asked |= !open.prompt.is_empty();
    if asked && !Path::new(&open.cwd).is_dir() {
        return Err("Working folder does not exist.".into());
    }
    Ok(Command::App { open: asked.then_some(open), windowless })
}

fn send(arguments: &[String]) -> Result<Command, String> {
    let (mut from, mut words, mut index) = (None, Vec::new(), 0);
    while index < arguments.len() {
        if arguments[index] == "--from" && index + 1 < arguments.len() {
            from = Some(arguments[index + 1].clone());
            index += 2;
            continue;
        }
        words.push(arguments[index].clone());
        index += 1;
    }
    if words.len() < 2 {
        return Err("--send needs a window and a message.".into());
    }
    Ok(Command::Send { to: words[0].clone(), from, text: words[1..].join(" ") })
}

fn set_dir(arguments: &[String], cwd: &Path) -> Result<Command, String> {
    let [to, folder] = arguments else { return Err("--set-dir needs a window and a folder.".into()) };
    let path = absolute(folder, cwd);
    let path = path.canonicalize().map_err(|_| format!("{} is not a folder.", path.display()))?;
    if !path.is_dir() {
        return Err(format!("{} is not a folder.", path.display()));
    }
    Ok(Command::SetDir { to: to.clone(), path })
}

fn absolute(folder: &str, cwd: &Path) -> PathBuf {
    let expanded = match folder.strip_prefix('~') {
        Some(rest) => PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(rest.trim_start_matches('/')),
        None => PathBuf::from(folder),
    };
    cwd.join(expanded)
}

pub fn version() -> &'static str {
    VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_words(words: &[&str]) -> Result<Command, String> {
        parse(&words.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>(), Path::new("/tmp"))
    }

    #[test]
    fn opens_a_window_in_the_folder_with_the_words_as_its_first_prompt() {
        let command = parse_words(&["--cwd", "/usr", "--focus", "build", "the", "app"]).unwrap();

        assert_eq!(command, Command::App { open: Some(Open { cwd: "/usr".into(), prompt: "build the app".into(), resume: None, focus: true }), windowless: false });
    }

    #[test]
    fn takes_a_relative_folder_from_the_caller_and_everything_after_dashes_as_words() {
        let command = parse_words(&["-C", ".", "--", "--not-an-option"]).unwrap();

        let Command::App { open: Some(open), .. } = command else { panic!("not an open") };
        assert_eq!((open.cwd.as_str(), open.prompt.as_str()), ("/tmp/.", "--not-an-option"));
    }

    #[test]
    fn resumes_the_last_conversation_or_the_one_named() {
        let last = parse_words(&["--resume"]).unwrap();
        let named = parse_words(&["-r", "T1", "go"]).unwrap();

        assert!(matches!(last, Command::App { open: Some(Open { resume: Some(ref id), .. }), .. } if id == "last"));
        assert!(matches!(named, Command::App { open: Some(Open { resume: Some(ref id), ref prompt, .. }), .. } if id == "T1" && prompt == "go"));
    }

    #[test]
    fn asks_for_no_window_when_launched_bare() {
        assert_eq!(parse_words(&["--windowless"]).unwrap(), Command::App { open: None, windowless: true });
    }

    #[test]
    fn reads_send_with_its_sender_and_refuses_one_without_a_message() {
        let send = parse_words(&["--send", "Rust app", "--from", "self", "hello", "there"]).unwrap();

        assert_eq!(send, Command::Send { to: "Rust app".into(), from: Some("self".into()), text: "hello there".into() });
        assert!(parse_words(&["--send", "Rust app"]).is_err());
    }

    #[test]
    fn moves_a_window_only_to_a_folder_that_exists() {
        let moved = parse_words(&["--set-dir", "A1B2", "/usr"]).unwrap();

        assert_eq!(moved, Command::SetDir { to: "A1B2".into(), path: "/usr".into() });
        assert!(parse_words(&["--set-dir", "A1B2", "/nonexistent-folder"]).is_err());
    }

    #[test]
    fn hands_print_mode_to_the_background_runner_and_refuses_unknown_options() {
        assert_eq!(parse_words(&["-p", "hi"]).unwrap(), Command::Background(vec!["-p".into(), "hi".into()]));
        assert_eq!(parse_words(&["--verbose"]).unwrap_err(), "Unknown option: --verbose");
    }
}
