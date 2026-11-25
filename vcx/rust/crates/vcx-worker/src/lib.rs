//! The VCX runtime worker in Rust. It takes the Swift worker's flags, so a frontend or a test starts either the same
//! way: `vcx-worker --runtime-worker <socket> [--runtime-test --runtime-fixture-command <command.json>]`.

// The metadata object a frontend reads is one `json!` literal of about sixty keys.
#![recursion_limit = "256"]

pub mod backend;
pub mod channel;
pub mod checkpoint;
pub mod server;
pub mod session;

use backend::{Config, SessionBackend};
use checkpoint::Store;
use server::{Backend, Server};
use std::path::{Path, PathBuf};
use std::rc::Rc;

pub const BUILD: &str = concat!("rust-", env!("CARGO_PKG_VERSION"));
const USAGE: &str = "usage: vcx-worker --runtime-worker <socket> [--runtime-test] [--runtime-fixture-command <command.json>]";
const CODEX: [&str; 3] = ["/usr/bin/env", "codex", "app-server"];

#[derive(Debug, PartialEq)]
pub struct Options {
    pub socket: PathBuf,
    pub test: bool,
    pub fixture: Option<Vec<String>>,
}

pub fn parse(args: &[String]) -> Result<Options, String> {
    let value = |flag: &str| args.iter().position(|arg| arg == flag).map(|index| args.get(index + 1).cloned().ok_or_else(|| format!("{flag} needs a value.\n{USAGE}")));
    let socket = value("--runtime-worker").ok_or_else(|| USAGE.to_owned())??;
    let test = args.iter().any(|arg| arg == "--runtime-test");
    let fixture = match value("--runtime-fixture-command").transpose()? {
        Some(file) => {
            if !test {
                return Err("Invalid runtime test command.".into());
            }
            let data = std::fs::read(&file).map_err(|_| "Invalid runtime test command.".to_owned())?;
            let command: Vec<String> = serde_json::from_slice(&data).map_err(|_| "Invalid runtime test command.".to_owned())?;
            if command.is_empty() {
                return Err("Invalid runtime test command.".into());
            }
            Some(command)
        }
        None => None,
    };
    Ok(Options { socket: PathBuf::from(socket), test, fixture })
}

/// Where this worker keeps checkpoints: never the Swift app's folder unless `VCX_RUNTIME_HOME` names it.
pub fn runtime_home() -> PathBuf {
    if let Some(home) = std::env::var_os("VCX_RUNTIME_HOME") {
        return PathBuf::from(home);
    }
    let state = std::env::var_os("VCX_STATE_HOME").map(PathBuf::from).unwrap_or_else(|| {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"));
        home.join(".local/state/vcx-rust")
    });
    state.join("runtime")
}

pub fn run(args: Vec<String>) -> i32 {
    let options = match parse(&args) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("{message}");
            return 2;
        }
    };
    // Its own session: a frontend that quits, or a terminal closing, does not take the worker with it.
    unsafe { libc::setsid() };
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("Cannot start the runtime: {error}");
            return 1;
        }
    };
    tokio::task::LocalSet::new().block_on(&runtime, serve(options))
}

async fn serve(options: Options) -> i32 {
    let listener = match channel::listen(&options.socket) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("{error}");
            return 1;
        }
    };
    let home = runtime_home();
    let state_directory = if options.test { home.join("test-state") } else { home.join("state") };
    let command = options.fixture.clone().unwrap_or_else(|| CODEX.map(str::to_owned).to_vec());
    let config = Rc::new(Config { command, fixture: options.fixture.is_some(), store: Store::new(&home), state_directory });
    let factory: server::Factory = Box::new(move |params| SessionBackend::start(params, Rc::clone(&config)).map(|backend| backend as Rc<dyn Backend>));
    let (done, mut finished) = tokio::sync::mpsc::unbounded_channel::<()>();
    let server = Server::new(BUILD.to_owned(), uuid::Uuid::new_v4().to_string().to_uppercase(), factory, Box::new(move || { let _ = done.send(()); }));
    let socket = options.socket.clone();
    tokio::task::spawn_local(Rc::clone(&server).serve(listener));
    let (Ok(mut terminate), Ok(mut interrupt)) = (
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()),
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt()),
    ) else {
        eprintln!("Cannot watch for termination signals.");
        return 1;
    };
    tokio::select! {
        _ = finished.recv() => {}
        _ = terminate.recv() => {}
        _ = interrupt.recv() => {}
    }
    server.stop();
    cleanup(&socket);
    // Agents got SIGTERM from their sessions; their process groups outlive this worker only if they ignore it.
    0
}

fn cleanup(socket: &Path) {
    let _ = std::fs::remove_file(socket);
    for lock in channel::lock_files(socket) {
        let _ = std::fs::remove_file(lock);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(args: &[&str]) -> Vec<String> {
        args.iter().map(|arg| (*arg).to_owned()).collect()
    }

    #[test]
    fn takes_the_swift_worker_flags() {
        let options = parse(&strings(&["--runtime-worker", "/tmp/w.sock", "--runtime-test"])).unwrap();

        assert_eq!(options, Options { socket: "/tmp/w.sock".into(), test: true, fixture: None });
    }

    #[test]
    fn refuses_a_fixture_command_outside_a_test_run() {
        let refused = parse(&strings(&["--runtime-worker", "/tmp/w.sock", "--runtime-fixture-command", "/tmp/command.json"]));

        assert_eq!(refused.unwrap_err(), "Invalid runtime test command.");
    }

    #[test]
    fn refuses_to_start_without_a_socket() {
        let refused = parse(&strings(&["--runtime-test"]));

        assert!(refused.unwrap_err().starts_with("usage:"));
    }
}
