//! The window list kept for a restart: which session each open window shows, on which socket, and where it stood.
//! A window closed by him leaves it; a window whose session another frontend took leaves it too.

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Saved {
    pub session_id: String,
    pub socket: PathBuf,
    pub cwd: String,
    pub frame: Option<Frame>,
    /// The worker's conversation record, to reopen the session cold when its worker is gone.
    pub record_id: Option<String>,
    /// The worker's state folder that record lives in: a session taken from the Swift app keeps its conversation there.
    pub state_directory: Option<PathBuf>,
    /// The window's desktop (macOS Space) as its place among the desktops, left to right (`desktops::index`).
    pub desktop: Option<usize>,
    /// Its close was asked and the worker had not confirmed it: the next launch finishes it instead of reopening it
    /// (Swift `closeRequested`).
    pub closing: bool,
    /// Where its transcript was scrolled, saved for a live update only (`scroll::READ`).
    pub scroll: Option<Value>,
}

pub fn read(file: &Path) -> Vec<Saved> {
    let Ok(text) = fs::read_to_string(file) else { return Vec::new() };
    let Ok(Value::Array(entries)) = serde_json::from_str(&text) else { return Vec::new() };
    entries.iter().filter_map(entry).collect()
}

fn entry(value: &Value) -> Option<Saved> {
    let text = |key: &str| value[key].as_str().map(str::to_owned);
    let frame = value["frame"].as_array().filter(|numbers| numbers.len() == 4).and_then(|numbers| {
        let number = |index: usize| numbers[index].as_f64();
        Some(Frame { x: number(0)?, y: number(1)?, width: number(2)?, height: number(3)? })
    });
    let desktop = value["desktop"].as_u64().and_then(|index| usize::try_from(index).ok());
    Some(Saved { session_id: text("sessionId")?, socket: text("socket")?.into(), cwd: text("cwd")?, frame, record_id: text("recordID"), state_directory: text("stateDirectory").map(PathBuf::from), desktop, closing: value["closing"] == true, scroll: value.get("scroll").filter(|scroll| scroll.is_object()).cloned() })
}

pub fn write(file: &Path, windows: &[Saved]) -> Result<(), String> {
    if let Some(folder) = file.parent() {
        vcx_config::private_folder(folder)?;
    }
    let entries: Vec<Value> = windows
        .iter()
        .map(|saved| {
            let mut value = json!({"sessionId": saved.session_id, "socket": saved.socket, "cwd": saved.cwd});
            if let Some(frame) = saved.frame {
                value["frame"] = json!([frame.x, frame.y, frame.width, frame.height]);
            }
            if let Some(record) = &saved.record_id {
                value["recordID"] = json!(record);
            }
            if let Some(state) = &saved.state_directory {
                value["stateDirectory"] = json!(state);
            }
            if let Some(desktop) = saved.desktop {
                value["desktop"] = json!(desktop);
            }
            if saved.closing {
                value["closing"] = json!(true);
            }
            if let Some(scroll) = &saved.scroll {
                value["scroll"] = scroll.clone();
            }
            value
        })
        .collect();
    vcx_config::write_private(file, (serde_json::to_string_pretty(&entries).expect("JSON values") + "\n").as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_back_the_windows_it_wrote() {
        let folder = std::env::temp_dir().join(format!("vcx-app-windows-{}", std::process::id()));
        let file = folder.join("windows.json");
        let windows = [
            Saved { session_id: "A".into(), socket: "/r/a.sock".into(), cwd: "/p".into(), frame: Some(Frame { x: 10.0, y: 20.0, width: 800.0, height: 600.0 }), record_id: Some("R".into()), state_directory: Some("/s".into()), desktop: Some(2), closing: false, scroll: Some(json!({"row": "item-4", "offset": -12.0})) },
            Saved { session_id: "B".into(), socket: "/r/b.sock".into(), cwd: "/q".into(), frame: None, record_id: None, state_directory: None, desktop: None, closing: true, scroll: None },
        ];

        write(&file, &windows).unwrap();
        let read_back = read(&file);

        fs::remove_dir_all(&folder).unwrap();
        assert_eq!(read_back, windows);
    }

    #[test]
    fn skips_an_entry_with_no_session() {
        let entries = json!([{"socket": "/r/a.sock", "cwd": "/p"}, {"sessionId": "B", "socket": "/r/b.sock", "cwd": "/q"}]);

        let kept: Vec<Saved> = entries.as_array().unwrap().iter().filter_map(entry).collect();

        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].session_id, "B");
    }
}
