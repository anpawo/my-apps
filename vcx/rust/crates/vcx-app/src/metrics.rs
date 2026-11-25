//! What the app costs, read from the kernel: its threads and memory, and those of the WebKit processes that draw its
//! pages (one web content process per page, outside the app, made responsible to it by macOS).

use serde_json::{Value, json};
use std::time::Duration;

const WEB_CONTENT: &str = "com.apple.WebKit.WebContent";
const NAME_BYTES: usize = 64;
/// Room for processes started between counting and listing.
const SPARE_PIDS: usize = 64;

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Usage {
    pub threads: i64,
    pub resident: u64,
    /// What Activity Monitor calls Memory.
    pub footprint: u64,
}

unsafe extern "C" {
    /// libsystem's answer to "which app is this XPC helper working for", as Activity Monitor groups them.
    fn responsibility_get_pid_responsible_for_pid(pid: libc::pid_t) -> libc::pid_t;
}

pub fn usage(pid: i32) -> Option<Usage> {
    let mut task: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_taskinfo>() as i32;
    // SAFETY: `task` is a writable proc_taskinfo of the size given.
    if unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTASKINFO, 0, (&raw mut task).cast(), size) } != size {
        return None;
    }
    let mut rusage: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
    // SAFETY: `rusage` is a writable rusage_info_v2, the flavor asked for.
    let footprint = if unsafe { libc::proc_pid_rusage(pid, libc::RUSAGE_INFO_V2, (&raw mut rusage).cast()) } == 0 { rusage.ri_phys_footprint } else { 0 };
    Some(Usage { threads: i64::from(task.pti_threadnum), resident: task.pti_resident_size, footprint })
}

/// The web content processes drawing this process's pages.
pub fn web_content(owner: i32) -> Vec<(i32, Usage)> {
    // SAFETY: a null buffer asks for the count only.
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) }.max(0) as usize + SPARE_PIDS;
    let mut pids = vec![0i32; count];
    let bytes = (pids.len() * std::mem::size_of::<i32>()) as i32;
    // SAFETY: `pids` holds `bytes` bytes.
    let listed = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) }.max(0) as usize;
    pids.truncate(listed);
    pids.into_iter()
        .filter(|&pid| pid > 0 && name(pid) == WEB_CONTENT)
        // SAFETY: any pid is a valid argument; an unknown one returns -1.
        .filter(|&pid| unsafe { responsibility_get_pid_responsible_for_pid(pid) } == owner)
        .filter_map(|pid| usage(pid).map(|usage| (pid, usage)))
        .collect()
}

fn name(pid: i32) -> String {
    let mut buffer = [0u8; NAME_BYTES];
    // SAFETY: `buffer` holds NAME_BYTES bytes.
    let length = unsafe { libc::proc_name(pid, buffer.as_mut_ptr().cast(), NAME_BYTES as u32) }.max(0) as usize;
    String::from_utf8_lossy(&buffer[..length]).into_owned()
}

/// p50, p95 and the largest, in milliseconds.
pub fn spread(delays: &[Duration]) -> Value {
    if delays.is_empty() {
        return json!({"count": 0});
    }
    let mut sorted: Vec<f64> = delays.iter().map(|delay| delay.as_secs_f64() * 1000.0).collect();
    sorted.sort_by(f64::total_cmp);
    // Nearest rank: the smallest delay that at least `share` of them do not exceed.
    let at = |share: f64| sorted[((sorted.len() as f64 * share).ceil() as usize).clamp(1, sorted.len()) - 1];
    json!({"count": sorted.len(), "p50": at(0.5), "p95": at(0.95), "max": sorted[sorted.len() - 1]})
}

pub fn report(owner: i32) -> Value {
    let own = usage(owner).unwrap_or_default();
    let pages = web_content(owner);
    let footprint: u64 = pages.iter().map(|(_, usage)| usage.footprint).sum();
    json!({
        "app": {"threads": own.threads, "resident": own.resident, "footprint": own.footprint},
        "webContent": {"processes": pages.len(), "footprint": footprint, "threads": pages.iter().map(|(_, usage)| usage.threads).sum::<i64>()},
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_this_process_threads_and_memory() {
        let usage = usage(std::process::id() as i32).unwrap();

        assert!(usage.threads >= 1 && usage.resident > 0 && usage.footprint > 0, "{usage:?}");
    }

    #[test]
    fn spreads_delays_into_median_tail_and_worst() {
        let delays: Vec<Duration> = (1..=100).map(Duration::from_millis).collect();

        let spread = spread(&delays);

        let near = |key: &str, expected: f64| (spread[key].as_f64().unwrap() - expected).abs() < 1.0;
        assert!(near("p50", 50.0) && near("p95", 95.0) && near("max", 100.0), "{spread}");
        assert_eq!(spread["count"], 100);
    }
}
