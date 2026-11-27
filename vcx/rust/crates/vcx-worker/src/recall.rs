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
    if rules.is_empty() || limit == 0 || minimum.is_nan() {
        return Vec::new();
    }

    let mut query = std::collections::HashMap::new();
    for_each_word_key(prompt, |key| {
        let next = query.len();
        query.entry(key).or_insert(next);
    });
    if query.is_empty() {
        return Vec::new();
    }

    let scores = scores(&query, rules);
    let mut kept: Vec<usize> = (0..rules.len()).filter(|&rule| scores[rule] >= minimum).collect();
    let compare = |&left: &usize, &right: &usize| {
        scores[right].total_cmp(&scores[left]).then_with(|| left.cmp(&right))
    };
    if kept.len() > limit {
        kept.select_nth_unstable_by(limit, compare);
        kept.truncate(limit);
    }
    kept.sort_unstable_by(compare);
    kept.into_iter().map(|rule| rules[rule].clone()).collect()
}

const QUERY_SLOTS: usize = 1024;
const QUERY_COLLISION: u64 = 1 << (u64::BITS - 1);
const QUERY_KEY_BITS: u32 = STEM_LENGTH as u32 * u8::BITS;
const QUERY_KEY_MASK: u64 = (1 << QUERY_KEY_BITS) - 1;
const QUERY_MAX_INLINE_TERM: usize = ((QUERY_COLLISION - 1) >> QUERY_KEY_BITS) as usize;

#[inline]
fn query_slot(key: u64) -> usize {
    const HASH_MULTIPLIER: u64 = 0x9e37_79b9_7f4a_7c15;
    const SHIFT: u32 = u64::BITS - QUERY_SLOTS.trailing_zeros();
    (key.wrapping_mul(HASH_MULTIPLIER) >> SHIFT) as usize
}

fn scores(query: &std::collections::HashMap<u64, usize>, rules: &[String]) -> Vec<f64> {
    let slots = query_slots(query);
    let (postings, mut lengths, total) = postings(&slots, query, rules);
    let count = rules.len() as f64;
    let average = total as f64 / count;
    let mut scores = vec![0.0; rules.len()];
    if total == 0 {
        return scores;
    }
    for norm in &mut lengths {
        if *norm != 0.0 {
            *norm = K1 * ((1.0 - B) + B * *norm / average);
        }
    }
    for matches in postings.into_iter().filter(|matches| !matches.is_empty()) {
        let found = matches.len() as f64;
        let idf = (1.0 + (count - found + 0.5) / (found + 0.5)).ln();
        for (rule, frequency) in matches {
            let frequency = frequency as f64;
            scores[rule] += idf * frequency * K1_PLUS_ONE / (frequency + lengths[rule]);
        }
    }
    scores
}

/// One slot per query word: its key in the low bits and its term above, or the collision bit that sends a lookup to
/// the map.
fn query_slots(query: &std::collections::HashMap<u64, usize>) -> [u64; QUERY_SLOTS] {
    let mut slots = [0_u64; QUERY_SLOTS];
    for (&key, &term) in query {
        let slot = &mut slots[query_slot(key)];
        if *slot & QUERY_KEY_MASK == 0 && term <= QUERY_MAX_INLINE_TERM {
            *slot |= key | ((term as u64) << QUERY_KEY_BITS);
        } else {
            *slot |= QUERY_COLLISION;
        }
    }
    slots
}

/// For each query term, the rules holding it with its frequency there; each rule's word count, zero when it matched
/// nothing (its norm is never read); and the words of all rules.
fn postings(
    slots: &[u64; QUERY_SLOTS],
    query: &std::collections::HashMap<u64, usize>,
    rules: &[String],
) -> (Vec<Vec<(usize, usize)>>, Vec<f64>, usize) {
    let mut postings: Vec<Vec<(usize, usize)>> = vec![Vec::new(); query.len()];
    let mut lengths = Vec::with_capacity(rules.len());
    let mut total = 0;
    for (rule, text) in rules.iter().enumerate() {
        let mut length = 0;
        let mut matched = false;
        for_each_word_key(text, |key| {
            length += 1;
            let stored = slots[query_slot(key)];
            let term = if stored & QUERY_KEY_MASK == key {
                ((stored & !QUERY_COLLISION) >> QUERY_KEY_BITS) as usize
            } else if stored & QUERY_COLLISION != 0 {
                let Some(&term) = query.get(&key) else {
                    return;
                };
                term
            } else {
                return;
            };
            matched = true;
            let matches = &mut postings[term];
            match matches.last_mut() {
                Some((last_rule, frequency)) if *last_rule == rule => *frequency += 1,
                _ => matches.push((rule, 1)),
            }
        });
        lengths.push(if matched { length as f64 } else { 0.0 });
        total += length;
    }
    (postings, lengths, total)
}

const CHUNK_BYTES: usize = std::mem::size_of::<u64>();
const BYTE_BITS: usize = u8::BITS as usize;
const BYTE_ONES: u64 = u64::from_le_bytes([1; CHUNK_BYTES]);
const HIGH_BITS: u64 = BYTE_ONES * 0x80;
const LOWERCASE_BITS: u64 = BYTE_ONES * b' ' as u64;

/// What `words` keeps, each word packed little-endian into a key, without building a String: the text is scanned eight
/// bytes at a time.
fn for_each_word_key(text: &str, mut emit: impl FnMut(u64)) {
    let lower;
    // Only the Kelvin sign lowercases to an ASCII letter; the i of a lowercase İ is dropped by its combining dot anyway.
    let text = if !text.is_ascii() && text.contains('\u{212A}') {
        lower = text.to_lowercase();
        lower.as_str()
    } else {
        text
    };
    let bytes = text.as_bytes();
    let mut remaining = bytes;
    while let Some((&first, tail)) = remaining.split_first() {
        if !first.is_ascii_alphanumeric() {
            remaining = tail;
            continue;
        }
        let (folded, mut length) = ascii_run(load(bytes, remaining));
        if length == CHUNK_BYTES {
            let tail = &remaining[CHUNK_BYTES..];
            length += tail.iter().position(|byte| !byte.is_ascii_alphanumeric()).unwrap_or(tail.len());
        }
        remaining = &remaining[length..];
        if let Some((&separator, tail)) = remaining.split_first() {
            if !separator.is_ascii()
                && (MINIMUM_WORD_LENGTH..=STEM_LENGTH).contains(&length)
                && text[text.len() - remaining.len()..].chars().next().is_some_and(extends)
            {
                length -= 1;
            }
            remaining = tail;
        }
        if length >= STEM_LENGTH {
            emit(folded & QUERY_KEY_MASK);
        } else if length >= MINIMUM_WORD_LENGTH {
            let key = folded & ((1_u64 << (length * BYTE_BITS)) - 1);
            if !is_stop_word(key) {
                emit(key);
            }
        }
    }
}

/// The eight bytes `remaining` starts with, zeros past the end of the text.
#[inline]
fn load(bytes: &[u8], remaining: &[u8]) -> u64 {
    if let Some(&chunk) = remaining.first_chunk::<CHUNK_BYTES>() {
        u64::from_le_bytes(chunk)
    } else if let Some(&chunk) = bytes.last_chunk::<CHUNK_BYTES>() {
        u64::from_le_bytes(chunk) >> ((CHUNK_BYTES - remaining.len()) * BYTE_BITS)
    } else {
        let mut chunk = [0; CHUNK_BYTES];
        chunk[..remaining.len()].copy_from_slice(remaining);
        u64::from_le_bytes(chunk)
    }
}

/// The eight bytes lowercased, and how many ASCII letters or digits they start with (eight: the run may go on).
#[inline]
fn ascii_run(packed: u64) -> (u64, usize) {
    let low = packed & !HIGH_BITS;
    let folded = low | LOWERCASE_BITS;
    // Digits are tested before folding: folding turns control bytes 0x10 to 0x19 into ASCII digits.
    let digits = (low + BYTE_ONES * (0x80 - b'0' as u64)) & !(low + BYTE_ONES * (0x7f - b'9' as u64));
    let letters = (folded + BYTE_ONES * (0x80 - b'a' as u64)) & !(folded + BYTE_ONES * (0x7f - b'z' as u64));
    let separators = HIGH_BITS & (packed | !(digits | letters));
    (folded, separators.trailing_zeros() as usize / BYTE_BITS)
}

const STOP_SLOTS: usize = 512;
const STOP_MASK: usize = STOP_SLOTS - 1;
const STOP_HASH_START: u64 = 0x9e37_79b9_7f4a_7c15;
const STOP_HASH_STEP: u64 = 0x517c_c1b7_2722_0a94;
const STOP_HASH_ATTEMPTS: usize = 64;

#[inline]
const fn stop_slot(key: u64, multiplier: u64) -> usize {
    const SHIFT: u32 = u64::BITS - STOP_SLOTS.trailing_zeros();
    (key.wrapping_mul(multiplier) >> SHIFT) as usize
}

const fn stop_table(multiplier: u64) -> ([u64; STOP_SLOTS], bool) {
    assert!(STOP.len() < STOP_SLOTS);
    let mut slots = [0; STOP_SLOTS];
    let mut collision = false;
    let mut index = 0;
    while index < STOP.len() {
        let word = STOP[index].as_bytes();
        assert!(!word.is_empty() && word.len() < STEM_LENGTH);
        let mut key = 0;
        let mut offset = 0;
        while offset < word.len() {
            key |= (word[offset] as u64) << (offset * u8::BITS as usize);
            offset += 1;
        }

        let mut slot = stop_slot(key, multiplier);
        while slots[slot] != 0 && slots[slot] != key {
            collision = true;
            slot = (slot + 1) & STOP_MASK;
        }
        slots[slot] = key;
        index += 1;
    }
    (slots, collision)
}

const STOP_HASH: (u64, [u64; STOP_SLOTS], bool) = {
    let mut multiplier = STOP_HASH_START;
    let mut attempt = 0;
    loop {
        let (slots, collision) = stop_table(multiplier);
        attempt += 1;
        if !collision || attempt == STOP_HASH_ATTEMPTS {
            break (multiplier, slots, collision);
        }
        multiplier = multiplier.wrapping_add(STOP_HASH_STEP);
    }
};

#[inline]
fn is_stop_word(key: u64) -> bool {
    let mut slot = stop_slot(key, STOP_HASH.0);
    let mut stored = STOP_HASH.1[slot];
    if STOP_HASH.2 {
        while stored != 0 && stored != key {
            slot = (slot + 1) & STOP_MASK;
            stored = STOP_HASH.1[slot];
        }
    }
    stored == key
}

/// Swift splits on grapheme clusters: an ASCII letter a combining mark extends is no longer ASCII, so it ends the word.
/// The reference `for_each_word_key` is tested against.
#[cfg(test)]
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

    #[test]
    fn packs_the_same_words_as_the_reference_tokenizer() {
        let traps = [
            "Never scrolling the Committed e\u{301}x", "\u{212a}elvin \u{212a}\u{212a} sign", "\u{130}stanbul DOTTED \u{130}I",
            "abcdefgh\u{300} ab\u{301} abcdef\u{301}", "ctrl\u{10}\u{19}bytes 0123\u{7f}", "CRLF line\r\nbuild\r\n", "never an the",
            "\u{ff46}\u{ff55}ll width", "emoji 👍🏽 test 👩‍💻 commit", "", "x", "abcdefghijklmnop", "tail1234567",
        ];

        for trap in traps {
            let mut keys = Vec::new();
            for_each_word_key(trap, |key| keys.push(key));
            let packed: Vec<u64> = words(trap).iter().map(|word| u64::from_le_bytes(std::array::from_fn(|index| word.as_bytes().get(index).copied().unwrap_or(0)))).collect();

            assert_eq!(keys, packed, "{trap:?}");
        }
    }
}
