//! The run panel's core (Swift `Run.swift`, `CommandRun`): a command from a reply runs on a pseudo-terminal of its
//! own, so sudo and anything else that reads a tty can ask. A line typed while the terminal's echo is off (a password)
//! goes from the page's password field to the tty only: never to the agent, a log or the disk.
//!
//! The page posts `run {id, command}`, `runInput {id, line}` and `runStop {id}`; it hears back
//! `run {id, state: running | finished, output, hidden, code}` after each chunk of output.

use serde_json::{Value, json};
use std::collections::HashMap;
use std::ffi::{CString, OsStr};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;

/// The output kept, from its end, as in Swift (`outputLimit`).
const OUTPUT_LIMIT: usize = 200_000;
/// A fixed count, so the dots never tell the password's length.
const MASK_LENGTH: usize = 8;
const MASK: char = '•';
const TAB_STOP: usize = 8;
const SHELL: &str = "/bin/zsh";
const READ_CHUNK: usize = 8192;
const EXIT_NOT_RUN: i32 = 127;
const EXIT_SIGNALLED: i32 = 128;
const ESCAPE: char = '\u{1b}';
const BELL: char = '\u{7}';
/// The agent's environment as Swift's `agentEnvironment` leaves it for a command: no Claude variables, no shell state,
/// no metered API key.
const DROPPED_VARIABLES: [&str; 7] = ["PWD", "OLDPWD", "SHLVL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"];
const DROPPED_PREFIX: &str = "CLAUDE";

/// Hands a message to the page that asked, from any thread.
pub type Emit = Arc<dyn Fn(Value) + Send + Sync>;

struct Run {
    master: i32,
    pid: i32,
    raw: Vec<u8>,
    hidden: bool,
    emit: Emit,
}

impl Run {
    fn show(&self, id: &str, state: &str, code: Option<i32>) {
        let output = terminal_text(&String::from_utf8_lossy(&self.raw));
        (self.emit)(json!({"type": "run", "id": id, "state": state, "output": output, "hidden": self.hidden, "code": code}));
    }

    fn keep(&mut self, bytes: &[u8]) {
        self.raw.extend_from_slice(bytes);
        if self.raw.len() > OUTPUT_LIMIT {
            self.raw.drain(..self.raw.len() - OUTPUT_LIMIT);
        }
    }
}

type Shared = Arc<Mutex<Run>>;

/// The commands running in this process, by the id their page gave them.
fn runs() -> &'static Mutex<HashMap<String, Shared>> {
    static RUNS: OnceLock<Mutex<HashMap<String, Shared>>> = OnceLock::new();
    RUNS.get_or_init(Default::default)
}

/// Serves the page's `run`, `runInput` and `runStop`; `false` for any other message.
pub fn handle(message: &Value, cwd: &Path, emit: Emit) -> bool {
    let text = |key: &str| message.get(key).and_then(Value::as_str);
    let Some(id) = text("id") else { return false };
    match text("type") {
        Some("run") => {
            if let Some(command) = text("command") {
                start(id, command, cwd, emit);
            }
        }
        Some("runInput") => send(id, text("line").unwrap_or_default()),
        Some("runStop") => stop(id),
        _ => return false,
    }
    true
}

fn environment() -> Vec<CString> {
    let kept = std::env::vars_os().filter(|(name, _)| {
        let name = name.to_string_lossy();
        !name.starts_with(DROPPED_PREFIX) && !DROPPED_VARIABLES.contains(&name.as_ref()) && name != "TERM"
    });
    let pairs = kept.map(|(name, value)| [name.as_bytes(), b"=", value.as_bytes()].concat());
    pairs.chain([b"TERM=dumb".to_vec()]).filter_map(|pair| CString::new(pair).ok()).collect()
}

fn start(id: &str, command: &str, cwd: &Path, emit: Emit) {
    if runs().lock().unwrap().contains_key(id) {
        return;
    }
    let failed = |reason: String| emit(json!({"type": "run", "id": id, "state": "finished", "output": reason, "hidden": false, "code": -1}));
    let (Ok(command), Ok(folder)) = (CString::new(command), CString::new(OsStr::as_bytes(cwd.as_os_str()))) else {
        return failed("The command holds a NUL character.".into());
    };
    // Built before the fork: the child may only call async-signal-safe functions until execve.
    let words = [CString::new(SHELL).unwrap(), CString::new("-c").unwrap(), command];
    let argv: Vec<*const libc::c_char> = words.iter().map(|word| word.as_ptr()).chain([std::ptr::null()]).collect();
    let variables = environment();
    let envp: Vec<*const libc::c_char> = variables.iter().map(|pair| pair.as_ptr()).chain([std::ptr::null()]).collect();
    let mut master = -1;
    // SAFETY: forkpty with no name, termios or size; the child only calls chdir, execve and _exit on memory made above.
    let pid = unsafe { libc::forkpty(&mut master, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut()) };
    if pid == 0 {
        unsafe {
            libc::chdir(folder.as_ptr());
            libc::execve(argv[0], argv.as_ptr(), envp.as_ptr());
            libc::_exit(EXIT_NOT_RUN);
        }
    }
    if pid < 0 {
        return failed(format!("Could not open a terminal: {}", std::io::Error::last_os_error()));
    }
    let run = Arc::new(Mutex::new(Run { master, pid, raw: Vec::new(), hidden: false, emit }));
    runs().lock().unwrap().insert(id.to_owned(), run.clone());
    run.lock().unwrap().show(id, "running", None);
    let id = id.to_owned();
    thread::spawn(move || follow(&id, &run, master, pid));
}

/// Reads the terminal until the command ends, telling the page each chunk and whether the terminal echoes.
fn follow(id: &str, run: &Shared, master: i32, pid: i32) {
    let mut buffer = [0u8; READ_CHUNK];
    loop {
        // SAFETY: `master` is this run's open terminal, read into a buffer of the length given.
        let count = unsafe { libc::read(master, buffer.as_mut_ptr().cast(), buffer.len()) };
        if count <= 0 {
            break;
        }
        let mut settings = unsafe { std::mem::zeroed::<libc::termios>() };
        // SAFETY: tcgetattr fills the termios given; a failure leaves it zeroed, which reads as echo off.
        let echo = unsafe { libc::tcgetattr(master, &mut settings) } == 0 && settings.c_lflag & libc::ECHO != 0;
        let mut run = run.lock().unwrap();
        run.keep(&buffer[..count as usize]);
        run.hidden = !echo;
        run.show(id, "running", None);
    }
    let mut status = 0;
    // SAFETY: `pid` is this run's child, waited for once; `master` is closed once, after its last read.
    unsafe {
        libc::waitpid(pid, &mut status, 0);
        libc::close(master);
    }
    let code = if libc::WIFEXITED(status) { libc::WEXITSTATUS(status) } else { EXIT_SIGNALLED + libc::WTERMSIG(status) };
    runs().lock().unwrap().remove(id);
    let mut run = run.lock().unwrap();
    run.master = -1;
    run.hidden = false;
    run.show(id, "finished", Some(code));
}

/// Types `line` and Return into the command's terminal. While its echo is off, the output shows dots in its place.
fn send(id: &str, line: &str) {
    let Some(run) = runs().lock().unwrap().get(id).cloned() else { return };
    let mut run = run.lock().unwrap();
    if run.master < 0 {
        return;
    }
    if run.hidden {
        let mask = format!("{}\n", MASK.to_string().repeat(MASK_LENGTH));
        run.keep(mask.as_bytes());
        run.show(id, "running", None);
    }
    let mut bytes = [line.as_bytes(), b"\n"].concat();
    // SAFETY: `master` is open while the run is listed; the buffer is the length given.
    unsafe { libc::write(run.master, bytes.as_ptr().cast(), bytes.len()) };
    // The copy made here is cleared at once; the page clears its field. Volatile, so the clearing is not optimized away.
    for byte in &mut bytes {
        unsafe { std::ptr::write_volatile(byte, 0) };
    }
}

/// A hangup to the command's whole group: forkpty made it a session leader, and sudo relays it to root's side.
fn stop(id: &str) {
    if let Some(run) = runs().lock().unwrap().get(id) {
        // SAFETY: a signal to the process group this run's child leads.
        unsafe { libc::kill(-run.lock().unwrap().pid, libc::SIGHUP) };
    }
}

/// Colour and cursor escapes taken out: `ESC [ … final` and `ESC ] … BEL`, as Swift's pattern; any other escape stays.
fn without_escapes(raw: &str) -> String {
    let characters: Vec<char> = raw.chars().collect();
    let mut plain = String::with_capacity(raw.len());
    let mut at = 0;
    while at < characters.len() {
        let end = (characters[at] == ESCAPE).then(|| escape_end(&characters, at + 1)).flatten();
        match end {
            Some(end) => at = end,
            None => {
                plain.push(characters[at]);
                at += 1;
            }
        }
    }
    plain
}

/// Where the escape whose introducer is at `at` ends, or `None` when it is not one the panel removes.
fn escape_end(characters: &[char], at: usize) -> Option<usize> {
    match characters.get(at)? {
        '[' => {
            let mut next = at + 1;
            while characters.get(next).is_some_and(|c| c.is_ascii_digit() || *c == ';' || *c == '?') {
                next += 1;
            }
            while characters.get(next).is_some_and(|c| (' '..='/').contains(c)) {
                next += 1;
            }
            characters.get(next).filter(|c| ('@'..='~').contains(*c)).map(|_| next + 1)
        }
        ']' => characters[at..].iter().position(|c| *c == BELL).map(|bell| at + bell + 1),
        _ => None,
    }
}

/// A terminal puts a tab's next column on a multiple of 8.
fn expand_tabs(line: &str) -> String {
    let mut result = String::new();
    for character in line.chars() {
        if character == '\t' {
            let width = result.chars().count();
            result.push_str(&" ".repeat(TAB_STOP - width % TAB_STOP));
        } else {
            result.push(character);
        }
    }
    result
}

/// Carriage returns redraw a line (progress bars) and escapes colour it: the panel keeps each line's last drawing, plain.
pub fn terminal_text(raw: &str) -> String {
    let plain = without_escapes(raw).replace("\r\n", "\n");
    let lines: Vec<String> = plain.split('\n').map(|line| expand_tabs(line.split('\r').rfind(|part| !part.is_empty()).unwrap_or_default())).collect();
    lines.join("\n").trim_matches('\n').to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    const WAIT: Duration = Duration::from_secs(10);

    fn collect() -> (Emit, mpsc::Receiver<Value>) {
        let (sender, receiver) = mpsc::channel();
        let sender = Mutex::new(sender);
        (Arc::new(move |message| sender.lock().unwrap().send(message).unwrap()), receiver)
    }

    /// The first message the run sends that `wanted` accepts.
    fn until(receiver: &mpsc::Receiver<Value>, wanted: impl Fn(&Value) -> bool) -> Value {
        loop {
            let message = receiver.recv_timeout(WAIT).expect("the run went quiet");
            if wanted(&message) {
                return message;
            }
        }
    }

    #[test]
    fn keeps_a_progress_lines_last_drawing_without_colour_codes_or_a_last_blank_line() {
        assert_eq!(terminal_text("a\r\nb 10%\rb 100%\n\u{1b}[31mred\u{1b}[0m\r\n"), "a\nb 100%\nred");
        assert_eq!(terminal_text("\u{1b}]0;title\u{7}x \u{1b}[?25lok"), "x ok");
    }

    #[test]
    fn lines_up_columns_on_eight_column_tab_stops() {
        assert_eq!(terminal_text("bin\tetc\nprivate\tx"), "bin     etc\nprivate x");
    }

    #[test]
    fn runs_a_command_in_its_folder_and_tells_its_exit_status() {
        let (emit, receiver) = collect();
        let folder = std::env::temp_dir().canonicalize().unwrap();

        assert!(handle(&json!({"type": "run", "id": "folder", "command": "pwd; exit 3"}), &folder, emit));

        let finished = until(&receiver, |message| message["state"] == "finished");
        assert_eq!((finished["code"].clone(), finished["output"].clone()), (json!(3), json!(folder.to_string_lossy())));
        assert!(!runs().lock().unwrap().contains_key("folder"));
    }

    #[test]
    fn sends_a_password_typed_with_echo_off_to_the_command_and_never_shows_it() {
        let (emit, receiver) = collect();
        let command = "stty -echo; printf 'Password:'; read secret; stty echo; echo; echo length=${#secret}; exit 3";

        handle(&json!({"type": "run", "id": "password", "command": command}), &std::env::temp_dir(), emit.clone());
        let asking = until(&receiver, |message| message["hidden"] == true);
        handle(&json!({"type": "runInput", "id": "password", "line": "hunter2"}), Path::new("/"), emit);
        let finished = until(&receiver, |message| message["state"] == "finished");

        assert!(asking["output"].as_str().unwrap().ends_with("Password:"), "{asking}");
        let output = finished["output"].as_str().unwrap();
        assert_eq!(finished["code"], 3);
        assert!(output.contains("length=7") && !output.contains("hunter2") && output.contains("Password:••••••••\n"), "{output}");
    }

    #[test]
    fn stop_hangs_up_a_running_command() {
        let (emit, receiver) = collect();

        handle(&json!({"type": "run", "id": "stop", "command": "echo started; sleep 30"}), &std::env::temp_dir(), emit.clone());
        until(&receiver, |message| message["output"] == "started");
        handle(&json!({"type": "runStop", "id": "stop"}), Path::new("/"), emit);
        let finished = until(&receiver, |message| message["state"] == "finished");

        assert_ne!(finished["code"], 0);
    }

    #[test]
    fn leaves_messages_that_are_not_the_run_panels() {
        let (emit, _receiver) = collect();

        assert!(!handle(&json!({"type": "files", "id": 1, "query": ""}), Path::new("/"), emit));
    }
}
