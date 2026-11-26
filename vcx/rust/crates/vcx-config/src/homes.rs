//! The folders. His settings (`settings.json`, accounts) are shared with the Swift app and `background.py`; the Rust
//! app's state is its own, apart from the Swift app's `~/.local/state/vcx`, which it never writes (K7 of the report).
//!
//! `VCX_STATE_HOME` and `VCX_RUNTIME_HOME` keep the meaning the Swift worker gives them, a worker's own folders, and
//! the app hands them to the worker it starts; the app itself answers to `VCX_RUST_*`, so a worker's folders leaking
//! into an agent's shell never redirect the app or its command line.

use std::ffi::{CStr, OsString};
use std::fs;
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub const SETTINGS_VARIABLE: &str = "VCX_CONFIG_HOME";
pub const CONFIG_VARIABLE: &str = "VCX_RUST_CONFIG_HOME";
pub const STATE_VARIABLE: &str = "VCX_RUST_STATE_HOME";
pub const RUNTIME_VARIABLE: &str = "VCX_RUST_RUNTIME_HOME";
pub const WORKER_STATE_VARIABLE: &str = "VCX_STATE_HOME";
pub const WORKER_RUNTIME_VARIABLE: &str = "VCX_RUNTIME_HOME";
pub const NATIVE_LOCK_VARIABLE: &str = "VCX_NATIVE_LOCK_HOME";

const SETTINGS_DEFAULT: &str = "Library/Application Support/VCX";
const CONFIG_DEFAULT: &str = "Library/Application Support/VCX Rust";
const STATE_DEFAULT: &str = ".local/state/vcx-rust";
/// The Swift app's state folder, named so a test can prove nothing here points into it.
pub const SWIFT_STATE: &str = ".local/state/vcx";
pub const PRIVATE_FOLDER: u32 = 0o700;
pub const PRIVATE_FILE: u32 = 0o600;
const GROUP_OR_OTHER: u32 = 0o077;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Homes {
    /// His settings, shared with the Swift app: `settings.json`, `settings.lock`, `claude-settings.json`, `Accounts/`.
    pub shared: PathBuf,
    /// The Rust app's own settings.
    pub config: PathBuf,
    pub state: PathBuf,
    /// Worker sockets and the tickets the command line leaves for the app.
    pub runtime: PathBuf,
}

/// What a worker process reads, under the names the Swift worker reads them by.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerHomes {
    pub settings: PathBuf,
    pub state: PathBuf,
    pub runtime: PathBuf,
}

impl Homes {
    pub fn from_env() -> Self {
        Self::from_lookup(&home_directory(), |name| std::env::var_os(name))
    }

    pub fn from_lookup(home: &Path, variable: impl Fn(&str) -> Option<OsString>) -> Self {
        let pick = |name: &str, default: PathBuf| variable(name).filter(|value| !value.is_empty()).map(PathBuf::from).unwrap_or(default);
        let state = pick(STATE_VARIABLE, home.join(STATE_DEFAULT));
        Homes {
            shared: pick(SETTINGS_VARIABLE, home.join(SETTINGS_DEFAULT)),
            config: pick(CONFIG_VARIABLE, home.join(CONFIG_DEFAULT)),
            runtime: pick(RUNTIME_VARIABLE, state.join("runtime")),
            state,
        }
    }

    /// Every folder inside `root`: what tests use, never his real ones.
    pub fn under(root: &Path) -> Self {
        Homes { shared: root.join("shared"), config: root.join("config"), state: root.join("state"), runtime: root.join("state/runtime") }
    }

    /// The variables that give a child process (a test's app, the command line it starts) these same folders.
    pub fn environment(&self) -> [(&'static str, &Path); 4] {
        [(SETTINGS_VARIABLE, &self.shared), (CONFIG_VARIABLE, &self.config), (STATE_VARIABLE, &self.state), (RUNTIME_VARIABLE, &self.runtime)]
    }

    /// The same as the field, under the name `vcx-app`'s first `Homes` gave it.
    pub fn runtime(&self) -> PathBuf {
        self.runtime.clone()
    }

    /// His `settings.json`, under the lock the Swift app and `background.py` take.
    pub fn shared_settings(&self) -> crate::SettingsFile {
        crate::SettingsFile::new(&self.shared)
    }

    /// Layered over his Claude settings in VCX sessions only.
    pub fn claude_settings(&self) -> PathBuf {
        self.shared.join("claude-settings.json")
    }

    /// Where a sign-in made in VCX keeps its provider home.
    pub fn accounts(&self) -> PathBuf {
        self.shared.join("Accounts")
    }

    /// The Rust app's own settings file (worker, template, window size).
    pub fn settings(&self) -> PathBuf {
        self.config.join("settings.json")
    }

    /// The page (HTML, CSS, JS) `build-rust.sh --install` puts outside the signed bundle, so a page change ships
    /// without a rebuild; it must stay in step with `build-rust.sh`'s `page` folder.
    pub fn page(&self) -> PathBuf {
        self.config.join("page")
    }

    /// The worker's `VCX_STATE_HOME`: conversations, archives and checkpoints of the Rust app's sessions.
    pub fn worker_state(&self) -> PathBuf {
        self.state.join("worker")
    }

    /// The worker's and `background.py`'s `VCX_CONFIG_HOME`: his shared settings, as the Swift app hands them, so an
    /// account one window or `vcx -p` finds rested is rested for all. Each writes under `settings.lock`.
    pub fn worker_config(&self) -> PathBuf {
        self.shared.clone()
    }

    pub fn worker(&self) -> WorkerHomes {
        WorkerHomes { settings: self.worker_config(), state: self.worker_state(), runtime: self.runtime.clone() }
    }

    pub fn windows(&self) -> PathBuf {
        self.state.join("windows.json")
    }

    /// One `<pid>.json` per app process, in the Swift app's Fleet record shape.
    pub fn fleet(&self) -> PathBuf {
        self.state.join("fleet")
    }

    pub fn control(&self) -> PathBuf {
        self.state.join("control.sock")
    }

    /// Held by the running app: a second launch hands its request over instead.
    pub fn lock(&self) -> PathBuf {
        self.state.join("app.lock")
    }

    pub fn native_locks(&self) -> PathBuf {
        std::env::var_os(NATIVE_LOCK_VARIABLE).map(PathBuf::from).unwrap_or_else(|| self.state.join("native-locks"))
    }
}

impl WorkerHomes {
    /// A worker started with no folders gets the Rust app's, never the Swift app's.
    pub fn from_env() -> Self {
        let homes = Homes::from_env();
        let pick = |name: &str, default: PathBuf| std::env::var_os(name).filter(|value| !value.is_empty()).map(PathBuf::from).unwrap_or(default);
        WorkerHomes {
            settings: pick(SETTINGS_VARIABLE, homes.worker_config()),
            state: pick(WORKER_STATE_VARIABLE, homes.worker_state()),
            runtime: pick(WORKER_RUNTIME_VARIABLE, homes.runtime),
        }
    }

    /// For `Command::envs` when starting a worker.
    pub fn environment(&self) -> [(&'static str, &Path); 3] {
        [(SETTINGS_VARIABLE, &self.settings), (WORKER_STATE_VARIABLE, &self.state), (WORKER_RUNTIME_VARIABLE, &self.runtime)]
    }
}

/// `$HOME`, else the account's home from the user database.
pub fn home_directory() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME").filter(|home| !home.is_empty()) {
        return PathBuf::from(home);
    }
    // SAFETY: getpwuid returns a pointer into static storage or null; it is read at once, on this thread.
    unsafe {
        let entry = libc::getpwuid(libc::getuid());
        if entry.is_null() || (*entry).pw_dir.is_null() {
            return PathBuf::from("/");
        }
        PathBuf::from(CStr::from_ptr((*entry).pw_dir).to_string_lossy().into_owned())
    }
}

/// Makes `folder` (and its parents) if needed, then refuses one another account owns or others can read.
pub fn private_folder(folder: &Path) -> Result<(), String> {
    if !folder.exists() {
        fs::DirBuilder::new().recursive(true).mode(PRIVATE_FOLDER).create(folder).map_err(|error| format!("Cannot create {}: {error}.", folder.display()))?;
        fs::set_permissions(folder, fs::Permissions::from_mode(PRIVATE_FOLDER)).map_err(|error| error.to_string())?;
    }
    let info = fs::symlink_metadata(folder).map_err(|error| format!("Cannot inspect {}: {error}.", folder.display()))?;
    // SAFETY: getuid has no preconditions.
    let owner = unsafe { libc::getuid() };
    if !info.is_dir() || info.uid() != owner || info.mode() & GROUP_OR_OTHER != 0 {
        return Err(format!("{} must be a private folder owned by your account.", folder.display()));
    }
    Ok(())
}

/// Writes in one move, so a reader never sees half a file, readable by this account only. The draft's name is
/// unique, so two writers never share one.
pub fn write_private(file: &Path, bytes: &[u8]) -> Result<(), String> {
    let name = file.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let draft = file.with_file_name(format!(".{name}.{}.{}.writing", std::process::id(), uuid::Uuid::new_v4().simple()));
    let written = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(PRIVATE_FILE)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&draft)
        .and_then(|mut handle| handle.write_all(bytes).and_then(|()| handle.sync_all()))
        .and_then(|()| fs::set_permissions(&draft, fs::Permissions::from_mode(PRIVATE_FILE)))
        .and_then(|()| fs::rename(&draft, file));
    if let Err(error) = written {
        let _ = fs::remove_file(&draft);
        return Err(format!("Cannot write {}: {error}.", file.display()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn lookup(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
        let map: HashMap<String, OsString> = pairs.iter().map(|(key, value)| (key.to_string(), OsString::from(value))).collect();
        move |name| map.get(name).cloned()
    }

    #[test]
    fn keeps_his_settings_and_its_own_state_apart_from_the_swift_state() {
        let homes = Homes::from_lookup(Path::new("/h"), lookup(&[]));

        assert_eq!(homes.shared, Path::new("/h/Library/Application Support/VCX"));
        assert_eq!(homes.config, Path::new("/h/Library/Application Support/VCX Rust"));
        assert_eq!(homes.state, Path::new("/h/.local/state/vcx-rust"));
        assert_eq!(homes.runtime, Path::new("/h/.local/state/vcx-rust/runtime"));
        let paths = [homes.runtime.clone(), homes.worker_state(), homes.windows(), homes.fleet(), homes.control(), homes.lock(), homes.native_locks()];
        assert!(paths.iter().all(|path| path.starts_with(&homes.state) && !path.starts_with(Path::new("/h").join(SWIFT_STATE))));
    }

    #[test]
    fn takes_each_folder_from_its_variable() {
        let homes = Homes::from_lookup(Path::new("/h"), lookup(&[(SETTINGS_VARIABLE, "/s"), (CONFIG_VARIABLE, "/c"), (STATE_VARIABLE, "/t"), (RUNTIME_VARIABLE, "/r")]));

        assert_eq!(homes, Homes { shared: "/s".into(), config: "/c".into(), state: "/t".into(), runtime: "/r".into() });
        assert_eq!(homes.shared_settings().path(), Path::new("/s/settings.json"));
        assert_eq!(homes.settings(), Path::new("/c/settings.json"));
    }

    #[test]
    fn ignores_the_swift_worker_variables_and_empty_ones() {
        let homes = Homes::from_lookup(Path::new("/h"), lookup(&[(WORKER_STATE_VARIABLE, "/swift"), (WORKER_RUNTIME_VARIABLE, "/swift/runtime"), (STATE_VARIABLE, "")]));

        assert_eq!(homes.state, Path::new("/h/.local/state/vcx-rust"));
        assert_eq!(homes.runtime, Path::new("/h/.local/state/vcx-rust/runtime"));
    }

    #[test]
    fn hands_a_worker_its_folders_under_the_swift_names() {
        let homes = Homes::under(Path::new("/x"));

        let names: Vec<(&str, PathBuf)> = homes.worker().environment().iter().map(|(name, path)| (*name, path.to_path_buf())).collect();

        assert_eq!(names, vec![("VCX_CONFIG_HOME", "/x/shared".into()), ("VCX_STATE_HOME", "/x/state/worker".into()), ("VCX_RUNTIME_HOME", "/x/state/runtime".into())]);
    }

    #[test]
    fn refuses_a_folder_others_can_read() {
        let folder = std::env::temp_dir().join(format!("vcx-config-home-{}-{}", std::process::id(), uuid::Uuid::new_v4().simple()));
        private_folder(&folder).unwrap();
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o755)).unwrap();

        let refused = private_folder(&folder);

        fs::remove_dir_all(&folder).unwrap();
        assert!(refused.is_err());
    }

    #[test]
    fn writes_a_private_file_in_one_move() {
        let folder = std::env::temp_dir().join(format!("vcx-config-write-{}-{}", std::process::id(), uuid::Uuid::new_v4().simple()));
        private_folder(&folder).unwrap();
        let file = folder.join("a.json");

        write_private(&file, b"one").unwrap();
        write_private(&file, b"two").unwrap();

        let mode = fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        let left: Vec<_> = fs::read_dir(&folder).unwrap().map(|entry| entry.unwrap().file_name()).collect();
        let text = fs::read_to_string(&file).unwrap();
        fs::remove_dir_all(&folder).unwrap();
        assert_eq!((text.as_str(), mode, left.len()), ("two", PRIVATE_FILE, 1));
    }
}
