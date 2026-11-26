//! Fleet presence in the app's own state folder (`<state>/fleet/<pid>.json`), in the record shape the Swift app writes
//! (`FleetPresence.swift`), so Fleet can read it once pointed there; `vcx_cli::fleet::list` reads it for `--sessions`.

use serde_json::{Value, json};
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use vcx_shell::summary::Summary;

pub struct Window<'a> {
    pub session_id: &'a str,
    pub cwd: &'a str,
    pub summary: Option<&'a Summary>,
    pub window_number: Option<i64>,
}

/// One record per process: the focused window's fields at the top, every window under `sessions`.
pub fn record(pid: u32, started_at: u64, windows: &[Window], focused: Option<&str>) -> Option<Value> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|elapsed| elapsed.as_secs_f64()).unwrap_or_default();
    let sessions: Vec<Value> = windows.iter().map(|window| session(pid, started_at, window, now)).collect();
    let pick = |state: &str| sessions.iter().find(|session| session["state"] == state);
    let top = focused.and_then(|id| sessions.iter().find(|session| session["sessionId"] == id)).or_else(|| pick("waiting")).or_else(|| pick("working")).or(sessions.first())?;
    let mut record = top.clone();
    record["sessions"] = json!(sessions);
    Some(record)
}

fn session(pid: u32, started_at: u64, window: &Window, now: f64) -> Value {
    let summary = window.summary.cloned().unwrap_or_default();
    let preview: Vec<Value> = summary.preview.iter().map(|(kind, text)| json!({"kind": kind, "text": text})).collect();
    let mut value = json!({
        "pid": pid, "startedAt": started_at, "sessionId": window.session_id,
        "cwd": if summary.cwd.is_empty() { window.cwd } else { &summary.cwd },
        "state": if window.summary.is_some() { summary.state } else { "fresh" },
        "preview": preview, "updatedAt": now,
    });
    let snapshot = snapshot_path(&summary).map(Value::from);
    let optional = [("prompt", summary.prompt.map(Value::from)), ("lastPromptAt", summary.last_prompt_at.map(Value::from)), ("context", summary.context.map(Value::from)), ("threadId", summary.thread_id.map(Value::from)), ("snapshotPath", snapshot), ("windowId", window.window_number.map(Value::from))];
    for (key, field) in optional {
        if let Some(field) = field {
            value[key] = field;
        }
    }
    value
}

/// The worker's saved conversation (Swift `Session.snapshotURL`): `<state>/native/<folder digest>/<record>.json`, where
/// Fleet reads which project the session works on.
fn snapshot_path(summary: &Summary) -> Option<String> {
    let (state, folder, record) = (summary.state_directory.as_ref()?, summary.conversation_directory.as_ref()?, summary.record_id.as_ref()?);
    let stem: String = sha256(folder.as_bytes()).iter().map(|byte| format!("{byte:02x}")).collect::<String>()[..POINTER_DIGITS].to_owned();
    Some(Path::new(state).join("native").join(stem).join(format!("{record}.json")).to_string_lossy().into_owned())
}

/// The folder digest's length in hex digits (Swift `Session.pointer`'s `prefix(24)`).
const POINTER_DIGITS: usize = 24;
const SHA256_BYTES: usize = 32;

unsafe extern "C" {
    fn CC_SHA256(data: *const std::ffi::c_void, len: u32, md: *mut u8) -> *mut u8;
}

fn sha256(data: &[u8]) -> [u8; SHA256_BYTES] {
    let mut digest = [0; SHA256_BYTES];
    // SAFETY: CommonCrypto reads `len` bytes of `data` and writes 32 into `digest`; a folder path is far under 4 GB.
    unsafe { CC_SHA256(data.as_ptr().cast(), data.len() as u32, digest.as_mut_ptr()) };
    digest
}

/// Writes this process's record, or removes it when no window is left.
pub fn publish(folder: &Path, pid: u32, record: Option<Value>) -> Result<(), String> {
    let file = folder.join(format!("{pid}.json"));
    let Some(record) = record else {
        let _ = fs::remove_file(&file);
        return Ok(());
    };
    vcx_config::private_folder(folder)?;
    vcx_config::write_private(&file, record.to_string().as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use vcx_cli::fleet::{Listed, list};
    use vcx_config::process::start_time;

    fn summary(state: &'static str, prompt: &str) -> Summary {
        Summary { state, prompt: Some(prompt.into()), cwd: "/p".into(), ..Summary::default() }
    }

    #[test]
    fn puts_the_focused_window_at_the_top_and_every_window_under_sessions() {
        let (working, waiting) = (summary("working", "build it"), summary("waiting", "ask me"));
        let windows = [Window { session_id: "A", cwd: "/p", summary: Some(&working), window_number: Some(7) }, Window { session_id: "B", cwd: "/q", summary: Some(&waiting), window_number: None }];

        let unfocused = record(1, 2, &windows, None).unwrap();
        let focused = record(1, 2, &windows, Some("A")).unwrap();

        assert_eq!(unfocused["sessionId"], "B", "a question for him comes before running work");
        assert_eq!(focused["sessionId"], "A");
        assert_eq!(focused["sessions"].as_array().unwrap().len(), 2);
        assert_eq!((&focused["windowId"], &focused["prompt"], &focused["pid"]), (&json!(7), &json!("build it"), &json!(1)));
        assert_eq!(record(1, 2, &[], None), None);
    }

    #[test]
    fn points_fleet_at_the_conversation_snapshot_the_swift_app_would_name() {
        let saved = Summary { state_directory: Some("/s".into()), conversation_directory: Some("abc".into()), record_id: Some("R".into()), ..summary("ready", "go") };
        let windows = [Window { session_id: "A", cwd: "/p", summary: Some(&saved), window_number: None }, Window { session_id: "B", cwd: "/q", summary: None, window_number: None }];

        let listed = record(1, 2, &windows, Some("A")).unwrap();

        assert_eq!(listed["snapshotPath"], "/s/native/ba7816bf8f01cfea414140de/R.json");
        assert_eq!(listed["sessions"][1].get("snapshotPath"), None);
    }

    #[test]
    fn lists_only_the_windows_of_a_live_process() {
        let folder = std::env::temp_dir().join(format!("vcx-app-fleet-{}", std::process::id()));
        let me = std::process::id();
        let live = record(me, start_time(me as i32).unwrap(), &[Window { session_id: "A", cwd: "/p", summary: None, window_number: None }], None);
        let gone = record(me, 1, &[Window { session_id: "B", cwd: "/q", summary: None, window_number: None }], None);
        publish(&folder, me, live).unwrap();
        vcx_config::write_private(&folder.join("1.json"), gone.unwrap().to_string().as_bytes()).unwrap();

        let listed = list(&folder);
        publish(&folder, me, None).unwrap();
        let after_close = list(&folder);

        fs::remove_dir_all(&folder).unwrap();
        assert_eq!(listed, [Listed { id: "A".into(), provider: "codex".into(), state: "fresh".into(), cwd: "/p".into(), name: "VCX session".into() }]);
        assert_eq!(after_close, []);
    }
}
