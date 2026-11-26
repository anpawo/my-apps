//! Conversations saved as the Swift app saves them, so either app reopens the other's: one snapshot per record in
//! `<state>/native/<folder pointer>/<record>.json`, the folder's pointers beside it, a lock per open record and a
//! lease per open native thread (Session.swift `save`, `claimRecord`; NativeThreadLease.swift; ArchivePath.swift).

mod sha256;

use serde_json::Value;
use std::fs::{self, File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::time::SystemTime;

pub type Object = serde_json::Map<String, Value>;

pub const RECORD_OPEN: &str = "This conversation is already open in another window. Use that window, or start a new conversation here.";
pub const THREAD_OPEN: &str = "This native conversation is already open in another window. Use that window, or start a new conversation here.";
/// How many saved conversations `/resume` lists, as the Swift `nativeRecentLimit`.
pub const RECENT_LIMIT: usize = 40;
pub const NEW_CONVERSATION: &str = "New conversation";
const POINTER_DIGITS: usize = 24;
const TITLE_CHARS: usize = 100;
const UUID_LENGTH: usize = 36;
const PRIVATE_FOLDER: u32 = 0o700;
const PRIVATE_FILE: u32 = 0o600;
/// Providers whose agents name their threads `<provider>:<id>`.
const NAMESPACED: [&str; 3] = ["claude", "agy", "qwen"];
const ANSWER: &str = "⟶ ";
const NEXT: &str = "⟶ Next:";

/// Swift's `UUID(uuidString:)`: the hyphenated form only.
pub fn is_uuid(text: &str) -> bool {
    text.len() == UUID_LENGTH && uuid::Uuid::try_parse(text).is_ok()
}

/// One provider thread a record owns, under the Swift JSON names.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct NativeSource {
    pub provider: String,
    pub home: String,
    #[serde(rename = "threadId")]
    pub thread_id: String,
    #[serde(rename = "nativeHistoryPath", default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(rename = "pendingCreation", default)]
    pub pending_creation: bool,
    #[serde(default)]
    pub managed: bool,
    #[serde(rename = "clientVersion", default, skip_serializing_if = "Option::is_none")]
    pub client_version: Option<String>,
    #[serde(rename = "accountId", default, skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
}

impl NativeSource {
    pub fn new(provider: &str, home: &str, thread: &str, path: Option<String>, pending_creation: bool) -> Self {
        let home = canonical_archive_root(Path::new(home)).map_or_else(|_| home.to_owned(), |root| root.to_string_lossy().into_owned());
        let raw = thread.rsplit(':').next().unwrap_or(thread);
        let thread_id = if is_uuid(raw) { raw.to_lowercase() } else { raw.to_owned() };
        Self { provider: provider.to_owned(), home, thread_id, path, pending_creation, managed: false, client_version: None, account_id: None }
    }

    /// A source as a record stores it, read as the Swift `init?(_:)` reads one.
    pub fn from_json(value: &Value) -> Option<Self> {
        let text = |key: &str| value.get(key).and_then(Value::as_str);
        let flag = |key: &str| value.get(key).and_then(Value::as_bool).unwrap_or(false);
        let mut source = Self::new(text("provider")?, text("home")?, text("threadId")?, text("nativeHistoryPath").map(str::to_owned), flag("pendingCreation"));
        source.managed = flag("managed");
        source.client_version = text("clientVersion").map(str::to_owned);
        source.account_id = text("accountId").map(str::to_owned);
        Some(source)
    }

    pub fn list(value: Option<&Value>) -> Vec<Self> {
        value.and_then(Value::as_array).into_iter().flatten().filter_map(Self::from_json).collect()
    }

    pub fn key(&self) -> String {
        sha256::hex(format!("{}\0{}\0{}", self.provider, self.home, self.thread_id).as_bytes())
    }

    pub fn json(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }

    /// The thread as its provider's agent resumes it.
    pub fn native_thread(&self) -> String {
        if NAMESPACED.contains(&self.provider.as_str()) { format!("{}:{}", self.provider, self.thread_id) } else { self.thread_id.clone() }
    }
}

/// `path` with `.` and `..` folded away, as Foundation's `standardizedFileURL`.
pub fn standardized(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// The real path of the closest existing ancestor, with the missing parts after it (`/tmp` reads `/private/tmp`).
pub fn canonical_archive_root(directory: &Path) -> Result<PathBuf, String> {
    let failed = || "Archive root could not be resolved.".to_owned();
    let mut ancestor = standardized(directory);
    let mut missing = Vec::new();
    loop {
        match fs::symlink_metadata(&ancestor) {
            Ok(_) => break,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound && ancestor.parent().is_some() => {
                missing.push(ancestor.file_name().ok_or_else(failed)?.to_owned());
                ancestor.pop();
            }
            Err(_) => return Err(failed()),
        }
    }
    let mut canonical = fs::canonicalize(&ancestor).map_err(|_| failed())?;
    canonical.extend(missing.iter().rev());
    Ok(canonical)
}

/// The name the Swift `pointer` gives a folder's files: the start of its path's SHA-256.
pub fn pointer_stem(conversation_directory: &str) -> String {
    sha256::hex(conversation_directory.as_bytes())[..POINTER_DIGITS].to_owned()
}

/// The Codex thread a folder reopens with `last`.
pub fn resume_pointer(state: &Path, conversation_directory: &str) -> PathBuf {
    state.join(format!("{}.json", pointer_stem(conversation_directory)))
}

/// The record a folder reopens with `last`.
pub fn native_pointer(state: &Path, conversation_directory: &str) -> PathBuf {
    state.join(format!("{}.native.json", pointer_stem(conversation_directory)))
}

pub fn native_directory(state: &Path, conversation_directory: &str) -> PathBuf {
    state.join("native").join(pointer_stem(conversation_directory))
}

pub fn snapshot(state: &Path, conversation_directory: &str, record: &str) -> PathBuf {
    native_directory(state, conversation_directory).join(format!("{record}.json"))
}

fn native_folders(state: &Path) -> Vec<PathBuf> {
    fs::read_dir(state.join("native")).into_iter().flatten().flatten().map(|entry| entry.path()).collect()
}

/// Every snapshot of `id`, whichever folder saved it.
pub fn record_files(state: &Path, id: &str) -> Vec<PathBuf> {
    native_folders(state).into_iter().map(|folder| folder.join(format!("{id}.json"))).filter(|path| path.exists()).collect()
}

fn modified(path: &Path) -> SystemTime {
    fs::metadata(path).and_then(|meta| meta.modified()).unwrap_or(SystemTime::UNIX_EPOCH)
}

pub fn newest_record_file(state: &Path, id: &str) -> Option<PathBuf> {
    record_files(state, id).into_iter().max_by_key(|path| modified(path))
}

/// Every snapshot file with its modification time.
pub fn snapshot_files(state: &Path) -> Vec<(String, SystemTime, PathBuf)> {
    let files = native_folders(state).into_iter().flat_map(|folder| fs::read_dir(folder).into_iter().flatten().flatten().map(|entry| entry.path()));
    files.filter(|path| path.extension().is_some_and(|extension| extension == "json")).map(|path| (path.file_stem().unwrap_or_default().to_string_lossy().into_owned(), modified(&path), path)).collect()
}

pub fn read_object(path: &Path) -> Option<Object> {
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

fn flock(file: &File, operation: i32) -> bool {
    // SAFETY: the descriptor belongs to `file`, open for the length of the call.
    unsafe { libc::flock(file.as_raw_fd(), operation | libc::LOCK_NB) == 0 }
}

fn lock_file(directory: &Path, name: &str, failed: &str) -> Result<File, String> {
    fs::DirBuilder::new().recursive(true).mode(PRIVATE_FOLDER).create(directory).map_err(|error| error.to_string())?;
    let file = OpenOptions::new().read(true).write(true).create(true).mode(PRIVATE_FILE).open(directory.join(name)).map_err(|_| failed.to_owned())?;
    Ok(file)
}

/// The record's lock, held while a window has it open; another open of the file conflicts, in this process too.
pub fn claim_record(state: &Path, id: &str) -> Result<File, String> {
    let file = lock_file(&state.join("locks"), &format!("{id}.lock"), "Could not open the conversation lock.")?;
    if flock(&file, libc::LOCK_EX) { Ok(file) } else { Err(RECORD_OPEN.into()) }
}

pub fn is_open(state: &Path, id: &str) -> bool {
    File::open(state.join("locks").join(format!("{id}.lock"))).is_ok_and(|file| !flock(&file, libc::LOCK_SH))
}

/// The lease on a native thread, which no two windows hold at once.
pub fn lease(directory: &Path, source: &NativeSource) -> Result<File, String> {
    if canonical_archive_root(Path::new(&source.home))?.to_string_lossy() != source.home {
        return Err("Could not resolve the native conversation home.".into());
    }
    let file = lock_file(directory, &format!("{}.lock", source.key()), "Could not open the native conversation lock.")?;
    if flock(&file, libc::LOCK_EX) { Ok(file) } else { Err(THREAD_OPEN.into()) }
}

/// The Swift `lastAnswer`: the last `⟶ ` line of the last answer that has one, without its links' targets or marks.
pub fn last_answer(rows: &[Value]) -> Option<String> {
    for row in rows.iter().rev().filter(|row| row["kind"] == "assistant") {
        for item in row["items"].as_array().into_iter().flatten().rev() {
            let text = item["text"].as_str().unwrap_or_default();
            let Some(line) = text.split('\n').filter(|line| line.starts_with(ANSWER) && !line.starts_with(NEXT)).last() else { continue };
            let line = line.replace(NEXT, "+ Next:").replace(ANSWER, "");
            return Some(unlinked(line.trim()).replace("**", "").replace('`', ""));
        }
    }
    None
}

/// `[label](target)` becomes `label`, as the Swift regular expression `\[([^\]]+)\]\([^)]*\)` replaces it.
fn unlinked(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        let after = &rest[open + 1..];
        let link = after.find(']').filter(|close| *close > 0).and_then(|close| {
            let target = after[close + 1..].strip_prefix('(')?;
            Some((close, target.find(')')?, target))
        });
        match link {
            Some((close, end, target)) => {
                out.push_str(&rest[..open]);
                out.push_str(&after[..close]);
                rest = &target[end + 1..];
            }
            None => {
                out.push_str(&rest[..=open]);
                rest = after;
            }
        }
    }
    out + rest
}

/// What the Swift `save` titles a record: its name, else its first prompt's first hundred characters.
pub fn title(name: Option<&str>, rows: &[Value]) -> String {
    let prompt = || {
        let row = rows.iter().find(|row| row["kind"] == "user")?;
        let content = row["items"].get(0)?["content"].as_array()?;
        content.iter().find_map(|piece| piece["text"].as_str()).map(|text| text.chars().take(TITLE_CHARS).collect())
    };
    name.map(str::to_owned).or_else(prompt).unwrap_or_else(|| NEW_CONVERSATION.to_owned())
}

/// Writes `bytes` in one move, readable by this account only.
pub fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(folder) = path.parent() {
        fs::DirBuilder::new().recursive(true).mode(PRIVATE_FOLDER).create(folder).map_err(|error| error.to_string())?;
    }
    vcx_config::homes::write_private(path, bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn scratch(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("vcx-records-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        fs::create_dir_all(&folder).unwrap();
        canonical_archive_root(&folder).unwrap()
    }

    #[test]
    fn names_a_folders_files_as_the_swift_pointer_does() {
        let state = Path::new("/state");

        let stem = pointer_stem("/Users/fixture/work");

        assert_eq!(stem, sha256::hex(b"/Users/fixture/work")[..24]);
        assert_eq!(native_pointer(state, "/Users/fixture/work"), state.join(format!("{stem}.native.json")));
        assert_eq!(snapshot(state, "/Users/fixture/work", "R"), state.join("native").join(&stem).join("R.json"));
    }

    #[test]
    fn a_source_keeps_the_raw_thread_lowercased_and_keys_its_provider_home_and_thread() {
        let home = scratch("source");
        let thread = "claude:6F9619FF-8B86-D011-B42D-00CF4FC964FF";

        let source = NativeSource::new("claude", &home.to_string_lossy(), thread, None, false);
        let read = NativeSource::from_json(&source.json()).unwrap();

        assert_eq!(source.thread_id, "6f9619ff-8b86-d011-b42d-00cf4fc964ff");
        assert_eq!(source.key(), sha256::hex(format!("claude\0{}\0{}", home.display(), source.thread_id).as_bytes()));
        assert_eq!(source.native_thread(), format!("claude:{}", source.thread_id));
        assert_eq!(read, source);
    }

    #[test]
    fn a_missing_home_resolves_through_its_closest_existing_folder() {
        let root = scratch("missing");

        let resolved = canonical_archive_root(&root.join("a/../b/.codex")).unwrap();

        assert_eq!(resolved, root.join("b/.codex"));
    }

    #[test]
    fn a_claimed_record_is_open_and_a_second_claim_is_refused() {
        let state = scratch("claim");

        let held = claim_record(&state, "R").unwrap();
        let second = claim_record(&state, "R");
        let open = is_open(&state, "R");
        drop(held);

        assert_eq!(second.unwrap_err(), RECORD_OPEN);
        assert!(open);
        assert!(!is_open(&state, "R"));
    }

    #[test]
    fn a_leased_thread_is_refused_to_a_second_lease() {
        let root = scratch("lease");
        let source = NativeSource::new("codex", &root.join("home").to_string_lossy(), "T", None, true);

        let held = lease(&root.join("locks"), &source).unwrap();
        let second = lease(&root.join("locks"), &source);

        assert_eq!(second.unwrap_err(), THREAD_OPEN);
        drop(held);
    }

    #[test]
    fn the_last_answer_line_names_a_conversation_without_links_or_marks() {
        let rows = [json!({"kind": "assistant", "items": [{"text": "⟶ Fixed **the** [parser](file:///x) in `lib`\n- detail\n⟶ Next: ship it?"}]}), json!({"kind": "notice", "items": [{"text": "⟶ not an answer"}]})];

        let answer = last_answer(&rows);

        assert_eq!(answer.as_deref(), Some("Fixed the parser in lib"));
        assert_eq!(last_answer(&[json!({"kind": "assistant", "items": [{"text": "plain"}]})]), None);
    }

    #[test]
    fn a_record_is_titled_by_its_name_else_its_first_prompt() {
        let rows = [json!({"kind": "user", "items": [{"content": [{"type": "text", "text": "fix the build"}]}]})];

        assert_eq!(title(Some("Named"), &rows), "Named");
        assert_eq!(title(None, &rows), "fix the build");
        assert_eq!(title(None, &[]), NEW_CONVERSATION);
    }
}
