//! One VCX session window in Rust: it attaches to the session's runtime worker and draws it with the page template.

mod app;
mod bridge;
mod check;
mod link;
mod session;
mod snapshot;
mod template;

use session::Source;
use std::collections::HashMap;
use std::process::ExitCode;
use std::time::Duration;
use vcx_proto::AttachRequest;

const USAGE: &str = "usage: vcx-shell (--socket <worker socket> [--session <id>] [--cwd <folder>] [--prompt <text>] [--resume <thread>] | --demo <state.json>)
                 [--template <folder>] [--check <report.json> [--picture <page.png>] [--check-timeout <seconds>]]";
const FLAGS: [&str; 10] = ["--socket", "--session", "--cwd", "--prompt", "--resume", "--demo", "--template", "--check", "--picture", "--check-timeout"];
const EXIT_USAGE: u8 = 2;
const CHECK_TIMEOUT_SECONDS: u64 = 30;

fn main() -> ExitCode {
    let options = match options(std::env::args().skip(1)) {
        Ok(options) => options,
        Err(problem) => {
            eprintln!("vcx-shell: {problem}\n{USAGE}");
            return ExitCode::from(EXIT_USAGE);
        }
    };
    let Err(problem) = app::run(options);
    eprintln!("vcx-shell: {problem}");
    ExitCode::FAILURE
}

fn options(mut arguments: impl Iterator<Item = String>) -> Result<app::Options, String> {
    let mut values = HashMap::new();
    while let Some(flag) = arguments.next() {
        let name = FLAGS.iter().copied().find(|name| *name == flag).ok_or_else(|| format!("unknown option {flag}"))?;
        values.insert(name, arguments.next().ok_or_else(|| format!("{flag} needs a value"))?);
    }
    let prompt = values.remove("--prompt").unwrap_or_default();
    let wait_for_answer = !prompt.is_empty();
    let source = match (values.remove("--demo"), values.remove("--socket")) {
        (Some(state), None) => Source::Demo(state.into()),
        (None, Some(socket)) => {
            let session_id = values.remove("--session").unwrap_or_else(|| uuid::Uuid::new_v4().to_string().to_uppercase());
            let cwd = match values.remove("--cwd") {
                Some(cwd) => cwd,
                None => std::env::current_dir().map_err(|error| error.to_string())?.to_string_lossy().into_owned(),
            };
            Source::Worker { socket: socket.into(), request: AttachRequest { session_id, cwd, prompt, resume: values.remove("--resume"), existing_only: false } }
        }
        _ => return Err("give either --socket or --demo".into()),
    };
    let timeout = match values.remove("--check-timeout") {
        Some(seconds) => seconds.parse().map_err(|_| format!("--check-timeout takes whole seconds, not {seconds}"))?,
        None => CHECK_TIMEOUT_SECONDS,
    };
    let picture = values.remove("--picture").map(Into::into);
    if picture.is_some() && !values.contains_key("--check") {
        return Err("--picture goes with --check".into());
    }
    let check = values.remove("--check").map(|output| check::Options { output: output.into(), picture, timeout: Duration::from_secs(timeout), wait_for_answer });
    Ok(app::Options { source, template: values.remove("--template").map(Into::into), check })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(arguments: &[&str]) -> Result<app::Options, String> {
        options(arguments.iter().map(|argument| (*argument).to_owned()))
    }

    #[test]
    fn attaches_to_a_worker_with_the_first_prompt_and_waits_for_its_answer_in_a_check() {
        let options = parse(&["--socket", "/tmp/w.sock", "--cwd", "/tmp", "--prompt", "hello", "--check", "/tmp/report.json"]).unwrap();

        let Source::Worker { request, .. } = options.source else { panic!("not a worker source") };
        assert_eq!((request.cwd.as_str(), request.prompt.as_str()), ("/tmp", "hello"));
        assert_eq!(request.session_id.len(), 36);
        assert!(options.check.unwrap().wait_for_answer);
    }

    #[test]
    fn refuses_a_window_with_nothing_to_show() {
        let neither = parse(&["--template", "/tmp/t"]);
        let both = parse(&["--demo", "state.json", "--socket", "/tmp/w.sock"]);

        assert!(neither.is_err());
        assert!(both.is_err());
    }

    #[test]
    fn refuses_an_option_it_does_not_know() {
        let unknown = parse(&["--demo", "state.json", "--verbose", "1"]);

        assert_eq!(unknown.err().unwrap(), "unknown option --verbose");
    }
}
