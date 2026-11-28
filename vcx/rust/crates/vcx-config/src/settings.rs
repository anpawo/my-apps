//! His `settings.json`, the one the Swift app (`Settings.swift`) and `background.py` (`preferences()`) read and write.
//! Typed accessors read over the file as it stands, so a key this code does not know survives a write, and a write
//! takes `settings.lock` the way both of them do: re-read under the lock, change, write in one move.

use crate::homes::{private_folder, write_private, PRIVATE_FILE};
use crate::json::{Document, Json, Style};
use std::fs;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

pub const DEFAULT_PROVIDER: &str = "auto";
pub const DEFAULT_MODE: &str = "bypass";
pub const QWEN_URL: &str = "http://100.100.151.8:11434/api/chat";
pub const QWEN_PROXY: &str = "socks5h://127.0.0.1:1056";
pub const QWEN_MODEL: &str = "qwen3.5-9b-abl";
/// The `/qwen` hosts: the same model served by this Mac's ollama, or by the Windows PC through the tailnet's SOCKS.
pub const QWEN_HOSTS: [(&str, &str, &str); 2] = [("mac", "http://localhost:11434/api/chat", ""), ("pc", QWEN_URL, QWEN_PROXY)];
/// The Swift app's fallback order; `background.py` leaves agy out.
pub const PROVIDERS: [&str; 4] = ["claude", "codex", "qwen", "agy"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Account {
    pub id: String,
    pub name: String,
    pub provider: String,
    /// The provider's home (`CLAUDE_CONFIG_DIR` or `CODEX_HOME`); none for the default one.
    pub home: Option<String>,
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Qwen {
    pub url: String,
    pub proxy: String,
    pub model: String,
    pub wake: bool,
}

impl Qwen {
    /// `mac`, `pc`, or `custom` for an endpoint neither names.
    pub fn host(&self) -> &'static str {
        QWEN_HOSTS.iter().find(|(_, url, proxy)| *url == self.url && *proxy == self.proxy).map_or("custom", |host| host.0)
    }
}

impl Account {
    fn new(id: &str, name: &str, provider: &str) -> Self {
        Account { id: id.into(), name: name.into(), provider: provider.into(), home: None, enabled: true }
    }

    fn from_json(value: &Json) -> Option<Self> {
        Some(Account {
            id: value.get("id")?.as_str()?.to_owned(),
            name: value.get("name").and_then(Json::as_str).unwrap_or_default().to_owned(),
            provider: value.get("provider")?.as_str()?.to_owned(),
            home: value.get("home").and_then(Json::as_str).map(str::to_owned),
            enabled: value.get("enabled").and_then(Json::as_bool).unwrap_or(true),
        })
    }

    fn to_json(&self) -> Json {
        let mut value = Json::default();
        value.set("id", Json::from(self.id.as_str()));
        value.set("name", Json::from(self.name.as_str()));
        value.set("provider", Json::from(self.provider.as_str()));
        if let Some(home) = &self.home {
            value.set("home", Json::from(home.as_str()));
        }
        value.set("enabled", Json::from(self.enabled));
        value
    }
}

/// The accounts a file without any holds, as the Swift app's `Preferences` declares them.
pub fn default_accounts() -> Vec<Account> {
    vec![Account::new("claude-default", "Default Claude", "claude"), Account::new("codex-default", "Default Codex", "codex")]
}

#[derive(Debug, Clone, Default)]
pub struct Settings {
    document: Document,
}

impl Settings {
    /// An object, or an empty file read as no settings at all.
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        if bytes.iter().all(u8::is_ascii_whitespace) {
            return Ok(Settings::default());
        }
        let document = Document::parse(bytes)?;
        if !matches!(document.root, Json::Object(_)) {
            return Err("The settings are not a JSON object.".into());
        }
        Ok(Settings { document })
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        self.document.to_bytes()
    }

    /// Who wrote the file last; a new value is written the same way.
    pub fn style(&self) -> Style {
        self.document.style
    }

    /// Any key, typed or not.
    pub fn get(&self, key: &str) -> Option<&Json> {
        self.document.root.get(key)
    }

    pub fn set(&mut self, key: &str, value: Json) {
        self.document.root.set(key, value);
    }

    fn text(&self, key: &str, default: &str) -> String {
        self.get(key).and_then(Json::as_str).unwrap_or(default).to_owned()
    }

    /// `auto` or a provider; the key is `defaultProvider`, since workers of older builds wrote a session's pick
    /// into `provider`.
    pub fn default_provider(&self) -> String {
        self.text("defaultProvider", DEFAULT_PROVIDER)
    }

    pub fn set_default_provider(&mut self, provider: &str) {
        self.set("defaultProvider", Json::from(provider));
    }

    /// `bypass` or `default`: whether agents ask before acting.
    pub fn mode(&self) -> String {
        self.text("mode", DEFAULT_MODE)
    }

    pub fn set_mode(&mut self, mode: &str) {
        self.set("mode", Json::from(mode));
    }

    pub fn accounts(&self) -> Vec<Account> {
        match self.get("accounts").and_then(Json::as_array) {
            Some(items) => items.iter().filter_map(Account::from_json).collect(),
            None => default_accounts(),
        }
    }

    pub fn account(&self, id: &str) -> Option<Account> {
        self.accounts().into_iter().find(|account| account.id == id)
    }

    /// The account objects as they stand, the defaults written out first when the file has none.
    fn account_values(&mut self) -> &mut Vec<Json> {
        if self.get("accounts").and_then(Json::as_array).is_none() {
            self.set("accounts", Json::Array(default_accounts().iter().map(Account::to_json).collect()));
        }
        self.document.root.get_mut("accounts").and_then(Json::as_array_mut).expect("accounts was just made an array")
    }

    fn change_account(&mut self, id: &str, key: &str, value: Json) -> bool {
        let found = self.account_values().iter_mut().find(|item| item.get("id").and_then(Json::as_str) == Some(id));
        match found {
            Some(item) => {
                item.set(key, value);
                true
            }
            None => false,
        }
    }

    /// Adds the account unless one has its id already; returns whether it was added.
    pub fn add_account(&mut self, account: &Account) -> bool {
        let values = self.account_values();
        if values.iter().any(|item| item.get("id").and_then(Json::as_str) == Some(account.id.as_str())) {
            return false;
        }
        values.push(account.to_json());
        true
    }

    pub fn set_account_enabled(&mut self, id: &str, enabled: bool) -> bool {
        self.change_account(id, "enabled", Json::from(enabled))
    }

    pub fn set_account_name(&mut self, id: &str, name: &str) -> bool {
        self.change_account(id, "name", Json::from(name))
    }

    /// Each account's limit: the time, in seconds since 1970, before which it is not tried.
    pub fn limits(&self) -> Vec<(String, f64)> {
        let Some(limits) = self.get("limits") else { return Vec::new() };
        limits.entries().filter_map(|(id, reset)| Some((id.to_owned(), reset.as_f64()?))).collect()
    }

    pub fn limit(&self, account: &str) -> Option<f64> {
        self.get("limits")?.get(account)?.as_f64()
    }

    pub fn set_limit(&mut self, account: &str, reset: f64) -> Result<(), String> {
        let reset = Json::number(reset).ok_or("A limit is a finite time.")?;
        if !matches!(self.get("limits"), Some(Json::Object(_))) {
            self.set("limits", Json::default());
        }
        self.document.root.get_mut("limits").expect("limits was just made an object").set(account, reset);
        Ok(())
    }

    pub fn qwen(&self) -> Qwen {
        Qwen {
            url: self.text("qwenURL", QWEN_URL),
            proxy: self.text("qwenProxy", QWEN_PROXY),
            model: self.text("qwenModel", QWEN_MODEL),
            wake: self.get("qwenWake").and_then(Json::as_bool).unwrap_or(false),
        }
    }

    /// Writes only the fields that differ, so an untouched field keeps its bytes.
    pub fn set_qwen(&mut self, qwen: &Qwen) {
        let current = self.qwen();
        if qwen.url != current.url {
            self.set("qwenURL", Json::from(qwen.url.as_str()));
        }
        if qwen.proxy != current.proxy {
            self.set("qwenProxy", Json::from(qwen.proxy.as_str()));
        }
        if qwen.model != current.model {
            self.set("qwenModel", Json::from(qwen.model.as_str()));
        }
        if qwen.wake != current.wake {
            self.set("qwenWake", Json::from(qwen.wake));
        }
    }

    /// Points Qwen at `mac` or `pc`; returns whether the host is known.
    pub fn set_qwen_host(&mut self, host: &str) -> bool {
        let Some((_, url, proxy)) = QWEN_HOSTS.iter().find(|(name, _, _)| *name == host) else { return false };
        let qwen = Qwen { url: (*url).into(), proxy: (*proxy).into(), ..self.qwen() };
        self.set_qwen(&qwen);
        true
    }

    /// The accounts to try for `provider` (`auto` for the default order), as the Swift app orders them: the
    /// provider first, then the others; Qwen and agy are one built-in account each.
    pub fn candidates(&self, provider: &str) -> Vec<Account> {
        let accounts = self.accounts();
        let first = if PROVIDERS.contains(&provider) { Some(provider) } else { None };
        first.into_iter().chain(PROVIDERS.into_iter().filter(|name| Some(*name) != first)).flat_map(|name| match name {
            "qwen" => vec![Account::new("qwen", "Qwen", "qwen")],
            "agy" => vec![Account::new("agy", "Antigravity", "agy")],
            _ => accounts.iter().filter(|account| account.provider == name && account.enabled).cloned().collect(),
        }).collect()
    }

    /// What the Settings sheet draws, as one page message: an account still limited at `now` carries the time it
    /// comes back (seconds since 1970).
    pub fn page(&self, now: f64) -> serde_json::Value {
        let accounts: Vec<serde_json::Value> = self.accounts().into_iter().map(|account| {
            let after = self.limit(&account.id).filter(|reset| *reset > now);
            serde_json::json!({"id": account.id, "name": account.name, "provider": account.provider, "enabled": account.enabled, "home": account.home, "availableAfter": after})
        }).collect();
        let qwen = self.qwen();
        serde_json::json!({
            "type": "settings",
            "provider": self.default_provider(),
            "mode": self.mode(),
            "accounts": accounts,
            "qwen": {"host": qwen.host(), "url": qwen.url, "proxy": qwen.proxy, "model": qwen.model, "wake": qwen.wake},
        })
    }

    /// The candidates whose limit has passed at `now` (seconds since 1970).
    pub fn available(&self, provider: &str, now: f64) -> Vec<Account> {
        self.candidates(provider).into_iter().filter(|account| self.limit(&account.id).is_none_or(|reset| reset <= now)).collect()
    }
}

/// The file, its folder and its lock.
#[derive(Debug, Clone)]
pub struct SettingsFile {
    folder: PathBuf,
}

impl SettingsFile {
    pub fn new(folder: impl Into<PathBuf>) -> Self {
        SettingsFile { folder: folder.into() }
    }

    pub fn path(&self) -> PathBuf {
        self.folder.join("settings.json")
    }

    pub fn lock_path(&self) -> PathBuf {
        self.folder.join("settings.lock")
    }

    /// No file reads as no settings; a file that is not a JSON object is an error, never the defaults.
    pub fn load(&self) -> Result<Settings, String> {
        read(&self.path())
    }

    /// Re-reads the file under the shared lock, applies `change`, writes it in one move and returns what it wrote.
    /// A file that cannot be read is left as it is: the Swift app would replace it with its defaults. One that
    /// `change` leaves equal is not written either, so a layout no VCX writer makes (an indented file) stays.
    pub fn update(&self, change: impl FnOnce(&mut Settings)) -> Result<Settings, String> {
        private_folder(&self.folder)?;
        let _lock = Lock::take(&self.lock_path())?;
        let mut settings = self.load()?;
        let before = settings.to_bytes();
        change(&mut settings);
        let after = settings.to_bytes();
        if after != before || !self.path().exists() {
            write_private(&self.path(), &after)?;
        }
        Ok(settings)
    }
}

fn read(file: &Path) -> Result<Settings, String> {
    match fs::read(file) {
        Ok(bytes) => Settings::parse(&bytes).map_err(|error| format!("{}: {error}", file.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Settings::default()),
        Err(error) => Err(format!("Cannot read {}: {error}.", file.display())),
    }
}

/// `flock(LOCK_EX)` on `settings.lock`, the same lock the Swift app and `background.py` take; let go on drop.
pub struct Lock {
    file: fs::File,
}

impl Lock {
    pub fn take(path: &Path) -> Result<Lock, String> {
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(PRIVATE_FILE)
            .custom_flags(libc::O_CLOEXEC)
            .open(path)
            .map_err(|error| format!("Could not lock shared settings: {error}."))?;
        loop {
            // SAFETY: the descriptor stays open for the whole call.
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                return Ok(Lock { file });
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(format!("Could not lock shared settings: {error}."));
            }
        }
    }
}

impl Drop for Lock {
    fn drop(&mut self) {
        // SAFETY: the descriptor is still open; closing it would release the lock as well.
        unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gives_the_settings_sheet_its_accounts_with_the_time_a_limited_one_comes_back() {
        let mut settings = Settings::parse(br#"{"defaultProvider":"claude","qwenURL":"http:\/\/localhost:11434\/api\/chat","qwenProxy":""}"#).unwrap();
        settings.set_limit("claude-default", 2000.0).unwrap();
        settings.set_limit("codex-default", 500.0).unwrap();

        let page = settings.page(1000.0);

        assert_eq!(page["type"], "settings");
        assert_eq!((page["provider"].as_str(), page["mode"].as_str()), (Some("claude"), Some("bypass")));
        assert_eq!(page["accounts"][0]["availableAfter"], 2000.0);
        assert!(page["accounts"][1]["availableAfter"].is_null());
        assert_eq!((page["accounts"][1]["provider"].as_str(), page["accounts"][1]["enabled"].as_bool()), (Some("codex"), Some(true)));
        assert_eq!(page["qwen"], serde_json::json!({"host": "mac", "url": "http://localhost:11434/api/chat", "proxy": "", "model": QWEN_MODEL, "wake": false}));
    }

    #[test]
    fn gives_the_swift_defaults_for_an_empty_file() {
        let settings = Settings::parse(b"").unwrap();

        assert_eq!((settings.default_provider().as_str(), settings.mode().as_str()), ("auto", "bypass"));
        assert_eq!(settings.accounts(), default_accounts());
        assert_eq!(settings.qwen(), Qwen { url: QWEN_URL.into(), proxy: QWEN_PROXY.into(), model: QWEN_MODEL.into(), wake: false });
        assert_eq!(settings.qwen().host(), "pc");
        assert!(settings.limits().is_empty());
    }

    #[test]
    fn orders_candidates_with_the_chosen_provider_first_and_skips_disabled_accounts() {
        let mut settings = Settings::default();
        settings.add_account(&Account { id: "c2".into(), name: "Second".into(), provider: "claude".into(), home: Some("/p".into()), enabled: false });

        let ids = |accounts: Vec<Account>| accounts.into_iter().map(|account| account.id).collect::<Vec<_>>();

        assert_eq!(ids(settings.candidates("auto")), ["claude-default", "codex-default", "qwen", "agy"]);
        assert_eq!(ids(settings.candidates("qwen")), ["qwen", "claude-default", "codex-default", "agy"]);
    }

    #[test]
    fn leaves_out_an_account_until_its_limit_passes() {
        let mut settings = Settings::default();
        settings.set_limit("claude-default", 100.0).unwrap();

        let at = |now| settings.available("claude", now).into_iter().map(|account| account.id).collect::<Vec<_>>();

        assert_eq!(at(99.0), ["codex-default", "qwen", "agy"]);
        assert_eq!(at(100.0), ["claude-default", "codex-default", "qwen", "agy"]);
    }

    #[test]
    fn writes_the_default_accounts_out_before_changing_one() {
        let mut settings = Settings::parse(br#"{"mode":"bypass"}"#).unwrap();

        assert!(settings.set_account_enabled("codex-default", false));

        assert_eq!(settings.accounts()[1], Account { enabled: false, ..default_accounts()[1].clone() });
        assert!(!settings.set_account_enabled("missing", false));
    }

    #[test]
    fn names_a_qwen_endpoint_neither_host_serves_custom() {
        let mut settings = Settings::default();

        assert!(settings.set_qwen_host("mac"));
        let mac = settings.qwen().host();
        settings.set_qwen(&Qwen { url: "http://elsewhere".into(), ..settings.qwen() });

        assert_eq!((mac, settings.qwen().host(), settings.set_qwen_host("moon")), ("mac", "custom", false));
    }

    #[test]
    fn refuses_settings_that_are_not_an_object_or_a_limit_that_is_not_a_time() {
        assert!(Settings::parse(b"[1]").is_err());
        assert!(Settings::default().set_limit("a", f64::NAN).is_err());
    }
}
