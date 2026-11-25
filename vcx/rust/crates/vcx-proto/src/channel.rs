use std::fs;
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::net::UnixStream;
use std::path::Path;

const PRIVATE_DIRECTORY_MODE: u32 = 0o700;
const PERMISSION_BITS: u32 = 0o777;
const OTHER_USERS_BITS: u32 = 0o077;

fn refuse(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}

/// Connects to a worker socket only when its folder, the socket and the peer all belong to this user.
pub fn connect(path: &Path) -> io::Result<UnixStream> {
    let user = unsafe { libc::geteuid() };
    let parent = path.parent().ok_or_else(|| refuse("Runtime socket has no parent directory."))?;
    let directory = fs::symlink_metadata(parent)?;
    if !directory.is_dir() || directory.uid() != user || directory.mode() & PERMISSION_BITS != PRIVATE_DIRECTORY_MODE {
        return Err(refuse("Runtime directory must be private and owned by this user."));
    }
    let socket = fs::symlink_metadata(path)?;
    if !socket.file_type().is_socket() || socket.uid() != user || socket.mode() & OTHER_USERS_BITS != 0 {
        return Err(refuse("Runtime socket is unavailable or has unsafe ownership."));
    }
    let stream = UnixStream::connect(path)?;
    if peer_user(&stream)? != user {
        return Err(refuse("Runtime peer belongs to another user."));
    }
    Ok(stream)
}

fn peer_user(stream: &UnixStream) -> io::Result<libc::uid_t> {
    let (mut user, mut group) = (0, 0);
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut user, &mut group) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(user)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;

    fn private_directory(name: &str) -> PathBuf {
        // Unix socket paths are capped near 104 bytes, so the folder sits in /tmp rather than the long per-user temp folder.
        let directory = PathBuf::from(format!("/tmp/vcx-proto-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(PRIVATE_DIRECTORY_MODE)).unwrap();
        directory
    }

    #[test]
    fn connects_when_the_folder_is_private_and_the_peer_is_this_user() {
        let directory = private_directory("ok");
        let path = directory.join("worker.sock");
        let _listener = UnixListener::bind(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();

        let result = connect(&path);

        assert!(result.is_ok());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn refuses_a_socket_in_a_folder_other_users_can_enter() {
        let directory = private_directory("open");
        let path = directory.join("worker.sock");
        let _listener = UnixListener::bind(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o755)).unwrap();

        let result = connect(&path);

        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn refuses_a_path_that_is_not_a_socket() {
        let directory = private_directory("file");
        let path = directory.join("worker.sock");
        fs::write(&path, b"").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();

        let result = connect(&path);

        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        fs::remove_dir_all(directory).unwrap();
    }
}
