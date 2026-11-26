use serde_json::json;
use std::path::PathBuf;
use std::process::ExitCode;
use std::thread;
use std::time::{Duration, Instant};
use vcx_app::app;
use vcx_cli::{Command, Context, control};
use vcx_config::Homes;

/// A second launch while the first is still starting finds the lock taken before the socket answers.
const FORWARD_WAIT: Duration = Duration::from_secs(10);
const FORWARD_POLL: Duration = Duration::from_millis(100);
const USAGE_CODE: u8 = 2;

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    let command = match vcx_cli::parse(&arguments, &cwd) {
        Ok(command) => command,
        Err(problem) => {
            eprintln!("vcx-rust: {problem}\n{}", vcx_cli::USAGE);
            return ExitCode::from(USAGE_CODE);
        }
    };
    match command {
        Command::App { open, windowless } => launch(Homes::from_env(), open, windowless),
        command => vcx_cli::run(command, &Context::from_env(), &mut std::io::stdin(), &mut std::io::stdout(), &mut std::io::stderr()),
    }
}

fn fail(problem: &str) -> ExitCode {
    eprintln!("vcx-rust: {problem}");
    ExitCode::FAILURE
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
                    None => {
                        if open.focus {
                            vcx_app::placement::hand_focus_to_running_app();
                        }
                        ExitCode::SUCCESS
                    }
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
