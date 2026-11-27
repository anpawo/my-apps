//! What the transcript shows for one item, ported from `Item` in the Swift `Session.swift`.

use crate::state::Object;
use serde_json::Value;
use std::path::Path;
use std::borrow::Cow;

/// Tool output shown in the transcript; the complete output stays in the provider's own history.
const MAX_OUTPUT_CHARS: usize = 16_384;
const OUTPUT_KEYS: [&str; 5] = ["aggregatedOutput", "result", "error", "contentItems", "output"];
const FILE_INPUT_KEYS: [&str; 2] = ["file_path", "notebook_path"];
const SUMMARY_INPUT_KEYS: [&str; 5] = ["description", "pattern", "url", "query", "skill"];

/// The scripts that run a round between models from a session; their output holds each turn after a `<<debate <speaker> [model]>>` line.
const DEBATE_SCRIPTS: [&str; 7] = ["ask-codex.sh", "ask-qwen.sh", "ask-agy.sh", "ask-gemini.sh", "ask-grok.sh", "ask-muse.sh", "ask-meta.sh"];
const DEBATE_HEAD: &str = "<<debate ";
const DEBATE_TAIL: &str = ">>";

#[derive(Debug, PartialEq)]
pub struct DebateTurn {
    pub speaker: String,
    pub model: String,
    pub text: String,
}

pub fn debate_turns(output: &str) -> Vec<DebateTurn> {
    let mut turns = Vec::new();
    let mut head: Option<(String, String)> = None;
    let mut lines: Vec<&str> = Vec::new();
    let mut close = |head: &Option<(String, String)>, lines: &mut Vec<&str>| {
        if let Some((speaker, model)) = head {
            turns.push(DebateTurn { speaker: speaker.clone(), model: model.clone(), text: lines.join("\n").trim().to_owned() });
        }
        lines.clear();
    };
    for line in output.split('\n') {
        match line.strip_prefix(DEBATE_HEAD).and_then(|rest| rest.strip_suffix(DEBATE_TAIL)) {
            Some(words) => {
                close(&head, &mut lines);
                let (speaker, model) = words.split_once(' ').unwrap_or((words, ""));
                let speaker = if speaker.is_empty() { "agent".to_owned() } else { speaker.to_lowercase() };
                head = Some((speaker, model.to_owned()));
            }
            None if head.is_some() => lines.push(line),
            None => {}
        }
    }
    close(&head, &mut lines);
    turns
}

/// The kind a row is drawn as, ported from `Row.kind` in the Swift `Session.swift`: a lone debate command that emitted
/// turns is a debate; reads and edits that only mention a debate script stay activity.
pub fn row_kind<'a>(stored: &'a str, items: &[&Object]) -> &'a str {
    if !matches!(stored, "activity" | "debate") {
        return stored;
    }
    let Some(item) = items.first() else { return stored };
    if (items.len() != 1 && stored != "debate") || kind(item) != "commandExecution" {
        return stored;
    }
    let command = text(item, "command").unwrap_or_default();
    if !command.match_indices("ask-").any(|(start, _)| {
        DEBATE_SCRIPTS.iter().any(|script| command[start..].starts_with(script))
    }) {
        return stored;
    }
    if items.len() != 1 || debate_turns(&output(item)).is_empty() { "activity" } else { "debate" }
}

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
    let suffix = item.get("exitCode").and_then(Value::as_i64)
        .map(|code| format!("\nExit: {code}"));
    let extra = suffix.as_ref().map_or(0, String::len);
    let mut shown = match kind(item) {
        "fileChange" => output_tail(changes(item).rev()
            .filter_map(|change| text(change, "diff")).map(Cow::Borrowed), extra),
        "reasoning" => output_tail(item.get("summary").and_then(Value::as_array)
            .into_iter().flatten().rev().filter_map(Value::as_str).map(Cow::Borrowed), extra),
        _ => output_tail(OUTPUT_KEYS.iter().rev().filter_map(|key| item.get(*key))
            .filter(|value| !value.is_null()).map(plain), extra),
    };
    if let Some(suffix) = suffix {
        shown.push_str(&suffix);
    }
    shown
}

fn plain(value: &Value) -> Cow<'_, str> {
    match value {
        Value::String(text) => Cow::Borrowed(text),
        other => Cow::Owned(serde_json::to_string_pretty(other).unwrap_or_default()),
    }
}

/// The last `MAX_OUTPUT_CHARS` chars of the parts joined by newlines, read from the end
/// (`parts` comes last first), with room for `extra` more bytes.
fn output_tail<'a>(parts: impl Iterator<Item = Cow<'a, str>>, extra: usize) -> String {
    let mut parts = parts.peekable();
    let Some(last) = parts.next() else { return String::new() };
    if let Some(start) = tail_start(&last, MAX_OUTPUT_CHARS) {
        return with_room(&last[start..], extra);
    }
    if parts.peek().is_none() {
        return match last {
            Cow::Borrowed(tail) => with_room(tail, extra),
            Cow::Owned(tail) => tail,
        };
    }
    let mut remaining = MAX_OUTPUT_CHARS - last.chars().count();
    let mut kept = vec![(last, 0)];
    for part in parts {
        if remaining == 0 {
            break;
        }
        remaining -= 1;
        if remaining == 0 {
            kept.push((Cow::Borrowed(""), 0));
            break;
        }
        if let Some(start) = tail_start(&part, remaining) {
            kept.push((part, start));
            break;
        }
        remaining -= part.chars().count();
        kept.push((part, 0));
    }
    join_last_first(kept, extra)
}

/// Byte index where the last `count` chars of `part` start, or `None` when all of it fits.
fn tail_start(part: &str, count: usize) -> Option<usize> {
    if part.len() <= count {
        return None;
    }
    let mut start = part.len() - count;
    if part.as_bytes()[start..].is_ascii() {
        return Some(start);
    }
    while !part.is_char_boundary(start) {
        start += 1;
    }
    let missing = count - part[start..].chars().count();
    part[..start].char_indices().nth_back(missing - 1).map(|(index, _)| index)
}

fn join_last_first(kept: Vec<(Cow<'_, str>, usize)>, extra: usize) -> String {
    let bytes = kept.iter().map(|(part, start)| part.len() - start + 1).sum::<usize>() - 1;
    let mut shown = String::with_capacity(bytes + extra);
    for (position, (part, start)) in kept.iter().rev().enumerate() {
        if position != 0 {
            shown.push('\n');
        }
        shown.push_str(&part[*start..]);
    }
    shown
}

fn with_room(tail: &str, extra: usize) -> String {
    let mut shown = String::with_capacity(tail.len() + extra);
    shown.push_str(tail);
    shown
}

fn changes(item: &Object) -> impl DoubleEndedIterator<Item = &Object> {
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
    fn keeps_the_newline_when_the_cut_falls_on_the_separator() {
        let last = "b".repeat(MAX_OUTPUT_CHARS - 1);
        let item = object(json!({"type": "fileChange", "changes": [{"diff": "a"}, {"diff": last}]}));

        let shown = output(&item);

        assert_eq!(shown, format!("\n{last}"));
    }

    #[test]
    fn drops_earlier_parts_when_the_last_one_fills_the_output() {
        let last = "y".repeat(MAX_OUTPUT_CHARS);
        let item = object(json!({"type": "fileChange", "changes": [{"diff": "early"}, {"diff": last}]}));

        let shown = output(&item);

        assert_eq!(shown, last);
    }

    #[test]
    fn keeps_the_last_characters_across_many_multibyte_diffs() {
        let diffs: Vec<String> = (0..9).map(|index| format!("{index}{}", "é".repeat(3_000))).collect();
        let item = object(json!({"type": "fileChange", "changes": diffs.iter().map(|diff| json!({"diff": diff})).collect::<Vec<_>>()}));
        let joined = diffs.join("\n");
        let expected: String = joined.chars().skip(joined.chars().count() - MAX_OUTPUT_CHARS).collect();

        let shown = output(&item);

        assert_eq!(shown, expected);
    }

    #[test]
    fn pretty_prints_a_part_that_is_not_a_string() {
        let item = object(json!({"type": "commandExecution", "aggregatedOutput": "out", "contentItems": [1, 2]}));

        let shown = output(&item);

        assert_eq!(shown, "out\n[\n  1,\n  2\n]");
    }

    #[test]
    fn appends_no_exit_line_for_an_exit_code_that_is_not_an_integer() {
        let float = object(json!({"type": "commandExecution", "aggregatedOutput": "x", "exitCode": 1.5}));
        let string = object(json!({"type": "commandExecution", "aggregatedOutput": "x", "exitCode": "2"}));

        let shown = (output(&float), output(&string));

        assert_eq!(shown, ("x".to_owned(), "x".to_owned()));
    }

    #[test]
    fn reads_each_turn_of_a_debate_with_its_speaker_and_model() {
        let output = "preamble\n<<debate Claude>>\nmy point\n\n<<debate codex gpt-6.2 sol>>\nits answer\n";

        let turns = debate_turns(output);

        assert_eq!(turns, vec![
            DebateTurn { speaker: "claude".into(), model: String::new(), text: "my point".into() },
            DebateTurn { speaker: "codex".into(), model: "gpt-6.2 sol".into(), text: "its answer".into() },
        ]);
    }

    #[test]
    fn draws_a_lone_debate_command_with_turns_as_a_debate() {
        let debate = object(json!({"type": "commandExecution", "command": "~/bin/ask-codex.sh brief.md", "aggregatedOutput": "<<debate codex>>\nyes"}));
        let mention = object(json!({"type": "commandExecution", "command": "cat ask-codex.sh", "aggregatedOutput": "no turns"}));
        let other = object(json!({"type": "commandExecution", "command": "ls"}));

        assert_eq!(row_kind("activity", &[&debate]), "debate");
        assert_eq!(row_kind("debate", &[&mention]), "activity");
        assert_eq!(row_kind("debate", &[&debate, &other]), "activity");
        assert_eq!(row_kind("activity", &[&other]), "activity");
        assert_eq!(row_kind("user", &[&debate]), "user");
    }

    #[test]
    fn joins_the_diffs_of_a_file_change() {
        let item = object(json!({"type": "fileChange", "changes": [{"path": "/a/x.rs", "diff": "+1"}, {"path": "/a/y.rs", "diff": "-2"}]}));

        assert_eq!(title(&item), "Edit x.rs, y.rs");
        assert_eq!(output(&item), "+1\n-2");
    }
}
