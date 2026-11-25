use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::mpsc;
use std::thread;
use vcx_cli::commands::{PROTOCOL, VERSION, background};
use vcx_cli::{Command, Context, ELSEWHERE, Open, USAGE, parse, run};
use vcx_config::Homes;

/// Every flag the Swift `vcx` takes before any `-p`: the launcher `~/.local/bin/vcx` and `main.swift`.
const SWIFT_FLAGS: &[&str] = &[
    "--focus", "-p", "--print", "--headless", "--ensure-qwen", "--terminal", "--send", "--set-model", "--set-dir", "--close",
    "--sessions", "--version", "--help", "--check", "--provider-check", "--bug-check", "--interaction-check", "--runtime-check",
    "--runtime-protocol", "--frontend-check", "--runtime-bounds-check", "--runtime-recovery-check", "--runtime-load-check",
    "--verify-runtime", "--update-now", "--archive-safety-check", "--archive-fixture-prune", "--archive-live-check",
    "--qwen-check", "--agy-check", "--runtime-swap-check", "--render", "--render-demo", "--scroll-bench", "--selection-check",
    "--chart-check", "--icon", "--graph-dump-check", "--busy-command-check", "--live-check", "--quota-check", "--adopt-check",
    "--publish-update", "--manual", "--recall", "--route-project", "--from", "--recovery-frontend", "--frontend-handoff-fixture",
    "--runtime-load-worker", "--runtime-worker", "--runtime-fixture-command", "--runtime-test", "--runtime-swap-test", "--adopt",
    "--runtime-recovery-test", "--restore-windows", "--cwd", "-C", "--resume", "-r", "--",
];
/// `background.py`'s own flags, which follow a `-p`.
const BACKGROUND_FLAGS: &[&str] = &[
    "--provider", "--codex", "--fork-session", "--session-id", "--session-id-format", "--model", "--output-format",
    "--input-format", "--system-prompt", "--append-system-prompt", "--append-system-prompt-file", "--json-schema", "--tools",
    "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools", "--setting-sources", "--settings",
    "--mcp-config", "--permission-mode", "--effort", "--max-turns", "--add-dir", "--strict-mcp-config",
    "--disable-slash-commands", "--no-session-persistence", "--dangerously-skip-permissions", "--restricted", "--verbose",
    "--include-partial-messages", "--check-denied-tools", "--check-tools", "--cwd",
];

fn words(line: &[&str]) -> Vec<String> {
    line.iter().map(|word| word.to_string()).collect()
}

/// A short folder: a socket path must stay under 104 bytes, which the per-user temp folder can pass.
fn scratch() -> PathBuf {
    let folder = PathBuf::from(format!("/tmp/vcx-cli-{}", &uuid::Uuid::new_v4().simple().to_string()[..12]));
    fs::create_dir_all(&folder).unwrap();
    folder.canonicalize().unwrap()
}

fn context(root: &Path) -> Context {
    Context { homes: Homes::under(root), threads: vec!["claude:caller-thread".into()], background: None, home: root.to_path_buf() }
}

/// The app's control socket, answering `answer` once and handing over what it was asked.
fn fake_app(homes: &Homes, answer: Value) -> mpsc::Receiver<Value> {
    fs::create_dir_all(&homes.state).unwrap();
    let listener = UnixListener::bind(homes.control()).unwrap();
    let (asked, received) = mpsc::channel();
    thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
        asked.send(serde_json::from_str::<Value>(&line).unwrap()).unwrap();
        let mut stream = stream;
        stream.write_all(format!("{answer}\n").as_bytes()).unwrap();
    });
    received
}

struct Ran {
    code: ExitCode,
    out: String,
    err: String,
}

fn ran(command: Command, context: &Context, stdin: &str) -> Ran {
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let code = run(command, context, &mut stdin.as_bytes(), &mut out, &mut err);
    Ran { code, out: String::from_utf8(out).unwrap(), err: String::from_utf8(err).unwrap() }
}

#[test]
fn opens_a_window_in_the_folder_given_by_cwd_or_c_with_the_prompt_after_the_double_dash() {
    let root = scratch();
    let folder = root.join("project");
    fs::create_dir(&folder).unwrap();

    let long = parse(&words(&["--cwd", "project", "--", "--fix", "it"]), &root).unwrap();
    let short = parse(&words(&["-C", folder.to_str().unwrap(), "fix", "it"]), Path::new("/")).unwrap();

    let expected = |prompt: &str| Command::App { open: Some(Open { cwd: folder.to_string_lossy().into(), prompt: prompt.into(), ..Open::default() }), windowless: false };
    assert_eq!(long, expected("--fix it"));
    assert_eq!(short, expected("fix it"));
}

#[test]
fn bare_words_open_a_window_in_the_current_folder() {
    let root = scratch();

    let command = parse(&words(&["hello", "there"]), &root).unwrap();

    assert_eq!(command, Command::App { open: Some(Open { cwd: root.to_string_lossy().into(), prompt: "hello there".into(), ..Open::default() }), windowless: false });
}

#[test]
fn no_words_start_the_app_with_only_its_last_windows() {
    assert_eq!(parse(&[], Path::new("/")).unwrap(), Command::App { open: None, windowless: false });
    assert_eq!(parse(&words(&["--windowless"]), Path::new("/")).unwrap(), Command::App { open: None, windowless: true });
}

#[test]
fn resume_takes_an_id_or_the_last_conversation() {
    let root = scratch();

    let last = parse(&words(&["--resume", "--focus"]), &root).unwrap();
    let id = parse(&words(&["-r", "019abc"]), &root).unwrap();

    let Command::App { open: Some(last), .. } = last else { panic!("{last:?}") };
    let Command::App { open: Some(id), .. } = id else { panic!("{id:?}") };
    assert_eq!((last.resume.as_deref(), last.focus), (Some("last"), true));
    assert_eq!(id.resume.as_deref(), Some("019abc"));
}

#[test]
fn refuses_a_cwd_that_is_not_a_folder() {
    let root = scratch();

    assert!(parse(&words(&["--cwd", "missing", "hi"]), &root).is_err());
    assert!(parse(&words(&["--cwd"]), &root).is_err());
}

#[test]
fn reads_sessions_send_set_dir_set_model_and_close() {
    let root = scratch();

    assert_eq!(parse(&words(&["--sessions"]), &root).unwrap(), Command::Sessions);
    assert_eq!(parse(&words(&["--send", "Rust app", "--from", "self", "hello", "you"]), &root).unwrap(), Command::Send { to: "Rust app".into(), from: Some("self".into()), text: "hello you".into() });
    assert_eq!(parse(&words(&["--send", "18BC", "-"]), &root).unwrap(), Command::Send { to: "18BC".into(), from: None, text: "-".into() });
    assert_eq!(parse(&words(&["--set-dir", "self", "."]), &root).unwrap(), Command::SetDir { to: "self".into(), path: root.clone() });
    assert_eq!(parse(&words(&["--close", "18BC"]), &root).unwrap(), Command::Close { to: "18BC".into() });
    assert!(parse(&words(&["--send", "18BC"]), &root).is_err());
    assert!(parse(&words(&["--set-dir", "self", "missing"]), &root).is_err());
    assert!(parse(&words(&["--close"]), &root).is_err());
}

#[test]
fn set_model_takes_a_provider_a_model_or_both_then_an_effort() {
    let set = |line: &[&str]| parse(&words(line), Path::new("/"));
    let model = |provider: Option<&str>, model: Option<&str>, effort: Option<&str>| Command::SetModel {
        to: "self".into(),
        provider: provider.map(Into::into),
        model: model.map(Into::into),
        effort: effort.map(Into::into),
    };

    assert_eq!(set(&["--set-model", "self", "codex"]).unwrap(), model(Some("codex"), None, None));
    assert_eq!(set(&["--set-model", "self", "claude", "opus", "high"]).unwrap(), model(Some("claude"), Some("opus"), Some("high")));
    assert_eq!(set(&["--set-model", "self", "gpt-5.5"]).unwrap(), model(None, Some("gpt-5.5"), None));
    assert!(set(&["--set-model", "self"]).is_err());
    assert!(set(&["--set-model", "self", "qwen", "a", "b", "c"]).is_err());
}

#[test]
fn hands_print_headless_and_ensure_qwen_to_background_py_untouched() {
    for flag in ["-p", "--print", "--headless", "--ensure-qwen"] {
        let line = words(&["--provider", "codex", flag, "--output-format", "json", "say hi"]);

        let command = parse(&line, Path::new("/")).unwrap();

        assert_eq!(command, Command::Background(line));
    }
}

#[test]
fn passes_every_background_py_flag_through_with_print() {
    for &flag in BACKGROUND_FLAGS {
        let line = words(&["-p", flag, "value"]);

        assert_eq!(parse(&line, Path::new("/")).unwrap(), Command::Background(line), "{flag}");
    }
}

#[test]
fn reads_version_help_and_runtime_protocol() {
    assert_eq!(parse(&words(&["--version"]), Path::new("/")).unwrap(), Command::Version);
    assert_eq!(parse(&words(&["--help"]), Path::new("/")).unwrap(), Command::Help);
    assert_eq!(parse(&words(&["--runtime-protocol"]), Path::new("/")).unwrap(), Command::RuntimeProtocol);
}

#[test]
fn every_swift_flag_is_taken_or_refused_with_where_it_went() {
    let root = scratch();
    for &flag in SWIFT_FLAGS {
        let result = parse(&words(&[flag]), &root);

        let elsewhere = ELSEWHERE.iter().find(|(name, _)| *name == flag).map(|(_, reason)| *reason);

        match (result, elsewhere) {
            (Err(problem), Some(reason)) => assert!(problem.contains(reason), "{flag}: {problem}"),
            (Err(problem), None) => assert!(!problem.starts_with("Unknown option"), "{flag}: {problem}"),
            (Ok(command), Some(_)) => panic!("{flag} is refused yet parsed as {command:?}"),
            (Ok(_), None) => {}
        }
    }
}

#[test]
fn an_unknown_flag_is_named_in_the_error() {
    assert_eq!(parse(&words(&["--nope"]), Path::new("/")).unwrap_err(), "Unknown option: --nope");
}

#[test]
fn prints_version_usage_and_protocol() {
    let root = scratch();
    let context = context(&root);

    let version = ran(Command::Version, &context, "");
    let help = ran(Command::Help, &context, "");
    let protocol = ran(Command::RuntimeProtocol, &context, "");

    assert_eq!((version.code, version.out), (ExitCode::SUCCESS, format!("{VERSION}\n")));
    assert_eq!(help.out, format!("{USAGE}\n"));
    assert_eq!(protocol.out, format!("{PROTOCOL}\n"));
}

#[test]
fn lists_the_windows_of_running_apps_as_the_swift_sessions_does() {
    let root = scratch();
    let context = context(&root);
    let fleet = context.homes.fleet();
    fs::create_dir_all(&fleet).unwrap();
    let pid = std::process::id();
    let session = |id: &str, thread: &str, context: Value, prompt: &str| json!({"sessionId": id, "threadId": thread, "state": "ready", "cwd": root.join("project"), "context": context, "prompt": prompt});
    let running = json!({"pid": pid, "startedAt": vcx_config::process::start_time(pid as i32), "sessions": [
        session("BBBBBBBB-2222", "019abc", Value::Null, "rebuild the whole thing"),
        session("AAAAAAAA-1111", "claude:x", json!("Rust config"), "hi"),
    ]});
    let gone = json!({"pid": pid, "startedAt": 1, "sessions": [session("CCCCCCCC-3333", "qwen:y", Value::Null, "old")]});
    fs::write(fleet.join("1.json"), running.to_string()).unwrap();
    fs::write(fleet.join("2.json"), gone.to_string()).unwrap();

    let listed = ran(Command::Sessions, &context, "");

    assert_eq!(listed.out, "AAAAAAAA\tclaude\tready\t~/project\tRust config\nBBBBBBBB\tcodex\tready\t~/project\trebuild the whole\n");
}

#[test]
fn says_when_no_window_is_open() {
    let root = scratch();

    assert_eq!(ran(Command::Sessions, &context(&root), "").out, "No VCX Rust window is open.\n");
}

#[test]
fn sends_a_message_with_the_caller_threads_and_tells_whether_it_went_or_waits() {
    let root = scratch();
    let context = context(&root);
    let asked = fake_app(&context.homes, json!({"sessionId": "AAAA", "name": "Rust app", "sent": false}));

    let sent = ran(Command::Send { to: "Rust app".into(), from: None, text: "hello".into() }, &context, "");

    assert_eq!(asked.recv().unwrap(), json!({"send": {"to": "Rust app", "from": null, "text": "hello", "threads": ["claude:caller-thread"]}}));
    assert_eq!((sent.code, sent.out), (ExitCode::SUCCESS, "Queued for Rust app: it goes once that window is idle.\n".to_owned()));
}

#[test]
fn reads_the_message_from_standard_input_after_a_dash() {
    let root = scratch();
    let context = context(&root);
    let asked = fake_app(&context.homes, json!({"name": "Rust app", "sent": true}));

    let sent = ran(Command::Send { to: "18BC".into(), from: Some("self".into()), text: "-".into() }, &context, "line one\nline two\n");

    assert_eq!(asked.recv().unwrap()["send"]["text"], "line one\nline two\n");
    assert_eq!(sent.out, "Sent to Rust app.\n");
}

#[test]
fn refuses_an_empty_message_before_asking_the_app() {
    let root = scratch();

    let sent = ran(Command::Send { to: "18BC".into(), from: None, text: "-".into() }, &context(&root), "  \n");

    assert_eq!((sent.code, sent.err), (ExitCode::FAILURE, "vcx-rust: Empty message.\n".to_owned()));
}

#[test]
fn moves_a_window_to_another_folder() {
    let root = scratch();
    let context = context(&root);
    let asked = fake_app(&context.homes, json!({"name": "Rust config"}));

    let moved = ran(Command::SetDir { to: "self".into(), path: root.join("project") }, &context, "");

    assert_eq!(asked.recv().unwrap(), json!({"setDir": {"to": "self", "path": root.join("project"), "threads": ["claude:caller-thread"]}}));
    assert_eq!(moved.out, "Rust config now works in ~/project.\n");
}

#[test]
fn asks_the_app_to_set_a_model_and_to_close_a_window() {
    let root = scratch();
    let context = context(&root);
    let model = Command::SetModel { to: "self".into(), provider: Some("claude".into()), model: Some("opus".into()), effort: None };

    let asked = fake_app(&context.homes, json!({"name": "Rust config"}));
    let set = ran(model, &context, "");
    let set_request = asked.recv().unwrap();
    fs::remove_file(context.homes.control()).unwrap();
    let asked = fake_app(&context.homes, json!({"name": "Rust config"}));
    let closed = ran(Command::Close { to: "18BC".into() }, &context, "");

    assert_eq!(set_request, json!({"setModel": {"to": "self", "provider": "claude", "model": "opus", "effort": null, "threads": ["claude:caller-thread"]}}));
    assert_eq!(set.out, "Rust config set.\n");
    assert_eq!(asked.recv().unwrap(), json!({"close": {"to": "18BC", "threads": ["claude:caller-thread"]}}));
    assert_eq!(closed.out, "Closed Rust config.\n");
}

#[test]
fn shows_the_app_refusal_and_fails() {
    let root = scratch();
    let context = context(&root);
    let _asked = fake_app(&context.homes, json!({"error": "No single open window matches nope."}));

    let closed = ran(Command::Close { to: "nope".into() }, &context, "");

    assert_eq!((closed.code, closed.err), (ExitCode::FAILURE, "vcx-rust: No single open window matches nope.\n".to_owned()));
}

#[test]
fn says_no_app_runs_when_the_socket_does_not_answer() {
    let root = scratch();

    let sent = ran(Command::Send { to: "x".into(), from: None, text: "hi".into() }, &context(&root), "");

    assert_eq!(sent.err, "vcx-rust: No VCX Rust app is running.\n");
}

#[test]
fn runs_background_py_with_its_words_in_the_rust_worker_folders() {
    let root = scratch();
    let script = root.join("background.py");
    fs::write(&script, "import json, os, sys\nprint(json.dumps({'words': sys.argv[1:], 'config': os.environ['VCX_CONFIG_HOME'], 'state': os.environ['VCX_STATE_HOME'], 'runtime': os.environ['VCX_RUNTIME_HOME']}))\n").unwrap();
    let context = Context { background: Some(script), ..context(&root) };
    let line = words(&["-p", "--provider", "qwen", "--output-format", "json", "say hi"]);

    let output = background(&context, &line).unwrap().output().unwrap();

    let seen: Value = serde_json::from_slice(&output.stdout).unwrap();
    let homes = &context.homes;
    assert_eq!(seen, json!({"words": line, "config": homes.worker_config(), "state": homes.worker_state(), "runtime": homes.runtime}));
}

#[test]
fn says_background_py_is_missing() {
    let root = scratch();
    let context = Context { background: Some(root.join("missing.py")), ..context(&root) };

    let ran = ran(Command::Background(words(&["-p", "hi"])), &context, "");

    assert_eq!((ran.code, ran.err), (ExitCode::FAILURE, "vcx-rust: background.py is missing from this build.\n".to_owned()));
}
