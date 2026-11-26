//! The page template: a folder of HTML, CSS and JS held in memory, served to the web view over `vcx://template/`.
//! An edit that cannot be loaded, or whose page never reports ready, leaves the last template that worked on screen.

use notify::{RecursiveMode, Watcher};
use serde_json::Value;
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock, mpsc};
use std::thread;
use std::time::Duration;
use crate::chart;
use vcx_model::assets;
use vcx_model::view::CONTRACT_VERSION;
use wry::http::{Response, StatusCode, header};

pub const SCHEME: &str = "vcx";
pub const HOME: &str = "vcx://template/index.html";
const HOST: &str = "template";
const MANIFEST: &str = "manifest.json";
const ENTRY: &str = "index.html";
const MAX_BYTES: u64 = 16 * 1024 * 1024;
/// An editor saves a file in several writes; one reload follows the last of them.
const SETTLE: Duration = Duration::from_millis(120);

/// Pictures larger than this are not served: a thumbnail of a huge file would stall the page.
const MAX_PICTURE_BYTES: u64 = 64 * 1024 * 1024;
const IMAGE_HOST: &str = "image";

const BUILT_IN: &[(&str, &[u8])] = &[
    (MANIFEST, include_bytes!("../../../template/manifest.json")),
    (ENTRY, include_bytes!("../../../template/index.html")),
    ("style.css", include_bytes!("../../../template/style.css")),
    ("app.js", include_bytes!("../../../template/app.js")),
    ("composer.css", include_bytes!("../../../template/composer.css")),
    ("composer.js", include_bytes!("../../../template/composer.js")),
    ("find.js", include_bytes!("../../../template/find.js")),
    ("define.js", include_bytes!("../../../template/define.js")),
    ("questions.js", include_bytes!("../../../template/questions.js")),
    ("chrome.css", include_bytes!("../../../template/chrome.css")),
    ("chrome.js", include_bytes!("../../../template/chrome.js")),
    ("run.css", include_bytes!("../../../template/run.css")),
    ("run.js", include_bytes!("../../../template/run.js")),
];

#[derive(Debug, PartialEq)]
pub struct Template {
    pub name: String,
    files: HashMap<String, Vec<u8>>,
}

#[derive(Debug, PartialEq)]
pub enum Change {
    None,
    /// Only style sheets moved: the page swaps them in place and keeps its state.
    Styles,
    Page,
}

impl Template {
    pub fn built_in() -> Self {
        let files = BUILT_IN.iter().chain(chart::BUILT_IN.iter()).map(|(name, bytes)| ((*name).to_owned(), bytes.to_vec())).collect();
        Self::checked(files).expect("the built-in template is valid")
    }

    pub fn load(folder: &Path) -> Result<Self, String> {
        let mut files = HashMap::new();
        let mut total = 0;
        collect(folder, folder, &mut files, &mut total)?;
        Self::checked(files)
    }

    fn checked(files: HashMap<String, Vec<u8>>) -> Result<Self, String> {
        let manifest = files.get(MANIFEST).ok_or("The template has no manifest.json.")?;
        let manifest: Value = serde_json::from_slice(manifest).map_err(|error| format!("The template manifest is not JSON: {error}."))?;
        let contract = manifest.get("contract").and_then(Value::as_u64);
        if contract != Some(u64::from(CONTRACT_VERSION)) {
            let found = contract.map_or("none".to_owned(), |version| version.to_string());
            return Err(format!("The template is written for contract {found}; this build speaks contract {CONTRACT_VERSION}."));
        }
        if !files.contains_key(ENTRY) {
            return Err(format!("The template has no {ENTRY}."));
        }
        let name = manifest.get("name").and_then(Value::as_str).unwrap_or("unnamed").to_owned();
        Ok(Self { name, files })
    }

    fn change_from(&self, earlier: &Template) -> Change {
        let names: HashSet<&String> = self.files.keys().chain(earlier.files.keys()).collect();
        let changed: Vec<&String> = names.into_iter().filter(|name| self.files.get(*name) != earlier.files.get(*name)).collect();
        match changed.as_slice() {
            [] => Change::None,
            names if names.iter().all(|name| name.ends_with(".css")) => Change::Styles,
            _ => Change::Page,
        }
    }
}

fn collect(root: &Path, folder: &Path, files: &mut HashMap<String, Vec<u8>>, total: &mut u64) -> Result<(), String> {
    let unreadable = |error: std::io::Error| format!("Cannot read the template folder {}: {error}.", folder.display());
    for entry in fs::read_dir(folder).map_err(unreadable)? {
        let path = entry.map_err(unreadable)?.path();
        if path.file_name().is_some_and(|name| name.to_string_lossy().starts_with('.')) {
            continue;
        }
        if path.is_dir() {
            collect(root, &path, files, total)?;
            continue;
        }
        let bytes = fs::read(&path).map_err(unreadable)?;
        *total += bytes.len() as u64;
        if *total > MAX_BYTES {
            return Err(format!("The template folder holds more than {MAX_BYTES} bytes."));
        }
        let name = path.strip_prefix(root).expect("a path under the template root").to_string_lossy().into_owned();
        files.insert(name, bytes);
    }
    Ok(())
}

/// The template on screen and the last one whose page reported ready.
pub struct Store {
    folder: Option<PathBuf>,
    current: RwLock<Arc<Template>>,
    good: Mutex<Arc<Template>>,
}

impl Store {
    /// Opens the folder's template, or the built-in one with the reason the folder was refused.
    pub fn open(folder: Option<&Path>) -> (Self, Option<String>) {
        let built_in = Arc::new(Template::built_in());
        let (current, problem) = match folder.map(Template::load) {
            Some(Ok(template)) => (Arc::new(template), None),
            Some(Err(problem)) => (built_in.clone(), Some(problem)),
            None => (built_in.clone(), None),
        };
        (Self { folder: folder.map(Path::to_owned), current: RwLock::new(current), good: Mutex::new(built_in) }, problem)
    }

    pub fn current(&self) -> Arc<Template> {
        self.current.read().unwrap().clone()
    }

    /// Reads the folder again. A folder that cannot be loaded changes nothing.
    pub fn reload(&self) -> Result<Change, String> {
        let Some(folder) = &self.folder else { return Ok(Change::None) };
        let template = Template::load(folder)?;
        let mut current = self.current.write().unwrap();
        let change = template.change_from(&current);
        if change != Change::None {
            *current = Arc::new(template);
        }
        Ok(change)
    }

    /// The page on screen reported ready: this template is the one to come back to.
    pub fn confirm(&self) {
        *self.good.lock().unwrap() = self.current();
    }

    /// Goes back to the last template that worked. False when it is already the one on screen.
    pub fn revert(&self) -> bool {
        let good = self.good.lock().unwrap().clone();
        let mut current = self.current.write().unwrap();
        if Arc::ptr_eq(&current, &good) {
            return false;
        }
        *current = good;
        true
    }

    pub fn respond(&self, host: Option<&str>, path: &str) -> Response<Cow<'static, [u8]>> {
        match host {
            Some(chart::HOST) => return chart::respond(path),
            Some(IMAGE_HOST) => return picture(path),
            _ => {}
        }
        let name = path.trim_start_matches('/');
        let template = self.current();
        let file = if host == Some(HOST) { template.files.get(name) } else { None };
        let (status, mime, body) = match file {
            Some(bytes) => (StatusCode::OK, mime(name), bytes.clone()),
            None => (StatusCode::NOT_FOUND, "text/plain; charset=utf-8", b"Not in the template.".to_vec()),
        };
        // Never cached: an edited file must be the one the next load reads.
        Response::builder().status(status).header(header::CONTENT_TYPE, mime).header(header::CACHE_CONTROL, "no-store").body(Cow::Owned(body)).expect("a response built from constant headers")
    }
}

/// A picture the user attached, by the name a view gave it: the page cannot ask for a file by its path.
fn picture(path: &str) -> Response<Cow<'static, [u8]>> {
    let file = assets::image_path(path.trim_start_matches('/'));
    let bytes = file.as_deref().filter(|file| fs::metadata(file).is_ok_and(|meta| meta.is_file() && meta.len() <= MAX_PICTURE_BYTES)).and_then(|file| fs::read(file).ok());
    let (status, mime, body) = match (bytes, file) {
        (Some(bytes), Some(file)) => (StatusCode::OK, mime(&file.to_string_lossy().to_ascii_lowercase()), bytes),
        _ => (StatusCode::NOT_FOUND, "text/plain; charset=utf-8", b"No such picture.".to_vec()),
    };
    Response::builder().status(status).header(header::CONTENT_TYPE, mime).header(header::CACHE_CONTROL, "no-store").body(Cow::Owned(body)).expect("a response built from constant headers")
}

fn mime(name: &str) -> &'static str {
    match name.rsplit('.').next() {
        Some("html") => "text/html; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("json") => "application/json",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("heic") => "image/heic",
        Some("tif" | "tiff") => "image/tiff",
        Some("woff2") => "font/woff2",
        _ => "application/octet-stream",
    }
}

/// Calls `edited` once after each burst of changes in the folder, for as long as the returned watcher lives.
pub fn watch(folder: &Path, edited: impl Fn() + Send + 'static) -> notify::Result<notify::RecommendedWatcher> {
    let (sender, events) = mpsc::channel();
    let mut watcher = notify::recommended_watcher(sender)?;
    watcher.watch(folder, RecursiveMode::Recursive)?;
    thread::Builder::new().name("vcx-template-watch".into()).spawn(move || {
        while events.recv().is_ok() {
            thread::sleep(SETTLE);
            while events.try_recv().is_ok() {}
            edited();
        }
    })?;
    Ok(watcher)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Folder(PathBuf);

    impl Folder {
        fn copy_of_built_in(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!("vcx-template-{}-{name}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            for (file, bytes) in BUILT_IN {
                fs::write(path.join(file), bytes).unwrap();
            }
            Self(path)
        }

        fn write(&self, file: &str, text: &str) {
            fs::write(self.0.join(file), text).unwrap();
        }
    }

    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn serves_a_template_file_with_its_type() {
        let (store, problem) = Store::open(None);

        let response = store.respond(Some("template"), "/style.css");

        assert_eq!(problem, None);
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[header::CONTENT_TYPE], "text/css; charset=utf-8");
        assert!(response.body().starts_with(b":root"));
    }

    #[test]
    fn serves_nothing_outside_the_template() {
        let (store, _) = Store::open(None);

        let other_host = store.respond(Some("elsewhere"), "/index.html");
        let unknown_file = store.respond(Some("template"), "/../Cargo.toml");

        assert_eq!(other_host.status(), StatusCode::NOT_FOUND);
        assert_eq!(unknown_file.status(), StatusCode::NOT_FOUND);
    }

    #[test]
    fn serves_a_picture_only_under_the_name_a_view_gave_it() {
        let folder = Folder::copy_of_built_in("picture");
        let file = folder.0.join("shot.png");
        fs::write(&file, b"png bytes").unwrap();
        let (store, _) = Store::open(None);
        let id = assets::image(&file.to_string_lossy());

        let named = store.respond(Some("image"), &format!("/{id}"));
        let by_path = store.respond(Some("image"), &file.to_string_lossy());

        assert_eq!((named.status(), named.headers()[header::CONTENT_TYPE].to_str().unwrap()), (StatusCode::OK, "image/png"));
        assert_eq!(named.body().as_ref(), b"png bytes");
        assert_eq!(by_path.status(), StatusCode::NOT_FOUND);
    }

    #[test]
    fn serves_the_chart_files_in_the_built_in_template() {
        let (store, _) = Store::open(None);

        let response = store.respond(Some("template"), "/chart/kit.js");

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[test]
    fn falls_back_to_the_built_in_template_when_the_folder_speaks_another_contract() {
        let folder = Folder::copy_of_built_in("contract");
        folder.write("manifest.json", r#"{"name": "future", "contract": 99}"#);

        let (store, problem) = Store::open(Some(&folder.0));

        assert_eq!(store.current().name, "VCX default");
        assert!(problem.unwrap().contains("contract 99"));
    }

    #[test]
    fn tells_a_style_edit_from_a_page_edit() {
        let folder = Folder::copy_of_built_in("change");
        let (store, _) = Store::open(Some(&folder.0));

        let untouched = store.reload();
        folder.write("style.css", "body { color: red; }");
        let styles = store.reload();
        folder.write("app.js", "window.ipc.postMessage('{}');");
        let page = store.reload();

        assert_eq!(untouched, Ok(Change::None));
        assert_eq!(styles, Ok(Change::Styles));
        assert_eq!(page, Ok(Change::Page));
    }

    #[test]
    fn keeps_the_template_on_screen_when_an_edit_cannot_be_loaded() {
        let folder = Folder::copy_of_built_in("broken");
        let (store, _) = Store::open(Some(&folder.0));
        folder.write("manifest.json", "{ not json");

        let reloaded = store.reload();

        assert!(reloaded.unwrap_err().contains("not JSON"));
        assert_eq!(store.respond(Some("template"), "/manifest.json").body().as_ref(), BUILT_IN[0].1);
    }

    #[test]
    fn reverts_to_the_last_template_whose_page_was_ready() {
        let folder = Folder::copy_of_built_in("revert");
        let (store, _) = Store::open(Some(&folder.0));
        store.confirm();
        folder.write("app.js", "throw new Error('broken edit');");
        store.reload().unwrap();

        let reverted = store.revert();
        let again = store.revert();

        assert!(reverted);
        assert!(!again);
        assert_eq!(store.respond(Some("template"), "/app.js").body().as_ref(), BUILT_IN[3].1);
    }
}
