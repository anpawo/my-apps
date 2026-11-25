//! What Qwen's turn loop decides from text alone, as the `qwen…` functions of `Agents.swift` do.

use crate::Object;
use serde_json::{Value, json};
use std::path::Path;

/// Qwen's window holds prompt and answer together: at 8192 tokens, 41 messages of tool output took 8106 of them and
/// it answered nothing (07/11). 65536 paged the 8 GB PC; he picked 32768 (7.12 GB, 6.2 tokens/s) on 21/11.
pub const WINDOW: usize = 32768;
/// 8K characters is about 3K tokens: one output cannot fill the window by itself.
pub const TOOL_OUTPUT_LIMIT: usize = 8000;
/// What the transcript shows of a command's output.
pub const SHOWN_OUTPUT_LIMIT: usize = 32768;
/// `ErrorsRecall`'s note appended to a prompt; the project is picked from the words before it.
const RECALL_MARKER: &str = "VCX note, not part of the request:";

/// Head and tail of a long output; `dropped` counts what the reader already left out of the middle.
pub fn tool_output(text: &str, dropped: usize, limit: usize) -> String {
    let count = text.chars().count();
    if count + dropped <= limit {
        return text.to_owned();
    }
    let head: String = text.chars().take(limit / 2).collect();
    let tail: String = text.chars().skip(count.saturating_sub(limit / 2)).collect();
    format!("{head}\n[… {} characters cut from the middle of this output …]\n{tail}", count + dropped - limit)
}

/// prompt_eval_count can leave out a prompt Ollama had cached, so the history's size (about 2.8 bytes of JSON per
/// token) backs it up; at 75 % the rest of the window still holds a step's outputs and the answer.
pub fn needs_compaction(tokens: usize, bytes: usize, window: usize) -> bool {
    tokens.max(bytes / 3) >= window * 3 / 4
}

pub fn repeats(commands: &[String]) -> bool {
    commands.len() >= 3 && commands[commands.len() - 3..].iter().all(|command| *command == commands[commands.len() - 1])
}

fn role(message: &Object) -> &str {
    message.get("role").and_then(Value::as_str).unwrap_or_default()
}

/// System prompt, the task's request word for word, the summary, then the last step as it came.
pub fn compacted(messages: &[Object], request: &Object, summary: &str) -> Vec<Object> {
    let from = messages.iter().rposition(|message| role(message) == "assistant").unwrap_or(messages.len());
    let last = messages[from..].iter().filter(|message| *message != request).cloned();
    let note = format!("Summary of the work so far (VCX compacted the earlier messages to fit your context):\n\n{summary}");
    let summary = json!({"role": "user", "content": note}).as_object().cloned().unwrap_or_default();
    [messages[0].clone(), request.clone(), summary].into_iter().chain(last).collect()
}

fn size(messages: &[&Object]) -> usize {
    serde_json::to_vec(messages).map_or(0, |bytes| bytes.len())
}

/// About 2.5 bytes per window token leaves room for the system prompt and an answer. Oldest messages go first; the
/// request in progress stays.
pub fn history(messages: &[Object], limit: usize) -> Vec<Object> {
    if messages.len() <= 2 {
        return messages.to_vec();
    }
    let task = messages.iter().rposition(|message| role(message) == "user").unwrap_or(1).max(1);
    let (mut before, mut after): (Vec<&Object>, Vec<&Object>) = (messages[1..task].iter().collect(), messages[task..].iter().collect());
    let total = |before: &[&Object], after: &[&Object]| size(&[&[&messages[0]][..], before, after].concat());
    while total(&before, &after) > limit && !before.is_empty() {
        before.remove(0);
    }
    while before.first().is_some_and(|message| role(message) == "tool") {
        before.remove(0);
    }
    while total(&before, &after) > limit && after.len() > 2 {
        after.remove(1);
        while after.len() > 2 && role(after[1]) == "tool" {
            after.remove(1);
        }
    }
    std::iter::once(&messages[0]).chain(before).chain(after).cloned().collect()
}

pub fn strip_recall(text: &str) -> &str {
    text.find(RECALL_MARKER).map_or(text, |at| text[..at].trim())
}

/// Qwen reads no CLAUDE.md and the 8B model chains `cd x && …` into wrong folders, so VCX picks the one `~/self`
/// project the first request names: a folder, a Mac app (my-apps) or Qwen's own words.
pub fn project(text: &str, cwd: &str, home: &Path) -> Option<String> {
    let root = home.join("self");
    let root_text = root.to_string_lossy();
    if cwd.starts_with(&format!("{root_text}/")) {
        return None;
    }
    let lower = text.to_lowercase();
    let named = |word: &str| {
        let word = word.to_lowercase();
        let part = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-';
        lower.match_indices(&word).any(|(at, _)| {
            let before = lower[..at].chars().next_back();
            let after = lower[at + word.len()..].chars().next();
            !before.is_some_and(part) && !after.is_some_and(part)
        })
    };
    let folders = |path: &Path| -> Vec<String> {
        std::fs::read_dir(path).into_iter().flatten().flatten().filter(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            !name.starts_with('.') && entry.file_type().is_ok_and(|kind| kind.is_dir())
        }).map(|entry| entry.file_name().to_string_lossy().into_owned()).collect()
    };
    // Word match only; "temp" and "archive" are everyday words, not projects to work in.
    let mut hits: std::collections::BTreeSet<String> = folders(&root).into_iter().filter(|name| !["temp", "archive"].contains(&name.as_str()) && named(name)).collect();
    if folders(&root.join("my-apps")).iter().any(|name| named(name)) {
        hits.insert("my-apps".into());
    }
    if ["qwen", "llama.cpp", "llama", "ollama", "fuse", "gguf"].iter().any(|word| named(word)) {
        hits.insert("qwen".into());
    }
    (hits.len() == 1).then(|| format!("{root_text}/{}", hits.into_iter().next().unwrap_or_default()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(role: &str, content: &str) -> Object {
        json!({"role": role, "content": content}).as_object().cloned().unwrap()
    }

    #[test]
    fn cuts_the_middle_of_a_long_output_and_counts_what_was_dropped() {
        let text = "a".repeat(10) + &"b".repeat(10);

        let cut = tool_output(&text, 5, 10);

        assert_eq!(cut, "aaaaa\n[… 15 characters cut from the middle of this output …]\nbbbbb");
        assert_eq!(tool_output("short", 0, 10), "short");
    }

    #[test]
    fn pauses_on_the_third_identical_command_in_a_row() {
        let twice = ["ls".to_owned(), "ls".to_owned()];
        let thrice = ["pwd".to_owned(), "ls".to_owned(), "ls".to_owned(), "ls".to_owned()];

        assert!(!repeats(&twice));
        assert!(repeats(&thrice));
    }

    #[test]
    fn compacts_at_three_quarters_of_the_window_by_tokens_or_bytes() {
        assert!(!needs_compaction(24_575, 0, WINDOW));
        assert!(needs_compaction(24_576, 0, WINDOW));
        assert!(needs_compaction(0, 24_576 * 3, WINDOW));
    }

    #[test]
    fn keeps_system_request_summary_and_last_step_when_compacting() {
        let request = message("user", "fix it");
        let messages = [message("system", "s"), request.clone(), message("assistant", "a1"), message("tool", "t1"), message("assistant", "a2"), message("tool", "t2")];

        let kept = compacted(&messages, &request, "did a1");

        let roles: Vec<&str> = kept.iter().map(role).collect();
        assert_eq!(roles, ["system", "user", "user", "assistant", "tool"]);
        assert_eq!(kept[3]["content"], "a2");
    }

    #[test]
    fn drops_the_oldest_messages_first_and_keeps_the_request_in_progress() {
        let filler = "x".repeat(400);
        let messages = [message("system", "s"), message("user", "old"), message("tool", &filler), message("assistant", &filler), message("user", "now"), message("tool", &filler), message("assistant", "last")];

        let kept = history(&messages, 400);

        let contents: Vec<&str> = kept.iter().map(|m| m["content"].as_str().unwrap()).collect();
        assert_eq!(contents, ["s", "now", "last"]);
    }

    #[test]
    fn picks_the_one_project_a_request_names() {
        let home = std::env::temp_dir().join(format!("vcx-qwen-home-{}", std::process::id()));
        for folder in ["self/vcx-site", "self/my-apps/fleet", "self/temp"] {
            std::fs::create_dir_all(home.join(folder)).unwrap();
        }

        let site = project("fix the vcx-site footer", "/tmp", &home);
        let app = project("why does fleet crash", "/tmp", &home);
        let both = project("vcx-site and fleet", "/tmp", &home);
        let inside = project("fleet", &format!("{}/self/my-apps", home.display()), &home);
        let word = project("put it in temp", "/tmp", &home);

        assert_eq!(site, Some(format!("{}/self/vcx-site", home.display())));
        assert_eq!(app, Some(format!("{}/self/my-apps", home.display())));
        assert_eq!((both, inside, word), (None, None, None));
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn reads_the_request_before_the_recall_note() {
        assert_eq!(strip_recall("fix fleet\n\nVCX note, not part of the request: past mistakes"), "fix fleet");
    }
}
