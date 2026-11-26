//! The Swift `Connectivity`: one watcher per worker process. A wake, a failed connection, a turn the network killed or
//! an API retry starts a probe every 10 s; once the internet answers, every session hears it, and the sessions that
//! lost their agent reconnect only if the network was really down, so a broken setup is not retried in a loop.

use crate::backend::SessionBackend;
use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::process::Stdio;
use std::rc::{Rc, Weak};
use std::time::{Duration, Instant, SystemTime};

const POLL: Duration = Duration::from_secs(10);
/// How long a turn still waiting on an API retry sent while offline gets once the network is back.
const GRACE: Duration = Duration::from_secs(15);
const PROBE_URL: &str = "https://captive.apple.com/hotspot-detect.html";
const PROBE_TIMEOUT_SECONDS: &str = "5";
const PROBE_ANSWER: &str = "Success";
/// A tick that finds the wall clock this much further ahead than the process's own clock saw the Mac asleep.
const SLEEP_GAP: Duration = Duration::from_secs(30);
pub const WOKE: &str = "the Mac woke";

pub enum Probe {
    /// Apple's captive-portal page, as the Swift app reads it.
    Internet,
    /// A test's network: down while this file exists.
    Flag(PathBuf),
}

pub struct Connectivity {
    probe: Probe,
    /// The waits are multiplied by this: 1, or a test's fraction.
    scale: f64,
    sessions: RefCell<Vec<Weak<SessionBackend>>>,
    probing: Cell<bool>,
    cause: RefCell<String>,
    was_offline: Cell<bool>,
    watching_sleep: Cell<bool>,
}

impl Connectivity {
    pub fn new(probe: Probe, scale: f64) -> Rc<Self> {
        Rc::new(Self { probe, scale, sessions: RefCell::default(), probing: Cell::new(false), cause: RefCell::default(), was_offline: Cell::new(false), watching_sleep: Cell::new(false) })
    }

    pub fn grace(&self) -> Duration {
        GRACE.mul_f64(self.scale)
    }

    pub fn watch(self: &Rc<Self>, session: &Rc<SessionBackend>) {
        let mut sessions = self.sessions.borrow_mut();
        sessions.retain(|watched| watched.strong_count() > 0);
        sessions.push(Rc::downgrade(session));
        drop(sessions);
        if !self.watching_sleep.replace(true) {
            tokio::task::spawn_local(Rc::clone(self).watch_sleep());
        }
    }

    pub async fn online(&self) -> bool {
        match &self.probe {
            Probe::Flag(path) => !path.exists(),
            Probe::Internet => {
                let probe = tokio::process::Command::new("/usr/bin/curl")
                    .args(["-s", "-m", PROBE_TIMEOUT_SECONDS, PROBE_URL])
                    .stdin(Stdio::null())
                    .stderr(Stdio::null())
                    .kill_on_drop(true)
                    .output()
                    .await;
                probe.is_ok_and(|probe| String::from_utf8_lossy(&probe.stdout).contains(PROBE_ANSWER))
            }
        }
    }

    /// Something suggests the network went away (`offline` when it is known to have): the probe starts if it is not
    /// running, and the first cause is the one told, a wake excepted.
    pub fn lost(self: &Rc<Self>, reason: &str, offline: bool) {
        if !self.probing.get() || reason == WOKE {
            *self.cause.borrow_mut() = reason.to_owned();
        }
        self.was_offline.set(self.was_offline.get() || offline);
        if !self.probing.replace(true) {
            tokio::task::spawn_local(Rc::clone(self).probe_until_online());
        }
    }

    async fn probe_until_online(self: Rc<Self>) {
        loop {
            tokio::time::sleep(POLL.mul_f64(self.scale)).await;
            if self.online().await {
                break;
            }
            self.was_offline.set(true);
        }
        let cause = self.cause.take();
        let reconnecting = self.was_offline.replace(false);
        self.probing.set(false);
        let sessions: Vec<Rc<SessionBackend>> = self.sessions.borrow().iter().filter_map(Weak::upgrade).collect();
        for session in sessions {
            session.network_back(&cause, reconnecting);
        }
    }

    /// The Swift app hears `NSWorkspace.didWakeNotification`; a worker sees the wall clock jump past `Instant`, which
    /// does not count the time the Mac sleeps.
    async fn watch_sleep(self: Rc<Self>) {
        let (mut wall, mut ran) = (SystemTime::now(), Instant::now());
        loop {
            tokio::time::sleep(POLL).await;
            let (now_wall, now_ran) = (SystemTime::now(), Instant::now());
            let slept = now_wall.duration_since(wall).unwrap_or_default().saturating_sub(now_ran - ran);
            (wall, ran) = (now_wall, now_ran);
            if slept > SLEEP_GAP {
                self.lost(WOKE, true);
            }
        }
    }
}
