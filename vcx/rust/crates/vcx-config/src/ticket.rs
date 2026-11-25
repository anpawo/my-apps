//! A request left in the runtime folder for the running app (`<uuid><suffix>`, readable by this account only), as
//! the Swift app's `RuntimeUpdate.writeTicket` and `readTicket` do it.

use crate::homes::{private_folder, PRIVATE_FILE};
use std::fs;
use std::io::{Read as _, Write as _};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

pub const MAXIMUM_BYTES: u64 = 1_048_576;
const GROUP_OR_OTHER: u32 = 0o077;

pub fn write(folder: &Path, value: &serde_json::Value, suffix: &str) -> Result<PathBuf, String> {
    private_folder(folder)?;
    let data = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    if data.len() as u64 > MAXIMUM_BYTES {
        return Err("The request is too large.".into());
    }
    let file = folder.join(format!("{}{suffix}", uuid::Uuid::new_v4().hyphenated().to_string().to_uppercase()));
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(PRIVATE_FILE)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&file)
        .and_then(|mut handle| handle.write_all(&data))
        .map_err(|error| format!("Cannot save the request: {error}."))?;
    Ok(file)
}

/// Refuses a file outside `folder`, of another account, readable by others, too large or swapped while opened.
pub fn read(folder: &Path, file: &Path, suffix: &str) -> Result<serde_json::Value, String> {
    let unsafe_file = || "Unsafe request file.".to_owned();
    let parent = file.parent().and_then(|parent| parent.canonicalize().ok());
    if parent.is_none() || parent != folder.canonicalize().ok() || !file.to_string_lossy().ends_with(suffix) {
        return Err(unsafe_file());
    }
    let info = fs::symlink_metadata(file).map_err(|_| unsafe_file())?;
    // SAFETY: getuid has no preconditions.
    let owner = unsafe { libc::getuid() };
    if !info.is_file() || info.uid() != owner || info.mode() & GROUP_OR_OTHER != 0 || info.len() > MAXIMUM_BYTES {
        return Err(unsafe_file());
    }
    let mut handle = fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(file).map_err(|_| unsafe_file())?;
    let opened = handle.metadata().map_err(|_| unsafe_file())?;
    if opened.ino() != info.ino() || opened.dev() != info.dev() {
        return Err(unsafe_file());
    }
    let mut data = Vec::new();
    handle.read_to_end(&mut data).map_err(|_| unsafe_file())?;
    serde_json::from_slice(&data).map_err(|_| "Invalid request file.".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn scratch() -> PathBuf {
        std::env::temp_dir().join(format!("vcx-config-ticket-{}-{}", std::process::id(), uuid::Uuid::new_v4().simple()))
    }

    #[test]
    fn reads_back_a_private_request_it_wrote() {
        let folder = scratch();
        let value = serde_json::json!({"cwd": "/tmp", "prompt": "hi"});

        let file = write(&folder, &value, ".open.json").unwrap();

        let mode = fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        let read = read(&folder, &file, ".open.json");
        fs::remove_dir_all(&folder).unwrap();
        assert_eq!((read.unwrap(), mode), (value, PRIVATE_FILE));
    }

    #[test]
    fn refuses_a_request_others_can_read_or_with_another_suffix() {
        let folder = scratch();
        let file = write(&folder, &serde_json::json!({}), ".open.json").unwrap();

        let suffix = read(&folder, &file, ".send.json");
        fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();
        let shared = read(&folder, &file, ".open.json");

        fs::remove_dir_all(&folder).unwrap();
        assert!(suffix.is_err() && shared.is_err());
    }
}
