//! The windows `--sessions` lists, read from the Fleet records the app writes (`<state>/fleet/<pid>.json`, the
//! Swift app's `FleetPresence` shape), so the list needs no running app.

use serde_json::Value;
use std::fs;
use std::path::Path;
use vcx_config::process::alive;

/// A window with no task label is named by its first prompt's first words, at most this long.
const NAME_CHARS: usize = 24;
const NAME_WORDS: usize = 3;
const UNNAMED: &str = "VCX session";
const PROVIDERS: [&str; 4] = ["claude", "codex", "qwen", "agy"];

#[derive(Debug, Clone, PartialEq)]
pub struct Listed {
    pub id: String,
    pub provider: String,
    pub state: String,
    pub cwd: String,
    pub name: String,
}

/// The windows of every app process still running, by id.
pub fn list(folder: &Path) -> Vec<Listed> {
    let Ok(entries) = fs::read_dir(folder) else { return Vec::new() };
    let mut found = Vec::new();
    for entry in entries.flatten() {
        let Some(root) = fs::read(entry.path()).ok().and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok()) else { continue };
        let Some(pid) = root["pid"].as_i64().and_then(|pid| i32::try_from(pid).ok()) else { continue };
        if !alive(pid, root["startedAt"].as_u64()) {
            continue;
        }
        for session in root["sessions"].as_array().into_iter().flatten() {
            let text = |key: &str| session[key].as_str().unwrap_or_default().to_owned();
            found.push(Listed {
                id: text("sessionId"),
                provider: provider(session["threadId"].as_str()).to_owned(),
                state: session["state"].as_str().unwrap_or("?").to_owned(),
                cwd: text("cwd"),
                name: name(session["context"].as_str(), session["prompt"].as_str()),
            });
        }
    }
    found.sort_by(|a, b| a.id.cmp(&b.id));
    found
}

/// The provider a thread id names (`claude:…`); a Codex thread has no prefix.
pub fn provider(thread: Option<&str>) -> &'static str {
    let thread = thread.unwrap_or_default();
    PROVIDERS.iter().copied().find(|provider| thread.starts_with(&format!("{provider}:"))).unwrap_or("codex")
}

/// The window's name, as `--send` matches it: its task label's first words, else its first prompt's.
pub fn name(context: Option<&str>, prompt: Option<&str>) -> String {
    let words = |text: &str, limit: usize| {
        let mut name = String::new();
        for word in text.split_whitespace().take(NAME_WORDS) {
            if !name.is_empty() && name.len() + 1 + word.len() > limit {
                break;
            }
            if !name.is_empty() {
                name.push(' ');
            }
            name.push_str(word);
        }
        name
    };
    match (context.map(|context| words(context, usize::MAX)).filter(|name| !name.is_empty()), prompt) {
        (Some(label), _) => label,
        (None, Some(prompt)) if !prompt.trim().is_empty() => words(prompt, NAME_CHARS),
        _ => UNNAMED.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_a_window_by_its_task_label_else_by_its_first_prompt() {
        assert_eq!(name(Some("Rust app slice four"), Some("hello")), "Rust app slice");
        assert_eq!(name(None, Some("rebuild the whole thing in rust today")), "rebuild the whole");
        assert_eq!(name(None, Some("internationalization considerations everywhere")), "internationalization");
        assert_eq!(name(Some(""), None), UNNAMED);
    }

    #[test]
    fn reads_the_provider_from_the_thread_prefix() {
        assert_eq!([provider(Some("claude:x")), provider(Some("qwen:y")), provider(Some("agy:z")), provider(Some("019a")), provider(None)], ["claude", "qwen", "agy", "codex", "codex"]);
    }
}
