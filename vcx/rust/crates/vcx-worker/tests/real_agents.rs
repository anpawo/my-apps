//! The worker against the real `claude` and `codex`, on his subscriptions and his accounts as his settings list them:
//! a turn each, a permission asked and answered, a tool call, a stopped turn, a conversation resumed after the worker
//! was killed, and a live update between two different builds with both agents idle.
//!
//! Opt-in: every check spends his quota (one very short prompt per turn) and needs his signed-in accounts.
//!   VCX_REAL_AGENTS=1 ~/.local/bin/build-stack cargo test -j 2 -p vcx-worker --test real_agents -- --ignored --test-threads 1
//! The live update starts from `VCX_REAL_OLD_WORKER`, else the worker of the installed `VCX Rust.app`, and updates to
//! this build. Each worker runs in its own folder under `target/real-run`: its config, state, runtime and temporary
//! folders are there, his home is his (the agents read their own sign-in), and nothing of the Swift app is touched.

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use vcx_conformance::Target;
use vcx_conformance::peer::{Held, Peer, prompt, request_for};
use vcx_model::SessionState;
use vcx_proto::{AttachRequest, Event, Hello};
use vcx_testkit::session_id;

const SWITCH: &str = "VCX_REAL_AGENTS";
const OLD_WORKER: &str = "VCX_REAL_OLD_WORKER";
const INSTALLED_WORKER: &str = "Applications/VCX Rust.app/Contents/MacOS/vcx-worker";
/// A real agent starts, reads its catalog and answers a one-word prompt well within this on a loaded Mac.
const TURN_WAIT: Duration = Duration::from_secs(240);
const SOCKET_WAIT: Duration = Duration::from_secs(20);
/// A stopped turn ends at once; the sleep it interrupted would last a minute.
const STOP_WAIT: Duration = Duration::from_secs(30);
const POLL: Duration = Duration::from_millis(50);
const KILL_GRACE: Duration = Duration::from_millis(500);
const PRIVATE_FOLDER: u32 = 0o700;
const SHOWN_TEXT: usize = 160;
const AGENTS: [&str; 2] = ["claude", "codex"];
const PONG: &str = "Reply with the single word: pong";

fn enabled() -> bool {
    let on = std::env::var(SWITCH).is_ok_and(|value| value == "1");
    if !on {
        eprintln!("skipped: set {SWITCH}=1 to run the real agents (spends his quota)");
    }
    on
}

/// A worker started as the app starts it, outside test mode: the provider comes from the settings, the agent is the
/// real one.
struct RealWorker {
    child: Option<Child>,
    root: PathBuf,
    binary: PathBuf,
    socket: PathBuf,
    work: PathBuf,
}

impl RealWorker {
    fn start(name: &str, binary: &Path, provider: &str, mode: &str) -> Self {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/real-run").join(name);
        let _ = fs::remove_dir_all(&root);
        for folder in ["config", "state", "runtime", "tmp", "work", "bin"] {
            fs::create_dir_all(root.join(folder)).unwrap();
        }
        let root = root.canonicalize().unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
        let own = root.join("bin/vcx-worker");
        fs::copy(binary, &own).unwrap();
        let mut worker = Self { child: None, socket: root.join("w.sock"), work: root.join("work"), binary: own, root };
        worker.settings(provider, mode);
        worker.launch();
        worker
    }

    /// His settings (accounts, limits, Qwen) with the provider and mode this check needs.
    fn settings(&self, provider: &str, mode: &str) {
        let his = vcx_config::Homes::from_env().shared.join("settings.json");
        let mut settings: Value = serde_json::from_slice(&fs::read(&his).unwrap_or_else(|_| b"{}".to_vec())).unwrap();
        settings["defaultProvider"] = json!(provider);
        settings["mode"] = json!(mode);
        fs::write(self.root.join("config/settings.json"), settings.to_string()).unwrap();
    }

    fn launch(&mut self) {
        let log = fs::OpenOptions::new().create(true).append(true).open(self.root.join("worker.log")).unwrap();
        let mut command = Command::new(&self.binary);
        command.args(["--runtime-worker", self.socket.to_str().unwrap()]).current_dir(&self.work);
        for (key, folder) in [("VCX_CONFIG_HOME", "config"), ("VCX_STATE_HOME", "state"), ("VCX_RUNTIME_HOME", "runtime"), ("TMPDIR", "tmp")] {
            command.env(key, self.root.join(folder));
        }
        for key in ["VCX_RUST_CONFIG_HOME", "VCX_RUST_STATE_HOME", "VCX_RUST_RUNTIME_HOME"] {
            command.env_remove(key);
        }
        self.child = Some(command.stdin(Stdio::null()).stdout(log.try_clone().unwrap()).stderr(log).spawn().unwrap());
        let deadline = Instant::now() + SOCKET_WAIT;
        while std::os::unix::net::UnixStream::connect(&self.socket).is_err() {
            assert!(Instant::now() < deadline, "the worker never served {}", self.socket.display());
            std::thread::sleep(POLL);
        }
    }

    fn pid(&self) -> i64 {
        i64::from(self.child.as_ref().unwrap().id())
    }

    fn target(&self) -> Target {
        Target { socket: self.socket.clone(), directory: self.work.clone(), pid: self.pid() }
    }

    /// The agents the worker runs: its children started as `claude` or `codex` (Claude's executable is named after
    /// its version, so the name it was started by tells them apart).
    fn agents(&self) -> Vec<(i64, String)> {
        processes().into_iter().filter(|(_, parent, name)| *parent == self.pid() && AGENTS.contains(&name.as_str())).map(|(pid, _, name)| (pid, name)).collect()
    }

    /// SIGKILL to the worker and everything under it, as a crash and then a clean desk.
    fn kill(&mut self) {
        let Some(mut child) = self.child.take() else { return };
        let tree = descendants(i64::from(child.id()));
        for pid in std::iter::once(i64::from(child.id())).chain(tree.iter().copied()) {
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
        }
        let _ = child.wait();
        std::thread::sleep(KILL_GRACE);
        let left: Vec<i64> = tree.into_iter().filter(|pid| alive(*pid)).collect();
        assert!(left.is_empty(), "processes of the worker still run: {left:?}");
    }

    /// Kills the worker and its agents, as a crash would, and starts the same build on the same folders.
    fn restart_after_kill(&mut self) {
        self.kill();
        self.launch();
    }

    /// Puts `binary` at the worker's own path, as an install does: the running image keeps its old file.
    fn replace_binary(&self, binary: &Path) {
        let next = self.binary.with_extension("next");
        fs::copy(binary, &next).unwrap();
        fs::rename(&next, &self.binary).unwrap();
    }
}

impl Drop for RealWorker {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_ref() {
            for pid in descendants(i64::from(child.id())).into_iter().chain([i64::from(child.id())]) {
                unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
            }
        }
        if let Some(mut child) = self.child.take() {
            let _ = child.wait();
        }
    }
}

/// Every process as (pid, parent, the name it was started by); its other arguments are never kept.
fn processes() -> Vec<(i64, i64, String)> {
    let output = Command::new("/bin/ps").args(["-A", "-o", "pid=,ppid=,args="]).output().unwrap();
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let (pid, parent) = (fields.next()?.parse().ok()?, fields.next()?.parse().ok()?);
            Some((pid, parent, fields.next().and_then(|program| program.rsplit('/').next()).unwrap_or_default().to_owned()))
        })
        .collect()
}

fn descendants(root: i64) -> Vec<i64> {
    let table = processes();
    let mut found = vec![root];
    let mut index = 0;
    while index < found.len() {
        let parent = found[index];
        found.extend(table.iter().filter(|(_, ppid, _)| *ppid == parent).map(|(pid, _, _)| *pid));
        index += 1;
    }
    found.split_off(1)
}

fn alive(pid: i64) -> bool {
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

fn busy(state: &SessionState) -> bool {
    meta(state, "busy") == &json!(true)
}

fn ready(state: &SessionState) -> bool {
    meta(state, "ready") == &json!(true)
}

fn permissions(state: &SessionState) -> Vec<Value> {
    meta(state, "permissions").as_array().cloned().unwrap_or_default()
}

fn items_of<'a>(state: &'a SessionState, kind: &'a str) -> impl Iterator<Item = &'a serde_json::Map<String, Value>> + 'a {
    state.rows.iter().flat_map(|row| &row.items).filter_map(|id| state.items.get(id)).filter(move |item| item.get("type").and_then(Value::as_str) == Some(kind))
}

/// What the agent said, every assistant message of the conversation in order.
fn said(state: &SessionState) -> String {
    items_of(state, "agentMessage").filter_map(|item| item.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n")
}

fn assistant_rows(state: &SessionState) -> usize {
    state.rows.iter().filter(|row| row.kind == "assistant").count()
}

fn short(text: &str) -> String {
    text.chars().take(SHOWN_TEXT).collect::<String>().replace('\n', " ")
}

/// The state in a few lines, for a check that timed out: row kinds, item types and the worker's own notices.
fn describe(state: &SessionState) -> String {
    let rows: Vec<&str> = state.rows.iter().map(|row| row.kind.as_str()).collect();
    let items: Vec<String> = state.rows.iter().flat_map(|row| &row.items).filter_map(|id| state.items.get(id)).map(|item| format!("{}:{}", item.get("type").and_then(Value::as_str).unwrap_or("?"), item.get("status").and_then(Value::as_str).unwrap_or(""))).collect();
    let notices: Vec<String> = state.rows.iter().filter(|row| row.kind == "notice").flat_map(|row| &row.items).filter_map(|id| state.items.get(id)?.get("text")?.as_str().map(short)).collect();
    format!("busy={} ready={} provider={} rows={rows:?} items={items:?} notices={notices:?} said={:?}", busy(state), ready(state), meta(state, "providerLabel"), short(&said(state)))
}

/// Applies the worker's updates until the state is the wanted one; any other event is set aside.
fn follow(held: &mut Held, wait: Duration, what: &str, reached: impl Fn(&SessionState) -> bool) {
    let deadline = Instant::now() + wait;
    while !reached(held.replica.state().expect("a snapshot")) {
        let left = deadline.saturating_duration_since(Instant::now());
        match held.peer.events.recv_timeout(left) {
            Ok(Event::Update { revision, patch, .. }) => drop(held.replica.update(revision, patch)),
            Ok(_) => {}
            Err(_) => panic!("{what} never came: {}", describe(held.replica.state().unwrap())),
        }
    }
}

fn open(worker: &RealWorker) -> Held {
    let target = worker.target();
    let mut held = Held::attach(Peer::greeted(&target), &request_for(&target, &session_id()));
    follow(&mut held, TURN_WAIT, "the agent's start", ready);
    held
}

/// `existing_only` for a worker that kept the session (a live update); a restarted worker reopens it cold.
fn reattach(worker: &RealWorker, id: &str, existing_only: bool) -> Held {
    let target = worker.target();
    let mut held = Held::attach(Peer::greeted(&target), &AttachRequest { existing_only, ..request_for(&target, id) });
    follow(&mut held, TURN_WAIT, "the reattached session", ready);
    held
}

/// Sends `text` and follows the turn to its answer, accepting whatever the agent asks; gives the asked methods.
fn turn(held: &mut Held, text: &str) -> Vec<String> {
    let before = assistant_rows(held.replica.state().unwrap());
    held.lease.perform(&held.peer.client, "send", prompt(text)).expect("the worker takes the prompt");
    let mut asked = Vec::new();
    let mut answered: Vec<Value> = Vec::new();
    let unanswered = |state: &SessionState, answered: &[Value]| permissions(state).into_iter().find(|permission| !answered.contains(&permission["rpcID"]));
    loop {
        follow(held, TURN_WAIT, "the answer", |state| (!busy(state) && assistant_rows(state) > before) || unanswered(state, &answered).is_some());
        let Some(permission) = unanswered(held.replica.state().unwrap(), &answered) else { return asked };
        answered.push(permission["rpcID"].clone());
        asked.push(permission["method"].as_str().unwrap_or_default().to_owned());
        let answer = json!({"rpcID": permission["rpcID"], "method": permission["method"], "result": {"decision": "accept"}});
        held.lease.perform(&held.peer.client, "answer", answer).expect("the worker takes the answer");
    }
}

fn last_answer(held: &Held) -> String {
    let state = held.replica.state().unwrap();
    let last = state.rows.iter().rev().find(|row| row.kind == "assistant").map(|row| row.items.clone()).unwrap_or_default();
    last.iter().filter_map(|id| state.items.get(id)?.get("text")?.as_str()).collect::<Vec<_>>().join(" ").to_lowercase()
}

fn assert_on(held: &Held, provider: &str, label: &str) {
    let state = held.replica.state().unwrap();
    assert_eq!(meta(state, "providerLabel"), label, "{}", describe(state));
    assert_eq!(meta(state, "account")["provider"], provider);
    assert!(meta(state, "threadID").as_str().is_some_and(|thread| !thread.is_empty()), "{:?}", meta(state, "threadID"));
}

fn this_build() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_vcx-worker"))
}

fn label(provider: &str) -> &'static str {
    if provider == "claude" { "Claude" } else { "Codex" }
}

fn answers_a_one_word_prompt(provider: &str) {
    let worker = RealWorker::start(&format!("{provider}-turn"), &this_build(), provider, "bypass");
    let mut held = open(&worker);

    let asked = turn(&mut held, PONG);

    assert_on(&held, provider, label(provider));
    assert!(last_answer(&held).contains("pong"), "{}", describe(held.replica.state().unwrap()));
    assert!(asked.is_empty(), "nothing to ask in bypass: {asked:?}");
    eprintln!("{provider}: thread {} answered {:?}", meta(held.replica.state().unwrap(), "threadID"), short(&last_answer(&held)));
}

#[test]
#[ignore = "real agent: VCX_REAL_AGENTS=1, spends his quota"]
fn a_real_claude_turn_answers_through_the_worker() {
    if enabled() {
        answers_a_one_word_prompt("claude");
    }
}

#[test]
#[ignore = "real agent: VCX_REAL_AGENTS=1, spends his quota"]
fn a_real_codex_turn_answers_through_the_worker() {
    if enabled() {
        answers_a_one_word_prompt("codex");
    }
}

/// A file outside the session's folder: in `ask` mode Claude asks for the shell command, Codex's sandbox refuses the
/// write and the agent asks to run it outside.
fn asks_before_a_command_and_runs_it_once_accepted(provider: &str) {
    let worker = RealWorker::start(&format!("{provider}-ask"), &this_build(), provider, "ask");
    let written = worker.root.join("asked.txt");
    let mut held = open(&worker);

    let asked = turn(&mut held, "Run exactly this shell command once: echo ok > ../asked.txt\nThen reply with the single word: done");

    let state = held.replica.state().unwrap();
    let commands: Vec<String> = items_of(state, "commandExecution").map(|item| format!("{}:{}", item.get("command").and_then(Value::as_str).map(short).unwrap_or_default(), item.get("status").and_then(Value::as_str).unwrap_or(""))).collect();
    eprintln!("{provider}: asked {asked:?}, tool calls {commands:?}, answered {:?}", short(&last_answer(&held)));
    assert!(!asked.is_empty(), "the agent asked nothing: {}", describe(state));
    assert!(!commands.is_empty(), "no tool call row: {}", describe(state));
    assert_eq!(fs::read_to_string(&written).map(|text| text.trim().to_owned()).ok().as_deref(), Some("ok"), "the accepted command ran");
}

#[test]
#[ignore = "real agent: VCX_REAL_AGENTS=1, spends his quota"]
fn a_real_claude_asks_before_a_command_and_runs_it_once_accepted() {
    if enabled() {
        asks_before_a_command_and_runs_it_once_accepted("claude");
    }
}

#[test]
#[ignore = "real agent: VCX_REAL_AGENTS=1, spends his quota"]
fn a_real_codex_asks_before_a_command_and_runs_it_once_accepted() {
    if enabled() {
        asks_before_a_command_and_runs_it_once_accepted("codex");
    }
}

fn running_sleep(state: &SessionState) -> bool {
    busy(state) && items_of(state, "commandExecution").any(|item| item.get("command").and_then(Value::as_str).is_some_and(|command| command.contains("sleep 60")))
}

fn a_stopped_turn_ends_at_once_and_the_agent_takes_the_next(provider: &str) {
    let worker = RealWorker::start(&format!("{provider}-stop"), &this_build(), provider, "bypass");
    let mut held = open(&worker);
    let agents = worker.agents();
    held.lease.perform(&held.peer.client, "send", prompt("Run exactly this shell command once: sleep 60\nThen reply with the single word: late")).unwrap();
    follow(&mut held, TURN_WAIT, "the sleep command", running_sleep);

    let stopped = Instant::now();
    held.lease.perform(&held.peer.client, "stop", json!({})).expect("the worker takes the stop");
    follow(&mut held, STOP_WAIT, "the end of the stopped turn", |state| !busy(state));
    let took = stopped.elapsed();
    eprintln!("{provider}: stopped in {took:?}: {}", describe(held.replica.state().unwrap()));
    let asked = turn(&mut held, PONG);

    assert!(took < STOP_WAIT, "the stop took {took:?}");
    assert!(!last_answer(&held).contains("late"));
    assert!(last_answer(&held).contains("pong"), "{}", describe(held.replica.state().unwrap()));
    assert!(asked.is_empty());
    assert_eq!(worker.agents(), agents, "the same agent answers after the stop");
    let state = held.replica.state().unwrap();
    assert!(!items_of(state, "commandExecution").any(|item| item.get("status") == Some(&json!("inProgress"))), "the stopped command is still shown running: {}", describe(state));
}

#[test]
#[ignore = "real agent: VCX_REAL_AGENTS=1, spends his quota"]
fn a_real_claude_turn_stopped_mid_command_ends_and_the_next_one_answers() {
    if enabled() {
        a_stopped_turn_ends_at_once_and_the_agent_takes_the_next("claude");
    }
}

#[test]
#[ignore = "real agent: VCX_REAL_AGENTS=1, spends his quota"]
fn a_real_codex_turn_stopped_mid_command_ends_and_the_next_one_answers() {
    if enabled() {
        a_stopped_turn_ends_at_once_and_the_agent_takes_the_next("codex");
    }
}

fn resumes_the_conversation_after_the_worker_was_killed(provider: &str) {
    let mut worker = RealWorker::start(&format!("{provider}-resume"), &this_build(), provider, "bypass");
    let word = format!("kiwi{}", std::process::id());
    let mut first = open(&worker);
    turn(&mut first, &format!("Remember the code word {word}. Reply with the single word: ok"));
    let (id, thread) = (first.id().to_owned(), meta(first.replica.state().unwrap(), "threadID").clone());
    let agents_before = worker.agents();
    drop(first);

    worker.restart_after_kill();
    let mut second = reattach(&worker, &id, false);
    turn(&mut second, "What was the code word? Reply with the code word only");

    let state = second.replica.state().unwrap();
    eprintln!("{provider}: resumed thread {thread} -> {}, answered {:?}", meta(state, "threadID"), short(&last_answer(&second)));
    assert_eq!(meta(state, "threadID"), &thread, "the same conversation");
    assert!(last_answer(&second).contains(&word), "{}", describe(state));
    assert_ne!(worker.agents(), agents_before, "a new agent process resumed it");
}

#[test]
#[ignore = "real agent: VCX_REAL_AGENTS=1, spends his quota"]
fn a_real_claude_conversation_resumes_after_the_worker_was_killed() {
    if enabled() {
        resumes_the_conversation_after_the_worker_was_killed("claude");
    }
}

#[test]
#[ignore = "real agent: VCX_REAL_AGENTS=1, spends his quota"]
fn a_real_codex_conversation_resumes_after_the_worker_was_killed() {
    if enabled() {
        resumes_the_conversation_after_the_worker_was_killed("codex");
    }
}

fn old_build() -> PathBuf {
    std::env::var_os(OLD_WORKER).map(PathBuf::from).unwrap_or_else(|| vcx_config::homes::home_directory().join(INSTALLED_WORKER))
}

fn hello(worker: &RealWorker) -> Option<Hello> {
    Peer::connect(&worker.target()).client.hello().ok()
}

/// SIGUSR1, then waits for the worker to serve from its next image.
fn updated(worker: &RealWorker, before: &Hello) -> Hello {
    unsafe { libc::kill(before.pid as libc::pid_t, libc::SIGUSR1) };
    let deadline = Instant::now() + SOCKET_WAIT;
    loop {
        if let Some(hello) = hello(worker).filter(|hello| hello.instance_id != before.instance_id) {
            return hello;
        }
        assert!(Instant::now() < deadline, "the worker never came back in a new image: {}", fs::read_to_string(worker.root.join("worker.log")).map(|log| short(&log)).unwrap_or_default());
        std::thread::sleep(POLL);
    }
}

#[test]
#[ignore = "real agents: VCX_REAL_AGENTS=1, spends his quota"]
fn a_live_update_between_two_builds_keeps_an_idle_claude_and_codex_answering() {
    if !enabled() {
        return;
    }
    let old = old_build();
    assert_ne!(fs::read(&old).expect("the older build"), fs::read(this_build()).unwrap(), "the two builds must differ");
    let worker = RealWorker::start("update", &old, "claude", "bypass");
    let mut claude = open(&worker);
    follow(&mut claude, TURN_WAIT, "Claude's catalog", |state| meta(state, "models").as_array().is_some_and(|models| !models.is_empty()));
    worker.settings("codex", "bypass");
    let codex = open(&worker);
    let agents = worker.agents();
    let before = hello(&worker).unwrap();
    let ids = [claude.id().to_owned(), codex.id().to_owned()];
    drop((claude, codex));

    worker.replace_binary(&this_build());
    let after = updated(&worker, &before);
    let mut answers = Vec::new();
    for (id, provider) in ids.iter().zip(["claude", "codex"]) {
        let mut again = reattach(&worker, id, true);
        turn(&mut again, PONG);
        assert_on(&again, provider, label(provider));
        answers.push(last_answer(&again));
    }

    eprintln!("update {} -> {}: agents {agents:?}, answers {answers:?}", before.build, after.build);
    assert_eq!(after.pid, before.pid, "the worker is the same process");
    assert_eq!(agents.len(), 2, "one Claude and one Codex: {agents:?}");
    assert_eq!(worker.agents(), agents, "the same agent processes answered after the update");
    assert!(answers.iter().all(|answer| answer.contains("pong")), "{answers:?}");
    assert!(!worker.socket.with_extension("sock.swap.json").exists(), "the manifest is removed once adopted");
}
