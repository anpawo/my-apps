//! The Swift `DiskCleanup`: cleanup.py frees what sessions leave on disk (idle /tmp scratch, Rust incremental caches,
//! other worktrees' builds, compose volumes no recent branch declares). It throttles itself to once an hour per project,
//! so every turn can ask; a closing session forces it.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const PYTHON: &str = "/usr/bin/python3";
const BUNDLED: &str = "../Resources/cleanup.py";
/// A test worker runs only the script a test put at this name in its runtime home: the real one sweeps his /tmp.
pub const TEST_SCRIPT: &str = "cleanup.py";
const DISABLED: &str = "VCX_NO_CLEANUP";

/// Where the script is looked for at each run, as the Swift worker checks its bundle each time.
pub fn script(test_home: Option<&Path>) -> Option<PathBuf> {
    match test_home {
        Some(home) => Some(home.join(TEST_SCRIPT)),
        None => Some(std::env::current_exe().ok()?.parent()?.join(BUNDLED)),
    }
}

pub fn arguments(script: &Path, cwd: &str, force: bool) -> Vec<String> {
    let mut arguments = vec![script.to_string_lossy().into_owned(), cwd.to_owned()];
    if force {
        arguments.push("--force".into());
    }
    arguments
}

/// Starts the script at background priority and leaves it; nothing waits on it but a thread that reaps it.
pub fn run(script: Option<&Path>, cwd: &str, force: bool) {
    let Some(script) = script.filter(|script| script.exists()) else { return };
    if std::env::var_os(DISABLED).is_some() {
        return;
    }
    let mut command = Command::new(PYTHON);
    command.args(arguments(script, cwd, force)).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::process::CommandExt;
        // The Swift `qualityOfService = .background`; setpriority is safe between fork and exec.
        unsafe {
            command.pre_exec(|| {
                libc::setpriority(libc::PRIO_DARWIN_PROCESS, 0, libc::PRIO_DARWIN_BG);
                Ok(())
            });
        }
    }
    if let Ok(mut child) = command.spawn() {
        std::thread::spawn(move || child.wait());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_closing_session_forces_the_cleanup_of_its_folder() {
        let script = Path::new("/app/cleanup.py");

        let after_turn = arguments(script, "/work", false);
        let on_close = arguments(script, "/work", true);

        assert_eq!(after_turn, ["/app/cleanup.py", "/work"]);
        assert_eq!(on_close, ["/app/cleanup.py", "/work", "--force"]);
    }

    #[test]
    fn a_test_worker_looks_for_the_script_in_its_own_runtime_home_only() {
        let home = Path::new("/tmp/worker/runtime");

        let found = script(Some(home));

        assert_eq!(found, Some(home.join(TEST_SCRIPT)));
    }
}
