//! What the transcript shows for one item, ported from `Item` in the Swift `Session.swift`.

use crate::state::Object;
use serde_json::Value;
use std::path::Path;

/// Tool output shown in the transcript; the complete output stays in the provider's own history.
const MAX_OUTPUT_CHARS: usize = 16_384;
const OUTPUT_KEYS: [&str; 5] = ["aggregatedOutput", "result", "error", "contentItems", "output"];
const FILE_INPUT_KEYS: [&str; 2] = ["file_path", "notebook_path"];
const SUMMARY_INPUT_KEYS: [&str; 5] = ["description", "pattern", "url", "query", "skill"];

pub fn kind(item: &Object) -> &str {
    text(item, "type").unwrap_or("activity")
}

pub fn failed(item: &Object) -> bool {
    matches!(text(item, "status"), Some("failed" | "declined"))
        || item.get("success") == Some(&Value::Bool(false))
        || item.get("error").is_some_and(|error| !error.is_null())
        || item.get("exitCode").and_then(Value::as_i64).unwrap_or(0) != 0
}

pub fn title(item: &Object) -> String {
    match kind(item) {
        "commandExecution" => command_title(item),
        "fileChange" => format!("Edit {}", changes(item).filter_map(|change| text(change, "path")).map(file_name).collect::<Vec<_>>().join(", ")),
        "mcpToolCall" | "dynamicToolCall" => ["server", "namespace", "tool"].iter().filter_map(|key| text(item, key)).collect::<Vec<_>>().join("."),
        "webSearch" => format!("Search: {}", text(item, "query").unwrap_or("web")),
        "peerMessage" => {
            let verb = match (text(item, "direction") == Some("sent"), failed(item)) {
                (true, true) => "Not sent to ",
                (true, false) => "Sent to ",
                (false, _) => "Message from ",
            };
            format!("{verb}{}", text(item, "name").unwrap_or("another session"))
        }
        "reasoning" => text(item, "description").unwrap_or("Thinking").to_owned(),
        other => spaced_words(other),
    }
}

fn command_title(item: &Object) -> String {
    if let Some(name) = text(item, "description").filter(|name| !name.is_empty()) {
        return name.to_owned();
    }
    let command = text(item, "command").unwrap_or("Command");
    let Some((first, rest)) = command.split_once('\n') else { return command.to_owned() };
    // Claude's other tools arrive as their name above their JSON input.
    let Ok(Value::Object(input)) = serde_json::from_str(rest) else { return first.to_owned() };
    let file = FILE_INPUT_KEYS.iter().find_map(|key| text(&input, key)).map(file_name);
    match file.or_else(|| SUMMARY_INPUT_KEYS.iter().find_map(|key| text(&input, key))) {
        Some(detail) => format!("{first} {detail}"),
        None => first.to_owned(),
    }
}

pub fn output(item: &Object) -> String {
    let parts: Vec<String> = match kind(item) {
        "fileChange" => changes(item).filter_map(|change| text(change, "diff")).map(str::to_owned).collect(),
        "reasoning" => item.get("summary").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect(),
        _ => OUTPUT_KEYS.iter().filter_map(|key| item.get(*key)).filter(|value| !value.is_null()).map(plain).collect(),
    };
    let joined = parts.join("\n");
    let skipped = joined.chars().count().saturating_sub(MAX_OUTPUT_CHARS);
    let mut shown: String = joined.chars().skip(skipped).collect();
    if let Some(code) = item.get("exitCode").and_then(Value::as_i64) {
        shown.push_str(&format!("\nExit: {code}"));
    }
    shown
}

fn plain(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => serde_json::to_string_pretty(other).unwrap_or_default(),
    }
}

fn changes(item: &Object) -> impl Iterator<Item = &Object> {
    item.get("changes").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_object)
}

fn file_name(path: &str) -> &str {
    Path::new(path).file_name().and_then(|name| name.to_str()).unwrap_or(path)
}

/// `commandExecution` reads "Command Execution".
fn spaced_words(kind: &str) -> String {
    let mut words = String::with_capacity(kind.len() + 4);
    let mut previous_lower = false;
    for (index, letter) in kind.chars().enumerate() {
        if letter.is_ascii_uppercase() && previous_lower {
            words.push(' ');
        }
        previous_lower = letter.is_ascii_lowercase();
        if index == 0 { words.extend(letter.to_uppercase()) } else { words.push(letter) }
    }
    words
}

pub(crate) fn text<'a>(object: &'a Object, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn object(value: Value) -> Object {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn titles_a_claude_tool_by_its_name_and_file() {
        let item = object(json!({"type": "commandExecution", "command": "Read\n{\"file_path\": \"/a/b/main.swift\"}"}));

        assert_eq!(title(&item), "Read main.swift");
    }

    #[test]
    fn titles_a_shell_command_by_its_description_when_it_has_one() {
        let item = object(json!({"type": "commandExecution", "command": "ls -la", "description": "List files"}));

        assert_eq!(title(&item), "List files");
    }

    #[test]
    fn titles_an_unknown_kind_by_its_spaced_name() {
        let item = object(json!({"type": "contextCompaction"}));

        assert_eq!(title(&item), "Context Compaction");
    }

    #[test]
    fn marks_a_command_failed_when_its_exit_code_is_not_zero() {
        let item = object(json!({"type": "commandExecution", "exitCode": 2, "error": null}));

        assert!(failed(&item));
    }

    #[test]
    fn does_not_mark_a_command_failed_on_a_null_error() {
        let item = object(json!({"type": "commandExecution", "exitCode": 0, "error": null}));

        assert!(!failed(&item));
    }

    #[test]
    fn keeps_the_end_of_a_long_output_and_appends_the_exit_code() {
        let long = "x".repeat(MAX_OUTPUT_CHARS) + "END";
        let item = object(json!({"type": "commandExecution", "aggregatedOutput": long, "exitCode": 0}));

        let shown = output(&item);

        assert!(shown.ends_with("END\nExit: 0"));
        assert_eq!(shown.chars().count(), MAX_OUTPUT_CHARS + "\nExit: 0".len());
    }

    #[test]
    fn joins_the_diffs_of_a_file_change() {
        let item = object(json!({"type": "fileChange", "changes": [{"path": "/a/x.rs", "diff": "+1"}, {"path": "/a/y.rs", "diff": "-2"}]}));

        assert_eq!(title(&item), "Edit x.rs, y.rs");
        assert_eq!(output(&item), "+1\n-2");
    }
}
