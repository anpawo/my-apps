//! What a window's agent is waiting on, drawn in the status bar like an update (port of TaskProgress.swift).
//! The agent writes one line to $VCX_PROGRESS_FILE: `<label>\t</abs/file being written>\t<final bytes>` or
//! `<label>\t<start epoch seconds>\t<expected seconds>`, and deletes it when the work ends.

use serde_json::{json, Value};
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// A line left by a session that died is dropped after a day.
pub const STALE_AFTER: f64 = 86_400.0;
/// The rate is measured over the samples of the last half minute.
pub const RATE_WINDOW: f64 = 30.0;
/// Fewer seconds of samples than this give a rate too jumpy to show.
pub const RATE_AFTER: f64 = 4.0;
/// A timer this many times past its length is over.
pub const TIMER_OVER_FACTOR: f64 = 2.0;
const SEPARATOR: &str = " · ";
const BYTE_UNITS: [(&str, u32); 6] = [("KB", 0), ("MB", 1), ("GB", 2), ("TB", 2), ("PB", 2), ("EB", 2)];

#[derive(Clone, Debug, PartialEq)]
pub enum Source {
    File { path: String, total: f64 },
    Timer { start: f64, seconds: f64 },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Progress {
    pub label: String,
    pub source: Source,
    pub fraction: f64,
    pub detail: String,
}

impl Progress {
    pub fn parse(text: &str) -> Option<Progress> {
        let parts: Vec<&str> = text.trim().split('\t').collect();
        let [label, middle, last] = parts[..] else { return None };
        let last: f64 = last.parse().ok()?;
        if label.is_empty() || !(last > 0.0) {
            return None;
        }
        let source = if middle.starts_with('/') {
            Source::File { path: middle.to_string(), total: last }
        } else {
            Source::Timer { start: middle.parse().ok()?, seconds: last }
        };
        Some(Progress { label: label.to_string(), source, fraction: 0.0, detail: String::new() })
    }

    /// Fills fraction and detail; `samples` keeps (time, bytes) of the last half minute for the rate. False once over.
    pub fn measure(&mut self, now: f64, size: Option<f64>, samples: &mut Vec<(f64, f64)>) -> bool {
        match self.source {
            Source::Timer { start, seconds } => {
                let elapsed = now - start;
                if !(elapsed < seconds * TIMER_OVER_FACTOR) {
                    return false;
                }
                self.fraction = (elapsed / seconds).clamp(0.0, 1.0);
                self.detail = remaining(seconds - elapsed);
            }
            Source::File { total, .. } => {
                let done = size.unwrap_or(0.0);
                samples.push((now, done));
                samples.retain(|(time, _)| now - time <= RATE_WINDOW);
                self.fraction = (done / total).min(1.0);
                let mut words = vec![percent(self.fraction), format!("{} of {}", bytes(done), bytes(total))];
                if let Some(&(first_time, first_bytes)) = samples.first() {
                    let span = now - first_time;
                    if span >= RATE_AFTER && done > first_bytes {
                        let rate = (done - first_bytes) / span;
                        words.push(format!("{}/s", bytes(rate)));
                        words.push(remaining((total - done) / rate));
                    }
                }
                self.detail = if done >= total { "done".to_string() } else { words.join(SEPARATOR) };
            }
        }
        true
    }
}

/// Reads, parses and measures the progress file; None when it is absent, malformed, stale or over.
pub fn read(path: &Path, now: f64, samples: &mut Vec<(f64, f64)>) -> Option<Progress> {
    let modified = epoch_seconds(fs::metadata(path).ok()?.modified().ok()?);
    if !(now - modified < STALE_AFTER) {
        return None;
    }
    let mut progress = Progress::parse(&fs::read_to_string(path).ok()?)?;
    let size = match &progress.source {
        Source::File { path, .. } => fs::metadata(path).ok().map(|meta| meta.len() as f64),
        Source::Timer { .. } => None,
    };
    // Swift clears the samples when the line's source changes; this module keeps no previous line, and a target
    // smaller than the last sample is a new or restarted file whose old samples would give a false rate.
    if samples.last().is_some_and(|&(_, last)| size.unwrap_or(0.0) < last) {
        samples.clear();
    }
    progress.measure(now, size, samples).then_some(progress)
}

/// The page's message: the bar with its label, detail and fraction, or an empty label that hides it.
pub fn message(progress: Option<&Progress>) -> Value {
    match progress {
        Some(progress) => json!({"type": "progress", "label": progress.label, "detail": progress.detail, "fraction": progress.fraction}),
        None => json!({"type": "progress", "label": ""}),
    }
}

pub fn percent(value: f64) -> String {
    format!("{}%", (value * 100.0) as i64)
}

/// Foundation's `ByteCountFormatter` in `.file` style: decimal units, whole KB, one decimal of MB, two above.
pub fn bytes(value: f64) -> String {
    let count = value as i64;
    if count == 0 {
        return "Zero KB".to_string();
    }
    let sign = if count < 0 { "-" } else { "" };
    let size = count.unsigned_abs() as u128;
    if size < 1000 {
        return format!("{sign}{size} {}", if size == 1 { "byte" } else { "bytes" });
    }
    let mut unit = 0;
    loop {
        let (name, decimals) = BYTE_UNITS[unit];
        let scale = 10u128.pow(decimals);
        let divisor = 1000u128.pow(unit as u32 + 1);
        let scaled = (size * scale * 2 + divisor) / (divisor * 2);
        // 999.5 KB rounds to 1000 KB, which Foundation writes as 1 MB.
        if scaled >= 1000 * scale && unit + 1 < BYTE_UNITS.len() {
            unit += 1;
            continue;
        }
        let (whole, part) = (scaled / scale, scaled % scale);
        if part == 0 {
            return format!("{sign}{whole} {name}");
        }
        let part = format!("{part:0width$}", width = decimals as usize);
        return format!("{sign}{whole}.{} {name}", part.trim_end_matches('0'));
    }
}

pub fn remaining(seconds: f64) -> String {
    if !(seconds > 0.0) {
        "any moment".to_string()
    } else if seconds < 60.0 {
        format!("{} s left", seconds as i64)
    } else if seconds < 3600.0 {
        format!("{} min left", (seconds / 60.0) as i64)
    } else {
        format!("{:.1} h left", seconds / 3600.0)
    }
}

fn epoch_seconds(time: SystemTime) -> f64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(after) => after.as_secs_f64(),
        Err(before) => -before.duration().as_secs_f64(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn file_progress(total: f64) -> Progress {
        Progress::parse(&format!("Weights\t/tmp/weights.bin\t{total}")).unwrap()
    }

    fn scratch(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("vcx-app-progress-{}-{name}", std::process::id()));
        fs::create_dir_all(&folder).unwrap();
        folder
    }

    fn now() -> f64 {
        epoch_seconds(SystemTime::now())
    }

    #[test]
    fn parses_a_file_line_and_a_timer_line() {
        let (file, timer) = ("Weights\t/tmp/w.bin\t1000000\n", "  Training\t1700000000\t600  ");

        let (file, timer) = (Progress::parse(file).unwrap(), Progress::parse(timer).unwrap());

        assert_eq!(file.label, "Weights");
        assert_eq!(file.source, Source::File { path: "/tmp/w.bin".into(), total: 1_000_000.0 });
        assert_eq!(timer.label, "Training");
        assert_eq!(timer.source, Source::Timer { start: 1_700_000_000.0, seconds: 600.0 });
    }

    #[test]
    fn rejects_malformed_lines() {
        let lines = [
            "",
            "Weights",
            "Weights\t/tmp/w.bin",
            "Weights\t/tmp/w.bin\t100\textra",
            "\t/tmp/w.bin\t100",
            "Weights\t/tmp/w.bin\t0",
            "Weights\t/tmp/w.bin\t-5",
            "Weights\t/tmp/w.bin\tmany",
            "Training\tyesterday\t600",
            "Training\trelative/file\t600",
        ];

        let parsed: Vec<Option<Progress>> = lines.iter().map(|line| Progress::parse(line)).collect();

        assert!(parsed.iter().all(Option::is_none), "{parsed:?}");
    }

    #[test]
    fn shows_percent_size_and_rate_of_a_file_being_written() {
        let mut progress = file_progress(10_000_000.0);
        let mut samples = vec![(100.0, 1_000_000.0)];

        let shown = progress.measure(110.0, Some(6_000_000.0), &mut samples);

        assert!(shown);
        assert!((progress.fraction - 0.6).abs() < 1e-9);
        assert_eq!(progress.detail, "60% · 6 MB of 10 MB · 500 KB/s · 8 s left");
    }

    #[test]
    fn hides_the_rate_before_four_seconds_of_samples() {
        let mut progress = file_progress(10_000_000.0);
        let mut samples = vec![(100.0, 1_000_000.0)];

        progress.measure(103.0, Some(2_500_000.0), &mut samples);

        assert_eq!(progress.detail, "25% · 2.5 MB of 10 MB");
        assert_eq!(samples.len(), 2);
    }

    #[test]
    fn measures_the_rate_over_the_last_half_minute_only() {
        let mut progress = file_progress(100_000_000.0);
        let mut samples = vec![(0.0, 0.0), (20.0, 10_000_000.0)];

        progress.measure(40.0, Some(30_000_000.0), &mut samples);

        assert_eq!(samples, vec![(20.0, 10_000_000.0), (40.0, 30_000_000.0)]);
        assert_eq!(progress.detail, "30% · 30 MB of 100 MB · 1 MB/s · 1 min left");
    }

    #[test]
    fn counts_a_missing_target_as_nothing_written() {
        let mut progress = file_progress(1_000_000.0);

        let shown = progress.measure(0.0, None, &mut Vec::new());

        assert!(shown);
        assert_eq!(progress.fraction, 0.0);
        assert_eq!(progress.detail, "0% · Zero KB of 1 MB");
    }

    #[test]
    fn says_done_once_the_file_reaches_its_final_size() {
        let mut progress = file_progress(1_000_000.0);
        let mut samples = vec![(0.0, 0.0)];

        progress.measure(10.0, Some(1_200_000.0), &mut samples);

        assert_eq!(progress.fraction, 1.0);
        assert_eq!(progress.detail, "done");
    }

    #[test]
    fn counts_down_a_timer_and_ends_it_twice_past_its_length() {
        let mut progress = Progress::parse("Training\t1000\t600").unwrap();

        let running = progress.measure(1150.0, None, &mut Vec::new());
        let (fraction, detail) = (progress.fraction, progress.detail.clone());
        let late = progress.measure(1900.0, None, &mut Vec::new());
        let late_detail = progress.detail.clone();
        let over = progress.measure(2200.0, None, &mut Vec::new());

        assert!(running);
        assert!((fraction - 0.25).abs() < 1e-9);
        assert_eq!(detail, "7 min left");
        assert!(late);
        assert_eq!(late_detail, "any moment");
        assert!(!over);
    }

    #[test]
    fn formats_bytes_like_foundation_file_style() {
        let cases: [(f64, &str); 22] = [
            (0.0, "Zero KB"),
            (1.0, "1 byte"),
            (500.0, "500 bytes"),
            (1000.0, "1 KB"),
            (1499.0, "1 KB"),
            (1500.0, "2 KB"),
            (12_345.0, "12 KB"),
            (999_499.0, "999 KB"),
            (999_500.0, "1 MB"),
            (1_049_999.0, "1 MB"),
            (1_050_000.0, "1.1 MB"),
            (1_234_567.0, "1.2 MB"),
            (12_345_678.0, "12.3 MB"),
            (123_456_789.0, "123.5 MB"),
            (999_950_000.0, "1 GB"),
            (1_005_000_000.0, "1.01 GB"),
            (1_234_567_890.0, "1.23 GB"),
            (12_345_678_901.0, "12.35 GB"),
            (999_999_999_999.0, "1 TB"),
            (1_234_567_890_123.0, "1.23 TB"),
            (5_500_000_000_000_000.0, "5.5 PB"),
            (-1500.0, "-2 KB"),
        ];

        let written: Vec<String> = cases.iter().map(|(value, _)| bytes(*value)).collect();

        let expected: Vec<String> = cases.iter().map(|(_, text)| text.to_string()).collect();
        assert_eq!(written, expected);
    }

    #[test]
    fn words_the_time_left_like_the_swift_bar() {
        let seconds = [0.0, -3.0, 0.5, 59.9, 60.0, 3599.0, 3600.0, 5400.0];

        let words: Vec<String> = seconds.iter().map(|value| remaining(*value)).collect();

        assert_eq!(words, ["any moment", "any moment", "0 s left", "59 s left", "1 min left", "59 min left", "1.0 h left", "1.5 h left"]);
    }

    #[test]
    fn reads_a_progress_file_and_measures_its_target() {
        let folder = scratch("read");
        let (line, target) = (folder.join("progress"), folder.join("weights.bin"));
        fs::write(&target, vec![0u8; 250_000]).unwrap();
        fs::write(&line, format!("Weights\t{}\t1000000\n", target.display())).unwrap();
        let mut samples = Vec::new();

        let progress = read(&line, now(), &mut samples);

        fs::remove_dir_all(&folder).unwrap();
        let progress = progress.unwrap();
        assert_eq!(progress.label, "Weights");
        assert!((progress.fraction - 0.25).abs() < 1e-9);
        assert_eq!(progress.detail, "25% · 250 KB of 1 MB");
        assert_eq!(samples.len(), 1);
    }

    #[test]
    fn forgets_the_samples_of_a_target_that_shrank() {
        let folder = scratch("shrank");
        let (line, target) = (folder.join("progress"), folder.join("weights.bin"));
        fs::write(&target, vec![0u8; 100_000]).unwrap();
        fs::write(&line, format!("Weights\t{}\t1000000\n", target.display())).unwrap();
        let start = now();
        let mut samples = vec![(start - 10.0, 900_000.0)];

        let progress = read(&line, start, &mut samples);

        fs::remove_dir_all(&folder).unwrap();
        assert_eq!(progress.unwrap().detail, "10% · 100 KB of 1 MB");
        assert_eq!(samples, vec![(start, 100_000.0)]);
    }

    #[test]
    fn drops_an_absent_malformed_stale_or_over_progress_file() {
        let folder = scratch("drop");
        let (absent, malformed, file, timer) = (folder.join("absent"), folder.join("malformed"), folder.join("file"), folder.join("timer"));
        fs::write(&malformed, "Weights only\n").unwrap();
        fs::write(&file, "Weights\t/nowhere/weights.bin\t1000\n").unwrap();
        let start = now();
        fs::write(&timer, format!("Training\t{}\t60\n", start - 121.0)).unwrap();

        let results = [
            read(&absent, start, &mut Vec::new()),
            read(&malformed, start, &mut Vec::new()),
            read(&file, start + STALE_AFTER + 1.0, &mut Vec::new()),
            read(&timer, start, &mut Vec::new()),
        ];
        let fresh = read(&file, start, &mut Vec::new());

        fs::remove_dir_all(&folder).unwrap();
        assert!(results.iter().all(Option::is_none), "{results:?}");
        assert!(fresh.is_some());
    }

    #[test]
    fn sends_the_label_detail_and_fraction_to_the_page() {
        let mut progress = file_progress(1_000_000.0);
        progress.measure(0.0, Some(500_000.0), &mut Vec::new());

        let sent = message(Some(&progress));

        assert_eq!(sent, json!({"type": "progress", "label": "Weights", "detail": "50% · 500 KB of 1 MB", "fraction": 0.5}));
    }

    #[test]
    fn hides_the_bar_with_an_empty_label_when_nothing_is_waited_on() {
        let sent = message(None);

        assert_eq!(sent["type"], "progress");
        assert_eq!(sent["label"], "");
    }
}
