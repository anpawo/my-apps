//! The worker's socket is created private whatever the umask. `listen` changes the process umask for a moment, so
//! this test runs in a process of its own: a test creating files beside it would get them unreadable.

use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use vcx_worker::channel::listen;

const PRIVATE_FOLDER: u32 = 0o700;
const PRIVATE_SOCKET: u32 = 0o600;

#[test]
fn binds_the_socket_private_whatever_the_umask_and_restores_it() {
    let folder = std::env::temp_dir().join(format!("vcx-worker-listen-{}", std::process::id()));
    let _ = fs::remove_dir_all(&folder);
    fs::create_dir(&folder).unwrap();
    fs::set_permissions(&folder, fs::Permissions::from_mode(PRIVATE_FOLDER)).unwrap();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let open = 0;
    let before = unsafe { libc::umask(open) };

    let listener = runtime.block_on(async { listen(&folder.join("w.sock")) }).unwrap();
    let after = unsafe { libc::umask(before) };

    assert_eq!(fs::metadata(&listener.path).unwrap().mode() & 0o777, PRIVATE_SOCKET);
    assert_eq!(after, open, "the process umask is given back");
    drop(listener);
    fs::remove_dir_all(folder).unwrap();
}
