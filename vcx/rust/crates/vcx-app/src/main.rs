use serde_json::{Value, json};
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command as Process, ExitCode};
use std::thread;
use std::time::{Duration, Instant};
use vcx_app::cli::{self, Command};
use vcx_config::Homes;
use vcx_app::{app, control, fleet};

/// A second launch while the first is still starting finds the lock taken before the socket answers.
const FORWARD_WAIT: Duration = Duration::from_secs(10);
const FORWARD_POLL: Duration = Duration::from_millis(100);
const PYTHON: &str = "/usr/bin/python3";
const BACKGROUND_VARIABLE: &str = "VCX_RUST_BACKGROUND";

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    let homes = Homes::from_env();
    let command = match cli::parse(&arguments, &cwd) {
        Ok(command) => command,
        Err(problem) => return fail(&format!("{problem}\n{}", cli::USAGE)),
    };
    match command {
        Command::Help => println!("{}", cli::USAGE),
        Command::Version => println!("{}", cli::version()),
        Command::Sessions => sessions(&homes),
        Command::Send { to, from, text } => return send(&homes, &to, from, &text),
        Command::SetDir { to, path } => return ask(&homes, &json!({"setDir": {"to": to, "path": path, "threads": threads()}})).map_or_else(|problem| fail(&problem), |_| ExitCode::SUCCESS),
        Command::Background(arguments) => return fail(&background(&homes, &arguments)),
        Command::App { open, windowless } => return launch(homes, open, windowless),
    }
    ExitCode::SUCCESS
}

fn fail(problem: &str) -> ExitCode {
    eprintln!("vcx-rust: {problem}");
    ExitCode::FAILURE
}

fn sessions(homes: &Homes) {
    let listed = fleet::list(&homes.fleet());
    if listed.is_empty() {
        return println!("No VCX Rust window is open.");
    }
    for session in listed {
        println!("{}  {:<8}  {}  {}", session.id, session.state, session.name, session.cwd);
    }
}

/// The caller's own thread, so the message names the window it comes from.
fn threads() -> Vec<String> {
    let claude = std::env::var("CLAUDE_CODE_SESSION_ID").ok().map(|id| format!("claude:{id}"));
    claude.into_iter().chain(std::env::var("VCX_THREAD_ID").ok()).filter(|thread| !thread.is_empty()).collect()
}

fn send(homes: &Homes, to: &str, from: Option<String>, text: &str) -> ExitCode {
    let text = if text == "-" {
        let mut read = String::new();
        if std::io::stdin().read_to_string(&mut read).is_err() {
            return fail("Cannot read the message from standard input.");
        }
        read
    } else {
        text.to_owned()
    };
    match ask(homes, &json!({"send": {"to": to, "from": from, "text": text, "threads": threads()}})) {
        Ok(answer) if answer["sent"] == true => println!("Sent to {}.", answer["name"].as_str().unwrap_or(to)),
        Ok(answer) => println!("Queued for {}: it goes once that window is idle.", answer["name"].as_str().unwrap_or(to)),
        Err(problem) => return fail(&problem),
    }
    ExitCode::SUCCESS
}

fn ask(homes: &Homes, body: &Value) -> Result<Value, String> {
    let answer = control::ask(&homes.control(), body).ok_or("No VCX Rust app is running.")?;
    match answer["error"].as_str() {
        Some(problem) => Err(problem.to_owned()),
        None => Ok(answer),
    }
}

/// Hands a window request to the app already running, or becomes the app.
fn launch(homes: Homes, open: Option<app::Open>, windowless: bool) -> ExitCode {
    let deadline = Instant::now() + FORWARD_WAIT;
    loop {
        if let Some(open) = &open {
            let body = json!({"open": {"cwd": open.cwd, "prompt": open.prompt, "resume": open.resume, "focus": open.focus}});
            if let Some(answer) = control::ask(&homes.control(), &body) {
                return match answer["error"].as_str() {
                    Some(problem) => fail(problem),
                    None => ExitCode::SUCCESS,
                };
            }
        }
        let problem = match app::run(app::Options { homes: homes.clone(), windowless, open: open.clone() }) {
            Err(problem) => problem,
        };
        if problem != app::ALREADY_RUNNING || open.is_none() || Instant::now() > deadline {
            return fail(&problem);
        }
        thread::sleep(FORWARD_POLL);
    }
}

/// `-p`: the background job runner, kept in Python as the Swift app keeps it, with this app's own homes.
fn background(homes: &Homes, arguments: &[String]) -> String {
    let script = std::env::var_os(BACKGROUND_VARIABLE).map(PathBuf::from).or_else(|| {
        let executable = std::env::current_exe().ok()?;
        Some(executable.parent()?.parent()?.join("Resources/background.py"))
    });
    let Some(script) = script.filter(|script| script.is_file()) else { return "background.py is missing from this build.".into() };
    let error = Process::new(PYTHON).arg(script).args(arguments).env("VCX_CONFIG_HOME", homes.worker_config()).env("VCX_STATE_HOME", homes.worker_state()).exec();
    format!("Cannot run {PYTHON}: {error}")
}
