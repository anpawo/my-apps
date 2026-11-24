use std::{fs::{self, File, OpenOptions, TryLockError}, io, path::Path};

pub fn claim(path: &Path) -> io::Result<Option<File>> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let file = OpenOptions::new().read(true).write(true).create(true).truncate(false).open(path)?;
    // Never unlink this file: a new inode would allow a second independent lock.
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(error)) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{io::Read, process::{Child, Command, Stdio}, sync::{Arc, Barrier}, thread, time::{Duration, Instant}};

    const READY_TIMEOUT: Duration = Duration::from_secs(5);
    const READY_POLL: Duration = Duration::from_millis(10);
    const CONTENDERS: usize = 8;

    struct Owner(Child);

    impl Drop for Owner {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("one-text-instance-{}-{name}.lock", std::process::id()))
    }

    fn owner(path: &Path) -> Owner {
        let mut child = Owner(Command::new(std::env::current_exe().unwrap())
            .args(["--ignored", "holds_instance_lock"])
            .env("ONE_TEXT_TEST_LOCK", path)
            .stdin(Stdio::piped()).stdout(Stdio::null()).spawn().unwrap());
        let deadline = Instant::now() + READY_TIMEOUT;
        while !path.with_extension("ready").exists() {
            assert!(child.0.try_wait().unwrap().is_none(), "lock owner exited before becoming ready");
            assert!(Instant::now() < deadline, "lock owner did not become ready");
            thread::sleep(READY_POLL);
        }
        child
    }

    #[test]
    #[ignore]
    fn holds_instance_lock() {
        let Some(path) = std::env::var_os("ONE_TEXT_TEST_LOCK") else { return };
        let path = std::path::PathBuf::from(path);
        let _lock = claim(&path).unwrap().unwrap();
        fs::write(path.with_extension("ready"), []).unwrap();
        let _ = io::stdin().read_to_end(&mut Vec::new());
    }

    #[test]
    fn rejects_second_process_while_first_owns_lock() {
        let path = path("second");
        let owner = owner(&path);

        let second = claim(&path).unwrap();

        assert!(second.is_none());
        drop(owner);
        fs::remove_file(path.with_extension("ready")).unwrap();
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn accepts_new_process_after_owner_is_killed() {
        let path = path("killed");
        let owner = owner(&path);
        drop(owner);

        let replacement = claim(&path).unwrap();

        assert!(replacement.is_some());
        drop(replacement);
        fs::remove_file(path.with_extension("ready")).unwrap();
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn admits_only_one_simultaneous_launch() {
        let path = path("concurrent");
        let barrier = Arc::new(Barrier::new(CONTENDERS));
        let contenders: Vec<_> = (0..CONTENDERS).map(|_| {
            let (path, barrier) = (path.clone(), barrier.clone());
            thread::spawn(move || { barrier.wait(); claim(&path).unwrap() })
        }).collect();

        let locks: Vec<_> = contenders.into_iter().map(|thread| thread.join().unwrap()).collect();

        assert_eq!(locks.iter().filter(|lock| lock.is_some()).count(), 1);
        drop(locks);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn reports_error_when_lock_path_is_unusable() {
        let path = path("unusable");
        fs::create_dir(&path).unwrap();

        let result = claim(&path);

        assert!(result.is_err());
        fs::remove_dir(path).unwrap();
    }
}
