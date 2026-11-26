//! The ERRORS lines a prompt recalls, as `ErrorsRecall` and `ErrorsRank` of the Swift app do: Marius's ERRORS files
//! hold his agents' past mistakes, and each prompt carries the few lines that share its words, ranked by BM25.

use std::path::{Path, PathBuf};

/// Starts the note a prompt carries; a conversation read back from its provider shows the prompt without it.
pub const MARKER: &str = "VCX note, not part of the request:";
pub const LIMIT: usize = 4;
pub const MINIMUM_SCORE: f64 = 6.0;
/// Six letters stand in for a stemmer: scroll and scrolling, commit and committed meet.
const STEM_LENGTH: usize = 6;
const MINIMUM_WORD_LENGTH: usize = 2;
const K1: f64 = 1.2;
const K1_PLUS_ONE: f64 = 2.2;
const B: f64 = 0.75;
const FILE_NAMES: [&str; 2] = ["ERRORS.md", "ERRORS.tools.md"];
const RULE_PREFIX: &str = "- ";
const HEADING_PREFIX: &str = "## ";
const STOP: &[&str] = &[
    "a", "an", "the", "of", "to", "in", "on", "and", "or", "is", "are", "be", "it", "its", "for", "with", "by", "from", "at", "as", "that",
    "this", "not", "never", "no", "his", "him", "he", "my", "me", "what", "when", "one",
];

pub fn recall(prompt: &str, cwd: &Path, home: &Path) -> Vec<String> {
    rank(prompt, &rules(cwd, home), LIMIT, MINIMUM_SCORE)
}

/// The heading a rule's line sits under says what it is for ("Shell and quoting").
pub fn section(rule: &str, cwd: &Path, home: &Path) -> Option<String> {
    let wanted = format!("{RULE_PREFIX}{rule}");
    for path in files(cwd, home) {
        let text = read(&path);
        let mut heading = "";
        for line in text.split('\n') {
            if let Some(name) = line.strip_prefix(HEADING_PREFIX) {
                heading = name;
            } else if line == wanted {
                return (!heading.is_empty()).then(|| heading.to_owned());
            }
        }
    }
    None
}

pub fn note(lines: &[String]) -> String {
    if lines.is_empty() {
        return String::new();
    }
    let listed: Vec<String> = lines.iter().map(|line| format!("{RULE_PREFIX}{line}")).collect();
    format!("{MARKER} past mistakes from Marius's ERRORS files that may apply to it.\n{}", listed.join("\n"))
}

pub fn lines(text: &str) -> Vec<String> {
    let Some(at) = text.find(MARKER) else { return Vec::new() };
    text[at + MARKER.len()..].split('\n').filter_map(|line| line.strip_prefix(RULE_PREFIX)).map(str::to_owned).collect()
}

/// The global files, then each folder's from `cwd` up to `home`, home itself left out.
fn files(cwd: &Path, home: &Path) -> Vec<PathBuf> {
    let claude = home.join(".claude");
    let mut found: Vec<PathBuf> = FILE_NAMES.iter().map(|name| claude.join(name)).collect();
    let home = resolved(home);
    let mut directory = Some(resolved(cwd));
    while let Some(folder) = directory.take().filter(|folder| folder.starts_with(&home) && *folder != home) {
        found.extend(FILE_NAMES.iter().map(|name| folder.join(name)));
        directory = folder.parent().map(Path::to_path_buf);
    }
    found
}

fn resolved(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

fn rules(cwd: &Path, home: &Path) -> Vec<String> {
    files(cwd, home)
        .iter()
        .flat_map(|path| read(path).split('\n').filter_map(|line| line.strip_prefix(RULE_PREFIX)).map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

/// Rules scoring at least `minimum`, best first, an earlier rule first on a tie.
pub fn rank(prompt: &str, rules: &[String], limit: usize, minimum: f64) -> Vec<String> {
    let mut query: Vec<String> = Vec::new();
    for word in words(prompt) {
        if !query.contains(&word) {
            query.push(word);
        }
    }
    if rules.is_empty() || limit == 0 || query.is_empty() {
        return Vec::new();
    }
    let scores = scores(&query, rules);
    let mut kept: Vec<usize> = (0..rules.len()).filter(|&rule| scores[rule] >= minimum).collect();
    kept.sort_by(|&left, &right| scores[right].total_cmp(&scores[left]));
    kept.into_iter().take(limit).map(|rule| rules[rule].clone()).collect()
}

fn scores(query: &[String], rules: &[String]) -> Vec<f64> {
    let tokens: Vec<Vec<String>> = rules.iter().map(|rule| words(rule)).collect();
    let count = rules.len() as f64;
    let average = tokens.iter().map(Vec::len).sum::<usize>() as f64 / count;
    let mut scores = vec![0.0; rules.len()];
    for term in query {
        let frequencies: Vec<(usize, f64)> = tokens
            .iter()
            .enumerate()
            .filter_map(|(rule, words)| {
                let frequency = words.iter().filter(|word| *word == term).count();
                (frequency > 0).then_some((rule, frequency as f64))
            })
            .collect();
        let found = frequencies.len() as f64;
        let idf = (1.0 + (count - found + 0.5) / (found + 0.5)).ln();
        for (rule, frequency) in frequencies {
            let norm = K1 * ((1.0 - B) + B * tokens[rule].len() as f64 / average);
            scores[rule] += idf * frequency * K1_PLUS_ONE / (frequency + norm);
        }
    }
    scores
}

/// Swift splits on grapheme clusters: an ASCII letter a combining mark extends is no longer ASCII, so it ends the word.
fn words(text: &str) -> Vec<String> {
    let lower: Vec<char> = text.to_lowercase().chars().collect();
    let mut words = Vec::new();
    let mut word = String::new();
    for (index, &character) in lower.iter().enumerate() {
        let extended = lower.get(index + 1).is_some_and(|&next| extends(next));
        if character.is_ascii_alphanumeric() && !extended {
            word.push(character);
            continue;
        }
        if word.len() >= MINIMUM_WORD_LENGTH && !STOP.contains(&word.as_str()) {
            words.push(word[..word.len().min(STEM_LENGTH)].to_owned());
        }
        word.clear();
    }
    if word.len() >= MINIMUM_WORD_LENGTH && !STOP.contains(&word.as_str()) {
        words.push(word[..word.len().min(STEM_LENGTH)].to_owned());
    }
    words
}

fn extends(character: char) -> bool {
    matches!(character,
        '\u{0300}'..='\u{036F}' | '\u{1AB0}'..='\u{1AFF}' | '\u{1DC0}'..='\u{1DFF}' | '\u{200D}' | '\u{20D0}'..='\u{20FF}'
        | '\u{FE00}'..='\u{FE0F}' | '\u{FE20}'..='\u{FE2F}' | '\u{1F3FB}'..='\u{1F3FF}' | '\u{E0020}'..='\u{E007F}' | '\u{E0100}'..='\u{E01EF}')
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Enough unrelated lines that a word only one rule holds weighs past `MINIMUM_SCORE`.
    const FILLER_RULES: usize = 60;
    const COMMIT_RULE: &str = "01/11: Read back each commit before the push.";
    const LAUNCH_RULE: &str = "03/11: Launch agents are loaded within 30 s.";

    struct Home(PathBuf);

    impl Home {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!("vcx-worker-recall-{}-{name}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).unwrap();
            Home(root)
        }

        fn write(&self, relative: &str, text: &str) -> PathBuf {
            let path = self.0.join(relative);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, text).unwrap();
            path
        }

        fn folder(&self, relative: &str) -> PathBuf {
            let path = self.0.join(relative);
            fs::create_dir_all(&path).unwrap();
            path
        }
    }

    impl Drop for Home {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn with_rules(name: &str) -> Home {
        let home = Home::new(name);
        let filler = format!("## Habits\n{}", "- 05/10: Water the green plants every single morning before work.\n".repeat(FILLER_RULES));
        home.write(".claude/ERRORS.md", &filler);
        home.write(".claude/ERRORS.tools.md", &format!("## Git\n- {COMMIT_RULE}\n- 02/11: A screenshot waits for the window to load.\n"));
        home.write("self/app/ERRORS.md", &format!("## Launchd\n- {LAUNCH_RULE}\n"));
        home
    }

    #[test]
    fn recalls_the_rule_that_shares_the_prompts_words() {
        let home = with_rules("matching");
        let cwd = home.folder("self/app");

        let recalled = recall("commit and push the git fix", &cwd, &home.0);

        assert_eq!(recalled, vec![COMMIT_RULE.to_owned()]);
    }

    #[test]
    fn recalls_nothing_for_a_prompt_sharing_no_word() {
        let home = with_rules("unrelated");
        let cwd = home.folder("self/app");

        let recalled = recall("hi there", &cwd, &home.0);

        assert!(recalled.is_empty());
    }

    #[test]
    fn ranks_a_project_rule_only_from_inside_the_project() {
        let home = with_rules("project");
        let inside = home.folder("self/app/src");
        let elsewhere = home.folder("self/other");

        let from_inside = rank("add a launch agent", &rules(&inside, &home.0), LIMIT, 1.0);
        let from_elsewhere = rank("add a launch agent", &rules(&elsewhere, &home.0), LIMIT, 1.0);

        assert_eq!(from_inside, vec![LAUNCH_RULE.to_owned()]);
        assert!(from_elsewhere.is_empty());
    }

    #[test]
    fn names_the_section_of_a_rule_from_the_home_file() {
        let home = with_rules("home-section");
        let cwd = home.folder("self/app");

        let named = section(COMMIT_RULE, &cwd, &home.0);

        assert_eq!(named.as_deref(), Some("Git"));
    }

    #[test]
    fn names_the_section_of_a_rule_from_a_project_file_up_the_cwd_chain() {
        let home = with_rules("project-section");
        let cwd = home.folder("self/app/src/deep");

        let named = section(LAUNCH_RULE, &cwd, &home.0);

        assert_eq!(named.as_deref(), Some("Launchd"));
    }

    #[test]
    fn names_no_section_for_a_rule_under_no_heading() {
        let home = Home::new("no-heading");
        home.write(".claude/ERRORS.md", "# Errors\n- 24/11: A rule before any heading.\n## Later\n- 25/11: Another.\n");
        let cwd = home.folder("self");

        let named = section("24/11: A rule before any heading.", &cwd, &home.0);

        assert_eq!(named, None);
    }

    #[test]
    fn reads_back_the_lines_of_its_note() {
        let recalled = vec![COMMIT_RULE.to_owned(), "02/11: Wait for the window.".to_owned()];

        let text = format!("Fix it\n{}", note(&recalled));

        assert_eq!(lines(&text), recalled);
        assert_eq!(note(&[]), "");
    }

    #[test]
    fn cuts_words_to_six_letters_and_drops_stop_words() {
        let cut = words("Never scrolling the Committed e\u{301}x");

        assert_eq!(cut, vec!["scroll", "commit"]);
    }
}
