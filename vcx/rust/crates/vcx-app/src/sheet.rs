//! The Settings sheet's answer (Swift `Views.settings`): his shared settings as vcx-config draws them, with what the
//! window's session runs on for the background block.

use serde_json::{Value, json};
use vcx_config::Settings;

/// The waits before a rate-limited turn is resent (Swift `Session.rateLimitRetries`), in seconds.
pub const RATE_LIMIT_RETRIES: [f64; 3] = [10.0, 30.0, 60.0];

/// `account` is the worker's `meta.account`; none before the session connects.
pub fn message(settings: &Settings, account: Option<&Value>, home: &str, now: f64) -> Value {
    let field = |key: &str| account.and_then(|account| account[key].as_str());
    let provider = field("provider").map_or_else(|| settings.default_provider(), str::to_owned);
    let route = match field("provider") {
        Some("claude") => field("name").map(str::to_owned),
        _ => settings.accounts().into_iter().find(|account| account.provider == "claude" && account.enabled).map(|account| account.name),
    };
    let fallbacks: Vec<String> = settings.available(&provider, now).into_iter().filter(|candidate| Some(candidate.id.as_str()) != field("id")).map(|candidate| candidate.name).collect();
    let mut page = settings.page(now);
    page["home"] = json!(home);
    page["account"] = json!(field("name"));
    page["routeAccount"] = json!(route);
    page["rateLimitRetries"] = json!(RATE_LIMIT_RETRIES);
    page["fallbacks"] = json!(fallbacks);
    page
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: f64 = 1_000.0;

    fn settings() -> Settings {
        Settings::parse(br#"{"accounts": [
            {"id": "work", "name": "Work Claude", "provider": "claude", "enabled": true},
            {"id": "home", "name": "Home Claude", "provider": "claude", "enabled": true},
            {"id": "codex", "name": "Codex", "provider": "codex", "enabled": true}
        ], "limits": {"home": 2000}}"#).unwrap()
    }

    #[test]
    fn names_the_session_account_and_falls_back_to_the_others_not_limited() {
        let account = json!({"id": "work", "name": "Work Claude", "provider": "claude"});

        let sent = message(&settings(), Some(&account), "/Users/demo", NOW);

        assert_eq!(sent["type"], "settings");
        assert_eq!((&sent["home"], &sent["account"], &sent["routeAccount"]), (&json!("/Users/demo"), &json!("Work Claude"), &json!("Work Claude")));
        assert_eq!(sent["rateLimitRetries"], json!([10.0, 30.0, 60.0]));
        assert_eq!(sent["fallbacks"], json!(["Codex", "Qwen", "Antigravity"]));
        assert_eq!(sent["accounts"][1]["availableAfter"], json!(2000.0));
    }

    #[test]
    fn routes_through_the_first_enabled_claude_account_for_another_provider() {
        let account = json!({"id": "codex", "name": "Codex", "provider": "codex"});

        let sent = message(&settings(), Some(&account), "/Users/demo", NOW);

        assert_eq!((&sent["account"], &sent["routeAccount"]), (&json!("Codex"), &json!("Work Claude")));
    }
}
