//! What the footer reads besides the agent's events, as the Swift `Session` reads it: the plan's usage
//! (`refreshUsage`), the repository and his pull request (`refreshRepository`), again each minute while a frontend is
//! attached.

use super::{REQUEST_TIMEOUT, SessionBackend, object};
use crate::session::Effect;
use crate::{capabilities, fallback, provider, repository};
use serde_json::{Value, json};
use std::path::Path;
use std::rc::Rc;
use std::time::Duration;
use vcx_config::Account;

/// How often an attached window's usage and repository are read again, as the Swift app's refresh timer does.
const REFRESH_PERIOD: Duration = Duration::from_secs(60);
const SELF_FOLDER: &str = "self";
const CONFIG_TIMEOUT: Duration = Duration::from_secs(5);
const FULL_WINDOW_PERCENT: i64 = 100;

/// The Swift `codexContextWindow`: the window Codex's model cache gives `model` (or `configured`), cut to the share
/// Codex lets a conversation use.
pub(crate) fn codex_context_window(model: &str, home: &Path, configured: Option<i64>) -> Option<i64> {
    let cache: Value = serde_json::from_slice(&std::fs::read(home.join("models_cache.json")).ok()?).ok()?;
    let entry = cache["models"].as_array()?.iter().find(|entry| entry["slug"] == model)?;
    let window = configured.or_else(|| entry["context_window"].as_i64()).filter(|window| *window > 0)?;
    let percent = entry["effective_context_window_percent"].as_i64().unwrap_or(FULL_WINDOW_PERCENT);
    (percent > 0 && percent <= FULL_WINDOW_PERCENT).then(|| window * percent / FULL_WINDOW_PERCENT)
}

impl SessionBackend {
    /// The Swift `refreshUsage`: Claude's usage is read once per connection and when asked, its turns' own reports
    /// keeping it current.
    pub(super) async fn refresh_usage(self: &Rc<Self>, force: bool) {
        let reading = self.session.borrow_mut().begin_usage_refresh(force, fallback::now());
        self.schedule();
        if !reading {
            return;
        }
        let generation = self.generation.get();
        let read = self.request("account/rateLimits/read", json!({}), REQUEST_TIMEOUT).await;
        if self.generation.get() != generation {
            return;
        }
        self.session.borrow_mut().usage_loading = false;
        let rest = read.ok().and_then(|result| self.session.borrow_mut().rate_limits(&object(result["rateLimits"].clone())));
        if let Some(Effect::Rest(reset)) = rest {
            self.rest_current(reset);
        }
        self.schedule();
    }

    /// The usage read a new connection makes: Claude's once per agent, the others' each time.
    pub(super) async fn refresh_connection_usage(self: &Rc<Self>) {
        let generation = self.generation.get();
        let claude = self.session.borrow().provider == "claude";
        if self.config.fixture.is_none() && (!claude || self.usage_read.replace(generation) != generation) {
            self.refresh_usage(true).await;
        }
    }

    /// The Swift `refreshRepository`: the footer of the session's folder, then his pull request on its branch.
    pub(super) async fn refresh_repository(self: Rc<Self>) {
        let (directory, edited) = {
            let session = self.session.borrow();
            (session.cwd.clone(), session.edited_folder.clone())
        };
        let read = self.repository_reads.get() + 1;
        self.repository_reads.set(read);
        let self_directory = vcx_config::homes::home_directory().join(SELF_FOLDER);
        let footer = repository::read(&directory, edited.as_deref(), &self_directory).await;
        if self.session.borrow().cwd != directory || self.repository_reads.get() != read {
            return;
        }
        self.session.borrow_mut().apply_repository(&footer);
        match footer.root {
            Some(root) => self.refresh_pull_request(root, footer.branch),
            None => self.session.borrow_mut().pull_request.clear(),
        }
        self.schedule();
    }

    /// The Swift `refreshPullRequest`: the cached answer at once, and `gh` asked again once it is five minutes old.
    fn refresh_pull_request(self: &Rc<Self>, root: String, branch: String) {
        let key = format!("{root}\n{branch}");
        let cached = repository::cached(&key);
        let (label, url) = cached.as_ref().map(|(_, label, url)| (label.clone(), url.clone())).unwrap_or_default();
        {
            let mut session = self.session.borrow_mut();
            session.pull_request_url = url.clone();
            session.pull_request = label.clone();
        }
        let now = fallback::now();
        if cached.is_some_and(|(read, ..)| now - read < repository::PULL_REQUEST_TTL) {
            return;
        }
        repository::remember(&key, (now, label, url));
        let directory = self.session.borrow().cwd.clone();
        let backend = Rc::clone(self);
        self.detach(async move {
            let anyone = Account { id: String::new(), name: String::new(), provider: String::new(), home: None, enabled: true };
            let environment = provider::environment(&anyone, &vcx_config::homes::home_directory(), "");
            let (label, url) = repository::pull_request(&root, &branch, &environment).await;
            repository::remember(&key, (fallback::now(), label.clone(), url.clone()));
            {
                let mut session = backend.session.borrow_mut();
                if session.cwd != directory || session.branch != branch {
                    return;
                }
                session.pull_request_url = url;
                session.pull_request = label;
            }
            backend.schedule();
        });
    }

    /// Each minute while a frontend is attached, the usage and the repository are read again, as the Swift app
    /// refreshes its visible windows; the loop ends with the session.
    pub(super) fn refresh_periodically(self: &Rc<Self>) {
        let backend = Rc::downgrade(self);
        tokio::task::spawn_local(async move {
            loop {
                tokio::time::sleep(REFRESH_PERIOD).await;
                let Some(backend) = backend.upgrade() else { return };
                if backend.closed.get() {
                    return;
                }
                if backend.on_change.borrow().is_none() {
                    continue;
                }
                let refreshing = Rc::clone(&backend);
                backend.detach(async move {
                    refreshing.refresh_usage(false).await;
                    refreshing.refresh_repository().await;
                });
            }
        });
    }

    /// The Swift `refreshContextLimit`: Claude's window as remembered for its model, Codex's from its config and
    /// model cache, so the context percentage shows before the first turn.
    pub(super) async fn refresh_context_limit(&self) {
        let (provider, model, cwd) = {
            let session = self.session.borrow();
            (session.provider.clone(), session.model.clone(), session.cwd.clone())
        };
        if provider == "claude" {
            let mut session = self.session.borrow_mut();
            session.context_limit = session.remembered_window(&model);
            return;
        }
        if provider != "codex" {
            return;
        }
        let generation = self.generation.get();
        let config = self.request("config/read", json!({"cwd": cwd, "includeLayers": false}), CONFIG_TIMEOUT).await.ok();
        let home = capabilities::provider_home(&self.current_account(), &self.config.errors_home);
        let mut session = self.session.borrow_mut();
        if self.generation.get() != generation || session.model != model || session.context_limit.is_some() {
            return;
        }
        session.context_limit = codex_context_window(&model, &home, config.and_then(|config| config["config"]["model_context_window"].as_i64()));
    }

    /// The account the session runs on rests until `reset`.
    pub(super) fn rest_current(&self, reset: f64) {
        let account = self.session.borrow().account["id"].as_str().unwrap_or_default().to_owned();
        if !account.is_empty() {
            self.rest(&account, reset);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_codex_window_is_the_cached_or_configured_one_cut_to_its_effective_share() {
        let home = std::env::temp_dir().join(format!("vcx-window-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        let cache = json!({"models": [{"slug": "gpt", "context_window": 200_000, "effective_context_window_percent": 95}, {"slug": "odd", "context_window": 1000, "effective_context_window_percent": 0}]});
        std::fs::write(home.join("models_cache.json"), cache.to_string()).unwrap();

        let windows = [codex_context_window("gpt", &home, None), codex_context_window("gpt", &home, Some(100_000)), codex_context_window("odd", &home, None), codex_context_window("missing", &home, None)];

        assert_eq!(windows, [Some(190_000), Some(95_000), None, None]);
        let _ = std::fs::remove_dir_all(home);
    }
}
