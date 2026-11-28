//! Every command but `App`, run against the homes of the Rust app. Output goes to the writers the caller hands in,
//! so tests read what the user would see.

use crate::parse::{Command, USAGE};
use crate::{control, fleet};
use serde_json::{Value, json};
use std::ffi::OsString;
use std::io::{Read, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command as Process, ExitCode};
use vcx_config::Homes;

pub const VERSION: &str = concat!("vcx-rust ", env!("CARGO_PKG_VERSION"), " (VCX Rust)");
/// The control socket's version, as the Swift `--runtime-protocol` prints its own.
pub const PROTOCOL: u32 = 1;
const PYTHON: &str = "/usr/bin/python3";
const BACKGROUND_VARIABLE: &str = "VCX_RUST_BACKGROUND";
const USAGE_CODE: u8 = 2;

/// What a command reads besides its words.
pub struct Context {
    pub homes: Homes,
    /// The caller's own agent threads, so `self` and the sender's name are found.
    pub threads: Vec<String>,
    /// `background.py`; `None`: the one this build carries.
    pub background: Option<PathBuf>,
    pub home: PathBuf,
}

impl Context {
    pub fn from_env() -> Self {
        let claude = std::env::var("CLAUDE_CODE_SESSION_ID").ok().filter(|id| !id.is_empty()).map(|id| format!("claude:{id}"));
        let threads = claude.into_iter().chain(std::env::var("VCX_THREAD_ID").ok()).filter(|thread| !thread.is_empty()).collect();
        let background = std::env::var_os(BACKGROUND_VARIABLE).map(PathBuf::from);
        Self { homes: Homes::from_env(), threads, background, home: vcx_config::homes::home_directory() }
    }
}

/// Runs `command`; `App` is the app's own and answers a usage error here.
pub fn run(command: Command, context: &Context, stdin: &mut dyn Read, out: &mut dyn Write, err: &mut dyn Write) -> ExitCode {
    let result = match command {
        Command::Help => say(out, USAGE),
        Command::Version => say(out, VERSION),
        Command::RuntimeProtocol => say(out, &PROTOCOL.to_string()),
        Command::Sessions => sessions(context, out),
        Command::Send { to, from, text } => send(context, &to, from, &text, stdin, out),
        Command::SetDir { to, path } => ask(context, json!({"setDir": {"to": to, "path": path, "threads": context.threads}})).and_then(|answer| {
            say(out, &format!("{} now works in {}.", answer["name"].as_str().unwrap_or(&to), tilde(&path.to_string_lossy(), &context.home)))
        }),
        Command::SetModel { to, provider, model, effort } => {
            let body = json!({"setModel": {"to": to, "provider": provider, "model": model, "effort": effort, "threads": context.threads}});
            ask(context, body).and_then(|answer| say(out, &format!("{} set.", answer["name"].as_str().unwrap_or(&to))))
        }
        Command::Close { to } => ask(context, json!({"close": {"to": to, "threads": context.threads}})).and_then(|answer| {
            let name = answer["name"].as_str().unwrap_or(&to);
            say(out, &if answer["closing"] == true { format!("{name} closes once this turn ends.") } else { format!("Closed {name}.") })
        }),
        Command::Background(arguments) => background(context, &arguments).and_then(|process| Err(exec(process))),
        Command::App { .. } => {
            let _ = writeln!(err, "vcx-rust: the app opens windows itself.");
            return ExitCode::from(USAGE_CODE);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(problem) => {
            let _ = writeln!(err, "vcx-rust: {problem}");
            ExitCode::FAILURE
        }
    }
}

fn say(out: &mut dyn Write, text: &str) -> Result<(), String> {
    writeln!(out, "{text}").map_err(|error| error.to_string())
}

fn ask(context: &Context, body: Value) -> Result<Value, String> {
    control::request(&context.homes.control(), &body)
}

/// One line per window, as the Swift `--sessions` prints them: id8, provider, state, folder, name.
fn sessions(context: &Context, out: &mut dyn Write) -> Result<(), String> {
    let listed = fleet::list(&context.homes.fleet());
    if listed.is_empty() {
        return say(out, "No VCX Rust window is open.");
    }
    for session in listed {
        let id: String = session.id.chars().take(8).collect();
        say(out, &format!("{id}\t{}\t{}\t{}\t{}", session.provider, session.state, tilde(&session.cwd, &context.home), session.name))?;
    }
    Ok(())
}

fn send(context: &Context, to: &str, from: Option<String>, text: &str, stdin: &mut dyn Read, out: &mut dyn Write) -> Result<(), String> {
    let mut text = text.to_owned();
    if text == "-" {
        text.clear();
        stdin.read_to_string(&mut text).map_err(|_| "Cannot read the message from standard input.")?;
    }
    if text.trim().is_empty() {
        return Err("Empty message.".into());
    }
    let answer = ask(context, json!({"send": {"to": to, "from": from, "text": text, "threads": context.threads}}))?;
    let name = answer["name"].as_str().unwrap_or(to);
    match answer["sent"] == true {
        true => say(out, &format!("Sent to {name}.")),
        false => say(out, &format!("Queued for {name}: it goes once that window is idle.")),
    }
}

/// `-p` and its kin run `background.py` as the Swift app runs it, in the worker's folders of the Rust app (as
/// `vcx-app` starts it), his shared settings among them.
pub fn background(context: &Context, arguments: &[String]) -> Result<Process, String> {
    let script = context.background.clone().or_else(|| {
        let executable = std::env::current_exe().ok()?;
        Some(executable.parent()?.parent()?.join("Resources/background.py"))
    });
    let script = script.filter(|script| script.is_file()).ok_or("background.py is missing from this build.")?;
    let mut process = Process::new(PYTHON);
    process.arg(script).args(arguments);
    let worker = context.homes.worker();
    for (name, folder) in worker.environment() {
        process.env(name, OsString::from(folder));
    }
    Ok(process)
}

fn exec(mut process: Process) -> String {
    format!("Cannot run {PYTHON}: {}", process.exec())
}

fn tilde(path: &str, home: &Path) -> String {
    let home = home.to_string_lossy();
    match path.strip_prefix(home.as_ref()) {
        Some(rest) if !home.is_empty() && (rest.is_empty() || rest.starts_with('/')) => format!("~{rest}"),
        _ => path.to_owned(),
    }
}
