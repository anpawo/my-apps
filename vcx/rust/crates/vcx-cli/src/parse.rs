//! The words of the command line, as the Swift `vcx` takes them.

use std::path::{Path, PathBuf};

pub const USAGE: &str = "usage: vcx-rust [--cwd FOLDER] [--resume [ID]] [--focus] [--windowless] [--] [PROMPT…]
       vcx-rust --sessions
       vcx-rust --send <window id or name> [--from <window id or name>] <message… | ->
       vcx-rust --set-dir <window id or name | self> <folder>
       vcx-rust --set-model <window id or name | self> [auto|claude|codex|qwen|agy] [model] [effort]
       vcx-rust --close <window id or name>
       vcx-rust -p [--provider auto|claude|codex|qwen] [--output-format text|json|stream-json] [PROMPT…]
       vcx-rust --ensure-qwen | --runtime-protocol | --version | --help";
pub const PROVIDERS: [&str; 5] = ["auto", "claude", "codex", "qwen", "agy"];
/// The flags that start `background.py` instead of a window, as the Swift launcher picks them.
pub const BACKGROUND: [&str; 4] = ["-p", "--print", "--headless", "--ensure-qwen"];

/// Swift `vcx` flags the Rust command line does not take, each with where it went.
pub const ELSEWHERE: [(&str, &str); 44] = {
    const UPDATE: &str = "the Rust app updates live when `vcx/build-rust.sh --install` replaces it, with no command to ask for it";
    const CHECK: &str = "the Swift app's built-in checks are `cargo test` in vcx/rust";
    const WORKER: &str = "a worker flag: the Rust worker is `vcx-worker`";
    const DEBUG: &str = "a debugging entry of the Swift app, not carried over";
    [
        ("--update-now", UPDATE),
        ("--publish-update", UPDATE),
        ("--manual", UPDATE),
        ("--restore-windows", UPDATE),
        ("--adopt-check", UPDATE),
        ("--terminal", "the old terminal interface stays `vcx --terminal`"),
        ("--recall", DEBUG),
        ("--route-project", DEBUG),
        ("--check", CHECK),
        ("--provider-check", CHECK),
        ("--qwen-check", CHECK),
        ("--agy-check", CHECK),
        ("--bug-check", CHECK),
        ("--interaction-check", CHECK),
        ("--selection-check", CHECK),
        ("--chart-check", CHECK),
        ("--runtime-check", CHECK),
        ("--frontend-check", CHECK),
        ("--runtime-bounds-check", CHECK),
        ("--runtime-recovery-check", CHECK),
        ("--runtime-load-check", CHECK),
        ("--runtime-swap-check", CHECK),
        ("--verify-runtime", CHECK),
        ("--busy-command-check", CHECK),
        ("--archive-safety-check", CHECK),
        ("--archive-fixture-prune", CHECK),
        ("--archive-live-check", CHECK),
        ("--live-check", CHECK),
        ("--quota-check", CHECK),
        ("--graph-dump-check", CHECK),
        ("--render", CHECK),
        ("--render-demo", CHECK),
        ("--scroll-bench", CHECK),
        ("--icon", CHECK),
        ("--recovery-frontend", CHECK),
        ("--frontend-handoff-fixture", CHECK),
        ("--runtime-worker", WORKER),
        ("--runtime-test", WORKER),
        ("--runtime-fixture-command", WORKER),
        ("--runtime-swap-test", WORKER),
        ("--runtime-recovery-test", WORKER),
        ("--runtime-load-worker", WORKER),
        ("--adopt", WORKER),
        ("--from", "`--from` goes with `--send`"),
    ]
};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Open {
    pub cwd: String,
    pub prompt: String,
    /// `last`, or a conversation id.
    pub resume: Option<String>,
    pub focus: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    /// Opens a window for `open`, in the running app or as the app. `None`: only the last run's windows.
    App { open: Option<Open>, windowless: bool },
    Sessions,
    Send { to: String, from: Option<String>, text: String },
    SetDir { to: String, path: PathBuf },
    SetModel { to: String, provider: Option<String>, model: Option<String>, effort: Option<String> },
    Close { to: String },
    /// `background.py` with these words, as the Swift app runs it.
    Background(Vec<String>),
    RuntimeProtocol,
    Version,
    Help,
}

pub fn parse(arguments: &[String], cwd: &Path) -> Result<Command, String> {
    let rest = arguments.get(1..).unwrap_or_default();
    match arguments.first().map(String::as_str) {
        Some("--sessions") => return Ok(Command::Sessions),
        Some("--send") => return send(rest),
        Some("--set-dir") => return set_dir(rest, cwd),
        Some("--set-model") => return set_model(rest),
        Some("--close") => return close(rest),
        _ => {}
    }
    if arguments.iter().any(|argument| BACKGROUND.contains(&argument.as_str())) {
        return Ok(Command::Background(arguments.to_vec()));
    }
    for (flag, command) in [("--runtime-protocol", Command::RuntimeProtocol), ("--version", Command::Version), ("--help", Command::Help)] {
        if arguments.iter().any(|argument| argument == flag) {
            return Ok(command);
        }
    }
    app(arguments, cwd)
}

fn app(arguments: &[String], cwd: &Path) -> Result<Command, String> {
    let mut open = Open { cwd: cwd.to_string_lossy().into_owned(), ..Open::default() };
    let (mut asked, mut windowless, mut words) = (false, false, Vec::new());
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
            _ if argument.starts_with('-') => return Err(unknown(argument)),
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

fn unknown(flag: &str) -> String {
    match ELSEWHERE.iter().find(|(name, _)| *name == flag) {
        Some((_, reason)) => format!("{flag} is not taken here: {reason}."),
        None => format!("Unknown option: {flag}"),
    }
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
        return Err("--send needs a window and a message (- reads it from standard input).".into());
    }
    Ok(Command::Send { to: words[0].clone(), from, text: words[1..].join(" ") })
}

fn set_dir(arguments: &[String], cwd: &Path) -> Result<Command, String> {
    let [to, folder] = arguments else { return Err("--set-dir needs a window and a folder.".into()) };
    let path = absolute(folder, cwd);
    match path.canonicalize() {
        Ok(path) if path.is_dir() => Ok(Command::SetDir { to: to.clone(), path }),
        _ => Err(format!("{} is not a folder.", path.display())),
    }
}

/// `<window> [provider] [model] [effort]`: a model without a provider stays with the window's provider.
fn set_model(arguments: &[String]) -> Result<Command, String> {
    let usage = || "--set-model needs a window, then a provider, a model or both, and an effort if wanted.".to_owned();
    let (to, rest) = arguments.split_first().ok_or_else(usage)?;
    let provider = rest.first().filter(|word| PROVIDERS.contains(&word.as_str())).cloned();
    let rest = &rest[usize::from(provider.is_some())..];
    let allowed = if provider.is_some() { 0..=2 } else { 1..=2 };
    if !allowed.contains(&rest.len()) {
        return Err(usage());
    }
    Ok(Command::SetModel { to: to.clone(), provider, model: rest.first().cloned(), effort: rest.get(1).cloned() })
}

fn close(arguments: &[String]) -> Result<Command, String> {
    match arguments {
        [to] => Ok(Command::Close { to: to.clone() }),
        _ => Err("--close needs one window id or name.".into()),
    }
}

fn absolute(folder: &str, cwd: &Path) -> PathBuf {
    let expanded = match folder.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => vcx_config::homes::home_directory().join(rest.trim_start_matches('/')),
        _ => PathBuf::from(folder),
    };
    cwd.join(expanded)
}
