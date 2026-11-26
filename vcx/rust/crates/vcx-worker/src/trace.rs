//! The Swift `Trace`: a session's prompts, agent events and notices, one JSON object per line (keys sorted, long
//! strings clipped, with the time, type and process). Lines go to `trace.jsonl` in the session's state folder, the file
//! `trace_archive.py` moves into `conversations.sqlite`, the table the Swift worker writes; the migration runs at most
//! once a minute per folder, and on close.

use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const LONGEST_STRING: usize = 600;
pub const TRACE_FILE: &str = "trace.jsonl";
pub const ROTATED_FILE: &str = "trace.jsonl.1";
/// Past this size the trace starts over beside its previous file, which the migration imports too: a worker that
/// finds no `trace_archive.py` still keeps its trace bounded.
const ROTATE_BYTES: u64 = 16 * 1024 * 1024;
const MIGRATION_INTERVAL: Duration = Duration::from_secs(60);
const MAX_MIGRATION_STATES: usize = 16;
const PRIVATE_FILE: u32 = 0o600;
const PRIVATE_FOLDER: u32 = 0o700;
const PYTHON: &str = "/usr/bin/python3";
const BUNDLED_ARCHIVE: &str = "../Resources/trace_archive.py";
/// A build run from its source tree uses the tree's script, as the Swift worker falls back to `#filePath`'s.
const SOURCE_ARCHIVE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../trace_archive.py");
const CLIPPED: &str = " … ";
const TIME_FORMAT: &str = "%Y-%m-%dT%H:%M:%S%.3f%:z";

pub fn clip(value: Value) -> Value {
    match value {
        Value::String(text) => {
            let count = text.chars().count();
            if count <= LONGEST_STRING {
                return Value::String(text);
            }
            let half = LONGEST_STRING / 2;
            let head: String = text.chars().take(half).collect();
            let tail: String = text.chars().skip(count - half).collect();
            Value::String(format!("{head}{CLIPPED}{tail}"))
        }
        Value::Object(fields) => Value::Object(fields.into_iter().map(|(key, value)| (key, clip(value))).collect()),
        Value::Array(list) => Value::Array(list.into_iter().map(clip).collect()),
        other => other,
    }
}

/// One line of the trace, without its newline.
pub fn entry(kind: &str, data: Value, time: &str) -> String {
    let mut entry = match clip(data) {
        Value::Object(fields) => fields,
        _ => Map::new(),
    };
    entry.insert("time".into(), json!(time));
    entry.insert("type".into(), json!(kind));
    entry.insert("pid".into(), json!(std::process::id()));
    Value::Object(entry).to_string()
}

pub fn write(directory: &Path, kind: &str, data: Value) {
    migrate(directory, false);
    let line = entry(kind, data, &jiff::Zoned::now().strftime(TIME_FORMAT).to_string()) + "\n";
    let _ = append(directory, line.as_bytes());
}

/// Appends to the folder's trace, a private file of his that is never a link.
fn append(directory: &Path, line: &[u8]) -> io::Result<()> {
    DirBuilder::new().recursive(true).mode(PRIVATE_FOLDER).create(directory)?;
    let file = directory.join(TRACE_FILE);
    if fs::symlink_metadata(&file).is_ok_and(|metadata| metadata.is_file() && metadata.len() >= ROTATE_BYTES) {
        fs::rename(&file, directory.join(ROTATED_FILE))?;
    }
    let mut handle = OpenOptions::new().append(true).create(true).mode(PRIVATE_FILE).custom_flags(libc::O_NOFOLLOW).open(&file)?;
    let metadata = handle.metadata()?;
    let owned = metadata.is_file() && metadata.uid() == unsafe { libc::getuid() } && metadata.mode() & 0o777 == PRIVATE_FILE && metadata.nlink() == 1;
    if !owned {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "The trace file is not a private file of this user."));
    }
    handle.write_all(line)
}

/// The Swift `migrationTimes` and `migrating`: one migration at a time per folder, at most 16 folders followed.
#[derive(Default)]
struct Migrations {
    times: BTreeMap<PathBuf, Instant>,
    running: BTreeSet<PathBuf>,
}

impl Migrations {
    const fn new() -> Self {
        Self { times: BTreeMap::new(), running: BTreeSet::new() }
    }

    fn begin(&mut self, directory: &Path, now: Instant, force: bool) -> bool {
        let recent = self.times.get(directory).is_some_and(|last| now.duration_since(*last) < MIGRATION_INTERVAL);
        if self.running.contains(directory) || self.running.len() >= MAX_MIGRATION_STATES || (recent && !force) {
            return false;
        }
        if self.times.len() >= MAX_MIGRATION_STATES {
            if let Some(oldest) = self.times.iter().min_by_key(|(_, time)| **time).map(|(folder, _)| folder.clone()) {
                self.times.remove(&oldest);
            }
        }
        self.times.insert(directory.to_owned(), now);
        self.running.insert(directory.to_owned());
        true
    }
}

static MIGRATIONS: Mutex<Migrations> = Mutex::new(Migrations::new());

fn archive_script() -> Option<PathBuf> {
    // A unit test reads the trace file it wrote; a migration would move it away under it.
    if cfg!(test) {
        return None;
    }
    let bundled = std::env::current_exe().ok().and_then(|exe| Some(exe.parent()?.join(BUNDLED_ARCHIVE)));
    bundled.filter(|script| script.exists()).or_else(|| Some(PathBuf::from(SOURCE_ARCHIVE)).filter(|script| script.exists()))
}

/// Moves the folder's trace into its database in the background; `force` skips the once-a-minute limit.
pub fn migrate(directory: &Path, force: bool) {
    let Some(script) = archive_script() else { return };
    if !MIGRATIONS.lock().is_ok_and(|mut migrations| migrations.begin(directory, Instant::now(), force)) {
        return;
    }
    let directory = directory.to_owned();
    std::thread::spawn(move || {
        let _ = run_archive(&script, &directory);
        if let Ok(mut migrations) = MIGRATIONS.lock() {
            migrations.running.remove(&directory);
        }
    });
}

fn run_archive(script: &Path, directory: &Path) -> io::Result<()> {
    let mut child = Command::new(PYTHON).arg(script).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn()?;
    let written = child.stdin.take().map(|mut input| input.write_all(json!({"state": directory}).to_string().as_bytes()));
    child.wait()?;
    written.unwrap_or(Ok(()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Session;

    fn scratch(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("vcx-trace-{name}-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&folder).unwrap();
        folder
    }

    fn lines(folder: &Path) -> Vec<Value> {
        fs::read_to_string(folder.join(TRACE_FILE)).unwrap_or_default().lines().map(|line| serde_json::from_str(line).unwrap()).collect()
    }

    #[test]
    fn a_long_string_keeps_its_two_ends_around_an_ellipsis() {
        let text = format!("{}{}", "a".repeat(LONGEST_STRING), "b".repeat(LONGEST_STRING));

        let clipped = clip(json!({"list": [text], "short": "kept", "count": 3}));

        let kept = clipped["list"][0].as_str().unwrap();
        assert_eq!(kept, format!("{}{CLIPPED}{}", "a".repeat(LONGEST_STRING / 2), "b".repeat(LONGEST_STRING / 2)));
        assert_eq!((clipped["short"].clone(), clipped["count"].clone()), (json!("kept"), json!(3)));
    }

    #[test]
    fn an_entry_is_one_line_with_sorted_keys_its_type_time_and_process() {
        let line = entry("prompt", json!({"text": "hi", "images": 1}), "2026-11-26T10:00:00.000+01:00");

        assert_eq!(line, format!(r#"{{"images":1,"pid":{},"text":"hi","time":"2026-11-26T10:00:00.000+01:00","type":"prompt"}}"#, std::process::id()));
    }

    #[test]
    fn a_tracing_session_writes_its_notice_with_its_record_thread_and_folder() {
        let folder = scratch("notice");
        let mut session = Session::new("/work", &folder.to_string_lossy());
        session.tracing = true;
        session.thread_id = Some("T".into());

        session.notice("Could not save.");

        let written = lines(&folder);
        assert_eq!(written.len(), 1);
        assert_eq!([&written[0]["type"], &written[0]["text"], &written[0]["thread"], &written[0]["cwd"]], [&json!("notice"), &json!("Could not save."), &json!("T"), &json!("/work")]);
        assert_eq!(written[0]["record"], json!(session.record_id));
        let mode = fs::metadata(folder.join(TRACE_FILE)).unwrap().mode() & 0o777;
        assert_eq!(mode, PRIVATE_FILE);
        fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn a_session_that_does_not_trace_writes_nothing() {
        let folder = scratch("silent");
        let mut session = Session::new("/work", &folder.to_string_lossy());

        session.notice("Could not save.");

        assert!(!folder.join(TRACE_FILE).exists());
        fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn a_linked_trace_file_is_refused_and_its_target_left_alone() {
        let folder = scratch("link");
        let target = folder.join("target");
        fs::write(&target, "").unwrap();
        std::os::unix::fs::symlink(&target, folder.join(TRACE_FILE)).unwrap();

        let appended = append(&folder, b"line\n");

        assert!(appended.is_err());
        assert_eq!(fs::read_to_string(&target).unwrap(), "");
        fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn a_full_trace_moves_beside_and_a_new_one_starts() {
        let folder = scratch("rotate");
        let full = OpenOptions::new().create(true).write(true).mode(PRIVATE_FILE).open(folder.join(TRACE_FILE)).unwrap();
        full.set_len(ROTATE_BYTES).unwrap();

        append(&folder, b"next\n").unwrap();

        assert_eq!(fs::metadata(folder.join(ROTATED_FILE)).unwrap().len(), ROTATE_BYTES);
        assert_eq!(fs::read_to_string(folder.join(TRACE_FILE)).unwrap(), "next\n");
        fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn a_folder_migrates_once_a_minute_unless_forced_and_never_twice_at_once() {
        let mut migrations = Migrations::new();
        let (folder, now) = (Path::new("/state"), Instant::now());

        let first = migrations.begin(folder, now, false);
        let while_running = migrations.begin(folder, now, true);
        migrations.running.remove(folder);
        let soon = migrations.begin(folder, now + Duration::from_secs(1), false);
        let forced = migrations.begin(folder, now + Duration::from_secs(1), true);
        migrations.running.remove(folder);
        let later = migrations.begin(folder, now + MIGRATION_INTERVAL + Duration::from_secs(1), false);

        assert_eq!([first, while_running, soon, forced, later], [true, false, false, true, true]);
    }
}
