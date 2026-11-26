//! Freeze diagnostics, as the Swift app's `FreezeTrace`: the main thread beats ten times a second; when it spins
//! without beating for 3 s a background thread samples the process into `<state>/freezes`, again every minute while it
//! stays stuck, and every stall over half a second while the app is in front gets a line in `<state>/hitches.log`.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime};

pub const BEAT: Duration = Duration::from_millis(100);
const STALL: Duration = Duration::from_secs(3);
const RESAMPLE: Duration = Duration::from_secs(60);
const HITCH: Duration = Duration::from_millis(500);
const CHECK: Duration = Duration::from_secs(1);
/// What `sample` is given: two seconds of the stuck process.
const SAMPLE_SECONDS: &str = "2";
const HITCH_LOG_LIMIT: u64 = 1_000_000;
const TOP_PROCESSES: usize = 3;
const BYTES_PER_GB: f64 = 1e9;

struct Beat {
    // `Instant` stops while the Mac sleeps, as Swift's uptime does: a night's sleep is no freeze.
    at: Instant,
    cpu: Duration,
    active: bool,
}

static LAST: Mutex<Option<Beat>> = Mutex::new(None);
static MAIN: Mutex<Option<libc::mach_port_t>> = Mutex::new(None);

/// Starts the watchdog; call on the main thread, then `beat` from it every `BEAT`.
pub fn start(state: &Path) {
    #[allow(deprecated)]
    // SAFETY: the calling thread's own port, kept for the life of the process as the main thread lives that long.
    let main = unsafe { libc::mach_thread_self() };
    *MAIN.lock().unwrap() = Some(main);
    *LAST.lock().unwrap() = Some(Beat { at: Instant::now(), cpu: cpu_time(main), active: false });
    let (freezes, hitches) = (state.join("freezes"), state.join("hitches.log"));
    *HITCHES.lock().unwrap() = Some(hitches);
    thread::Builder::new().name("vcx-freeze".into()).spawn(move || watch(main, &freezes)).expect("a thread for the freeze watchdog");
}

static HITCHES: Mutex<Option<PathBuf>> = Mutex::new(None);

/// The main thread's beat; `active` when the app is in front, where a stall is felt.
pub fn beat(active: bool) {
    let Some(main) = *MAIN.lock().unwrap() else { return };
    let (now, cpu) = (Instant::now(), cpu_time(main));
    let previous = LAST.lock().unwrap().replace(Beat { at: now, cpu, active });
    let Some(previous) = previous else { return };
    let gap = now - previous.at;
    // App Nap delays a background app's timers by seconds: only a stall seen active on both of its beats counts.
    if previous.active && active && gap > HITCH {
        let used = cpu.saturating_sub(previous.cpu);
        thread::spawn(move || log_hitch(gap, used));
    }
}

fn watch(main: libc::mach_port_t, folder: &Path) {
    let mut fresh: Option<(Instant, Instant, Duration)> = None;
    let mut stuck: Option<(String, u32, Instant)> = None;
    loop {
        thread::sleep(CHECK);
        let Some(beat) = LAST.lock().unwrap().as_ref().map(|beat| beat.at) else { continue };
        let (now, cpu) = (Instant::now(), cpu_time(main));
        if fresh.is_none_or(|(seen, ..)| seen != beat) {
            fresh = Some((beat, now, cpu));
            stuck = None;
            continue;
        }
        if now - beat <= STALL {
            continue;
        }
        if let Some((stamp, samples, last)) = &mut stuck {
            if now - *last >= RESAMPLE {
                *samples += 1;
                *last = now;
                sample(&folder.join(format!("{stamp}.sample-{samples}.txt")));
            }
            continue;
        }
        let (_, seen_at, seen_cpu) = fresh.expect("set above");
        // CPU from the first check that saw the last beat, so a beat seen late does not count as idle time.
        let (stalled, used) = (now - seen_at, cpu.saturating_sub(seen_cpu));
        if !spinning(stalled, used) {
            continue;
        }
        let stamp = stamp();
        stuck = Some((stamp.clone(), 1, now));
        if vcx_config::private_folder(folder).is_err() {
            continue;
        }
        let report = format!("The main thread did not beat for {:.1} s, {:.1} s of it on the CPU; footprint {:.1} GB.\n", (now - beat).as_secs_f64(), used.as_secs_f64(), footprint());
        let _ = vcx_config::write_private(&folder.join(format!("{stamp}.txt")), report.as_bytes());
        sample(&folder.join(format!("{stamp}.sample.txt")));
    }
}

/// A stall is a freeze only if the main thread spent most of it on the CPU: blocked or idle, it is something else.
pub fn spinning(stalled: Duration, cpu: Duration) -> bool {
    cpu > stalled / 2
}

fn sample(file: &Path) {
    let _ = Command::new("/usr/bin/sample").arg(std::process::id().to_string()).arg(SAMPLE_SECONDS).arg("-file").arg(file).stdout(Stdio::null()).stderr(Stdio::null()).status();
}

fn cpu_time(thread: libc::mach_port_t) -> Duration {
    // SAFETY: an all-zero thread_basic_info is valid, and thread_info writes at most `count` integers into it.
    let mut info: libc::thread_basic_info = unsafe { std::mem::zeroed() };
    let mut count = libc::THREAD_BASIC_INFO_COUNT;
    let result = unsafe { libc::thread_info(thread, libc::THREAD_BASIC_INFO as libc::thread_flavor_t, (&raw mut info).cast(), &mut count) };
    if result != libc::KERN_SUCCESS {
        return Duration::ZERO;
    }
    let seconds = (info.user_time.seconds + info.system_time.seconds) as u64;
    let micros = (info.user_time.microseconds + info.system_time.microseconds) as u64;
    Duration::from_secs(seconds) + Duration::from_micros(micros)
}

fn footprint() -> f64 {
    // SAFETY: an all-zero rusage_info_v2 is valid, and proc_pid_rusage fills the version-2 record it is given.
    let mut info: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
    let result = unsafe { libc::proc_pid_rusage(std::process::id() as i32, libc::RUSAGE_INFO_V2, (&raw mut info).cast()) };
    if result == 0 { info.ri_phys_footprint as f64 / BYTES_PER_GB } else { 0.0 }
}

/// The local time to the second, with dashes for colons so it names a file (Swift's ISO 8601 stamp).
fn stamp() -> String {
    let seconds = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|elapsed| elapsed.as_secs() as libc::time_t).unwrap_or_default();
    // SAFETY: localtime_r fills the zeroed tm it is given from a valid time.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&seconds, &mut tm) };
    format!("{:04}-{:02}-{:02}T{:02}-{:02}-{:02}", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec)
}

pub fn hitch_line(time: &str, stalled: Duration, cpu: Duration, footprint: f64, load: f64, top: &[String]) -> String {
    let who = if spinning(stalled, cpu) { "VCX busy" } else { "VCX waiting" };
    format!("{time}\t{:.1} s\t{who} ({:.1} s CPU)\tfootprint {footprint:.1} GB\tload {load:.1}\ttop: {}\n", stalled.as_secs_f64(), cpu.as_secs_f64(), top.join(", "))
}

fn log_hitch(stalled: Duration, cpu: Duration) {
    let Some(path) = HITCHES.lock().unwrap().clone() else { return };
    let mut load = [0.0; 3];
    // SAFETY: getloadavg writes at most the three numbers it is given room for.
    unsafe { libc::getloadavg(load.as_mut_ptr(), 3) };
    let listed = Command::new("/bin/ps").args(["-Arco", "pcpu=,comm="]).stderr(Stdio::null()).output().map(|output| String::from_utf8_lossy(&output.stdout).into_owned()).unwrap_or_default();
    let top: Vec<String> = listed.lines().take(TOP_PROCESSES).filter_map(|line| line.trim().split_once(' ')).map(|(cpu, name)| format!("{} {}%", name.trim(), cpu.parse::<f64>().unwrap_or_default() as i64)).collect();
    let line = hitch_line(&stamp(), stalled, cpu, footprint(), load[0], &top);
    if fs::metadata(&path).is_ok_and(|metadata| metadata.len() > HITCH_LOG_LIMIT) {
        let _ = fs::rename(&path, path.with_extension("log.1"));
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = file.write_all(line.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_a_stall_as_a_freeze_only_when_the_main_thread_spent_most_of_it_on_the_cpu() {
        let stalled = Duration::from_secs(4);

        let verdicts = [Duration::from_secs(3), Duration::from_secs(1)].map(|cpu| spinning(stalled, cpu));

        assert_eq!(verdicts, [true, false]);
    }

    #[test]
    fn writes_a_hitch_line_with_who_held_the_cpu() {
        let top = ["WebContent 80%".to_owned(), "cargo 40%".to_owned()];

        let line = hitch_line("2026-11-26T20-00-00", Duration::from_millis(1400), Duration::from_millis(1200), 1.25, 3.5, &top);

        assert_eq!(line, "2026-11-26T20-00-00\t1.4 s\tVCX busy (1.2 s CPU)\tfootprint 1.2 GB\tload 3.5\ttop: WebContent 80%, cargo 40%\n");
    }
}
