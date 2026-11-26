//! The quota popover (Swift `QuotaOverview.read`): the 5-hour and weekly quota of every agent on this Mac, each
//! Claude account from its usage endpoint, each Codex home from its newest turn, Antigravity from `agy -p /quota`,
//! and the deep skill's daily web prompts.

use serde_json::{Value, json};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;
use vcx_config::{Account, Settings};

/// Claude's usage endpoint answers HTTP 429 when polled, so a reopened popover within a minute shows the last read.
pub const CACHE_LIFE: Duration = Duration::from_secs(60);
/// MAX_PROMPTS_PER_DAY in ~/.claude/skills/deep/ask-web.mjs.
const WEB_DAILY_CAP: u32 = 25;
const WEB_SITES: [&str; 4] = ["gemini", "grok", "muse", "meta"];
const AGY_TIMEOUT: Duration = Duration::from_secs(30);
const FIVE_HOURS_MINUTES: i64 = 300;
const WEEK_MINUTES: i64 = 10_080;
const NO_WINDOW: &str = "–";
const WEEKLY_ZONE: &str = "Europe/Paris";
const FIXED_PATH: [&str; 6] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"];

#[derive(Debug, Clone, PartialEq)]
pub struct Line {
    pub agent: String,
    pub five_hour: String,
    pub week: String,
}

impl Line {
    fn new(agent: impl Into<String>, five_hour: impl Into<String>, week: impl Into<String>) -> Self {
        Line { agent: agent.into(), five_hour: five_hour.into(), week: week.into() }
    }
}

pub fn message(lines: &[Line]) -> Value {
    let lines: Vec<Value> = lines.iter().map(|line| json!({"agent": line.agent, "fiveHour": line.five_hour, "week": line.week})).collect();
    json!({"type": "quota", "lines": lines})
}

/// Reads every line; it blocks for as long as the slowest source, up to Antigravity's timeout.
pub fn read(settings: &Settings, home: &Path, now: f64) -> Vec<Line> {
    let agy = thread::spawn({
        let home = home.to_owned();
        move || antigravity(&run_agy(&home), now)
    });
    let accounts = settings.candidates("auto");
    let mut lines = claude_lines(&accounts, home, now);
    for account in accounts.iter().filter(|account| account.provider == "codex") {
        let codex_home = account.home.as_ref().map_or_else(|| home.join(".codex"), PathBuf::from);
        let name = account_name("Codex", account);
        lines.push(codex_rate_limits(&codex_home).map_or_else(|| Line::new(&name, "No Codex turn yet", ""), |rate| line(&name, &rate, now)));
    }
    lines.extend(agy.join().unwrap_or_default());
    let today = jiff::Zoned::now().date().to_string();
    lines.extend(WEB_SITES.map(|site| web(site, web_count(home, site, &today))));
    lines
}

fn claude_lines(accounts: &[Account], home: &Path, now: f64) -> Vec<Line> {
    let claude: Vec<&Account> = accounts.iter().filter(|account| account.provider == "claude").collect();
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else { return Vec::new() };
    runtime.block_on(async {
        let mut lines = Vec::new();
        for account in claude {
            let name = account_name("Claude", account);
            let usage = vcx_agents::claude_usage::read_usage(account.home.as_deref().map(Path::new), &home.join(".claude")).await;
            lines.push(match usage.and_then(|usage| vcx_agents::claude_usage::rate_limits(&usage)) {
                Ok(rate) => line(&name, &rate, now),
                Err(problem) => Line::new(&name, problem.replace("Usage unavailable: ", ""), ""),
            });
        }
        lines
    })
}

fn account_name(agent: &str, account: &Account) -> String {
    if account.name.is_empty() || account.name.starts_with("Default ") { agent.to_owned() } else { format!("{agent} · {}", account.name) }
}

/// `primary`/`secondary` windows as the worker reports them: `usedPercent`, `windowDurationMins`, `resetsAt`.
fn line(agent: &str, rate: &Value, now: f64) -> Line {
    let text = |minutes: i64| {
        let window = ["primary", "secondary"].iter().filter_map(|key| rate.get(key)).find(|window| window["windowDurationMins"].as_i64() == Some(minutes));
        match window.and_then(|window| window["usedPercent"].as_f64().map(|used| (used, window["resetsAt"].as_f64()))) {
            Some((used, reset)) => quota(used, reset, minutes == WEEK_MINUTES, now),
            None => NO_WINDOW.to_owned(),
        }
    };
    Line::new(agent, text(FIVE_HOURS_MINUTES), text(WEEK_MINUTES))
}

fn quota(used: f64, reset: Option<f64>, weekly: bool, now: f64) -> String {
    let percent = used.round() as i64;
    let Some(reset) = reset else { return format!("{percent}%") };
    // A window whose reset has passed starts again from zero.
    if reset <= now {
        return "0%".into();
    }
    let countdown = if weekly {
        jiff::Timestamp::from_second(reset as i64).ok().and_then(|at| at.in_tz(WEEKLY_ZONE).ok()).map(|at| at.strftime("%a %Hh%M").to_string()).unwrap_or_default()
    } else {
        let minutes = ((reset - now) / 60.0) as i64;
        [(minutes / 60, "h"), (minutes % 60, "m")].iter().filter(|(count, _)| *count > 0).map(|(count, unit)| format!("{count}{unit}")).collect()
    };
    format!("{percent}% - reset {}", if countdown.is_empty() { "0m" } else { &countdown })
}

/// Codex writes its plan windows into each turn's token_count event; the newest rollout holds the latest.
fn codex_rate_limits(home: &Path) -> Option<Value> {
    let mut folder = home.join("sessions");
    for _ in 0..3 {
        let newest = fs::read_dir(&folder).ok()?.filter_map(|entry| entry.ok()?.file_name().into_string().ok()).filter(|name| !name.starts_with('.')).max()?;
        folder.push(newest);
    }
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = fs::read_dir(&folder).ok()?.filter_map(|entry| {
        let path = entry.ok()?.path();
        (path.extension()? == "jsonl").then(|| (fs::metadata(&path).and_then(|meta| meta.modified()).unwrap_or(std::time::UNIX_EPOCH), path))
    }).collect();
    files.sort_by(|a, b| b.0.cmp(&a.0));
    files.iter().find_map(|(_, path)| {
        let text = fs::read_to_string(path).ok()?;
        text.lines().rev().filter(|line| line.contains("\"rate_limits\"")).find_map(|line| {
            let event: Value = serde_json::from_str(line).ok()?;
            let limits = event.pointer("/payload/rate_limits")?;
            let mut rate = serde_json::Map::new();
            for key in ["primary", "secondary"] {
                let Some(used) = limits[key]["used_percent"].as_f64() else { continue };
                rate.insert(key.into(), json!({"usedPercent": used, "windowDurationMins": limits[key]["window_minutes"].as_i64().unwrap_or(0), "resetsAt": limits[key]["resets_at"].as_f64()}));
            }
            (!rate.is_empty()).then_some(Value::Object(rate))
        })
    })
}

/// `agy -p /quota`'s output, empty when it cannot run or outlives its timeout.
fn run_agy(home: &Path) -> String {
    let inherited = std::env::var("PATH").unwrap_or_default();
    let local = home.join(".local/bin").to_string_lossy().into_owned();
    let path: Vec<&str> = inherited.split(':').chain([local.as_str()]).chain(FIXED_PATH).filter(|entry| !entry.is_empty()).collect();
    let mut command = Command::new("/usr/bin/env");
    command.args(["agy", "-p", "/quota"]).env("PATH", path.join(":")).current_dir(std::env::temp_dir()).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    let Ok(mut child) = command.spawn() else { return String::new() };
    let (finished, timed_out) = mpsc::channel::<()>();
    let pid = child.id() as i32;
    let watchdog = thread::spawn(move || {
        if timed_out.recv_timeout(AGY_TIMEOUT) == Err(mpsc::RecvTimeoutError::Timeout) {
            // SAFETY: kill has no memory preconditions; the child is not reaped before the wait below.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    });
    let mut output = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        let _ = stdout.read_to_string(&mut output);
    }
    let _ = finished.send(());
    let _ = watchdog.join();
    let _ = child.wait();
    output
}

/// One tab-separated row per model group: name, window, percent remaining, reset (ISO 8601).
fn antigravity(output: &str, now: f64) -> Vec<Line> {
    let lines: Vec<Line> = output.lines().filter_map(|row| {
        let fields: Vec<&str> = row.split('\t').map(str::trim).collect();
        let remaining: f64 = fields.get(2)?.replace('%', "").parse().ok()?;
        let reset = fields.get(3)?.parse::<jiff::Timestamp>().ok().map(|at| at.as_second() as f64);
        let text = quota(100.0 - remaining, reset, true, now);
        let weekly = fields[1].to_lowercase().contains("week");
        let agent = format!("Antigravity · {}", fields[0].replace(" models", "").replace(" Models", ""));
        Some(if weekly { Line::new(agent, NO_WINDOW, text) } else { Line::new(agent, text, NO_WINDOW) })
    }).collect();
    if lines.is_empty() { vec![Line::new("Antigravity", "Not reported", "")] } else { lines }
}

/// The deep skill counts its own prompts per site and day, apart from the websites' quotas.
fn web_count(home: &Path, site: &str, day: &str) -> u32 {
    fs::read_to_string(home.join(".local/state").join(format!("{site}-web")).join(day)).ok().and_then(|text| text.trim().parse().ok()).unwrap_or(0)
}

fn web(site: &str, count: u32) -> Line {
    let mut name = if site == "meta" { "Meta AI".to_owned() } else { site[..1].to_uppercase() + &site[1..] };
    name.push_str(" web");
    Line::new(name, NO_WINDOW, format!("{count}/{WEB_DAILY_CAP} today - reset 00h00"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: f64 = 4_102_444_800.0; // 2100-01-01T00:00:00Z

    #[test]
    fn writes_each_window_as_used_percent_and_its_reset() {
        let rate = json!({"primary": {"usedPercent": 31.4, "windowDurationMins": 300, "resetsAt": NOW + 7_500.0}, "secondary": {"usedPercent": 22.5, "windowDurationMins": 10080, "resetsAt": NOW + 3.0 * 86_400.0}});

        let written = line("Claude", &rate, NOW);

        assert_eq!(written, Line::new("Claude", "31% - reset 2h5m", "23% - reset Mon 01h00"));
    }

    #[test]
    fn starts_a_passed_window_from_zero_and_shows_a_missing_one_as_a_dash() {
        let rate = json!({"primary": {"usedPercent": 80, "windowDurationMins": 300, "resetsAt": NOW - 1.0}});

        assert_eq!(line("Codex", &rate, NOW), Line::new("Codex", "0%", NO_WINDOW));
        assert_eq!(quota(12.0, None, false, NOW), "12%");
        assert_eq!(quota(12.0, Some(NOW + 30.0), false, NOW), "12% - reset 0m");
    }

    #[test]
    fn reads_codex_limits_from_the_newest_rollout() {
        let home = std::env::temp_dir().join(format!("vcx-app-quota-{}", std::process::id()));
        let (old, new) = (home.join("sessions/2026/11/24"), home.join("sessions/2026/11/25"));
        fs::create_dir_all(&old).unwrap();
        fs::create_dir_all(&new).unwrap();
        fs::write(old.join("a.jsonl"), r#"{"payload":{"rate_limits":{"primary":{"used_percent":99,"window_minutes":300}}}}"#).unwrap();
        let event = r#"{"payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":22.0,"window_minutes":300,"resets_at":5000000000},"secondary":null}}}"#;
        fs::write(new.join("b.jsonl"), format!("{event}\n{{\"payload\":{{}}}}\n")).unwrap();

        let rate = codex_rate_limits(&home);

        fs::remove_dir_all(&home).unwrap();
        assert_eq!(rate, Some(json!({"primary": {"usedPercent": 22.0, "windowDurationMins": 300, "resetsAt": 5_000_000_000.0}})));
        assert_eq!(codex_rate_limits(Path::new("/nonexistent")), None);
    }

    #[test]
    fn reads_antigravity_groups_and_says_when_it_reported_nothing() {
        let output = "Gemini Models\tWeekly Limit Remaining\t12%\t2100-01-03T08:05:00Z\nClaude and GPT models\t5 Hour Limit\t40%\t2100-01-01T02:00:00Z\nnoise\n";

        let lines = antigravity(output, NOW);

        assert_eq!(lines, [Line::new("Antigravity · Gemini", NO_WINDOW, "88% - reset Sun 09h05"), Line::new("Antigravity · Claude and GPT", "60% - reset Fri 03h00", NO_WINDOW)]);
        assert_eq!(antigravity("", NOW), [Line::new("Antigravity", "Not reported", "")]);
    }

    #[test]
    fn counts_the_web_prompts_of_the_day_against_the_daily_cap() {
        let home = std::env::temp_dir().join(format!("vcx-app-quota-web-{}", std::process::id()));
        fs::create_dir_all(home.join(".local/state/grok-web")).unwrap();
        fs::write(home.join(".local/state/grok-web/2026-11-26"), "7\n").unwrap();

        let lines = [web("grok", web_count(&home, "grok", "2026-11-26")), web("meta", web_count(&home, "meta", "2026-11-26"))];

        fs::remove_dir_all(&home).unwrap();
        assert_eq!(lines, [Line::new("Grok web", NO_WINDOW, "7/25 today - reset 00h00"), Line::new("Meta AI web", NO_WINDOW, "0/25 today - reset 00h00")]);
    }

    #[test]
    fn names_an_account_unless_it_is_the_default_one() {
        let account = |name: &str| Account { id: "a".into(), name: name.into(), provider: "claude".into(), home: None, enabled: true };

        assert_eq!([account_name("Claude", &account("Default Claude")), account_name("Claude", &account("Work"))], ["Claude", "Claude · Work"]);
    }
}
