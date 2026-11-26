//! Which provider a session runs and how its connection starts, as the Swift `Session` picks them: the checkpoint's
//! account, else the first available one for his default provider, each started with the environment
//! `agentEnvironment` gives it.

use crate::fleet;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::sync::mpsc::UnboundedReceiver;
use vcx_agents::agy::{AgyConnection, AgyOptions};
use vcx_agents::claude::{ClaudeConnection, ClaudeOptions};
use vcx_agents::claude_stream::ClaudePaths;
use vcx_agents::qwen::{self, QwenConnection, QwenOptions};
use vcx_agents::{Agent, AgentError, Connection, Incoming};
use vcx_config::{Account, Settings};

const CODEX: [&str; 2] = ["codex", "app-server"];
/// Agy and Qwen are one built-in account each, never in the saved list.
const BUILT_IN: [&str; 2] = ["agy", "qwen"];
const UNSET: [&str; 3] = ["PWD", "OLDPWD", "SHLVL"];
/// A subscription is what he pays for: an inherited, metered API key must never be used instead.
const METERED_KEYS: [&str; 4] = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"];
const FIXED_PATH: [&str; 6] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
const BUILD_QUEUE: &str = ".local/lib/build-stack/bin";
const LOG_LIMIT: u64 = 1024 * 1024;
/// The wake helper, as the app bundle holds it beside the worker's `Contents/MacOS`.
const WAKE_HELPER: &str = "../Resources/background.py";

pub fn label(provider: &str) -> String {
    match provider {
        "codex" => "Codex".into(),
        "agy" => "Antigravity".into(),
        _ => provider.get(..1).map_or_else(String::new, str::to_uppercase) + provider.get(1..).unwrap_or_default(),
    }
}

fn built_in(provider: &str) -> Account {
    Account { id: format!("{provider}-default"), name: format!("Default {}", label(provider)), provider: provider.into(), home: None, enabled: true }
}

/// `forced` is a test's provider; `saved` the account a checkpoint names; `now` in seconds since 1970.
pub fn choose(settings: &Settings, forced: Option<&str>, saved: Option<&str>, now: f64) -> Account {
    if let Some(provider) = forced {
        return settings.candidates(provider).into_iter().find(|account| account.provider == provider).unwrap_or_else(|| built_in(provider));
    }
    let mut restorable = settings.accounts().into_iter().chain(settings.candidates("auto").into_iter().filter(|account| BUILT_IN.contains(&account.provider.as_str())));
    if let Some(account) = saved.and_then(|id| restorable.find(|account| account.id == id)) {
        return account;
    }
    settings.available(&settings.default_provider(), now).into_iter().next().unwrap_or_else(|| built_in("codex"))
}

/// The provider's home when it is not the default one: Claude reads `CLAUDE_CONFIG_DIR` being set at all as another
/// keychain login, so the default `~/.claude` is never passed.
fn profile(account: &Account, home: &Path) -> Option<String> {
    let default_claude = home.join(".claude");
    account.home.clone().filter(|profile| !(account.provider == "claude" && Path::new(profile) == default_claude))
}

/// The agent's environment; `fleet` is its session's Fleet file.
pub fn environment(account: &Account, home: &Path, fleet: &str) -> Vec<(String, String)> {
    environment_from(std::env::vars().collect(), account, home, fleet)
}

/// `inherited` is the worker's own environment: a Fleet file there belongs to another session.
fn environment_from(inherited: Vec<(String, String)>, account: &Account, home: &Path, fleet: &str) -> Vec<(String, String)> {
    let inherited_path: String = inherited.iter().find(|(key, _)| key == "PATH").map(|(_, value)| value.clone()).unwrap_or_default();
    let mut environment: Vec<(String, String)> = inherited
        .into_iter()
        .filter(|(key, _)| !key.starts_with("CLAUDE") && !UNSET.contains(&key.as_str()) && !METERED_KEYS.contains(&key.as_str()))
        .filter(|(key, _)| key != "PATH" && !fleet::VARIABLES.contains(&key.as_str()))
        .collect();
    let queue = home.join(BUILD_QUEUE);
    let fixed = std::iter::once(home.join(".local/bin").to_string_lossy().into_owned()).chain(FIXED_PATH.map(str::to_owned));
    let mut path: Vec<String> = Vec::new();
    for entry in queue.is_dir().then(|| queue.to_string_lossy().into_owned()).into_iter().chain(inherited_path.split(':').map(str::to_owned)).chain(fixed) {
        if !entry.is_empty() && !path.contains(&entry) {
            path.push(entry);
        }
    }
    environment.push(("PATH".into(), path.join(":")));
    if let Some(profile) = profile(account, home) {
        environment.push((if account.provider == "claude" { "CLAUDE_CONFIG_DIR" } else { "CODEX_HOME" }.into(), profile));
    }
    environment.extend(fleet::variables(fleet));
    environment
}

/// `program` (`codex app-server`, or a test's agent) under `env`, with the environment the other agents get: only names
/// are removed and PATH, CODEX_HOME and the session's files set on its command line, since any process can read
/// another's arguments.
fn codex_command(environment: &[(String, String)], program: Vec<String>) -> Vec<String> {
    let mut command = vec!["/usr/bin/env".to_owned()];
    for (key, _) in std::env::vars().filter(|(key, _)| !environment.iter().any(|(kept, _)| kept == key)) {
        command.extend(["-u".to_owned(), key]);
    }
    command.extend(environment.iter().filter(|(key, _)| key == "PATH" || key == "CODEX_HOME" || fleet::VARIABLES.contains(&key.as_str())).map(|(key, value)| format!("{key}={value}")));
    command.extend(program);
    command
}

/// Opens the log for appending, cut back to its last half once past the limit, as `vcx-agents` keeps the other
/// agents' logs (its own opener is private to it).
fn open_log(path: &Path) -> std::io::Result<std::fs::File> {
    use std::io::{Read, Seek, SeekFrom};
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if std::fs::metadata(path).is_ok_and(|meta| meta.len() > LOG_LIMIT) {
        let mut old = std::fs::File::open(path)?;
        old.seek(SeekFrom::End(-((LOG_LIMIT / 2) as i64)))?;
        let mut kept = Vec::new();
        old.read_to_end(&mut kept)?;
        std::fs::write(path, kept)?;
    }
    std::fs::OpenOptions::new().create(true).append(true).open(path)
}

fn wake_command() -> Option<Vec<String>> {
    let helper = std::env::current_exe().ok()?.parent()?.join(WAKE_HELPER);
    helper.exists().then(|| vec!["/usr/bin/python3".to_owned(), helper.to_string_lossy().into_owned(), "--ensure-qwen".to_owned()])
}

pub struct Start<'a> {
    pub account: &'a Account,
    pub settings: &'a Settings,
    /// `bypass`, or a mode that asks first: his settings' unless the session chose another.
    pub mode: &'a str,
    /// Where the agent's stderr goes, kept per conversation.
    pub log: PathBuf,
    /// VCX's own Claude settings, layered over his when the file exists.
    pub claude_settings: PathBuf,
    /// A test's agent in place of the provider's command; Qwen has none, it speaks HTTP.
    pub fixture: Option<Vec<String>>,
    pub cwd: &'a str,
    /// The session's Fleet file, beside which its progress and task files sit.
    pub fleet: &'a str,
}

pub async fn connect(start: Start<'_>) -> Result<(Connection, UnboundedReceiver<Incoming>), String> {
    let failed = |error: AgentError| error.message;
    let home = vcx_config::homes::home_directory();
    let environment = environment(start.account, &home, start.fleet);
    let cwd = start.cwd.to_owned();
    match start.account.provider.as_str() {
        "claude" => {
            let profile = profile(start.account, &home).map(PathBuf::from);
            let settings = Some(start.claude_settings).filter(|file| file.exists());
            let options = ClaudeOptions { command: start.fixture, cwd, mode: start.mode.to_owned(), environment: Some(environment), log: Some(start.log), settings, paths: ClaudePaths::standard(profile.clone()), profile };
            let (claude, incoming) = ClaudeConnection::start(options).await.map_err(failed)?;
            Ok((Connection::Claude(claude), incoming))
        }
        "agy" => {
            let (agy, incoming) = AgyConnection::start(AgyOptions { command: start.fixture, cwd, environment: Some(environment), log: Some(start.log) }).await.map_err(failed)?;
            Ok((Connection::Agy(agy), incoming))
        }
        "qwen" => {
            let qwen = start.settings.qwen();
            let wake = if qwen.wake { wake_command() } else { None };
            let options = QwenOptions { url: qwen.url, proxy: qwen.proxy, model: qwen.model, mode: start.mode.to_owned(), cwd, environment: Some(environment), wake, home, step_limit: qwen::STEP_LIMIT };
            let (qwen, incoming) = QwenConnection::start(options).await.map_err(failed)?;
            Ok((Connection::Qwen(qwen), incoming))
        }
        _ => {
            let command = codex_command(&environment, start.fixture.unwrap_or_else(|| CODEX.map(str::to_owned).into()));
            let log = open_log(&start.log).map_err(|error| format!("Cannot open the agent log: {error}"))?;
            let (agent, incoming) = Agent::spawn(&command, Path::new(&start.cwd), Stdio::from(log)).map_err(|error| format!("Cannot start the agent: {error}"))?;
            Ok((Connection::Codex(agent), incoming))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: f64 = 1_000_000.0;

    fn settings(text: &str) -> Settings {
        Settings::parse(text.as_bytes()).unwrap()
    }

    #[test]
    fn takes_the_first_account_of_his_default_provider() {
        let chosen = choose(&settings(r#"{"defaultProvider": "codex"}"#), None, None, NOW);

        assert_eq!(chosen.id, "codex-default");
    }

    #[test]
    fn skips_an_account_still_limited_and_tries_the_next() {
        let chosen = choose(&settings(r#"{"defaultProvider": "claude", "limits": {"claude-default": 2000000}}"#), None, None, NOW);

        assert_eq!(chosen.id, "codex-default");
    }

    #[test]
    fn reopens_the_account_a_checkpoint_names_even_a_built_in_one() {
        let chosen = choose(&settings(r#"{"defaultProvider": "codex"}"#), None, Some("qwen"), NOW);

        assert_eq!((chosen.id.as_str(), chosen.provider.as_str()), ("qwen", "qwen"));
    }

    #[test]
    fn a_tests_provider_wins_over_his_settings() {
        let chosen = choose(&settings(r#"{"defaultProvider": "codex"}"#), Some("agy"), Some("codex-default"), NOW);

        assert_eq!(chosen.provider, "agy");
    }

    #[test]
    fn never_passes_a_metered_key_or_the_default_claude_home() {
        let home = Path::new("/Users/fixture");
        let account = Account { id: "claude-default".into(), name: "Default Claude".into(), provider: "claude".into(), home: Some("/Users/fixture/.claude".into()), enabled: true };

        let environment = environment(&account, home, "");

        assert!(environment.iter().all(|(key, _)| !METERED_KEYS.contains(&key.as_str()) && key != "CLAUDE_CONFIG_DIR"));
        assert!(environment.iter().any(|(key, value)| key == "PATH" && value.split(':').any(|entry| entry == "/usr/bin")));
    }

    #[test]
    fn gives_a_codex_profile_its_own_home() {
        let account = Account { id: "codex-work".into(), name: "Work".into(), provider: "codex".into(), home: Some("/tmp/codex-work".into()), enabled: true };

        let environment = environment(&account, Path::new("/Users/fixture"), "");

        assert!(environment.contains(&("CODEX_HOME".into(), "/tmp/codex-work".into())));
    }

    fn codex_account() -> Account {
        Account { id: "codex-default".into(), name: "Default Codex".into(), provider: "codex".into(), home: None, enabled: true }
    }

    fn named<'a>(environment: &'a [(String, String)], key: &str) -> Vec<&'a str> {
        environment.iter().filter(|(name, _)| name == key).map(|(_, value)| value.as_str()).collect()
    }

    #[test]
    fn an_agents_fleet_progress_and_task_files_are_its_own_sessions_never_inherited_ones() {
        let inherited = [("FLEET_CONTEXT_FILE", "/tmp/other/task.context"), ("VCX_PROGRESS_FILE", "/tmp/other/task.progress"), ("VCX_TASK_FILE", "/tmp/other/task.goal"), ("PATH", "/usr/bin")].map(|(key, value)| (key.to_owned(), value.to_owned()));

        let own = environment_from(inherited.to_vec(), &codex_account(), Path::new("/Users/fixture"), "/tmp/fleet-a/task.context");
        let none = environment_from(inherited.to_vec(), &codex_account(), Path::new("/Users/fixture"), "");

        assert_eq!(fleet::VARIABLES.map(|key| named(&own, key)), [vec!["/tmp/fleet-a/task.context"], vec!["/tmp/fleet-a/task.progress"], vec!["/tmp/fleet-a/task.goal"]]);
        assert!(fleet::VARIABLES.iter().all(|key| named(&none, key).is_empty()));
    }

    #[test]
    fn codex_gets_the_session_files_on_its_command_line_and_runs_the_given_agent() {
        let environment = environment(&codex_account(), Path::new("/Users/fixture"), "/tmp/fleet-a/task.context");

        let command = codex_command(&environment, vec!["/usr/bin/python3".into(), "agent.py".into()]);

        assert!(command.contains(&"VCX_TASK_FILE=/tmp/fleet-a/task.goal".to_owned()), "{command:?}");
        assert_eq!(command[command.len() - 2..], ["/usr/bin/python3", "agent.py"]);
    }

    #[test]
    fn names_each_provider_as_the_swift_app_does() {
        assert_eq!(["codex", "claude", "agy", "qwen"].map(label), ["Codex", "Claude", "Antigravity", "Qwen"]);
    }
}
