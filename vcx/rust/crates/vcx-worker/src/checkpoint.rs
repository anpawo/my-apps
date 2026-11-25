//! What survives a killed worker: one file per session in `<runtime home>/recovery`, in the Swift worker's format
//! (`RuntimeRecovery.saveCheckpoint`), so either frontend can reopen the conversation cold.

use serde_json::Value;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub type Object = serde_json::Map<String, Value>;

pub const KEYS: [&str; 11] = ["cwd", "conversationDirectory", "stateDirectory", "recordID", "threadID", "draft", "draftGeneration", "windowState", "consumedGeneration", "accountID", "interrupted"];
const PRIVATE_FOLDER: u32 = 0o700;
const PRIVATE_FILE: u32 = 0o600;
const OTHER_USERS_BITS: u32 = 0o077;
const MAX_BYTES: u64 = vcx_proto::frame::MAX_FRAME_BYTES as u64;

fn unsafe_data(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}

pub struct Store {
    directory: PathBuf,
}

impl Store {
    pub fn new(runtime_home: &Path) -> Self {
        Self { directory: runtime_home.join("recovery") }
    }

    fn prepare(&self) -> io::Result<()> {
        if let Some(parent) = self.directory.parent() {
            fs::create_dir_all(parent)?;
        }
        match fs::create_dir(&self.directory) {
            Ok(()) => fs::set_permissions(&self.directory, fs::Permissions::from_mode(PRIVATE_FOLDER))?,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        let info = fs::symlink_metadata(&self.directory)?;
        if !info.is_dir() || info.uid() != unsafe { libc::geteuid() } || info.mode() & 0o777 != PRIVATE_FOLDER {
            return Err(unsafe_data("Recovery folder must be private and owned by your account."));
        }
        Ok(())
    }

    fn file(&self, session_id: &str) -> io::Result<PathBuf> {
        let id = uuid::Uuid::parse_str(session_id).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "Invalid recovery session identifier."))?;
        self.prepare()?;
        Ok(self.directory.join(format!("{}.checkpoint.json", id.to_string().to_uppercase())))
    }

    pub fn read(&self, session_id: &str) -> io::Result<Option<Object>> {
        let path = self.file(session_id)?;
        let info = match fs::symlink_metadata(&path) {
            Ok(info) => info,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        if !info.is_file() || info.uid() != unsafe { libc::geteuid() } || info.mode() & OTHER_USERS_BITS != 0 || info.len() > MAX_BYTES {
            return Err(unsafe_data("Session recovery data has unsafe ownership, permissions or size."));
        }
        let mut data = Vec::new();
        OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(&path)?.read_to_end(&mut data)?;
        match serde_json::from_slice(&data) {
            Ok(Value::Object(object)) => Ok(Some(object)),
            _ => Err(io::Error::new(io::ErrorKind::InvalidData, "Session recovery data is invalid.")),
        }
    }

    /// Writes through a temporary file and a rename, so a kill mid-write leaves the previous checkpoint whole.
    pub fn save(&self, session_id: &str, state: &Object) -> io::Result<()> {
        let path = self.file(session_id)?;
        let selected: Object = state.iter().filter(|(key, _)| KEYS.contains(&key.as_str())).map(|(key, value)| (key.clone(), value.clone())).collect();
        let data = serde_json::to_vec(&selected)?;
        if data.len() as u64 > MAX_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "Session recovery data exceeds the size limit."));
        }
        let temporary = self.directory.join(format!("{}.tmp", uuid::Uuid::new_v4().to_string().to_uppercase()));
        let written = (|| {
            let mut file: File = OpenOptions::new().write(true).create_new(true).mode(PRIVATE_FILE).custom_flags(libc::O_NOFOLLOW).open(&temporary)?;
            file.write_all(&data)?;
            file.sync_all()?;
            fs::rename(&temporary, &path)
        })();
        if written.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        written
    }

    pub fn remove(&self, session_id: &str) -> io::Result<()> {
        match fs::remove_file(self.file(session_id)?) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn store(name: &str) -> (Store, PathBuf) {
        let home = std::env::temp_dir().join(format!("vcx-worker-checkpoint-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        (Store::new(&home), home)
    }

    #[test]
    fn keeps_only_the_recovery_keys_in_a_private_file() {
        let (store, home) = store("keys");
        let id = "6f1b7e9c-2c1d-4a8e-9b70-3d5c4e2a1f00";
        let state = json!({"cwd": "/tmp", "threadID": "T", "draft": [], "rows": [1, 2]});

        store.save(id, state.as_object().unwrap()).unwrap();
        let read = store.read(id).unwrap().unwrap();
        let mode = fs::metadata(home.join("recovery/6F1B7E9C-2C1D-4A8E-9B70-3D5C4E2A1F00.checkpoint.json")).unwrap().mode() & 0o777;

        assert_eq!(read, *json!({"cwd": "/tmp", "threadID": "T", "draft": []}).as_object().unwrap());
        assert_eq!(mode, PRIVATE_FILE);
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn refuses_a_checkpoint_other_users_can_read() {
        let (store, home) = store("open");
        let id = "6f1b7e9c-2c1d-4a8e-9b70-3d5c4e2a1f00";
        store.save(id, json!({"cwd": "/tmp"}).as_object().unwrap()).unwrap();
        let path = home.join("recovery/6F1B7E9C-2C1D-4A8E-9B70-3D5C4E2A1F00.checkpoint.json");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

        let read = store.read(id);

        assert_eq!(read.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn reads_nothing_for_a_session_never_saved() {
        let (store, home) = store("none");

        let read = store.read("6f1b7e9c-2c1d-4a8e-9b70-3d5c4e2a1f00").unwrap();

        assert_eq!(read, None);
        let _ = fs::remove_dir_all(home);
    }
}
