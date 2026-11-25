//! Chart frames. A ```chart block becomes a sandboxed frame whose document is served from `vcx://chart/<id>` with its
//! own CSP: it runs its script and talks to the transcript page by `postMessage`, it reaches no network and no other
//! page. `vcx.live` reaches the core through the page, and the core fetches the URL from the Mac for it.

use serde_json::Value;
use std::borrow::Cow;
use std::collections::HashMap;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use wry::http::{Response, StatusCode, header};

pub const HOST: &str = "chart";
const ORIGIN: &str = "vcx://chart/";

/// The chart's files in the built-in template, beside the transcript's.
pub const BUILT_IN: [(&str, &[u8]); 6] = [
    ("chart.js", include_bytes!("../../../template/chart.js")),
    ("chart.css", include_bytes!("../../../template/chart.css")),
    ("chart/kit.js", include_bytes!("../../../template/chart/kit.js")),
    ("chart/frame.css", include_bytes!("../../../template/chart/frame.css")),
    ("chart/lightweight-charts.js", include_bytes!("../../../template/chart/lightweight-charts.js")),
    ("chart/LICENSE-lightweight-charts", include_bytes!("../../../template/chart/LICENSE-lightweight-charts")),
];

/// Scripts and styles from the template and the block itself, pictures and fonts inline; no fetch, no socket, no
/// frame, no form, no base. Navigation is the navigation handler's: it lets a frame load only `vcx://chart/`.
pub const POLICY: &str = "default-src 'none'; script-src 'unsafe-inline' vcx://template; style-src 'unsafe-inline' vcx://template; img-src data: blob: vcx://template; font-src data: vcx://template; form-action 'none'; base-uri 'none'";
const HEAD: &str = r#"<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="vcx://template/chart/frame.css"><script src="vcx://template/chart/kit.js"></script></head>"#;

/// The fastest a feed polls, whatever the page asks: Nasdaq and its like refuse a client that asks more often.
const MIN_POLL: Duration = Duration::from_secs(5);
const MAX_POLL: Duration = Duration::from_secs(3600);
/// How often a waiting feed looks whether it was stopped.
const STOP_POLL: Duration = Duration::from_millis(100);
const FETCH_SECONDS: &str = "20";
const MAX_BODY_BYTES: &str = "8388608";
const CURL: &str = "/usr/bin/curl";
/// Nasdaq's API answers a browser, not a bare client.
const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
const ACCEPT: &str = "Accept: application/json, text/plain, */*";

/// A frame's own address: the navigation handler lets these load besides the template.
pub fn is_frame(url: &str) -> bool {
    url.starts_with(ORIGIN)
}

/// The frame document: the kit first, so the block's own script finds `vcx`, then the block as the agent wrote it. A
/// block that is a whole document of its own still parses: the second doctype, `html` and `head` are dropped.
pub fn document(html: &str) -> String {
    format!("{HEAD}{html}")
}

/// Answers `vcx://chart/<id>`: the document of a chart a view registered, nothing else.
pub fn respond(path: &str) -> Response<Cow<'static, [u8]>> {
    let id = path.trim_start_matches('/');
    let page = vcx_model::assets::chart_page(id);
    let (status, body) = match page {
        Some(html) => (StatusCode::OK, document(&html).into_bytes()),
        None => (StatusCode::NOT_FOUND, b"No such chart.".to_vec()),
    };
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "text/html; charset=utf-8")
        .header("Content-Security-Policy", POLICY)
        .header("X-Content-Type-Options", "nosniff")
        .header(header::CACHE_CONTROL, "no-store")
        .body(Cow::Owned(body))
        .expect("a response built from constant headers")
}

#[derive(Debug, PartialEq)]
enum Request {
    Live { frame: u64, id: u64, url: String, every: Duration },
    Stop { frame: u64 },
}

fn parse(body: &str) -> Option<Request> {
    let message: Value = serde_json::from_str(body).ok()?;
    let frame = message.get("frame")?.as_u64()?;
    match message.get("type")?.as_str()? {
        "chartLive" => {
            let url = message.get("url")?.as_str()?;
            let lowered = url.to_ascii_lowercase();
            if !(lowered.starts_with("http://") || lowered.starts_with("https://")) {
                return None;
            }
            let seconds = message.get("seconds").and_then(Value::as_f64).filter(|seconds| seconds.is_finite()).unwrap_or(0.0);
            let every = Duration::from_secs_f64(seconds.clamp(MIN_POLL.as_secs_f64(), MAX_POLL.as_secs_f64()));
            Some(Request::Live { frame, id: message.get("id")?.as_u64()?, url: url.to_owned(), every })
        }
        "chartStop" => Some(Request::Stop { frame }),
        _ => None,
    }
}

/// The script that hands a fetched body to the frame that asked, through the page.
pub fn deliver(frame: u64, id: u64, body: &str) -> String {
    let body = Value::String(body.to_owned());
    format!("window.vcxCharts&&vcxCharts.push({frame},{id},{body})")
}

/// Hands a script to the page, on the thread that owns it.
pub type Deliver = Arc<dyn Fn(String) + Send + Sync>;

/// The page's `vcx.live` feeds, one thread each, stopped by their frame, by the page leaving or by being dropped.
pub struct Feeds {
    deliver: Deliver,
    running: Mutex<HashMap<u64, Vec<Arc<AtomicBool>>>>,
}

impl Feeds {
    pub fn new(deliver: Deliver) -> Self {
        Self { deliver, running: Mutex::new(HashMap::new()) }
    }

    /// Takes a message the page posted. False when it is not a chart's, for the page's other handlers.
    pub fn handle(&self, body: &str) -> bool {
        match parse(body) {
            Some(Request::Live { frame, id, url, every }) => {
                let stop = Arc::new(AtomicBool::new(false));
                self.running.lock().unwrap().entry(frame).or_default().push(stop.clone());
                let deliver = self.deliver.clone();
                let started = thread::Builder::new().name("vcx-chart-feed".into()).spawn(move || poll(&url, every, &stop, |text| deliver(self::deliver(frame, id, text))));
                if let Err(error) = started {
                    eprintln!("vcx: a chart feed could not start: {error}");
                }
                true
            }
            Some(Request::Stop { frame }) => {
                for stop in self.running.lock().unwrap().remove(&frame).unwrap_or_default() {
                    stop.store(true, Ordering::Relaxed);
                }
                true
            }
            None => false,
        }
    }

    /// The page is gone: every feed stops.
    pub fn stop_all(&self) {
        for stop in self.running.lock().unwrap().drain().flat_map(|(_, stops)| stops) {
            stop.store(true, Ordering::Relaxed);
        }
    }

    pub fn count(&self) -> usize {
        self.running.lock().unwrap().values().map(Vec::len).sum()
    }
}

impl Drop for Feeds {
    fn drop(&mut self) {
        self.stop_all();
    }
}

fn poll(url: &str, every: Duration, stop: &AtomicBool, mut got: impl FnMut(&str)) {
    while !stop.load(Ordering::Relaxed) {
        match fetch(url) {
            Ok(text) if !stop.load(Ordering::Relaxed) => got(&text),
            Ok(_) => return,
            Err(problem) => eprintln!("vcx: a chart feed failed: {problem}"),
        }
        let wake = Instant::now() + every;
        while Instant::now() < wake {
            if stop.load(Ordering::Relaxed) {
                return;
            }
            thread::sleep(STOP_POLL);
        }
    }
}

/// Fetches `url` with the system's curl: TLS and redirects come from the Mac, the shell links no HTTP stack.
fn fetch(url: &str) -> Result<String, String> {
    let output = Command::new(CURL)
        .args(["--silent", "--show-error", "--fail", "--location", "--proto", "=http,https", "--proto-redir", "=http,https"])
        .args(["--max-time", FETCH_SECONDS, "--max-filesize", MAX_BODY_BYTES, "--user-agent", USER_AGENT, "--header", ACCEPT, "--url", url])
        .output()
        .map_err(|error| format!("{CURL}: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn serves_a_registered_chart_with_its_own_policy_and_the_kit_first() {
        let id = vcx_model::assets::chart("<script>vcx.chart({kind:'cards'})</script>");

        let response = respond(&format!("/{id}"));

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()["Content-Security-Policy"], POLICY);
        let body = String::from_utf8(response.body().to_vec()).unwrap();
        assert!(body.find("chart/kit.js").unwrap() < body.find("vcx.chart(").unwrap(), "{body}");
    }

    #[test]
    fn serves_nothing_for_a_chart_no_view_registered() {
        let response = respond("/0000000000000000");

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[test]
    fn polls_no_faster_than_the_floor_and_only_the_web() {
        let fast = parse(r#"{"type":"chartLive","frame":1,"id":2,"url":"https://example.com/a","seconds":0.1}"#);
        let file = parse(r#"{"type":"chartLive","frame":1,"id":2,"url":"file:///etc/passwd","seconds":30}"#);
        let other = parse(r#"{"type":"send","text":"hi"}"#);

        assert_eq!(fast, Some(Request::Live { frame: 1, id: 2, url: "https://example.com/a".into(), every: MIN_POLL }));
        assert_eq!(file, None);
        assert_eq!(other, None);
    }

    #[test]
    fn hands_the_body_to_the_page_as_one_string() {
        let script = deliver(3, 4, "{\"a\":\"it's\"}");

        assert_eq!(script, r#"window.vcxCharts&&vcxCharts.push(3,4,"{\"a\":\"it's\"}")"#);
    }

    #[test]
    fn stops_the_feeds_of_a_frame_that_left() {
        let (sender, _) = mpsc::channel::<String>();
        let sender = Mutex::new(sender);
        let feeds = Feeds::new(Arc::new(move |script| drop(sender.lock().unwrap().send(script))));
        feeds.handle(r#"{"type":"chartLive","frame":7,"id":1,"url":"http://127.0.0.1:9/","seconds":60}"#);
        feeds.handle(r#"{"type":"chartLive","frame":8,"id":1,"url":"http://127.0.0.1:9/","seconds":60}"#);

        let heard = feeds.handle(r#"{"type":"chartStop","frame":7}"#);

        assert!(heard);
        assert_eq!(feeds.count(), 1);
    }
}
