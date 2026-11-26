//! The task bar (Swift `TaskBoard`): the task of every window of the app, as its agent wrote it to $VCX_TASK_FILE,
//! grouped by project; each page gets the list with its own window marked current.

use serde_json::{Value, json};
use std::fs;
use std::path::Path;
use std::time::Duration;

/// The agent is asked for at most this many characters; a longer line is cut, as the Swift bar cuts it.
pub const LONGEST_TASK: usize = 40;
/// How often the task files are read again (Swift `progressTick`).
pub const TICK: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub id: String,
    pub group: String,
    pub task: String,
    pub state: &'static str,
}

/// The first line of the task file, trimmed and cut; `None` while the agent has written none.
pub fn task(path: &Path) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    let line = text.lines().next()?.trim();
    (!line.is_empty()).then(|| line.chars().take(LONGEST_TASK).collect())
}

/// The project a task is filed under: its folder with links resolved.
pub fn group(cwd: &str) -> String {
    fs::canonicalize(cwd).map_or_else(|_| cwd.to_owned(), |path| path.to_string_lossy().into_owned())
}

/// The message one page gets: every entry, its own window's marked current.
pub fn message(entries: &[Entry], current: &str) -> Value {
    let entries: Vec<Value> = entries.iter().map(|entry| json!({"id": entry.id, "group": entry.group, "task": entry.task, "state": entry.state, "current": entry.id == current})).collect();
    json!({"type": "tasks", "entries": entries})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_first_line_of_the_task_file_trimmed_and_cut() {
        let folder = std::env::temp_dir().join(format!("vcx-app-tasks-{}", std::process::id()));
        fs::create_dir_all(&folder).unwrap();
        let (short, long, blank) = (folder.join("short"), folder.join("long"), folder.join("blank"));
        fs::write(&short, "  Add a task bar to VCX  \nmore\n").unwrap();
        fs::write(&long, "x".repeat(LONGEST_TASK + 5)).unwrap();
        fs::write(&blank, "\n").unwrap();

        let read = [task(&short), task(&long).map(|task| task.len().to_string()), task(&blank), task(&folder.join("missing"))];

        fs::remove_dir_all(&folder).unwrap();
        assert_eq!(read, [Some("Add a task bar to VCX".into()), Some(LONGEST_TASK.to_string()), None, None]);
    }

    #[test]
    fn marks_only_the_receiving_window_current() {
        let entries = [Entry { id: "A".into(), group: "/p".into(), task: "one".into(), state: "working" }, Entry { id: "B".into(), group: "/q".into(), task: "two".into(), state: "done" }];

        let sent = message(&entries, "B");

        assert_eq!(sent["type"], "tasks");
        assert_eq!(sent["entries"].as_array().unwrap().iter().map(|entry| entry["current"].as_bool().unwrap()).collect::<Vec<_>>(), [false, true]);
        assert_eq!(sent["entries"][1], json!({"id": "B", "group": "/q", "task": "two", "state": "done", "current": true}));
    }
}
