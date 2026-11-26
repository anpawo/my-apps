//! The update `auto-update.sh` is building, drawn as the status bar's updating chip (Swift `UpdateBuild`): the script
//! writes `<start epoch seconds>\t<the commit's subject>` to `building` while it runs, and the seconds the last one
//! took to `last-duration`, which paces the chip's line.

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};

/// Where `auto-update.sh` keeps its state, under his home.
const FOLDER: &str = ".local/share/vcx-update";
/// A test points the app at a folder of its own.
pub const FOLDER_VARIABLE: &str = "VCX_UPDATE_STATE";
/// Without a previous build to go by, one is taken to last this long.
const DEFAULT_SECONDS: f64 = 270.0;
const SHORTEST_SECONDS: f64 = 30.0;
/// A file left by a killed run is ignored after an hour.
const STALE_AFTER: f64 = 3600.0;
/// Past the previous build's time the line keeps creeping toward the end without reaching it.
const CREEP_FROM: f64 = 0.9;
const CREEP_RATE: f64 = 2.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Build {
    pub started: f64,
    pub words: String,
    pub expected: f64,
}

pub fn folder(home: &Path) -> PathBuf {
    std::env::var_os(FOLDER_VARIABLE).map_or_else(|| home.join(FOLDER), PathBuf::from)
}

pub fn parse(text: &str, expected: f64, now: f64) -> Option<Build> {
    let (start, words) = text.split_once('\t')?;
    let started: f64 = start.trim().parse().ok()?;
    (now - started < STALE_AFTER).then(|| Build { started, words: words.trim().to_owned(), expected: expected.max(SHORTEST_SECONDS) })
}

pub fn progress(build: &Build, now: f64) -> f64 {
    let t = (now - build.started).max(0.0) / build.expected;
    if t < CREEP_FROM { t } else { 1.0 - (1.0 - CREEP_FROM) * (-(t - CREEP_FROM) * CREEP_RATE).exp() }
}

pub fn read(folder: &Path, now: f64) -> Option<Build> {
    let text = fs::read_to_string(folder.join("building")).ok()?;
    let last = fs::read_to_string(folder.join("last-duration")).ok().and_then(|text| text.trim().parse().ok());
    parse(&text, last.unwrap_or(DEFAULT_SECONDS), now)
}

/// The page's message; empty words hide the chip.
pub fn message(build: Option<&Build>, now: f64) -> Value {
    match build {
        Some(build) => json!({"type": "update", "words": build.words, "fraction": progress(build, now)}),
        None => json!({"type": "update", "words": ""}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_build_under_way_paced_by_the_last_one() {
        let build = parse("1000\tfix: the bar\n", 200.0, 1100.0);

        assert_eq!(build, Some(Build { started: 1000.0, words: "fix: the bar".into(), expected: 200.0 }));
        assert_eq!(message(build.as_ref(), 1100.0), json!({"type": "update", "words": "fix: the bar", "fraction": 0.5}));
    }

    #[test]
    fn ignores_a_file_a_killed_run_left_and_hides_the_chip() {
        assert_eq!(parse("1000\tfix: the bar", 200.0, 1000.0 + STALE_AFTER), None);
        assert_eq!(parse("not a time\tfix", 200.0, 0.0), None);
        assert_eq!(message(None, 0.0), json!({"type": "update", "words": ""}));
    }

    #[test]
    fn creeps_toward_the_end_without_reaching_it_once_past_the_last_build_time() {
        let build = Build { started: 0.0, words: "w".into(), expected: 100.0 };

        let late = [progress(&build, 95.0), progress(&build, 200.0), progress(&build, 1000.0)];

        assert!(late[0] > CREEP_FROM && late[0] < late[1] && late[1] < late[2] && late[2] < 1.0, "{late:?}");
    }
}
