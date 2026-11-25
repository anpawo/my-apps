//! Chart frames in a window that is never shown: what they draw is read back from the frames, the network they try is
//! watched from a local server, and the pointer is real `NSEvent`s handed to the web view.
//! Its own `main` on the main thread: AppKit and WebKit live there, and the test harness runs tests elsewhere.

#[allow(dead_code, unused_imports)]
#[path = "../src/bridge.rs"]
mod bridge;
#[allow(dead_code, unused_imports)]
#[path = "../src/chart.rs"]
mod chart;
#[allow(dead_code, unused_imports)]
#[path = "../src/input.rs"]
mod input;
#[allow(dead_code, unused_imports)]
#[path = "../src/template.rs"]
mod template;

use objc2::runtime::{AnyClass, AnyObject, Bool, Imp, Sel};
use objc2::{class, ffi, msg_send, sel};
use objc2_app_kit::{NSEvent, NSEventModifierFlags, NSEventType, NSView};
use objc2_foundation::{MainThreadMarker, NSDate, NSPoint, NSProcessInfo, NSRunLoop, NSString};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::Path;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};
use tao::dpi::LogicalSize;
use tao::event_loop::{EventLoop, EventLoopBuilder};
use tao::window::{Window, WindowBuilder};
use wry::{BackgroundThrottlingPolicy, WebView, WebViewBuilder, WebViewExtMacOS};

const WAIT: Duration = Duration::from_secs(10);
const SPIN: f64 = 0.005;
/// How long a frame is given to try the network before the server's log is read.
const NETWORK_TRIES: Duration = Duration::from_millis(1500);
const MOUSE_STEPS: usize = 6;
const WITHOUT_POLICY: &str = "control=no-policy";
/// lightweight-charts takes a mouse event in the first 500 ms of its page for one a touch made, and drops it.
const TOUCH_GUARD: Duration = Duration::from_millis(600);
/// WebKit sends the web process one move at a time; the last ones arrive after the loop that made them.
const MOVES_SETTLE: Duration = Duration::from_millis(300);
/// How long WebKit is given to tell the page its window became active or inactive.
const ACTIVATION_SETTLE: Duration = Duration::from_millis(200);
const FULL_PRESSURE: f32 = 1.0;
/// The size of a VCX window, so the transcript lays out as it does on screen.
const WINDOW_SIZE: LogicalSize<f64> = LogicalSize { width: 980.0, height: 720.0 };

/// A local server that answers every request and remembers each one: path and user agent.
struct Server {
    port: u16,
    seen: Arc<Mutex<Vec<(String, String)>>>,
}

impl Server {
    fn start() -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                let _ = reader.read_line(&mut line);
                let path = line.split_whitespace().nth(1).unwrap_or_default().to_owned();
                let mut agent = String::new();
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim().is_empty() {
                        break;
                    }
                    if let Some(value) = header.strip_prefix("User-Agent: ").or_else(|| header.strip_prefix("user-agent: ")) {
                        agent = value.trim().to_owned();
                    }
                }
                log.lock().unwrap().push((path.clone(), agent));
                let body = if path == "/data.json" { r#"{"value": 42, "label": "from the test server"}"# } else { "reached" };
                let mut stream = stream;
                let _ = write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            }
        });
        Server { port, seen }
    }

    fn paths(&self) -> Vec<String> {
        self.seen.lock().unwrap().iter().map(|(path, _)| path.clone()).collect()
    }
}

struct Page {
    webview: WebView,
    /// Every message the core heard, with the address of the frame that posted it.
    posts: Arc<Mutex<Vec<(String, Value)>>>,
    feeds: Arc<chart::Feeds>,
    scripts: mpsc::Receiver<String>,
    server: Server,
    serial: std::cell::Cell<u64>,
    _window: Window,
}

fn spin() {
    NSRunLoop::currentRunLoop().runUntilDate(&NSDate::dateWithTimeIntervalSinceNow(SPIN));
}

fn template_folder() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../template")
}

impl Page {
    fn open(event_loop: &EventLoop<()>) -> Page {
        let window = WindowBuilder::new().with_title("VCX charts test").with_inner_size(WINDOW_SIZE).with_visible(false).build(event_loop).unwrap();
        let (store, problem) = template::Store::open(Some(&template_folder()));
        assert!(problem.is_none(), "{problem:?}");
        let posts = Arc::new(Mutex::new(Vec::new()));
        let received = posts.clone();
        let (sender, scripts) = mpsc::channel();
        let sender = Mutex::new(sender);
        let feeds = Arc::new(chart::Feeds::new(Arc::new(move |script| drop(sender.lock().unwrap().send(script)))));
        let to_feeds = feeds.clone();
        let webview = WebViewBuilder::new()
            .with_custom_protocol(template::SCHEME.into(), move |_, request| match request.uri().host() {
                Some(chart::HOST) => {
                    let mut response = chart::respond(request.uri().path());
                    // The control of the network test: the same document without its policy.
                    if request.uri().query() == Some(WITHOUT_POLICY) {
                        response.headers_mut().remove("Content-Security-Policy");
                    }
                    response
                }
                host => store.respond(host, request.uri().path()),
            })
            // As the pane does: only the template talks to the core, and the chart messages go to the feeds.
            .with_ipc_handler(move |request| {
                let uri = request.uri().to_string();
                if bridge::is_template(&uri) {
                    to_feeds.handle(request.body());
                }
                received.lock().unwrap().push((uri, serde_json::from_str(request.body()).unwrap_or(Value::Null)));
            })
            .with_navigation_handler(|url| bridge::is_template(&url) || chart::is_frame(&url))
            .with_background_throttling(BackgroundThrottlingPolicy::Disabled)
            .with_url(template::HOME)
            .build(&window)
            .unwrap();
        Page { webview, posts, feeds, scripts, server: Server::start(), serial: 0.into(), _window: window }
    }

    fn spin(&self) {
        spin();
        while let Ok(script) = self.scripts.try_recv() {
            self.webview.evaluate_script(&script).unwrap();
        }
    }

    fn wait(&self, what: &str, done: impl Fn(&Page) -> bool) -> Result<(), String> {
        let deadline = Instant::now() + WAIT;
        while !done(self) {
            if Instant::now() > deadline {
                return Err(format!("timed out waiting for {what}"));
            }
            self.spin();
        }
        Ok(())
    }

    fn pause(&self, length: Duration) {
        let until = Instant::now() + length;
        while Instant::now() < until {
            self.spin();
        }
    }

    /// Runs `script` in the page and gives back what it evaluates to, as JSON.
    fn eval(&self, script: &str) -> Result<Value, String> {
        let result = Arc::new(Mutex::new(None));
        let slot = result.clone();
        self.webview.evaluate_script_with_callback(&format!("JSON.stringify(({script}))"), move |value| *slot.lock().unwrap() = Some(value)).map_err(|error| error.to_string())?;
        self.wait(script, |_| result.lock().unwrap().is_some())?;
        let text = result.lock().unwrap().take().unwrap();
        if text.is_empty() {
            return Ok(Value::Null);
        }
        let inner: Value = serde_json::from_str(&text).map_err(|error| format!("{script}: {error}: {text}"))?;
        match inner {
            Value::String(json) => serde_json::from_str(&json).map_err(|error| format!("{script}: {error}: {json}")),
            other => Ok(other),
        }
    }

    /// Waits until `script` evaluates to something `accept` takes, and gives it back.
    fn until(&self, what: &str, script: &str, accept: impl Fn(&Value) -> bool) -> Result<Value, String> {
        let deadline = Instant::now() + WAIT;
        loop {
            let value = self.eval(script)?;
            if accept(&value) {
                return Ok(value);
            }
            if Instant::now() > deadline {
                return Err(format!("{what}: the page has {value}"));
            }
            self.spin();
        }
    }

    fn reload(&self) -> Result<(), String> {
        self.feeds.stop_all();
        self.posts.lock().unwrap().clear();
        self.webview.load_url(template::HOME).map_err(|error| error.to_string())?;
        self.wait("the page to report ready", |page| page.posts.lock().unwrap().iter().any(|(_, post)| post["type"] == "ready"))
    }

    /// Shows one answer holding `markdown`, as the session hands it over, and waits for its chart frames to say hello.
    fn answer(&self, markdown: &str, frames: usize) -> Result<(), String> {
        self.serial.set(self.serial.get() + 1);
        let html = vcx_model::markdown::to_html(markdown);
        let row = json!({"id": "R1", "kind": "assistant", "items": [{"id": "a1", "type": "agentMessage", "html": html, "provider": "Claude", "endedTurn": true}]});
        let message = json!({"type": "full", "serial": self.serial.get(), "meta": {"ready": true}, "rows": [row]});
        self.webview.evaluate_script(&bridge::deliver(&message)).map_err(|error| error.to_string())?;
        self.until("the chart frames to say hello", "document.querySelectorAll('.chart iframe[data-heard]').length", |count| count.as_u64() >= Some(frames as u64)).map(drop)
    }

    /// What the frame `frame` (a selector in the page) shows for `selector`: each element's text and box in page pixels.
    fn read(&self, frame: &str, selector: &str) -> Result<Value, String> {
        let start = format!("(window.__read = null, vcxCharts.read(document.querySelector({frame}), {selector}).then(r => window.__read = r, e => window.__read = {{error: String(e)}}), 0)", frame = json!(frame), selector = json!(selector));
        self.eval(&start)?;
        let read = self.until(&format!("the frame to answer for {selector}"), "window.__read", |read| !read.is_null())?;
        if let Some(error) = read.get("error") {
            return Err(format!("reading {selector}: {error}"));
        }
        Ok(read)
    }

    /// Waits until the frame shows `selector` with text that `accept` takes, and gives back what it shows.
    fn read_until(&self, frame: &str, selector: &str, accept: impl Fn(&Value) -> bool) -> Result<Value, String> {
        let deadline = Instant::now() + WAIT;
        loop {
            let read = self.read(frame, selector)?;
            if accept(&read) {
                return Ok(read);
            }
            if Instant::now() > deadline {
                return Err(format!("the frame shows for {selector}: {read}"));
            }
            self.spin();
        }
    }

    fn box_of(&self, selector: &str) -> Result<[f64; 4], String> {
        let read = self.eval(&format!("(r => r && [r.x, r.y, r.width, r.height])(document.querySelector({})?.getBoundingClientRect())", json!(selector)))?;
        boxed(&read).ok_or_else(|| format!("no box for {selector}: {read}"))
    }

    fn mouse(&self, kind: NSEventType, x: f64, y: f64, clicks: isize) -> Result<(), String> {
        let window = self.webview.ns_window();
        let view = self.webview.webview();
        let view: &NSView = &view;
        let in_view = NSPoint::new(x, if view.isFlipped() { y } else { view.bounds().size.height - y });
        let location = view.convertPoint_toView(in_view, None);
        let now = NSProcessInfo::processInfo().systemUptime();
        let event = NSEvent::mouseEventWithType_location_modifierFlags_timestamp_windowNumber_context_eventNumber_clickCount_pressure(kind, location, NSEventModifierFlags::empty(), now, window.windowNumber(), None, 0, clicks, FULL_PRESSURE).ok_or("AppKit made no mouse event.")?;
        match kind {
            NSEventType::MouseMoved => self.track(&event),
            NSEventType::LeftMouseDown => view.mouseDown(&event),
            NSEventType::LeftMouseUp => view.mouseUp(&event),
            NSEventType::RightMouseDown => view.rightMouseDown(&event),
            NSEventType::RightMouseUp => view.rightMouseUp(&event),
            _ => return Err(format!("no mouse event of kind {kind:?} here")),
        }
        Ok(())
    }

    /// Hands a mouse move to whoever AppKit hands it to: the owner of the web view's tracking area that asks for moves
    /// (WebKit's tracking observer). `WKWebView` itself does not take `mouseMoved:`.
    fn track(&self, event: &NSEvent) {
        const TRACKS_MOVES: usize = 0x02;
        let view = self.webview.webview();
        let view: &AnyObject = &view;
        // SAFETY: `trackingAreas` gives an array of `NSTrackingArea`; `options` and `owner` are its own properties, and
        // the owner of an area that tracks moves takes `mouseMoved:` with an event.
        unsafe {
            let areas: *mut AnyObject = msg_send![view, trackingAreas];
            let count: usize = msg_send![areas, count];
            for index in 0..count {
                let area: *mut AnyObject = msg_send![areas, objectAtIndex: index];
                let options: usize = msg_send![area, options];
                if options & TRACKS_MOVES != 0 {
                    let owner: *mut AnyObject = msg_send![area, owner];
                    let _: () = msg_send![owner, mouseMoved: event];
                }
            }
        }
    }

    /// Moves the pointer from `from` to `to` in a few steps, as a hand does, then lets the page take the moves.
    fn move_pointer(&self, from: (f64, f64), to: (f64, f64)) -> Result<(), String> {
        for step in 0..=MOUSE_STEPS {
            let share = step as f64 / MOUSE_STEPS as f64;
            self.mouse(NSEventType::MouseMoved, from.0 + (to.0 - from.0) * share, from.1 + (to.1 - from.1) * share, 0)?;
            self.spin();
        }
        Ok(())
    }

    /// Makes the window that is never shown say it is the key window, and tells WebKit, which then hands the page
    /// mouse moves with no button held: an inactive page gets them on its scroll bars only (`WebPage.cpp`,
    /// `handleMouseMoveOnScrollbarEvent`). The events stay real; the window is still never shown.
    fn set_active(&self, active: bool) {
        static ACTIVE: AtomicBool = AtomicBool::new(false);
        extern "C-unwind" fn is_key(_: *mut AnyObject, _: Sel) -> Bool {
            Bool::new(ACTIVE.load(Ordering::Relaxed))
        }
        ACTIVE.store(active, Ordering::Relaxed);
        let window = self.webview.ns_window();
        let window: &AnyObject = &window;
        // SAFETY: `isKeyWindow` takes no argument and returns a BOOL, as `is_key` does ("c@:"); the class is the
        // window's own, made by tao for this process. The notification is the one AppKit posts with the window.
        unsafe {
            let class = ffi::object_getClass(window) as *mut AnyClass;
            let imp: Imp = std::mem::transmute(is_key as extern "C-unwind" fn(*mut AnyObject, Sel) -> Bool);
            ffi::class_replaceMethod(class, sel!(isKeyWindow), imp, c"c@:".as_ptr());
            let name = NSString::from_str(if active { "NSWindowDidBecomeKeyNotification" } else { "NSWindowDidResignKeyNotification" });
            let center: *mut AnyObject = msg_send![class!(NSNotificationCenter), defaultCenter];
            let _: () = msg_send![center, postNotificationName: &*name, object: window];
        }
        self.pause(ACTIVATION_SETTLE);
    }

    fn double_click(&self, x: f64, y: f64) -> Result<(), String> {
        for clicks in [1, 2] {
            self.mouse(NSEventType::LeftMouseDown, x, y, clicks)?;
            self.mouse(NSEventType::LeftMouseUp, x, y, clicks)?;
        }
        Ok(())
    }

    fn frame_posts(&self) -> Vec<(String, Value)> {
        self.posts.lock().unwrap().iter().filter(|(uri, _)| !bridge::is_template(uri)).cloned().collect()
    }
}

fn boxed(value: &Value) -> Option<[f64; 4]> {
    let items = value.as_array()?;
    Some([items.first()?.as_f64()?, items.get(1)?.as_f64()?, items.get(2)?.as_f64()?, items.get(3)?.as_f64()?])
}

fn items(read: &Value) -> Vec<Value> {
    read["items"].as_array().cloned().unwrap_or_default()
}

fn texts(read: &Value) -> Vec<String> {
    items(read).iter().map(|item| item["text"].as_str().unwrap_or_default().trim().to_owned()).collect()
}

fn first_box(read: &Value) -> Option<[f64; 4]> {
    items(read).first().and_then(|item| boxed(&item["box"]))
}

fn check(condition: bool, what: impl Into<String>) -> Result<(), String> {
    if condition { Ok(()) } else { Err(what.into()) }
}

fn inside(inner: [f64; 4], outer: [f64; 4]) -> bool {
    const SLACK: f64 = 1.0;
    inner[0] >= outer[0] - SLACK && inner[1] >= outer[1] - SLACK && inner[0] + inner[2] <= outer[0] + outer[2] + SLACK && inner[1] + inner[3] <= outer[1] + outer[3] + SLACK
}

const FRAME: &str = ".prose .chart iframe";
const SERIES: &str = "```chart\n<script>\nconst start = Date.UTC(2026, 0, 5) / 1000;\nvcx.chart({ title: 'Test series', name: 'Close', data: Array.from({ length: 30 }, (_, i) => ({ time: start + i * 86400, value: 100 + i })) })\n  .then(c => { document.body.dataset.x = c.chart.timeScale().timeToCoordinate(start + 12 * 86400); });\n</script>\n```\n";

fn draws_a_time_series(page: &Page) -> Result<(), String> {
    page.answer(SERIES, 1)?;

    let value = page.read_until(FRAME, ".vcx-value", |read| !texts(read).concat().is_empty())?;
    let title = page.read(FRAME, ".vcx-title")?;
    let plot = page.read(FRAME, ".vcx-plot")?;
    let canvases = page.read(FRAME, ".vcx-plot canvas")?;
    let frame = page.box_of(FRAME)?;

    check(texts(&title) == ["Test series"], format!("the title: {title}"))?;
    check(texts(&value) == ["129.00"], format!("the last value heads the chart: {value}"))?;
    let plot = first_box(&plot).ok_or("no plot")?;
    check(plot[2] > 100.0 && plot[3] > 200.0 && inside(plot, frame), format!("the plot is laid out inside its frame {frame:?}: {plot:?}"))?;
    check(!items(&canvases).is_empty(), "the library drew its canvases")
}

fn draws_a_table(page: &Page) -> Result<(), String> {
    page.answer("```chart\n<script>vcx.chart({ kind: 'table', title: 'Trades', columns: ['Ticker', 'Qty'], data: [{ Ticker: 'NVDA', Qty: 12 }, { Ticker: 'AAPL', Qty: 3.5, tone: 'green' }] })</script>\n```\n", 1)?;

    let heads = page.read_until(FRAME, ".vcx-table th", |read| !items(read).is_empty())?;
    let cells = page.read(FRAME, ".vcx-table td")?;
    let rows = page.read(FRAME, ".vcx-table tbody tr")?;
    let table = page.read(FRAME, ".vcx-table")?;

    check(texts(&heads) == ["Ticker", "Qty"], format!("the header row: {heads}"))?;
    check(texts(&cells) == ["NVDA", "12.0", "AAPL", "3.5"], format!("the cells, numbers with one decimal: {cells}"))?;
    check(items(&rows)[1]["className"] == "t-green", format!("a row keeps its tone: {rows}"))?;
    let table = first_box(&table).ok_or("no table")?;
    check(table[2] > 100.0 && table[3] > 40.0 && inside(table, page.box_of(FRAME)?), format!("the table is laid out inside its frame: {table:?}"))
}

fn draws_cards(page: &Page) -> Result<(), String> {
    page.answer("```chart\n<script>vcx.chart({ kind: 'cards', title: 'Today', data: [{ label: 'Open', value: 3, unit: 'trades' }, { label: 'Breaks', value: 0, tone: 'red', note: 'none left' }] })</script>\n```\n", 1)?;

    let labels = page.read_until(FRAME, ".vcx-tile dt", |read| items(read).len() == 2)?;
    let figures = page.read(FRAME, ".vcx-tile .v")?;
    let tiles = page.read(FRAME, ".vcx-tile")?;

    check(texts(&labels) == ["Open", "Breaks"], format!("the labels: {labels}"))?;
    check(texts(&figures) == ["3", "0"], format!("the figures: {figures}"))?;
    let tiles = items(&tiles);
    check(tiles[1]["className"].as_str().unwrap_or_default().contains("t-red"), "a card keeps its tone")?;
    let (first, second) = (boxed(&tiles[0]["box"]).ok_or("no tile")?, boxed(&tiles[1]["box"]).ok_or("no tile")?);
    check(first[2] >= 96.0 && second[0] >= first[0] + first[2], format!("the cards sit side by side: {first:?} {second:?}"))
}

/// A chart that tries every way out it has and marks on its body what each one did.
fn escaping_chart(base: &str, port: u16) -> String {
    format!(
        "```chart\n<p>trying</p>\n<script>\nconst base = '{base}', mark = (k, v) => document.body.dataset[k] = v;\nfetch(base + '/fetch').then(() => mark('fetch', 'reached'), () => mark('fetch', 'refused'));\nconst image = new Image(); image.onload = () => mark('image', 'reached'); image.onerror = () => mark('image', 'refused'); image.src = base + '/image';\ntry {{ const socket = new WebSocket('ws://127.0.0.1:{port}/socket'); socket.onerror = () => mark('socket', 'refused'); socket.onopen = () => mark('socket', 'reached'); }} catch (e) {{ mark('socket', 'refused'); }}\ntry {{ mark('parent', parent.document.title ? 'reached' : 'reached'); }} catch (e) {{ mark('parent', 'refused'); }}\ntry {{ webkit.messageHandlers.ipc.postMessage(JSON.stringify({{ type: 'send', text: 'from a frame' }})); mark('ipc', 'posted'); }} catch (e) {{ mark('ipc', 'absent'); }}\nsetTimeout(() => {{ location.href = base + '/navigate'; }}, 200);\n</script>\n```\n"
    )
}

const WAYS_OUT: [&str; 4] = ["fetch", "image", "socket", "parent"];

fn refuses_a_frame_the_network(page: &Page) -> Result<(), String> {
    let base = format!("http://127.0.0.1:{}", page.server.port);
    page.answer(&escaping_chart(&base, page.server.port), 1)?;

    page.pause(NETWORK_TRIES);
    let read = page.read_until(FRAME, "p", |read| WAYS_OUT.iter().all(|key| read["data"][key].is_string()))?;

    let data = &read["data"];
    check(page.server.paths().is_empty(), format!("the local server was reached: {:?}", page.server.paths()))?;
    for key in WAYS_OUT {
        check(data[key] == "refused", format!("{key}: {data}"))?;
    }
    check(texts(&read) == ["trying"], "the frame is still its own page after trying to navigate away")?;
    let heard = page.frame_posts();
    check(heard.iter().all(|(uri, _)| chart::is_frame(uri)), format!("a frame's own post to the core comes from its own address, which the core refuses: {heard:?}"))?;
    check(!page.posts.lock().unwrap().iter().any(|(uri, post)| bridge::is_template(uri) && post["type"] == "send"), "nothing was sent in the template's name")
}

/// The other side of the network test: the same frame served without its policy reaches the server, so the refusal
/// above is the policy's, not the custom scheme's or the sandbox's.
fn lets_a_frame_without_the_policy_reach_the_network(page: &Page) -> Result<(), String> {
    let base = format!("http://127.0.0.1:{}", page.server.port);
    let markdown = escaping_chart(&base, page.server.port);
    let id = vcx_model::assets::chart(markdown.trim_start_matches("```chart\n").trim_end_matches("```\n"));
    page.eval(&format!("(() => {{ const block = document.createElement('div'); block.className = 'chart'; block.dataset.chart = '{id}'; const frame = document.createElement('iframe'); frame.setAttribute('sandbox', 'allow-scripts'); frame.src = 'vcx://chart/{id}?{WITHOUT_POLICY}'; block.append(frame); document.getElementById('rows').append(block); return 0 }})()"))?;
    page.until("the control frame to say hello", "document.querySelectorAll('.chart iframe[data-heard]').length", |count| count == 1)?;

    page.pause(NETWORK_TRIES);

    let paths = page.server.paths();
    eprintln!("control: the server saw {paths:?}");
    check(paths.iter().any(|path| path == "/fetch") && paths.iter().any(|path| path == "/image"), format!("without the policy the frame fetches and loads pictures: {paths:?}"))?;
    check(!paths.iter().any(|path| path == "/navigate"), "the navigation handler still keeps the frame home")
}

fn hears_a_frame_that_posts_to_its_parent(page: &Page) -> Result<(), String> {
    page.answer("```chart\n<div style=\"height: 333px\">tall</div>\n```\n", 1)?;

    let height = page.until("the frame's height to reach the page", &format!("document.querySelector({}).style.height", json!(FRAME)), |height| height == "333px")?;

    check(height == "333px", "the page took the height the frame posted")?;
    let frame = page.box_of(FRAME)?;
    check((frame[3] - 333.0).abs() < 1.0, format!("the frame is drawn at that height: {frame:?}"))
}

fn delivers_live_data_from_a_local_server(page: &Page) -> Result<(), String> {
    let url = format!("http://127.0.0.1:{}/data.json", page.server.port);
    page.answer(&format!("```chart\n<p id=\"out\">waiting</p>\n<script>vcx.live('{url}', 60, d => out.textContent = d.label + ' ' + d.value)</script>\n```\n"), 1)?;

    let read = page.read_until(FRAME, "#out", |read| texts(read) != ["waiting"])?;

    check(texts(&read) == ["from the test server 42"], format!("the frame got the data: {read}"))?;
    let seen = page.server.seen.lock().unwrap().clone();
    check(seen.len() == 1 && seen[0].0 == "/data.json", format!("the core fetched it once: {seen:?}"))?;
    check(seen[0].1.starts_with("Mozilla/5.0"), format!("as a browser would: {}", seen[0].1))?;
    check(page.feeds.count() == 1, "one feed runs for the frame")?;
    page.reload()?;
    check(page.feeds.count() == 0, "the feed stops with the page")
}

fn shows_the_value_under_the_pointer(page: &Page) -> Result<(), String> {
    page.answer(SERIES, 1)?;
    let read = page.read_until(FRAME, ".vcx-plot", |read| read["data"]["x"].is_string())?;
    let plot = first_box(&read).ok_or("no plot")?;
    let x: f64 = read["data"]["x"].as_str().unwrap().parse().map_err(|_| "no coordinate for the hovered day")?;
    let target = (plot[0] + x, plot[1] + plot[3] / 2.0);

    page.pause(TOUCH_GUARD);
    page.set_active(true);
    let moved = page.move_pointer((plot[0] + 2.0, target.1), target);
    page.pause(MOVES_SETTLE);
    page.set_active(false);
    moved?;

    let legend = page.read_until(FRAME, ".vcx-plot .legend", |read| texts(read).concat().contains("112"))?;
    let shown = page.read(FRAME, ".vcx-plot")?;
    check(texts(&legend) == ["Close 112.00"], format!("the legend shows the hovered day's value: {legend}"))?;
    check(items(&shown)[0]["className"].as_str().unwrap_or_default().contains("hover"), "the legend is shown")
}

fn pins_a_chart_above_the_chat(page: &Page) -> Result<(), String> {
    page.answer("```chart pin\n<script>vcx.chart({ kind: 'cards', title: 'Pinned', data: [{ label: 'Open', value: 7 }] })</script>\n```\n", 2)?;

    let pinned = page.read_until("#chart-pin iframe", ".vcx-title", |read| texts(read) == ["Pinned"])?;
    let strip = page.box_of("#chart-pin")?;
    let transcript = page.box_of("#transcript")?;
    let frame = page.box_of("#chart-pin iframe")?;

    check(texts(&pinned) == ["Pinned"], "the pinned frame draws its chart")?;
    let rows = page.box_of("#rows")?;
    check((strip[1] - transcript[1]).abs() <= 1.0 && strip[1] + strip[3] <= rows[1] + 1.0 && frame[3] > 40.0 && inside(frame, strip), format!("the pinned chart sits above the chat: strip {strip:?}, frame {frame:?}, transcript {transcript:?}, rows {rows:?}"))?;
    page.eval("(() => { const transcript = document.getElementById('transcript'); document.getElementById('rows').style.minHeight = '3000px'; transcript.scrollTop = transcript.scrollHeight; return 0 })()")?;
    let scrolled = page.box_of("#chart-pin")?;
    check((scrolled[1] - transcript[1]).abs() <= 1.0, format!("the pinned chart stays at the top once the chat scrolls: {scrolled:?}"))?;
    page.eval("(() => { document.getElementById('rows').style.minHeight = ''; return 0 })()")?;
    let button = page.box_of(".prose .chart .chart-button.pin")?;
    input::click(&page.webview, button[0] + button[2] / 2.0, button[1] + button[3] / 2.0)?;
    page.until("the pin to come off", "document.getElementById('chart-pin').hidden", |hidden| hidden == true).map(drop)
}

fn enlarges_a_chart_on_a_double_click(page: &Page) -> Result<(), String> {
    page.answer("```chart\n<script>vcx.chart({ kind: 'cards', title: 'Big', data: [{ label: 'Open', value: 7 }] })</script>\n```\n", 1)?;
    let frame = page.box_of(FRAME)?;
    page.read_until(FRAME, ".vcx-title", |read| texts(read) == ["Big"])?;

    page.double_click(frame[0] + frame[2] - 20.0, frame[1] + frame[3] - 10.0)?;

    page.until("the enlarged chart", "document.querySelectorAll('#chart-zoom .chart iframe[data-heard]').length", |count| count == 1)?;
    let enlarged = page.box_of("#chart-zoom .chart")?;
    check(enlarged[2] > frame[2], format!("the enlarged chart is wider than the inline one: {enlarged:?} {frame:?}"))?;
    page.read_until("#chart-zoom iframe", ".vcx-title", |read| texts(read) == ["Big"])?;
    let close = page.box_of("#chart-zoom .chart-button.close")?;
    input::click(&page.webview, close[0] + close[2] / 2.0, close[1] + close[3] / 2.0)?;
    page.until("the enlarged chart to zoom out and go", "!document.querySelector('.chart-zoom')", |gone| gone == true).map(drop)
}

type Test = fn(&Page) -> Result<(), String>;

const TESTS: [(&str, Test); 10] = [
    ("draws a time series", draws_a_time_series),
    ("draws a table", draws_a_table),
    ("draws cards", draws_cards),
    ("refuses a frame the network", refuses_a_frame_the_network),
    ("lets a frame without the policy reach the network", lets_a_frame_without_the_policy_reach_the_network),
    ("hears a frame that posts to its parent", hears_a_frame_that_posts_to_its_parent),
    ("delivers live data from a local server", delivers_live_data_from_a_local_server),
    ("shows the value under the pointer", shows_the_value_under_the_pointer),
    ("pins a chart above the chat", pins_a_chart_above_the_chat),
    ("enlarges a chart on a double click", enlarges_a_chart_on_a_double_click),
];

fn main() -> ExitCode {
    MainThreadMarker::new().expect("the charts test runs on the main thread");
    let event_loop = EventLoopBuilder::new().build();
    let page = Page::open(&event_loop);
    let filter: Vec<String> = std::env::args().skip(1).filter(|argument| !argument.starts_with('-')).collect();
    let mut failed = 0;
    for (name, test) in TESTS {
        if !filter.is_empty() && !filter.iter().any(|wanted| name.contains(wanted.as_str())) {
            continue;
        }
        page.server.seen.lock().unwrap().clear();
        let outcome = page.reload().and_then(|()| test(&page));
        match outcome {
            Ok(()) => println!("test {name} ... ok"),
            Err(problem) => {
                failed += 1;
                println!("test {name} ... FAILED: {problem}");
            }
        }
    }
    if failed == 0 { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
