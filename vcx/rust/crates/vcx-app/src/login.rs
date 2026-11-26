//! Signing in a new subscription account (Swift `Settings.signIn`): the provider's own login runs in a fresh profile
//! folder under `Accounts/`, its output is the sign-in panel's text, and a login that succeeds adds the account.

use serde_json::{Value, json};
use std::io::Read;
use std::os::unix::fs::symlink;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use vcx_config::{Account, SettingsFile};

pub const PROVIDERS: [&str; 2] = ["claude", "codex"];
/// The panel shows the end of what the login printed (Swift keeps the last 16 KB).
const KEPT_OUTPUT: usize = 16384;
/// A subscription is what he pays for: an inherited, metered API key must never be used instead.
const METERED_KEYS: [&str; 4] = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"];
const FIXED_PATH: [&str; 6] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
const STARTED: &str = "Complete sign-in in your browser.";
const ADDED: &str = "Account added. Enable the accounts to use for fallback.";
const FAILED: &str = "Sign-in did not complete. You can retry or use an existing profile.";

/// The panel's message; an empty text hides it.
pub fn message(text: &str, signing_in: bool) -> Value {
    json!({"type": "login", "text": text, "signingIn": signing_in})
}

/// A login still running; cancelling it ends the provider's process.
pub struct Running {
    pid: u32,
    done: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
}

impl Running {
    pub fn is_running(&self) -> bool {
        !self.done.load(Ordering::SeqCst)
    }

    pub fn cancel(&self) {
        if self.is_running() {
            self.cancelled.store(true, Ordering::SeqCst);
            // SAFETY: kill has no memory preconditions; the pid is the login's, still unreaped while `done` is false.
            unsafe { libc::kill(self.pid as i32, libc::SIGTERM) };
        }
    }
}

pub struct Start<'a> {
    pub provider: &'a str,
    /// His shared settings folder, where `Accounts/` lives.
    pub shared: &'a Path,
    pub home: &'a Path,
    /// A test's login in place of the provider's.
    pub program: Option<Vec<String>>,
}

/// Starts the login; `report` gets each panel message, from other threads, the last one once it ends.
pub fn start(start: Start, report: impl Fn(Value) + Send + 'static) -> Result<Running, String> {
    let provider = start.provider.to_owned();
    let id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let profile = start.shared.join("Accounts").join(&provider).join(&id);
    vcx_config::private_folder(&profile)?;
    link_his_setup(&provider, start.home, &profile)?;
    let program = start.program.unwrap_or_else(|| provider_login(&provider));
    let (mut reader, writer) = std::io::pipe().map_err(|error| error.to_string())?;
    let mut command = Command::new(&program[0]);
    command.args(&program[1..]).env_clear().envs(environment(&provider, start.home, &profile)).stdin(Stdio::null());
    command.stdout(writer.try_clone().map_err(|error| error.to_string())?).stderr(writer);
    let mut child = command.spawn().map_err(|error| format!("Cannot start the {provider} sign-in: {error}."))?;
    // The pipe's write end lives in the child only, so the read below ends with it.
    drop(command);
    let (done, cancelled) = (Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(false)));
    let running = Running { pid: child.id(), done: done.clone(), cancelled: cancelled.clone() };
    report(message(STARTED, true));
    let settings = SettingsFile::new(start.shared);
    thread::spawn(move || {
        let mut kept: Vec<u8> = Vec::new();
        let mut chunk = [0u8; 4096];
        while let Ok(read) = reader.read(&mut chunk) {
            if read == 0 {
                break;
            }
            kept.extend_from_slice(&chunk[..read]);
            kept.drain(..kept.len().saturating_sub(KEPT_OUTPUT));
            report(message(&plain(&String::from_utf8_lossy(&kept)), true));
        }
        let succeeded = child.wait().is_ok_and(|status| status.success());
        done.store(true, Ordering::SeqCst);
        let text = match succeeded {
            true => add_account(&settings, &provider, &id, &profile).map_or_else(|problem| problem, |()| ADDED.to_owned()),
            false if cancelled.load(Ordering::SeqCst) => String::new(),
            false => FAILED.to_owned(),
        };
        report(message(&text, false));
    });
    Ok(running)
}

fn provider_login(provider: &str) -> Vec<String> {
    let login: &[&str] = if provider == "claude" { &["claude", "auth", "login", "--claudeai"] } else { &["codex", "login", "--device-auth"] };
    std::iter::once("/usr/bin/env").chain(login.iter().copied()).map(str::to_owned).collect()
}

/// The new profile reads his own settings, instructions and skills, as the Swift sign-in links them.
fn link_his_setup(provider: &str, home: &Path, profile: &Path) -> Result<(), String> {
    let (folder, names): (&str, &[&str]) = match provider {
        "claude" => (".claude", &["settings.json", "CLAUDE.md", "skills", "agents", "commands", "plugins"]),
        _ => (".codex", &["config.toml", "AGENTS.md", "skills", "plugins"]),
    };
    for name in names {
        let source = home.join(folder).join(name);
        if source.exists() {
            symlink(&source, profile.join(name)).map_err(|error| format!("Cannot link {}: {error}.", source.display()))?;
        }
    }
    Ok(())
}

fn environment(provider: &str, home: &Path, profile: &Path) -> Vec<(String, String)> {
    let mut environment: Vec<(String, String)> = std::env::vars().filter(|(key, _)| !key.starts_with("CLAUDE") && !METERED_KEYS.contains(&key.as_str()) && key != "PATH" && key != "CODEX_HOME").collect();
    let inherited = std::env::var("PATH").unwrap_or_default();
    let mut path: Vec<String> = Vec::new();
    for entry in inherited.split(':').map(str::to_owned).chain(std::iter::once(home.join(".local/bin").to_string_lossy().into_owned())).chain(FIXED_PATH.map(str::to_owned)) {
        if !entry.is_empty() && !path.contains(&entry) {
            path.push(entry);
        }
    }
    environment.push(("PATH".into(), path.join(":")));
    environment.push((if provider == "claude" { "CLAUDE_CONFIG_DIR" } else { "CODEX_HOME" }.into(), profile.to_string_lossy().into_owned()));
    environment
}

/// Named after how many accounts of the provider there are, as the Swift app names it.
fn add_account(settings: &SettingsFile, provider: &str, id: &str, profile: &Path) -> Result<(), String> {
    settings.update(|settings| {
        let number = settings.accounts().iter().filter(|account| account.provider == provider).count() + 1;
        let mut name: String = provider[..1].to_uppercase();
        name.push_str(&provider[1..]);
        let account = Account { id: id.to_owned(), name: format!("{name} account {number}"), provider: provider.to_owned(), home: Some(profile.to_string_lossy().into_owned()), enabled: true };
        settings.add_account(&account);
    }).map(drop)
}

/// The login's output without its terminal colours and cursor moves.
fn plain(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' || chars.peek() != Some(&'[') {
            out.push(c);
            continue;
        }
        chars.next();
        while chars.next_if(|c| ('0'..='?').contains(c)).is_some() {}
        while chars.next_if(|c| (' '..='/').contains(c)).is_some() {}
        chars.next_if(|c| ('@'..='~').contains(c));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Mutex;
    use std::sync::mpsc;
    use std::time::Duration;

    const WAIT: Duration = Duration::from_secs(10);

    fn scratch(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("vcx-app-login-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(folder.join("home/.claude/skills")).unwrap();
        vcx_config::private_folder(&folder.join("shared")).unwrap();
        folder
    }

    fn run(folder: &Path, script: &str) -> (Vec<Value>, Running) {
        let (sent, received) = mpsc::channel();
        let sent = Mutex::new(sent);
        let start = Start { provider: "claude", shared: &folder.join("shared"), home: &folder.join("home"), program: Some(vec!["/bin/sh".into(), "-c".into(), script.into()]) };
        let running = super::start(start, move |message| drop(sent.lock().unwrap().send(message))).unwrap();
        let mut messages = Vec::new();
        while let Ok(message) = received.recv_timeout(WAIT) {
            let last = message["signingIn"] == false;
            messages.push(message);
            if last {
                break;
            }
        }
        (messages, running)
    }

    #[test]
    fn shows_the_login_output_and_adds_the_account_in_its_own_profile() {
        let folder = scratch("added");

        let (messages, running) = run(&folder, r#"printf '\033[1mOpen\033[0m https://claude.example/x\n'; printf '%s' "$CLAUDE_CONFIG_DIR" > "$CLAUDE_CONFIG_DIR/seen""#);

        let accounts = SettingsFile::new(folder.join("shared")).load().unwrap().accounts();
        let added = accounts.last().unwrap();
        let profile = PathBuf::from(added.home.clone().unwrap());
        let seen = std::fs::read_to_string(profile.join("seen")).unwrap();
        let mode = std::fs::metadata(&profile).unwrap().permissions().mode() & 0o777;
        let linked = std::fs::read_link(profile.join("skills")).unwrap();
        std::fs::remove_dir_all(&folder).unwrap();
        assert_eq!(messages.first(), Some(&message(STARTED, true)));
        assert!(messages.contains(&message("Open https://claude.example/x\n", true)), "{messages:?}");
        assert_eq!(messages.last(), Some(&message(ADDED, false)));
        assert!(!running.is_running());
        assert_eq!((added.name.as_str(), added.provider.as_str(), added.enabled), ("Claude account 2", "claude", true));
        assert_eq!((seen, mode, linked), (profile.to_string_lossy().into_owned(), 0o700, folder.join("home/.claude/skills")));
    }

    #[test]
    fn says_the_sign_in_did_not_complete_and_adds_nothing() {
        let folder = scratch("failed");

        let (messages, _) = run(&folder, "exit 3");

        let accounts = SettingsFile::new(folder.join("shared")).load().unwrap().accounts();
        std::fs::remove_dir_all(&folder).unwrap();
        assert_eq!(messages.last(), Some(&message(FAILED, false)));
        assert_eq!(accounts.len(), 2, "{accounts:?}");
    }

    #[test]
    fn hides_the_panel_once_a_cancelled_login_ends() {
        let folder = scratch("cancelled");
        let (sent, received) = mpsc::channel();
        let sent = Mutex::new(sent);
        let start = Start { provider: "codex", shared: &folder.join("shared"), home: &folder.join("home"), program: Some(vec!["/bin/sleep".into(), "30".into()]) };
        let running = super::start(start, move |message| drop(sent.lock().unwrap().send(message))).unwrap();

        running.cancel();

        let messages: Vec<Value> = std::iter::from_fn(|| received.recv_timeout(WAIT).ok()).take(2).collect();
        std::fs::remove_dir_all(&folder).unwrap();
        assert_eq!(messages, [message(STARTED, true), message("", false)]);
    }

    #[test]
    fn drops_terminal_colours_and_cursor_moves() {
        assert_eq!(plain("\u{1b}[1;32mok\u{1b}[0m \u{1b}[2K\u{1b}[?25lgo"), "ok go");
    }
}
