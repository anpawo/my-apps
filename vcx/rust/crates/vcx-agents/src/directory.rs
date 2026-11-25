//! The folder a finished `cd` command moved an agent's shell to, as `Directory.swift` reads it.

use crate::Object;
use serde_json::Value;
use std::path::{Component, Path, PathBuf};

/// The folder a completed, successful lone `cd` (bare or inside `sh -c`) leads to, kept only inside `initial` or one
/// of the added folders.
pub fn shell_directory(item: &Object, current: &str, initial: &str, added: &[String]) -> Option<String> {
    let text = |key: &str| item.get(key).and_then(Value::as_str);
    if text("type") != Some("commandExecution") || text("status") != Some("completed") || item.get("exitCode").and_then(Value::as_i64).unwrap_or(0) != 0 {
        return None;
    }
    let base = text("cwd").unwrap_or(current);
    if !base.starts_with('/') {
        return None;
    }
    let mut words = literal_shell_words(text("command").unwrap_or_default());
    if let Some(shell) = &words {
        let name = Path::new(&shell.first()?).file_name().and_then(|name| name.to_str()).unwrap_or_default().to_owned();
        if shell.len() == 3 && ["sh", "bash", "zsh"].contains(&name.as_str()) && ["-c", "-lc", "-ic", "-ilc"].contains(&shell[1].as_str()) {
            words = literal_shell_words(&shell[2]);
        }
    }
    let words = words?;
    if words.first().map(String::as_str) != Some("cd") || !(words.len() == 2 || (words.len() == 3 && words[1] == "--")) {
        return None;
    }
    let path = words.last()?;
    if path == "-" || (path.starts_with('~') && path != "~" && !path.starts_with("~/")) {
        return None;
    }
    let expanded = match path.strip_prefix('~') {
        Some(rest) => format!("{}{rest}", std::env::var("HOME").unwrap_or_default()),
        None => path.clone(),
    };
    let target = standardize(&Path::new(base).join(expanded));
    std::iter::once(initial).chain(added.iter().map(String::as_str)).find_map(|root| working_directory(&target, root))
}

/// `target` when it is an existing folder at or under `initial` (any folder when `initial` is `/`).
pub fn working_directory(target: &str, initial: &str) -> Option<String> {
    if !target.starts_with('/') {
        return None;
    }
    let path = standardize(Path::new(target));
    if !(initial == "/" || path == initial || path.starts_with(&format!("{initial}/"))) {
        return None;
    }
    Path::new(&path).is_dir().then_some(path)
}

fn standardize(path: &Path) -> String {
    let mut parts = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::ParentDir => {
                parts.pop();
            }
            Component::Normal(part) => parts.push(part),
            _ => {}
        }
    }
    parts.to_string_lossy().into_owned()
}

/// The words of a command made only of literal words: nil as soon as it holds anything a shell would expand or chain.
fn literal_shell_words(command: &str) -> Option<Vec<String>> {
    let (mut words, mut word) = (Vec::new(), String::new());
    let (mut quote, mut escaped, mut started) = (None::<char>, false, false);
    for character in command.chars() {
        if escaped {
            word.push(character);
            escaped = false;
            continue;
        }
        if quote == Some('\'') {
            if character == '\'' { quote = None } else { word.push(character) }
        } else if character == '\\' {
            escaped = true;
            started = true;
        } else if let Some(delimiter) = quote {
            if character == delimiter {
                quote = None;
            } else if character == '$' || character == '`' {
                return None;
            } else {
                word.push(character);
            }
        } else if character == '\'' || character == '"' {
            quote = Some(character);
            started = true;
        } else if character.is_whitespace() {
            if started {
                words.push(std::mem::take(&mut word));
                started = false;
            }
        } else if ";&|()<>$`*?[]{}\n\r".contains(character) {
            return None;
        } else {
            word.push(character);
            started = true;
        }
    }
    if quote.is_some() || escaped {
        return None;
    }
    if started {
        words.push(word);
    }
    Some(words)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn command(text: &str, cwd: &str) -> Object {
        json!({"type": "commandExecution", "status": "completed", "exitCode": 0, "command": text, "cwd": cwd}).as_object().unwrap().clone()
    }

    #[test]
    fn follows_a_lone_cd_inside_the_initial_folder() {
        let root = std::env::temp_dir().canonicalize().unwrap();
        let child = root.join(format!("vcx-agents-cd-{}", std::process::id()));
        std::fs::create_dir_all(&child).unwrap();
        let (root, child) = (root.to_str().unwrap(), child.to_str().unwrap());

        let moved = shell_directory(&command(&format!("/bin/zsh -lc 'cd {child}'"), root), root, root, &[]);
        let chained = shell_directory(&command(&format!("cd {child} && ls"), root), root, root, &[]);
        let outside = shell_directory(&command("cd /usr", root), root, root, &[]);

        assert_eq!(moved.as_deref(), Some(child));
        assert_eq!(chained, None);
        assert_eq!(outside, None);
        std::fs::remove_dir(child).unwrap();
    }
}
