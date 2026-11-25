//! Processes named in state files by pid and start time: a forced reboot hands an old pid to another process, so a
//! pid alone does not tell that the app which wrote the file still runs.

/// The process's start, in whole seconds since 1970, if it runs under this account.
pub fn start_time(pid: i32) -> Option<u64> {
    let info = bsd_info(pid)?;
    Some(info.pbi_start_tvsec)
}

/// Whether `pid` runs and, when the file gave one, started at `started_at` (seconds, as the Swift app writes it).
pub fn alive(pid: i32, started_at: Option<u64>) -> bool {
    match (start_time(pid), started_at) {
        (None, _) => false,
        (Some(_), None) => true,
        (Some(start), Some(expected)) => start == expected,
    }
}

fn bsd_info(pid: i32) -> Option<libc::proc_bsdinfo> {
    if pid <= 0 {
        return None;
    }
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    // SAFETY: proc_bsdinfo is plain data; proc_pidinfo writes at most `size` bytes into it.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let written = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) };
    // SAFETY: getuid has no preconditions.
    (written == size && info.pbi_uid == unsafe { libc::getuid() }).then_some(info)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn knows_this_process_by_its_start_and_refuses_another_start() {
        let pid = std::process::id() as i32;
        let start = start_time(pid).unwrap();

        assert!(alive(pid, Some(start)) && alive(pid, None));
        assert!(!alive(pid, Some(start - 1)));
        assert!(!alive(0, None));
    }
}
