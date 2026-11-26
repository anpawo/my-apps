//! The usage line under the composer, as the Swift `updateUsage` writes it: each reported window's share, the time
//! left before a short window resets, and the Paris day and time of a weekly reset.

use crate::fallback;
use serde_json::Value;

pub type Object = serde_json::Map<String, Value>;

/// How often a periodic refresh may read the usage endpoint again, as the Swift `refreshUsage` allows.
pub const REFRESH_INTERVAL: f64 = 60.0;
const WINDOWS: [&str; 2] = ["primary", "secondary"];
const WEEK_MINUTES: i64 = 10_080;
const SESSION_MINUTES: i64 = 300;
const DAY_MINUTES: i64 = 1_440;
const HOUR_MINUTES: i64 = 60;
const USED_UP: f64 = 100.0;
const RESET_ZONE: &str = "Europe/Paris";
const WEEKLY_RESET_FORMAT: &str = "%a %Hh%M";

fn used(window: &Object) -> Option<f64> {
    window.get("usedPercent").and_then(Value::as_f64)
}

fn minutes(window: &Object) -> i64 {
    window.get("windowDurationMins").and_then(Value::as_i64).unwrap_or_default()
}

/// The windows the provider reported a share for.
fn windows(rate: &Object) -> Vec<&Object> {
    WINDOWS.iter().filter_map(|key| rate.get(*key).and_then(Value::as_object)).filter(|window| used(window).is_some()).collect()
}

/// The footer's color follows the most depleted window.
pub fn percent(rate: &Object) -> Option<f64> {
    windows(rate).into_iter().filter_map(used).reduce(f64::max)
}

/// When a used-up window lets the account work again, the latest of them; `None` while none is used up.
pub fn exhausted_reset(rate: &Object, now: f64) -> Option<f64> {
    let full: Vec<&Object> = WINDOWS.iter().filter_map(|key| rate.get(*key).and_then(Value::as_object)).filter(|window| used(window).unwrap_or_default() >= USED_UP).collect();
    full.into_iter().map(|window| fallback::limit_reset(window, now)).reduce(f64::max)
}

fn label(minutes: i64) -> String {
    match minutes {
        WEEK_MINUTES => "wk".into(),
        SESSION_MINUTES => "usage".into(),
        m if m >= DAY_MINUTES && m % DAY_MINUTES == 0 => format!("{}d", m / DAY_MINUTES),
        m if m >= HOUR_MINUTES && m % HOUR_MINUTES == 0 => format!("{}h", m / HOUR_MINUTES),
        m => format!("{m}m"),
    }
}

fn paris(reset: f64) -> String {
    let zone = jiff::tz::TimeZone::get(RESET_ZONE).unwrap_or_else(|_| jiff::tz::TimeZone::system());
    jiff::Timestamp::from_millisecond((reset * 1000.0) as i64).map_or_else(|_| String::new(), |time| time.to_zoned(zone).strftime(WEEKLY_RESET_FORMAT).to_string())
}

fn countdown(reset: f64, minutes: i64, now: f64) -> String {
    if reset <= now {
        return "now".into();
    }
    if minutes == WEEK_MINUTES {
        return paris(reset);
    }
    let remaining = (((reset - now) / 60.0) as i64).max(0);
    let parts: String = [(remaining / HOUR_MINUTES, "h"), (remaining % HOUR_MINUTES, "m")].iter().filter(|(count, _)| *count > 0).map(|(count, unit)| format!("{count}{unit}")).collect();
    if parts.is_empty() { "0m".into() } else { parts }
}

/// `18% usage - reset 2h50m - 32% wk`: an unused 5 h window with no reset is left out beside a weekly one, and only a
/// weekly window shown first tells its reset.
pub fn line(rate: &Object, now: f64) -> String {
    let windows = windows(rate);
    let weekly = windows.iter().any(|window| minutes(window) == WEEK_MINUTES);
    let empty = |window: &Object| weekly && minutes(window) == SESSION_MINUTES && used(window) == Some(0.0) && !window.contains_key("resetsAt");
    let shown = windows.into_iter().filter(|window| !empty(window));
    let texts: Vec<String> = shown
        .enumerate()
        .filter_map(|(index, window)| {
            let minutes = minutes(window);
            let mut text = format!("{}% {}", used(window)?.round() as i64, label(minutes));
            if let Some(reset) = window.get("resetsAt").and_then(Value::as_f64).filter(|_| minutes != WEEK_MINUTES || index == 0) {
                text += &format!(" - reset {}", countdown(reset, minutes, now));
            }
            Some(text)
        })
        .collect();
    texts.join(" - ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 2026-11-26T12:00:00Z.
    const NOW: f64 = 1_795_694_400.0;

    fn rate(value: Value) -> Object {
        value.as_object().unwrap().clone()
    }

    fn at(text: &str) -> f64 {
        text.parse::<jiff::Timestamp>().unwrap().as_millisecond() as f64 / 1000.0
    }

    #[test]
    fn a_short_window_counts_down_to_its_reset_in_hours_and_minutes() {
        let limits = rate(json!({"primary": {"usedPercent": 18.0, "windowDurationMins": 300, "resetsAt": NOW + 10_230.0}, "secondary": {"usedPercent": 32.0, "windowDurationMins": 10_080}}));

        let text = line(&limits, NOW);

        assert_eq!(text, "18% usage - reset 2h50m - 32% wk");
        assert_eq!(percent(&limits), Some(32.0));
    }

    #[test]
    fn a_countdown_drops_its_empty_unit_and_says_now_once_due() {
        let window = |reset: f64| rate(json!({"primary": {"usedPercent": 5.0, "windowDurationMins": 300, "resetsAt": reset}}));

        let texts = [NOW + 7_200.0, NOW + 900.0, NOW + 30.0, NOW].map(|reset| line(&window(reset), NOW));

        assert_eq!(texts, ["5% usage - reset 2h", "5% usage - reset 15m", "5% usage - reset 0m", "5% usage - reset now"]);
    }

    #[test]
    fn a_weekly_reset_shows_its_paris_day_and_time_through_daylight_saving() {
        let weekly = |reset: &str| rate(json!({"primary": {"usedPercent": 10.0, "windowDurationMins": 10_080, "resetsAt": at(reset)}}));

        let texts = ["2099-11-04T00:59:59.934Z", "2099-07-04T16:59:59Z", "2099-11-04T17:00:00Z"].map(|reset| line(&weekly(reset), NOW));

        assert_eq!(texts, ["10% wk - reset Wed 01h59", "10% wk - reset Sat 18h59", "10% wk - reset Wed 18h00"]);
    }

    #[test]
    fn an_unused_five_hour_window_without_a_reset_is_left_out_beside_a_weekly_one() {
        let limits = rate(json!({"primary": {"usedPercent": 0.0, "windowDurationMins": 300}, "secondary": {"usedPercent": 40.0, "windowDurationMins": 10_080, "resetsAt": at("2099-11-04T17:00:00Z")}}));
        let alone = rate(json!({"primary": {"usedPercent": 0.0, "windowDurationMins": 300}}));

        let (shown, kept) = (line(&limits, NOW), line(&alone, NOW));

        assert_eq!(shown, "40% wk - reset Wed 18h00");
        assert_eq!(kept, "0% usage");
    }

    #[test]
    fn a_weekly_reset_after_another_window_is_not_told() {
        let limits = rate(json!({"primary": {"usedPercent": 25.0, "windowDurationMins": 1_440}, "secondary": {"usedPercent": 40.0, "windowDurationMins": 10_080, "resetsAt": NOW + 3_600.0}}));

        let text = line(&limits, NOW);

        assert_eq!(text, "25% 1d - 40% wk");
    }

    #[test]
    fn an_empty_answer_reports_no_usage() {
        let (text, share) = (line(&Object::new(), NOW), percent(&Object::new()));

        assert_eq!((text.as_str(), share), ("", None));
    }

    #[test]
    fn a_used_up_window_rests_the_account_until_its_latest_reset() {
        let limits = rate(json!({"primary": {"usedPercent": 100.0, "windowDurationMins": 300, "resetsAt": NOW + 600.0}, "secondary": {"usedPercent": 100.0, "windowDurationMins": 10_080, "resetsAt": NOW + 86_400.0}}));
        let open = rate(json!({"primary": {"usedPercent": 99.0, "windowDurationMins": 300, "resetsAt": NOW + 600.0}}));

        let (rest, none) = (exhausted_reset(&limits, NOW), exhausted_reset(&open, NOW));

        assert_eq!(rest, Some(NOW + 86_400.0));
        assert_eq!(none, None);
    }
}
