//! The core's half of the composer (`template/composer.js`): the files an `@` word lists, and the pictures a paste
//! hands over, written to disk because a page cannot name a file.

use objc2::AllocAnyThread;
use objc2_foundation::{NSData, NSDataBase64DecodingOptions, NSString};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};

/// As many as the palette shows without feeling long.
const FILE_RESULTS: usize = 50;
/// A home folder holds millions of files: the walk stops here and lists what it found.
const VISIT_LIMIT: usize = 20_000;
const SKIPPED_FOLDERS: [&str; 8] = [".git", "node_modules", "target", ".build", "dist", "build", "__pycache__", ".venv"];
/// The page refuses bigger pictures (`IMAGE_MAX_BYTES` in `composer.js`).
const IMAGE_MAX_BYTES: usize = 32 * 1024 * 1024;
/// The Rust app's state folder, as `vcx-config` names it (`STATE_VARIABLE`, `STATE_DEFAULT`), which `vcx-shell` does
/// not depend on; pasted pictures live under it, never in the Swift app's folders.
const STATE_VARIABLE: &str = "VCX_RUST_STATE_HOME";
const STATE_DEFAULT: &str = ".local/state/vcx-rust";
const ATTACHMENTS: &str = "attachments";

#[derive(Debug, PartialEq)]
pub struct Found {
    pub path: String,
    pub absolute: PathBuf,
    pub folder: bool,
}

/// How well `relative` matches `query` (lower is better), or `None` when it does not.
fn rank(relative: &str, query: &str) -> Option<u8> {
    let path = relative.to_lowercase();
    let name = path.rsplit('/').next().unwrap_or(&path);
    if name.starts_with(query) {
        Some(0)
    } else if name.contains(query) {
        Some(1)
    } else {
        path.contains(query).then_some(2)
    }
}

/// The files and folders under `root` whose path holds `query`, best first: a name that starts with it, a name that
/// holds it, then a path that holds it; shorter paths first within each. Hidden entries only when the query asks.
pub fn find_files(root: &Path, query: &str) -> Vec<Found> {
    let query = query.to_lowercase();
    let hidden = query.starts_with('.') || query.contains("/.");
    let mut ranked = Vec::new();
    let mut folders = VecDeque::from([PathBuf::new()]);
    let mut visited = 0;
    while let Some(folder) = folders.pop_front() {
        let Ok(entries) = fs::read_dir(root.join(&folder)) else { continue };
        for entry in entries.flatten() {
            visited += 1;
            if visited > VISIT_LIMIT {
                folders.clear();
                break;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            let is_folder = entry.file_type().is_ok_and(|kind| kind.is_dir());
            if (name.starts_with('.') && !hidden) || (is_folder && SKIPPED_FOLDERS.contains(&name.as_str())) {
                continue;
            }
            let relative = folder.join(&name);
            let path = relative.to_string_lossy().into_owned();
            if let Some(score) = rank(&path, &query) {
                ranked.push((score, Found { path, absolute: root.join(&relative), folder: is_folder }));
            }
            if is_folder {
                folders.push_back(relative);
            }
        }
    }
    ranked.sort_by(|(a, first), (b, second)| (a, first.path.len(), &first.path).cmp(&(b, second.path.len(), &second.path)));
    ranked.into_iter().take(FILE_RESULTS).map(|(_, found)| found).collect()
}

/// The page's answer to its `{type: 'files', id, query}`.
pub fn files_reply(id: &Value, found: &[Found]) -> Value {
    let files: Vec<Value> = found.iter().map(|file| json!({"path": file.path, "absolute": file.absolute.to_string_lossy(), "folder": file.folder})).collect();
    json!({"type": "files", "id": id, "files": files})
}

/// The last part of the name the page gave, with nothing that climbs out of the folder or hides the file.
fn safe_name(name: &str) -> String {
    let last = name.rsplit(['/', '\\']).next().unwrap_or_default();
    let name: String = last.chars().filter(|character| !character.is_control()).collect();
    let name = name.trim_start_matches('.');
    if name.is_empty() { "image.png".to_owned() } else { name.to_owned() }
}

/// Writes the pasted picture, sent by the page as base64, into `folder` under a name of its own.
pub fn save_image(folder: &Path, name: &str, base64: &str) -> Result<PathBuf, String> {
    let text = NSString::from_str(base64);
    let data = NSData::initWithBase64EncodedString_options(NSData::alloc(), &text, NSDataBase64DecodingOptions::IgnoreUnknownCharacters).ok_or("The pasted picture is not base64.")?;
    let bytes = data.to_vec();
    if bytes.is_empty() || bytes.len() > IMAGE_MAX_BYTES {
        return Err(format!("A pasted picture of {} bytes is not kept.", bytes.len()));
    }
    fs::create_dir_all(folder).map_err(|error| format!("{}: {error}", folder.display()))?;
    let path = folder.join(format!("{}-{}", uuid::Uuid::new_v4().simple(), safe_name(name)));
    fs::write(&path, bytes).map_err(|error| format!("{}: {error}", path.display()))?;
    Ok(path)
}

/// The page's chip for a picture it pasted as `id`, now on disk at `path`.
pub fn image_attached(id: &Value, path: &Path) -> Value {
    json!({"type": "attach", "items": [{"kind": "image", "id": id, "path": path.to_string_lossy()}]})
}

/// The chips for paths dropped on the window: pictures by their extension, folders, and other files named from `cwd`.
pub fn dropped(paths: &[PathBuf], cwd: &Path) -> Value {
    const IMAGE_EXTENSIONS: [&str; 7] = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"];
    let items: Vec<Value> = paths
        .iter()
        .map(|path| {
            let extension = path.extension().map(|extension| extension.to_string_lossy().to_lowercase()).unwrap_or_default();
            let kind = if path.is_dir() { "folder" } else if IMAGE_EXTENSIONS.contains(&extension.as_str()) { "image" } else { "file" };
            let relative = path.strip_prefix(cwd).ok().filter(|relative| !relative.as_os_str().is_empty());
            json!({"kind": kind, "path": path.to_string_lossy(), "relative": relative.map(|relative| relative.to_string_lossy().into_owned())})
        })
        .collect();
    json!({"type": "attach", "items": items})
}

/// Where pasted pictures are written.
pub fn attachments_folder() -> PathBuf {
    let state = std::env::var_os(STATE_VARIABLE).filter(|value| !value.is_empty()).map(PathBuf::from);
    let home = || std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default().join(STATE_DEFAULT);
    state.unwrap_or_else(home).join(ATTACHMENTS)
}

/// The page's answer to a composer request the core serves: `files` (an `@` word's list, from `cwd`), `image` (a pasted
/// picture, written into `attachments`) and `dropped` (paths dropped on the window). It reads the disk: call it off
/// the main thread. `None` for any other message.
pub fn answer(message: &Value, cwd: &Path, attachments: &Path) -> Option<Value> {
    let text = |key: &str| message.get(key).and_then(Value::as_str);
    match text("type")? {
        "files" => {
            let found = if cwd.is_dir() { find_files(cwd, text("query").unwrap_or_default()) } else { Vec::new() };
            Some(files_reply(&message["id"], &found))
        }
        "image" => Some(match save_image(attachments, text("name").unwrap_or_default(), text("data")?) {
            Ok(path) => image_attached(&message["id"], &path),
            Err(problem) => json!({"type": "notice", "text": problem}),
        }),
        "dropped" => {
            let paths: Vec<PathBuf> = message.get("paths")?.as_array()?.iter().filter_map(Value::as_str).map(PathBuf::from).collect();
            (!paths.is_empty()).then(|| dropped(&paths, cwd))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("vcx-composer-{name}-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(&folder).unwrap();
        folder
    }

    #[test]
    fn lists_names_that_start_with_the_query_before_paths_that_hold_it() {
        let root = scratch("rank");
        for file in ["src/main.rs", "src/domain/main_test.rs", "docs/remain.md", "main/readme.md", "other.txt"] {
            fs::create_dir_all(root.join(file).parent().unwrap()).unwrap();
            fs::write(root.join(file), "").unwrap();
        }

        let found: Vec<String> = find_files(&root, "Main").into_iter().map(|file| file.path).collect();

        assert_eq!(found, ["main", "src/main.rs", "src/domain/main_test.rs", "src/domain", "docs/remain.md", "main/readme.md"]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn skips_hidden_entries_and_build_folders_unless_the_query_names_them() {
        let root = scratch("skip");
        for file in [".env", "target/app.rs", "node_modules/app.js", "app.rs"] {
            fs::create_dir_all(root.join(file).parent().unwrap()).unwrap();
            fs::write(root.join(file), "").unwrap();
        }

        let plain: Vec<String> = find_files(&root, "").into_iter().map(|file| file.path).collect();
        let dotted: Vec<String> = find_files(&root, ".en").into_iter().map(|file| file.path).collect();

        assert_eq!(plain, ["app.rs"]);
        assert_eq!(dotted, [".env"]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn answers_the_page_with_paths_and_folders() {
        let found = [Found { path: "src".into(), absolute: "/work/src".into(), folder: true }];

        let reply = files_reply(&json!(4), &found);

        assert_eq!(reply, json!({"type": "files", "id": 4, "files": [{"path": "src", "absolute": "/work/src", "folder": true}]}));
    }

    #[test]
    fn writes_a_pasted_picture_under_a_name_that_stays_in_its_folder() {
        let folder = scratch("image");

        let path = save_image(&folder, "../../.evil/shot.png", "iVBORw0KGgo=").unwrap();

        assert_eq!(path.parent(), Some(folder.as_path()));
        assert!(path.file_name().unwrap().to_string_lossy().ends_with("-shot.png"), "{path:?}");
        assert_eq!(fs::read(&path).unwrap(), [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]);
        fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn refuses_a_picture_that_is_not_base64() {
        let folder = scratch("bad");

        let saved = save_image(&folder, "shot.png", "");

        assert!(saved.is_err());
        fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn answers_files_images_and_drops_and_leaves_other_messages() {
        let (root, attachments) = (scratch("answer"), scratch("attachments"));
        fs::write(root.join("notes.md"), "").unwrap();

        let files = answer(&json!({"type": "files", "id": 2, "query": "not"}), &root, &attachments).unwrap();
        let image = answer(&json!({"type": "image", "id": 3, "name": "shot.png", "data": "iVBORw0KGgo="}), &root, &attachments).unwrap();
        let refused = answer(&json!({"type": "image", "id": 4, "name": "shot.png", "data": ""}), &root, &attachments).unwrap();
        let drop = answer(&json!({"type": "dropped", "paths": [root.join("notes.md")]}), &root, &attachments).unwrap();
        let nowhere = answer(&json!({"type": "files", "id": 5, "query": ""}), Path::new(""), &attachments).unwrap();

        assert_eq!((files["id"].clone(), files["files"][0]["path"].clone()), (json!(2), json!("notes.md")));
        assert!(image["items"][0]["path"].as_str().unwrap().starts_with(attachments.to_str().unwrap()), "{image}");
        assert_eq!((image["type"].clone(), image["items"][0]["id"].clone(), refused["type"].clone()), (json!("attach"), json!(3), json!("notice")));
        assert_eq!(drop["items"][0]["relative"], "notes.md");
        assert_eq!(nowhere["files"], json!([]));
        assert_eq!(answer(&json!({"type": "draft"}), &root, &attachments), None);
        fs::remove_dir_all(root).unwrap();
        fs::remove_dir_all(attachments).unwrap();
    }

    #[test]
    fn names_dropped_files_from_the_working_folder_and_tells_pictures_and_folders_apart() {
        let root = scratch("drop");
        fs::create_dir_all(root.join("docs")).unwrap();

        let reply = dropped(&[root.join("shot.PNG"), root.join("docs"), PathBuf::from("/elsewhere/notes.md")], &root);

        let kinds: Vec<&str> = reply["items"].as_array().unwrap().iter().map(|item| item["kind"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["image", "folder", "file"]);
        assert_eq!(reply["items"][1]["relative"], "docs");
        assert_eq!(reply["items"][2]["relative"], Value::Null);
        fs::remove_dir_all(root).unwrap();
    }
}
