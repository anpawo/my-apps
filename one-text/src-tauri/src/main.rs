mod group;

use serde_json::{json, Value};
use std::{fs, path::PathBuf, sync::Mutex, time::{Duration, Instant}};
use tauri::{http::Response, Manager, State};

/// one-text runs on the always-on Beeper Server that the beeper CLI installs as this LaunchAgent, not on Beeper Desktop.
const AGENT: &str = "com.beeper.cli.profile.background";
const MISSING: &str = "Beeper Server isn't installed. In Terminal: brew install beeper/tap/cli && beeper setup --server --install";
const STARTING: &str = "Beeper Server isn't answering: starting it…";

struct Beeper {
    target: Mutex<Option<(String, String)>>,
    nudged: Mutex<Option<Instant>>,
    http: reqwest::Client,
    overrides: PathBuf,
    unread: Mutex<std::collections::HashMap<String, i64>>,
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
}

/// The server's address and the token the beeper CLI saved for it.
fn read_target() -> Option<(String, String)> {
    let target: Value = serde_json::from_str(&fs::read_to_string(home().join(".beeper/targets/background.json")).ok()?).ok()?;
    Some((
        target["baseURL"].as_str().unwrap_or("http://127.0.0.1:23374").trim_end_matches('/').into(),
        target["auth"]["accessToken"].as_str()?.into(),
    ))
}

fn beeper(overrides: PathBuf) -> Beeper {
    Beeper { target: Mutex::new(read_target()), nudged: Mutex::new(None), http: reqwest::Client::new(), overrides, unread: Default::default() }
}

impl Beeper {
    fn target(&self) -> Result<(String, String), String> {
        let mut t = self.target.lock().unwrap();
        if t.is_none() {
            *t = read_target();
        }
        t.clone().ok_or_else(|| MISSING.into())
    }

    /// Starts the server's LaunchAgent, at most once a minute (its first start takes a few seconds).
    fn start_server(&self) {
        let mut last = self.nudged.lock().unwrap();
        if last.is_some_and(|t| t.elapsed() < Duration::from_secs(60)) {
            return;
        }
        *last = Some(Instant::now());
        use std::os::unix::fs::MetadataExt;
        let uid = fs::metadata(home()).map(|m| m.uid()).unwrap_or(501);
        let plist = home().join(format!("Library/LaunchAgents/{AGENT}.plist"));
        let launchctl = |args: &[&str]| std::process::Command::new("/bin/launchctl").args(args).status().is_ok_and(|s| s.success());
        if !launchctl(&["kickstart", &format!("gui/{uid}/{AGENT}")]) {
            launchctl(&["bootstrap", &format!("gui/{uid}"), &plist.to_string_lossy()]);
        }
    }

    async fn call(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value, String> {
        let (base, token) = self.target()?;
        let method = reqwest::Method::from_bytes(method.as_bytes()).map_err(|e| e.to_string())?;
        let mut req = self.http.request(method, format!("{base}{path}")).bearer_auth(&token);
        if let Some(body) = body {
            req = req.json(&body);
        }
        let res = match req.send().await {
            Err(e) if e.is_connect() => {
                self.start_server();
                return Err(STARTING.into());
            }
            r => r.map_err(|e| e.to_string())?,
        };
        if res.status() == reqwest::StatusCode::UNAUTHORIZED {
            // `beeper setup` again writes a new token: read it on the next call.
            *self.target.lock().unwrap() = None;
        }
        let status = res.status();
        let text = res.text().await.map_err(|e| e.to_string())?;
        if !status.is_success() {
            return Err(format!("{status}: {}", text.chars().take(200).collect::<String>()));
        }
        Ok(serde_json::from_str(&text).unwrap_or(Value::Null))
    }

    fn overrides(&self) -> Value {
        fs::read_to_string(&self.overrides).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(json!({}))
    }
}

#[tauri::command]
async fn api(b: State<'_, Beeper>, method: String, path: String, body: Option<Value>) -> Result<Value, String> {
    b.call(&method, &path, body).await
}

/// Every chat, newest first, grouped into people and group chats.
#[tauri::command]
async fn people(b: State<'_, Beeper>) -> Result<Value, String> {
    Ok(group::build(&all_chats(&b).await?, &b.overrides()))
}

async fn all_chats(b: &Beeper) -> Result<Vec<Value>, String> {
    let mut chats = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let path = match &cursor {
            Some(c) => format!("/v1/chats?limit=200&direction=before&cursor={}", urlencode(c)),
            None => "/v1/chats?limit=200".into(),
        };
        let page = b.call("GET", &path, None).await?;
        chats.extend(page["items"].as_array().cloned().unwrap_or_default());
        cursor = page["oldestCursor"].as_str().map(String::from);
        if page["hasMore"] != true || cursor.is_none() {
            break;
        }
    }
    chats.retain(|c| c["isArchived"] != true);
    // A chat Beeper merged itself (Eliot's: SMS, Instagram, WhatsApp, Teams, LinkedIn in one) lists as one chat of
    // network "Beeper (Matrix)": open it into the chats it merges, which the list hides, so each network shows and
    // can be replied on. `mergedInto` keeps them one person (group::build).
    let mut out = Vec::with_capacity(chats.len());
    for c in chats {
        let ids: Vec<String> = c["merge"]["chatIDs"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(String::from)).collect();
        let mut parts = Vec::new();
        for id in &ids {
            if let Ok(mut part) = b.call("GET", &format!("/v1/chats/{}", urlencode(id)), None).await {
                part["mergedInto"] = c["id"].clone();
                parts.push(part);
            }
        }
        if parts.is_empty() { out.push(c) } else { out.extend(parts) }
    }
    // Beeper counts a reaction to one of my messages as unread, though the thread never shows it: count only the
    // unread messages it shows. A muted chat counts none. Kept per chat and latest message, so a refresh asks again
    // only for chats that moved.
    let mut ask = Vec::new();
    for (i, c) in out.iter_mut().enumerate().filter(|(_, c)| c["unreadCount"].as_i64().unwrap_or(0) > 0) {
        if c["isMuted"] == true {
            c["unreadCount"] = json!(0);
            continue;
        }
        let key = format!("{}|{}", c["id"], c["preview"]["sortKey"]);
        match b.unread.lock().unwrap().get(&key) {
            Some(&n) => c["unreadCount"] = json!(n),
            None => ask.push((i, key, format!("/v1/chats/{}/messages", urlencode(c["id"].as_str().unwrap_or(""))))),
        }
    }
    let pages = futures_util::future::join_all(ask.iter().map(|(_, _, path)| b.call("GET", path, None))).await;
    for ((i, key, _), page) in ask.into_iter().zip(pages) {
        let Ok(page) = page else { continue };
        let n = shown_unread(page["items"].as_array().map(Vec::as_slice).unwrap_or_default(), out[i]["unreadCount"].as_i64().unwrap_or(0));
        b.unread.lock().unwrap().insert(key, n);
        out[i]["unreadCount"] = json!(n);
    }
    Ok(out)
}

/// The unread messages a page shows (reactions and deleted ones aside); a page all unread holds fewer than there
/// are, so Beeper's count stands.
fn shown_unread(page: &[Value], beeper_count: i64) -> i64 {
    let unread: Vec<&Value> = page.iter().filter(|m| m["isUnread"] == true).collect();
    if !page.is_empty() && unread.len() == page.len() {
        return beeper_count;
    }
    unread.iter().filter(|m| m["isHidden"] != true && m["isDeleted"] != true).count() as i64
}

#[tauri::command]
fn overrides(b: State<'_, Beeper>) -> Value {
    b.overrides()
}

#[tauri::command]
fn set_overrides(b: State<'_, Beeper>, value: Value) -> Result<(), String> {
    if let Some(dir) = b.overrides.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    fs::write(&b.overrides, serde_json::to_string_pretty(&value).unwrap()).map_err(|e| e.to_string())
}

/// Instagram's grey silhouette, in the two sizes Beeper keeps (shared by 23 contacts on 12/11/2026): a 404 lets
/// the avatar fall through to the next network's picture.
fn is_default_picture(bytes: &[u8]) -> bool {
    use sha2::{Digest, Sha256};
    const DEFAULTS: [&str; 2] = [
        "f5319c27a8a51bad81caeabb1ffdc72dd296a73ee1f426e1c462e7b42269eff6",
        "76c85ef9f896fd6ce0bf7d6e85d6b0f3c4940bc67d0e5acf15f486e8c5108fc0",
    ];
    let hex: String = Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect();
    DEFAULTS.contains(&hex.as_str())
}

/// Links open in the default browser: the webview has no new-window handler, so `target="_blank"` alone does nothing.
#[tauri::command]
fn open_url(url: String) -> Result<(), String> {
    if !url.starts_with("https://") && !url.starts_with("http://") {
        return Err("not a web link".into());
    }
    std::process::Command::new("/usr/bin/open").arg(&url).spawn().map(|_| ()).map_err(|e| e.to_string())
}

fn urlencode(s: &str) -> String {
    s.bytes()
        .map(|b| if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect()
}

#[cfg(test)]
mod live {
    /// Against the running Beeper Server, counts only: `cargo test -- --ignored --nocapture`.
    #[test]
    fn reactions_are_not_unread() {
        use serde_json::json;
        let m = |unread: bool, hidden: bool| json!({ "isUnread": unread, "isHidden": hidden });
        assert_eq!(super::shown_unread(&[m(false, false), m(true, true)], 1), 0);
        assert_eq!(super::shown_unread(&[m(false, false), m(true, false), m(true, true)], 2), 1);
        assert_eq!(super::shown_unread(&[m(true, false), m(true, false)], 57), 57);
    }

    #[test]
    #[ignore]
    fn people_from_beeper() {
        let b = super::beeper(std::env::temp_dir().join("chats-no-overrides.json"));
        let rt = tauri::async_runtime::block_on(super::all_chats(&b)).unwrap();
        let out = super::group::build(&rt, &serde_json::json!({}));
        let people = out["people"].as_array().unwrap();
        let merged = people.iter().filter(|p| p["chats"].as_array().unwrap().len() > 1).count();
        println!("chats {} people {} merged-people {} groups {}", rt.len(), people.len(), merged, out["groups"].as_array().unwrap().len());
        let mut shapes = std::collections::BTreeMap::new();
        for p in people.iter().filter(|p| p["chats"].as_array().unwrap().len() > 1) {
            let mut nets: Vec<&str> = p["chats"].as_array().unwrap().iter().map(|c| c["network"].as_str().unwrap_or("?")).collect();
            nets.sort();
            *shapes.entry(nets.join("+")).or_insert(0) += 1;
        }
        println!("merged shapes {shapes:?}");
        let unread = |v: &serde_json::Value| v.as_array().unwrap().iter().filter(|p| p["unread"].as_i64().unwrap_or(0) > 0).count();
        println!("with unread: people {} groups {}", unread(&out["people"]), unread(&out["groups"]));
        if let Ok(name) = std::env::var("PERSON") {
            for p in people.iter().filter(|p| p["name"].as_str().is_some_and(|n| n.contains(name.as_str()))) {
                let nets: Vec<&str> = p["chats"].as_array().unwrap().iter().map(|c| c["network"].as_str().unwrap_or("?")).collect();
                println!("{}: {nets:?}", p["name"]);
            }
        }
        assert!(!people.is_empty());
    }

    /// With the server stopped (`launchctl bootout gui/$(id -u)/com.beeper.cli.profile.background`), one call brings it back.
    #[test]
    #[ignore]
    fn starts_stopped_server() {
        let b = super::beeper(std::env::temp_dir().join("chats-no-overrides.json"));
        let get = || tauri::async_runtime::block_on(b.call("GET", "/v1/chats?limit=1", None));
        assert_eq!(get().unwrap_err(), super::STARTING);
        let start = std::time::Instant::now();
        while get().is_err() {
            assert!(start.elapsed().as_secs() < 60, "server still down after 60 s");
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
        println!("back after {} s", start.elapsed().as_secs());
    }
}

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let overrides = app.path().app_data_dir()?.join("overrides.json");
            app.manage(beeper(overrides));
            Ok(())
        })
        // <img src="beeper://localhost/asset?url=mxc://…">: avatars and media need the token, which an <img> cannot send.
        .register_asynchronous_uri_scheme_protocol("beeper", |ctx, request, responder| {
            let app = ctx.app_handle().clone();
            let query = request.uri().query().unwrap_or("").to_string();
            tauri::async_runtime::spawn(async move {
                let b = app.state::<Beeper>();
                let fail = |code: u16| Response::builder().status(code).body(Vec::new()).unwrap();
                let Ok((base, token)) = b.target() else { return responder.respond(fail(503)) };
                let res = b.http.get(format!("{base}/v1/assets/serve?{query}")).bearer_auth(&token).send().await;
                responder.respond(match res {
                    Ok(r) if r.status().is_success() => {
                        let kind = r.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("application/octet-stream").to_string();
                        match r.bytes().await {
                            Ok(bytes) if is_default_picture(&bytes) => fail(404),
                            Ok(bytes) =>Response::builder().header("content-type", kind).header("cache-control", "max-age=86400").body(bytes.to_vec()).unwrap(),
                            Err(_) => fail(502),
                        }
                    }
                    Ok(r) => fail(r.status().as_u16()),
                    Err(_) => fail(502),
                });
            });
        })
        .invoke_handler(tauri::generate_handler![api, people, overrides, set_overrides, open_url])
        .run(tauri::generate_context!())
        .expect("error while running one-text");
}
