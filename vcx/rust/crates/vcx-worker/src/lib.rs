//! The VCX runtime worker in Rust. It takes the Swift worker's flags, so a frontend or a test starts either the same
//! way: `vcx-worker --runtime-worker <socket> [--runtime-test --runtime-fixture-command <command.json>]`. A test may
//! add `--runtime-fixture-provider <provider>` for a fixture that speaks another provider than Codex.

// The metadata object a frontend reads is one `json!` literal of about sixty keys.
#![recursion_limit = "256"]

pub mod backend;
pub mod channel;
pub mod checkpoint;
pub mod fallback;
pub mod provider;
pub mod server;
pub mod session;

use backend::{Config, SessionBackend};
use checkpoint::Store;
use server::{Backend, Server};
use std::path::{Path, PathBuf};
use std::rc::Rc;

pub const BUILD: &str = concat!("rust-", env!("CARGO_PKG_VERSION"));
/// A test worker waits a hundredth of the rate-limit retry delays, so a retry test takes milliseconds.
const TEST_RETRY_SCALE: f64 = 0.01;
const USAGE: &str = "usage: vcx-worker --runtime-worker <socket> [--runtime-test] [--runtime-fixture-command <command.json>] [--runtime-fixture-provider <provider>]";

#[derive(Debug, PartialEq)]
pub struct Options {
    pub socket: PathBuf,
    pub test: bool,
    pub fixture: Option<Vec<String>>,
    pub provider: Option<String>,
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
    let provider = value("--runtime-fixture-provider").transpose()?;
    if provider.as_ref().is_some_and(|provider| !test || !vcx_config::settings::PROVIDERS.contains(&provider.as_str())) {
        return Err("Invalid runtime test provider.".into());
    }
    Ok(Options { socket: PathBuf::from(socket), test, fixture, provider })
}

/// Where this worker keeps checkpoints: never the Swift app's folder unless `VCX_RUNTIME_HOME` names it.
pub fn runtime_home() -> PathBuf {
    vcx_config::WorkerHomes::from_env().runtime
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
    let homes = vcx_config::WorkerHomes::from_env();
    let home = homes.runtime;
    let retry_scale = if options.test { TEST_RETRY_SCALE } else { 1.0 };
    let state_directory = if options.test { home.join("test-state") } else { home.join("state") };
    let provider = options.provider.or_else(|| options.fixture.is_some().then(|| "codex".to_owned()));
    let config = Rc::new(Config { fixture: options.fixture, provider, settings: homes.settings, store: Store::new(&home), state_directory, retry_scale });
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

        assert_eq!(options, Options { socket: "/tmp/w.sock".into(), test: true, fixture: None, provider: None });
    }

    #[test]
    fn takes_a_fixture_provider_in_a_test_run_only() {
        let taken = parse(&strings(&["--runtime-worker", "/tmp/w.sock", "--runtime-test", "--runtime-fixture-provider", "claude"])).unwrap();
        let outside = parse(&strings(&["--runtime-worker", "/tmp/w.sock", "--runtime-fixture-provider", "claude"]));
        let unknown = parse(&strings(&["--runtime-worker", "/tmp/w.sock", "--runtime-test", "--runtime-fixture-provider", "gpt"]));

        assert_eq!(taken.provider.as_deref(), Some("claude"));
        assert_eq!(outside.unwrap_err(), "Invalid runtime test provider.");
        assert_eq!(unknown.unwrap_err(), "Invalid runtime test provider.");
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
