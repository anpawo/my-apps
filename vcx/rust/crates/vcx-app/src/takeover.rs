//! Taking over the Swift app's windows at the switch (Swift `RuntimeRecovery.pending`): each window its recovery folder
//! lists, whose frontend is gone, reopens in VCX Rust on the same worker and session. Only when asked: a session the
//! Swift app still shows is never taken, since its live owner keeps it out of the list.

use serde_json::{Map, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// The Swift app's own limits (`RuntimeChannel.maximumFrame`, `RuntimeRecovery.entries`).
const MAXIMUM_BYTES: u64 = 32 * 1024 * 1024;
const MAXIMUM_ENTRIES: usize = 1024;
const PRIVATE_FOLDER: u32 = 0o700;
const GROUP_OR_OTHER: u32 = 0o077;
const MICROSECONDS_PER_SECOND: u64 = 1_000_000;
const WINDOW_SUFFIX: &str = ".window.json";
/// Where the Swift app keeps its recovery list, under his home.
const SWIFT_RECOVERY: &str = "runtime/recovery";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub session_id: String,
    pub cwd: String,
    pub socket: PathBuf,
    pub record_id: Option<String>,
    /// The desktop the Swift window was on (its `windowState.desktop`, Swift `Desktops.index`).
    pub desktop: Option<usize>,
}

/// The Swift app's recovery folder on his Mac.
pub fn default_folder(home: &Path) -> PathBuf {
    home.join(vcx_config::homes::SWIFT_STATE).join(SWIFT_RECOVERY)
}

/// The windows listed in `folder` whose frontend is gone, with the Swift app's own checks; an unsafe file fails the
/// whole read, as it does in Swift.
pub fn pending(folder: &Path) -> Result<Vec<Entry>, String> {
    let info = fs::symlink_metadata(folder).map_err(|error| format!("Cannot read {}: {error}.", folder.display()))?;
    if !info.is_dir() || info.uid() != uid() || info.mode() & 0o777 != PRIVATE_FOLDER {
        return Err("The Swift recovery folder must be private and owned by your account.".into());
    }
    let mut names: Vec<String> = fs::read_dir(folder).map_err(|error| format!("Cannot list {}: {error}.", folder.display()))?
        .flatten().map(|entry| entry.file_name().to_string_lossy().into_owned()).filter(|name| name.ends_with(WINDOW_SUFFIX)).collect();
    names.sort();
    let mut entries = Vec::new();
    for name in names {
        if entries.len() >= MAXIMUM_ENTRIES {
            return Err("Too many sessions require recovery.".into());
        }
        let Some(value) = read(&folder.join(&name))? else { continue };
        if let Some(entry) = entry(folder, &name, &value)? {
            entries.push(entry);
        }
    }
    Ok(entries)
}

fn entry(folder: &Path, name: &str, value: &Value) -> Result<Option<Entry>, String> {
    if value["closeRequested"] == Value::Bool(true) || owner_alive(value) {
        return Ok(None);
    }
    let Some(id) = value["sessionId"].as_str().and_then(uuid_string) else { return Ok(None) };
    let (Some(socket), Some(state)) = (value["socket"].as_str().filter(|socket| socket.starts_with('/')), value["state"].as_object()) else { return Ok(None) };
    if name != format!("{id}{WINDOW_SUFFIX}") {
        return Ok(None);
    }
    // The worker's checkpoint is newer than the window's own state for every field read here.
    let checkpoint = read(&folder.join(format!("{id}.checkpoint.json")))?.and_then(|checkpoint| checkpoint.as_object().cloned()).unwrap_or_default();
    let field = |key: &str| checkpoint.get(key).or_else(|| state.get(key)).and_then(Value::as_str).map(str::to_owned);
    let Some(cwd) = field("conversationDirectory").or_else(|| field("cwd")).filter(|cwd| cwd.starts_with('/')) else { return Ok(None) };
    let record_id = field("recordID").as_deref().and_then(uuid_string);
    // Only the window state is the window's own over the checkpoint's (Swift `RuntimeRecovery.pending`).
    let window_state = state.get("windowState").or_else(|| checkpoint.get("windowState"));
    let desktop = window_state.and_then(|window| window["desktop"].as_u64()).and_then(|index| usize::try_from(index).ok());
    Ok(Some(Entry { session_id: id, cwd, socket: socket.into(), record_id, desktop }))
}

/// A frontend still running owns its window: the recorded pid started at the recorded time (Swift `ownerStart`).
fn owner_alive(value: &Value) -> bool {
    let (Some(pid), Some(started)) = (value["ownerPID"].as_i64().and_then(|pid| i32::try_from(pid).ok()), value["ownerStart"].as_u64()) else { return false };
    started > 0 && start_microseconds(pid) == Some(started)
}

fn start_microseconds(pid: i32) -> Option<u64> {
    // SAFETY: proc_bsdinfo is plain data; zeroed is a valid value for it.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    // SAFETY: the buffer is a proc_bsdinfo of exactly `size` bytes, which PROC_PIDTBSDINFO fills.
    let filled = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) };
    (filled == size).then(|| info.pbi_start_tvsec * MICROSECONDS_PER_SECOND + info.pbi_start_tvusec)
}

/// Read through the opened file itself, so a file swapped after the check is never the one read.
fn read(file: &Path) -> Result<Option<Value>, String> {
    let mut opened: File = match OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(file) {
        Ok(opened) => opened,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("Cannot open session recovery data.".into()),
    };
    let info = opened.metadata().map_err(|_| "Cannot inspect session recovery data.")?;
    if !info.is_file() || info.uid() != uid() || info.mode() & GROUP_OR_OTHER != 0 || info.len() > MAXIMUM_BYTES {
        return Err("Session recovery data has unsafe ownership, permissions or size.".into());
    }
    let mut bytes = Vec::new();
    opened.read_to_end(&mut bytes).map_err(|_| "Cannot read session recovery data.")?;
    serde_json::from_slice::<Map<String, Value>>(&bytes).map(|value| Some(Value::Object(value))).map_err(|_| "Session recovery data is invalid.".into())
}

/// The Swift app names sessions and records by upper-case UUIDs.
fn uuid_string(raw: &str) -> Option<String> {
    uuid::Uuid::parse_str(raw).ok().map(|id| id.to_string().to_uppercase())
}

fn uid() -> u32 {
    // SAFETY: getuid has no preconditions.
    unsafe { libc::getuid() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::os::unix::fs::PermissionsExt;

    const ID: &str = "0A1B2C3D-0000-4000-8000-000000000001";
    const RECORD: &str = "0A1B2C3D-0000-4000-8000-0000000000AA";

    fn folder(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("vcx-app-takeover-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        fs::create_dir_all(&folder).unwrap();
        fs::set_permissions(&folder, fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
        folder
    }

    fn write(folder: &Path, name: &str, value: &Value) {
        let file = folder.join(name);
        fs::write(&file, value.to_string()).unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
    }

    fn window(owner: i64, started: u64) -> Value {
        json!({"sessionId": ID.to_lowercase(), "socket": "/tmp/w.sock", "ownerPID": owner, "ownerStart": started, "state": {"cwd": "/tmp/project", "recordID": RECORD}})
    }

    #[test]
    fn lists_a_window_whose_swift_frontend_is_gone_with_its_checkpoint_folder() {
        let folder = folder("gone");
        write(&folder, &format!("{ID}.window.json"), &window(1, 1));
        write(&folder, &format!("{ID}.checkpoint.json"), &json!({"conversationDirectory": "/tmp/moved"}));

        let listed = pending(&folder);

        fs::remove_dir_all(&folder).unwrap();
        assert_eq!(listed, Ok(vec![Entry { session_id: ID.into(), cwd: "/tmp/moved".into(), socket: "/tmp/w.sock".into(), record_id: Some(RECORD.into()), desktop: None }]));
    }

    #[test]
    fn keeps_the_desktop_of_the_window_state_over_the_checkpoints() {
        let folder = folder("desktop");
        let mut window = window(1, 1);
        window["state"]["windowState"] = json!({"desktop": 2});
        write(&folder, &format!("{ID}.window.json"), &window);
        write(&folder, &format!("{ID}.checkpoint.json"), &json!({"windowState": {"desktop": 0}}));

        let listed = pending(&folder);

        fs::remove_dir_all(&folder).unwrap();
        assert_eq!(listed.map(|entries| entries.iter().map(|entry| entry.desktop).collect::<Vec<_>>()), Ok(vec![Some(2)]));
    }

    #[test]
    fn leaves_a_window_its_running_frontend_holds_or_asked_to_close() {
        let folder = folder("held");
        let me = i64::from(std::process::id());
        write(&folder, &format!("{ID}.window.json"), &window(me, start_microseconds(me as i32).unwrap()));
        let other = "0A1B2C3D-0000-4000-8000-000000000002";
        let mut closing = window(1, 1);
        closing["sessionId"] = json!(other);
        closing["closeRequested"] = json!(true);
        write(&folder, &format!("{other}.window.json"), &closing);

        let listed = pending(&folder);

        fs::remove_dir_all(&folder).unwrap();
        assert_eq!(listed, Ok(Vec::new()));
    }

    #[test]
    fn refuses_a_recovery_file_others_can_read() {
        let folder = folder("open");
        write(&folder, &format!("{ID}.window.json"), &window(1, 1));
        fs::set_permissions(folder.join(format!("{ID}.window.json")), fs::Permissions::from_mode(0o644)).unwrap();

        let listed = pending(&folder);

        fs::remove_dir_all(&folder).unwrap();
        assert_eq!(listed, Err("Session recovery data has unsafe ownership, permissions or size.".into()));
    }
}
