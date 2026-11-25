//! Claude's subscription usage, read as `readClaudeUsage` and `claudeRateLimits` in `Agents.swift` read it: the
//! profile's OAuth token from the keychain (or its `.credentials.json`), then Anthropic's usage endpoint, turned
//! into the `rateLimits` Codex reports. curl makes the HTTPS call; the token goes to it on stdin, never as an argument.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const KEYCHAIN_TIMEOUT: Duration = Duration::from_secs(5);
const REQUEST_SECONDS: u64 = 15;
const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
const FIVE_HOURS_MINUTES: i64 = 300;
const SEVEN_DAYS_MINUTES: i64 = 10_080;

/// The usage windows as Codex's `rateLimits`: the five-hour window is the primary one, the week the secondary.
pub fn rate_limits(usage: &Value) -> Result<Value, String> {
    let mut limits = serde_json::Map::new();
    for (source, target, minutes) in [("five_hour", "primary", FIVE_HOURS_MINUTES), ("seven_day", "secondary", SEVEN_DAYS_MINUTES)] {
        let Some(window) = usage.get(source) else { continue };
        if !window.is_null() && !window["utilization"].is_number() {
            return Err("Usage unavailable: invalid Claude window.".into());
        }
        let mut rate = json!({"usedPercent": window["utilization"].as_f64().unwrap_or(0.0), "windowDurationMins": minutes});
        if let Some(reset) = window["resets_at"].as_str().and_then(|reset| reset.parse::<jiff::Timestamp>().ok()) {
            rate["resetsAt"] = (reset.as_millisecond() as f64 / 1000.0).into();
        }
        limits.insert(target.into(), rate);
    }
    if limits.is_empty() {
        return Err("Usage unavailable: Claude returned no usage windows.".into());
    }
    Ok(Value::Object(limits))
}

/// The keychain item of a Claude profile: the default one has none, another home a hash of its path.
pub fn keychain_service(home: Option<&Path>) -> String {
    match home {
        None => KEYCHAIN_SERVICE.into(),
        Some(home) => {
            let digest = Sha256::digest(home.to_string_lossy().as_bytes());
            let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
            format!("{KEYCHAIN_SERVICE}-{}", &hex[..8])
        }
    }
}

/// `home` is the profile's `CLAUDE_CONFIG_DIR`, `None` for `~/.claude`.
pub async fn read_usage(home: Option<&Path>, default: &Path) -> Result<Value, String> {
    let unavailable = || "Usage unavailable: sign in to this Claude profile.".to_owned();
    let mut security = tokio::process::Command::new("/usr/bin/security");
    security.args(["find-generic-password", "-s", &keychain_service(home), "-w"]).stdin(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true);
    let stored = match tokio::time::timeout(KEYCHAIN_TIMEOUT, security.output()).await {
        Ok(Ok(output)) if output.status.success() => output.stdout,
        _ => Vec::new(),
    };
    let data = if stored.is_empty() { std::fs::read(home.unwrap_or(default).join(".credentials.json")).unwrap_or_default() } else { stored };
    let credentials: Value = serde_json::from_slice(&data).map_err(|_| unavailable())?;
    let token = credentials.pointer("/claudeAiOauth/accessToken").and_then(Value::as_str).filter(|token| !token.is_empty()).ok_or_else(unavailable)?;
    let mut curl = tokio::process::Command::new("/usr/bin/curl");
    curl.args(["-sS", "--max-time", &REQUEST_SECONDS.to_string(), "-H", "@-", "-H", "anthropic-beta: oauth-2025-04-20", "-A", concat!("VibeCodeX/", env!("CARGO_PKG_VERSION")), "-w", "\n%{http_code}", USAGE_URL])
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true);
    let mut child = curl.spawn().map_err(|error| format!("Usage unavailable: {error}"))?;
    if let Some(mut input) = child.stdin.take() {
        input.write_all(format!("Authorization: Bearer {token}\n").as_bytes()).await.map_err(|error| format!("Usage unavailable: {error}"))?;
    }
    let output = child.wait_with_output().await.map_err(|error| format!("Usage unavailable: {error}"))?;
    let text = String::from_utf8_lossy(&output.stdout);
    let (body, status) = text.rsplit_once('\n').unwrap_or(("", &text));
    if status.trim() != "200" {
        return Err(format!("Usage unavailable: Claude returned HTTP {}.", status.trim()));
    }
    serde_json::from_str(body).map_err(|_| "Usage unavailable: invalid Claude response.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turns_claude_usage_windows_into_codex_rate_limits() {
        let usage = json!({"five_hour": {"utilization": 42.0, "resets_at": "2026-11-26T03:00:00.500000+00:00"}, "seven_day": null, "seven_day_opus": {"utilization": 1.0}});

        let limits = rate_limits(&usage).unwrap();

        assert_eq!(limits["primary"], json!({"usedPercent": 42.0, "windowDurationMins": 300, "resetsAt": 1_795_662_000.5}));
        assert_eq!(limits["secondary"], json!({"usedPercent": 0.0, "windowDurationMins": 10_080}));
        assert!(rate_limits(&json!({"five_hour": {"utilization": "high"}})).is_err());
        assert!(rate_limits(&json!({})).is_err());
    }

    #[test]
    fn names_the_keychain_item_of_a_profile_by_a_hash_of_its_home() {
        let other = keychain_service(Some(Path::new("/Users/user/.claude-work")));

        assert_eq!(keychain_service(None), "Claude Code-credentials");
        assert!(other.starts_with("Claude Code-credentials-") && other.len() == KEYCHAIN_SERVICE.len() + 9);
    }
}
