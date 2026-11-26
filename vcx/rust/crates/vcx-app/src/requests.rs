//! What the control socket asks of the running app: open a window, pass a message from another window's agent, move a
//! session to another folder, place a window, report, quit, take over the Swift app's windows at the switch, and in a windowless check run a
//! page script.

use crate::app::{App, AppEvent, Open, Queued};
use crate::control::Request;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tao::dpi::{LogicalPosition, LogicalSize};
use tao::event_loop::EventLoopWindowTarget;
use vcx_shell::session::Message;

/// A message for a window that never becomes idle, or never opens, is dropped after an hour (as `vcx --send`).
const QUEUE_LIFE: Duration = Duration::from_secs(3600);
/// An id prefix this long names a window, as `vcx --send` takes them.
const ID_PREFIX_CHARS: usize = 4;
const PROVIDERS: [&str; 4] = ["claude", "codex", "qwen", "agy"];
const CHOICES: [&str; 5] = ["auto", "claude", "codex", "qwen", "agy"];

pub(crate) fn handle(app: &mut App, target: &EventLoopWindowTarget<AppEvent>, request: Request) -> Option<i32> {
    let body = &request.body;
    let answer = if let Some(open) = body.get("open") {
        self::open(app, target, open)
    } else if let Some(send) = body.get("send") {
        self::send(app, send)
    } else if let Some(change) = body.get("setDir") {
        set_dir(app, change)
    } else if let Some(change) = body.get("setModel") {
        set_model(app, change)
    } else if let Some(close) = body.get("close") {
        self::close(app, close)
    } else if let Some(place) = body.get("frame") {
        frame(app, place)
    } else if let Some(take) = body.get("takeOver") {
        take_over(app, target, take)
    } else if let Some(evaluate) = body.get("evaluate") {
        match page(app, evaluate) {
            Ok(key) => {
                let answer = request.answer;
                app.windows[&key].pane.read(evaluate["script"].as_str().unwrap_or_default(), move |result| drop(answer.send(json!({"result": result}))));
                return None;
            }
            Err(problem) => Err(problem),
        }
    } else if body.get("report").is_some() {
        app.begin_report(request.answer);
        return None;
    } else if body.get("quit").is_some() {
        let code = app.quit();
        let _ = request.answer.send(json!({"quit": true}));
        return Some(code);
    } else {
        Err(format!("Unknown request {body}."))
    };
    let _ = request.answer.send(answer.unwrap_or_else(|problem| json!({"error": problem})));
    None
}

fn open(app: &mut App, target: &EventLoopWindowTarget<AppEvent>, open: &Value) -> Result<Value, String> {
    let cwd = open["cwd"].as_str().ok_or("An open request needs a cwd.")?;
    if !Path::new(cwd).is_dir() {
        return Err(format!("{cwd} is not a folder."));
    }
    let request = Open { cwd: cwd.to_owned(), prompt: open["prompt"].as_str().unwrap_or_default().to_owned(), resume: open["resume"].as_str().map(str::to_owned), focus: open["focus"].as_bool().unwrap_or(false) };
    Ok(json!({"sessionId": app.new_session(target, request)}))
}

/// The window `key` names: an id, an id prefix, or a name, matching one window only.
/// At the switch from the Swift app: its windows whose frontend is gone reopen here (`from`: its recovery folder).
fn take_over(app: &mut App, target: &EventLoopWindowTarget<AppEvent>, take: &Value) -> Result<Value, String> {
    let home = std::env::var_os("HOME").map_or_else(|| "/".into(), PathBuf::from);
    let folder = take["from"].as_str().map_or_else(|| crate::takeover::default_folder(&home), PathBuf::from);
    let mut taken = Vec::new();
    for entry in crate::takeover::pending(&folder)? {
        let cwd = entry.cwd.clone();
        if let Some(session_id) = app.adopt(target, entry) {
            taken.push(json!({"sessionId": session_id, "cwd": cwd}));
        }
    }
    app.return_to_desktops();
    Ok(json!({"taken": taken}))
}

/// Only a windowless app, a check's, runs a script it is handed: a page he works in takes none from outside.
fn page(app: &App, evaluate: &Value) -> Result<u64, String> {
    if !app.windowless {
        return Err("Only a windowless VCX Rust runs a page script.".into());
    }
    if !evaluate["script"].is_string() {
        return Err("evaluate takes a script.".into());
    }
    find(app, evaluate["to"].as_str().unwrap_or_default())
}

fn find(app: &App, key: &str) -> Result<u64, String> {
    let key = key.to_lowercase();
    let by_id: Vec<u64> = app.windows.iter().filter(|(_, win)| {
        let id = win.session_id.to_lowercase();
        id == key || (key.len() >= ID_PREFIX_CHARS && id.starts_with(&key))
    }).map(|(&window, _)| window).collect();
    if let [window] = by_id[..] {
        return Ok(window);
    }
    let by_name: Vec<u64> = app.windows.iter().filter(|(_, win)| name(win).to_lowercase() == key).map(|(&window, _)| window).collect();
    match by_name[..] {
        [window] => Ok(window),
        _ => Err(format!("No single open window matches {key}.")),
    }
}

/// The window a request names, `self` being the caller's own, found by the agent thread it runs in.
fn addressed(app: &App, key: &Value, request: &Value) -> Result<u64, String> {
    match key.as_str().unwrap_or_default() {
        "self" => caller(app, request).ok_or_else(|| "The caller runs in no VCX Rust window.".into()),
        key => find(app, key),
    }
}

fn caller(app: &App, request: &Value) -> Option<u64> {
    let threads: Vec<&str> = request["threads"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    app.windows.iter().find(|(_, win)| win.summary.as_ref().and_then(|summary| summary.thread_id.as_deref()).is_some_and(|thread| threads.contains(&thread))).map(|(&key, _)| key)
}

fn name(win: &crate::app::Win) -> String {
    let summary = win.summary.as_ref();
    vcx_cli::fleet::name(summary.and_then(|summary| summary.context.as_deref()), summary.and_then(|summary| summary.prompt.as_deref()))
}

fn provider(win: &crate::app::Win) -> &'static str {
    let thread = win.summary.as_ref().and_then(|summary| summary.thread_id.as_deref()).unwrap_or_default();
    PROVIDERS.iter().copied().find(|provider| thread.starts_with(&format!("{provider}:"))).unwrap_or("codex")
}

/// Queues a message in the shape the Swift app gives it, `<provider> from [<window name>]: "<text>"`, so the agent
/// that reads it does not take it for him; it goes once that window is idle.
fn send(app: &mut App, send: &Value) -> Result<Value, String> {
    let text = send["text"].as_str().map(str::trim).filter(|text| !text.is_empty()).ok_or("Empty message.")?;
    let target = addressed(app, &send["to"], send)?;
    let sender = match send["from"].as_str() {
        Some(_) => addressed(app, &send["from"], send).ok(),
        None => caller(app, send),
    };
    let (provider, from) = sender.and_then(|key| app.windows.get(&key)).map_or(("agent", "unknown".to_owned()), |win| (provider(win), name(win)));
    let win = &app.windows[&target];
    let (id, to) = (win.session_id.clone(), name(win));
    app.queue.push(Queued { session_id: id.clone(), text: format!("{provider} from [{from}]: \"{text}\""), at: Instant::now() });
    deliver_queue(app);
    let sent = !app.queue.iter().any(|queued| queued.session_id == id);
    Ok(json!({"sessionId": id, "name": to, "sent": sent}))
}

/// Sends each queued message whose window is idle; drops those past their life.
pub(crate) fn deliver_queue(app: &mut App) {
    let now = Instant::now();
    let windows = &app.windows;
    app.queue.retain(|queued| {
        if now.duration_since(queued.at) > QUEUE_LIFE {
            return false;
        }
        let Some(win) = windows.values().find(|win| win.session_id == queued.session_id) else { return true };
        if !win.summary.as_ref().is_some_and(|summary| summary.idle) {
            return true;
        }
        win.pane.tell(Message::Act { action: "send", params: json!({"text": queued.text, "images": []}) });
        false
    });
}

fn set_dir(app: &mut App, change: &Value) -> Result<Value, String> {
    let path = change["path"].as_str().ok_or("A folder change needs a path.")?;
    if !Path::new(path).is_dir() {
        return Err(format!("{path} is not a folder."));
    }
    let key = addressed(app, &change["to"], change)?;
    let win = &app.windows[&key];
    win.pane.tell(Message::Act { action: "moveDirectory", params: json!({"path": path}) });
    Ok(json!({"sessionId": win.session_id, "name": name(win), "requested": path}))
}

/// Asks for `/model <provider> [model] [effort]`, as the Swift app does: the worker checks the catalog, and a busy
/// session keeps it for the end of its turn.
fn set_model(app: &mut App, change: &Value) -> Result<Value, String> {
    let key = addressed(app, &change["to"], change)?;
    let win = &app.windows[&key];
    let provider = change["provider"].as_str().unwrap_or_else(|| provider(win));
    if !CHOICES.contains(&provider) {
        return Err(format!("Unknown provider {provider}."));
    }
    let words: Vec<&str> = ["/model", provider].into_iter().chain(["model", "effort"].iter().filter_map(|key| change[key].as_str())).collect();
    win.pane.tell(Message::Act { action: "command", params: json!({"text": words.join(" ")}) });
    Ok(json!({"sessionId": win.session_id, "name": name(win), "requested": words.join(" ")}))
}

/// Closes an idle window, its conversation saved by the worker; a busy one is left to finish.
fn close(app: &mut App, close: &Value) -> Result<Value, String> {
    let key = addressed(app, &close["to"], close)?;
    let win = &app.windows[&key];
    if !win.summary.as_ref().is_some_and(|summary| summary.idle) {
        return Err(format!("{} is busy: close it once its turn ends.", name(win)));
    }
    let closed = name(win);
    app.drop_window(key, true);
    Ok(json!({"closed": true, "name": closed}))
}

fn frame(app: &mut App, place: &Value) -> Result<Value, String> {
    let key = find(app, place["to"].as_str().unwrap_or_default())?;
    let number = |index: usize| place["frame"][index].as_f64().ok_or("A frame is [x, y, width, height].");
    let (x, y, width, height) = (number(0)?, number(1)?, number(2)?, number(3)?);
    let win = &app.windows[&key];
    win.window.set_outer_position(LogicalPosition::new(x, y));
    win.window.set_inner_size(LogicalSize::new(width, height));
    // tao applies both on a later turn of the run loop, and a window never shown sends no Moved or Resized: the list
    // is saved after the save delay.
    app.schedule_save();
    Ok(json!({"frame": [x, y, width, height]}))
}
