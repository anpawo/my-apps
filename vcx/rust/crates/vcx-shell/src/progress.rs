//! What a window's agent waits on, as the Swift `TaskProgress` reads it. The agent writes one line to
//! $VCX_PROGRESS_FILE: "<label>\t<file being written>\t<final bytes>" (a download, any output of known size) or
//! "<label>\t<start epoch seconds>\t<expected seconds>" (a run of known length), and deletes it when the work ends.
//! The page's status bar draws it as its progress chip.

use serde_json::{Value, json};
use std::fs;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// How often a window reads its progress file (Swift `progressTick`).
pub const TICK: Duration = Duration::from_secs(2);
/// A line left by a session that died is dropped after a day.
const STALE_AFTER: Duration = Duration::from_secs(86_400);
/// The download rate is measured over the last half minute, once four seconds of it are known.
const RATE_WINDOW_SECS: f64 = 30.0;
const RATE_AFTER_SECS: f64 = 4.0;
/// A timed run twice past its expected length is over.
const TIMER_OVER_FACTOR: f64 = 2.0;
const SECONDS_PER_MINUTE: f64 = 60.0;
const SECONDS_PER_HOUR: f64 = 3600.0;
/// `ByteCountFormatter`'s file style: decimal units, as many places as each unit shows.
const BYTE_STEP: f64 = 1000.0;
const BYTE_UNITS: [(&str, usize); 5] = [("KB", 0), ("MB", 1), ("GB", 2), ("TB", 2), ("PB", 2)];

#[derive(Debug, Clone, PartialEq)]
enum Source {
    File { path: String, total: f64 },
    Timer { start: f64, seconds: f64 },
}

/// One window's reader: it keeps the sizes it saw of the file being written, for the rate.
#[derive(Debug, Default)]
pub struct Progress {
    source: Option<Source>,
    samples: Vec<(f64, f64)>,
}

impl Progress {
    /// The page's progress message for the file at `path` at `now`: its label, fraction and detail, or a bare
    /// `{type: "progress"}` when nothing is waited on.
    pub fn read(&mut self, path: &Path, now: SystemTime) -> Value {
        let measured = fresh(path, now).and_then(|text| parse(&text)).and_then(|(label, source)| {
            if self.source.as_ref() != Some(&source) {
                self.samples.clear();
                self.source = Some(source.clone());
            }
            self.measure(&source, seconds(now)).map(|(fraction, detail)| (label, fraction, detail))
        });
        match measured {
            Some((label, fraction, detail)) => json!({"type": "progress", "label": label, "fraction": fraction, "detail": detail}),
            None => {
                self.source = None;
                self.samples.clear();
                json!({"type": "progress"})
            }
        }
    }

    fn measure(&mut self, source: &Source, now: f64) -> Option<(f64, String)> {
        match source {
            Source::Timer { start, seconds } => {
                let elapsed = now - start;
                (elapsed < seconds * TIMER_OVER_FACTOR).then(|| ((elapsed / seconds).clamp(0.0, 1.0), remaining(seconds - elapsed)))
            }
            Source::File { path, total } => {
                let done = fs::metadata(path).map(|file| file.len() as f64).unwrap_or(0.0);
                self.samples.push((now, done));
                self.samples.retain(|(at, _)| now - at <= RATE_WINDOW_SECS);
                let fraction = (done / total).min(1.0);
                let mut words = vec![percent(fraction), format!("{} of {}", bytes(done), bytes(*total))];
                if let Some(&(at, first)) = self.samples.first()
                    && now - at >= RATE_AFTER_SECS
                    && done > first
                {
                    let rate = (done - first) / (now - at);
                    words.push(format!("{}/s", bytes(rate)));
                    words.push(remaining((total - done) / rate));
                }
                Some((fraction, if done >= *total { "done".into() } else { words.join(" · ") }))
            }
        }
    }
}

fn seconds(time: SystemTime) -> f64 {
    time.duration_since(UNIX_EPOCH).map(|since| since.as_secs_f64()).unwrap_or(0.0)
}

/// The file's line, unless it was last written more than a day before `now`.
fn fresh(path: &Path, now: SystemTime) -> Option<String> {
    let modified = fs::metadata(path).and_then(|file| file.modified()).ok()?;
    if now.duration_since(modified).unwrap_or_default() >= STALE_AFTER {
        return None;
    }
    fs::read_to_string(path).ok()
}

fn parse(text: &str) -> Option<(String, Source)> {
    let parts: Vec<&str> = text.trim().split('\t').collect();
    let [label, middle, last] = parts[..] else { return None };
    let last: f64 = last.parse().ok().filter(|last| *last > 0.0)?;
    if label.is_empty() {
        return None;
    }
    if middle.starts_with('/') {
        return Some((label.into(), Source::File { path: middle.into(), total: last }));
    }
    Some((label.into(), Source::Timer { start: middle.parse().ok()?, seconds: last }))
}

fn percent(fraction: f64) -> String {
    format!("{}%", (fraction * 100.0) as i64)
}

/// Swift `ByteCountFormatter.string(fromByteCount:countStyle: .file)`.
pub fn bytes(value: f64) -> String {
    let count = value.max(0.0).trunc();
    if count == 0.0 {
        return "Zero KB".into();
    }
    if count == 1.0 {
        return "1 byte".into();
    }
    if count < BYTE_STEP {
        return format!("{count} bytes");
    }
    let mut scaled = count / BYTE_STEP;
    for (index, (unit, places)) in BYTE_UNITS.iter().enumerate() {
        let factor = 10f64.powi(*places as i32);
        let rounded = (scaled * factor).round() / factor;
        // A figure that rounds up to a thousand is the next unit's one.
        if rounded < BYTE_STEP || index == BYTE_UNITS.len() - 1 {
            let figure = format!("{rounded:.places$}");
            let figure = if figure.contains('.') { figure.trim_end_matches('0').trim_end_matches('.') } else { &figure };
            return format!("{figure} {unit}");
        }
        scaled /= BYTE_STEP;
    }
    unreachable!("the last unit always returns")
}

fn remaining(seconds: f64) -> String {
    if seconds <= 0.0 {
        "any moment".into()
    } else if seconds < SECONDS_PER_MINUTE {
        format!("{} s left", seconds as i64)
    } else if seconds < SECONDS_PER_HOUR {
        format!("{} min left", (seconds / SECONDS_PER_MINUTE) as i64)
    } else {
        format!("{:.1} h left", seconds / SECONDS_PER_HOUR)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    const TOTAL_BYTES: u64 = 2_900_000_000;
    const FIRST_BYTES: u64 = 1_200_000_000;
    const RATE_BYTES_PER_SECOND: u64 = 30_000_000;
    const LATER_SECS: u64 = 5;

    /// A folder of its own for each test, gone when it ends.
    struct Folder(PathBuf);

    impl Folder {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!("vcx-progress-{name}-{}", std::process::id()));
            fs::create_dir_all(&path).unwrap();
            Folder(path)
        }

        fn write(&self, name: &str, text: &str) -> PathBuf {
            let path = self.0.join(name);
            fs::write(&path, text).unwrap();
            path
        }
    }

    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn counts_bytes_in_the_swift_file_style() {
        let counts = [0.0, 1.0, 999.0, 1000.0, 1499.0, 1500.0, 999_499.0, 999_500.0, 1_234_567.0, 12_345_678.0, 999_950_000.0, 1_234_567_890.0, 2_900_000_000.0, 12_345_678_901.0, 1.5e12];

        let shown: Vec<String> = counts.iter().map(|count| bytes(*count)).collect();

        assert_eq!(shown, ["Zero KB", "1 byte", "999 bytes", "1 KB", "1 KB", "2 KB", "999 KB", "1 MB", "1.2 MB", "12.3 MB", "1 GB", "1.23 GB", "2.9 GB", "12.35 GB", "1.5 TB"]);
    }

    #[test]
    fn says_the_time_left_in_seconds_minutes_or_hours() {
        let left = [0.0, 57.9, 61.0, 5400.0];

        let shown: Vec<String> = left.iter().map(|seconds| remaining(*seconds)).collect();

        assert_eq!(shown, ["any moment", "57 s left", "1 min left", "1.5 h left"]);
    }

    #[test]
    fn shows_a_timed_run_with_its_fraction_and_time_left() {
        let folder = Folder::new("timer");
        let now = SystemTime::now();
        let start = seconds(now) - 30.0;
        let file = folder.write("task.progress", &format!("Running the tests\t{start}\t120\n"));

        let message = Progress::default().read(&file, now);

        assert_eq!(message["label"], "Running the tests");
        assert_eq!(message["detail"], "1 min left");
        assert!((message["fraction"].as_f64().unwrap() - 0.25).abs() < 1e-6, "{message}");
    }

    #[test]
    fn drops_a_timed_run_twice_past_its_length() {
        let folder = Folder::new("over");
        let now = SystemTime::now();
        let file = folder.write("task.progress", &format!("Building\t{}\t10", seconds(now) - 20.0));

        let message = Progress::default().read(&file, now);

        assert_eq!(message, json!({"type": "progress"}));
    }

    #[test]
    fn shows_a_download_by_its_size_then_its_rate_once_measured() {
        let folder = Folder::new("download");
        let target = folder.0.join("weights.bin");
        let download = fs::File::create(&target).unwrap();
        download.set_len(FIRST_BYTES).unwrap();
        let file = folder.write("task.progress", &format!("Downloading the Qwen model weights\t{}\t{TOTAL_BYTES}", target.display()));
        let now = SystemTime::now();
        let mut progress = Progress::default();

        let first = progress.read(&file, now);
        download.set_len(FIRST_BYTES + RATE_BYTES_PER_SECOND * LATER_SECS).unwrap();
        let later = progress.read(&file, now + Duration::from_secs(LATER_SECS));

        assert_eq!(first["detail"], "41% · 1.2 GB of 2.9 GB");
        assert_eq!(later["detail"], "46% · 1.35 GB of 2.9 GB · 30 MB/s · 51 s left");
    }

    #[test]
    fn says_done_once_the_file_has_its_whole_size() {
        let folder = Folder::new("done");
        let target = folder.write("out.bin", "12345");
        let file = folder.write("task.progress", &format!("Writing\t{}\t5", target.display()));

        let message = Progress::default().read(&file, SystemTime::now());

        assert_eq!(json!([&message["fraction"], &message["detail"]]), json!([1.0, "done"]));
    }

    #[test]
    fn ignores_a_line_left_more_than_a_day_ago() {
        let folder = Folder::new("stale");
        let file = folder.write("task.progress", "Building\t/tmp/out.bin\t5");
        let written = fs::metadata(&file).unwrap().modified().unwrap();

        let message = Progress::default().read(&file, written + STALE_AFTER + Duration::from_secs(1));

        assert_eq!(message, json!({"type": "progress"}));
    }

    #[test]
    fn gives_nothing_for_a_missing_file_or_a_malformed_line() {
        let folder = Folder::new("malformed");
        let lines = ["Building\t/tmp/out.bin", "\t/tmp/out.bin\t5", "Building\tsoon\t5", "Building\t/tmp/out.bin\t0"];
        let mut progress = Progress::default();

        let missing = progress.read(&folder.0.join("none"), SystemTime::now());
        let malformed: Vec<Value> = lines.iter().map(|line| progress.read(&folder.write("task.progress", line), SystemTime::now())).collect();

        assert_eq!(missing, json!({"type": "progress"}));
        assert!(malformed.iter().all(|message| *message == json!({"type": "progress"})), "{malformed:?}");
    }
}
