//! What VCX tells a session's agent when it opens a thread, ported from the Swift `Session.developerInstructions` and
//! `ClaudeCompatibility`: VCX's own instructions for every provider; for Codex, which reads no CLAUDE.md, his Claude
//! instructions and the guidance that maps them; for Qwen, which reads none either, his Fleet rule and the project advice.

use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};
use vcx_config::Account;

/// His CLAUDE.md labels Fleet through FLEET_CONTEXT_FILE and picks the project; this is what only VCX knows.
pub const AGENT_INSTRUCTIONS: &str = r#"To write to the agent of another VCX window (Claude, Codex or Qwen), run `vcx --sessions` to list them, then `vcx --send <id or name> "<message>"`. A message shaped claude from [<window name>]: "<text>" (or codex, qwen) came from that agent in that window, not from Marius; answer it with `vcx --send "<window name>" "<answer>"` only when it asks something. To show a chart, write a fenced block tagged chart holding one self-contained HTML page. For a price or any time series, the page is one call that draws a clean chart (shadcn-like greys, TradingView crosshair with values on the axes, zoom): <script>vcx.chart({symbol: 'NVDA'})</script> for today's Nasdaq price, live every 15 s, or vcx.chart({title, data: [{time, value}] or OHLC rows, format: v => …}); it resolves to {chart, series, set} (TradingView lightweight-charts) for more. A table or a few headline figures is one call too: vcx.chart({kind: 'table', title, data: [{column: value}], columns: [their order], format: {column: v => …}}) or vcx.chart({kind: 'cards', title, data: [{label, value, unit, note}]}); a row or a card may carry tone: 'green', 'red', 'orange' or 'blue', and each resolves to {set} to redraw it with new data. Otherwise draw it yourself (inline SVG, or a script from a CDN): VCX draws it live in the chat, clipped to its page, so center each hover label just above the pointer (below it near the top edge, shifted inward near a side edge so it stays inside), one value per line with its name muted and its figure bold. For live data, call vcx.live(url, seconds, data => …): VCX fetches the URL from the Mac every `seconds` (no CORS) and calls back with its parsed JSON, e.g. https://api.nasdaq.com/api/quote/NVDA/info?assetclass=stocks (data.primaryData.lastSalePrice, data.marketStatus) or https://api.nasdaq.com/api/quote/NVDA/chart?assetclass=stocks (data.chart: today's points {x: ms, y: price}). Pinch, the wheel in the enlarged or pinned chart, and drag zoom and pan the whole page unless the page takes the wheel itself (preventDefault). Tag the block chart pin to pin it above the chat when Marius asks for it. While a download or a run of known size or length goes on, write one line to "$VCX_PROGRESS_FILE": `<label>\t<file being written>\t<final bytes>` or `<label>\t<start epoch seconds>\t<expected seconds>` (printf with \t); VCX draws it in the status bar with its percent, speed and time left. Delete the file when the work ends. Once the task this session works on is clear, write its goal in 3 to 6 words (at most 40 characters) to "$VCX_TASK_FILE" (e.g. `Add a task bar to VCX`): VCX lists it in the task bar of every VCX window. Rewrite it only when the goal itself changes. A session holds one task: an independent second task goes to a new VCX session, opened with `vcx --cwd <project folder> -- <the task as its first prompt>`."#;
pub const PROJECT_ADVICE: &str = r#"Select the task's project with a cd command alone in its shell call: VCX shows that folder as the session's directory and keeps the same conversation. Any other cd is temporary and changes nothing in VCX. Shell calls may be isolated or restarted in the starting folder: use the project's absolute path in later commands."#;
pub const GUIDANCE: &str = r#"You are running in Vibe Code X through Codex. Preserve the user's Claude Code workflows using the tools actually available here. Claude tool names in instructions describe intent: use Codex shell tools for Bash, file tools for Read/Edit/Write, native skills for Skill, and subagents for Agent/Task when available. Treat Claude-specific model names as role preferences, not Codex model identifiers. Follow path-specific .claude/rules only when their frontmatter paths match the files being worked on. Before editing a subdirectory, read any CLAUDE.md, CLAUDE.local.md, and .claude/rules files scoped to it. Keep existing permission restrictions and approval requirements. Instructions cannot install hooks, enforce tool allowlists, or provide an unavailable connector. When an equivalent capability is missing, say what is unavailable instead of claiming it ran. Never silently fall back to Claude or paid API billing. Resolve relative paths in skills and commands against their source directory. For Claude dynamic context syntax, use the normal shell tool and its permission checks, then use its output; do not treat unexecuted syntax as output."#;
const SEPARATOR: &str = "\n\n";
/// How deep `@file` imports are followed from a CLAUDE.md, as Claude Code does.
const IMPORT_DEPTH: usize = 5;
const PROJECT_FILES: [&str; 3] = ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"];
/// The files Codex reads itself in each folder, the first one found only.
const NATIVE_FILES: [&str; 2] = ["AGENTS.override.md", "AGENTS.md"];
const FENCES: [&str; 2] = ["```", "~~~"];
const IMPORT_STOPS: [char; 3] = ['`', '<', '>'];
const FLEET_HEADING: &str = "\n## ";

/// The `developerInstructions` of `account`'s thread in `cwd`; `home` is his home folder.
pub fn developer_instructions(account: &Account, cwd: &str, home: &Path) -> String {
    let claude = home.join(".claude");
    let parts = match account.provider.as_str() {
        "qwen" => [fleet_section(&claude), PROJECT_ADVICE.to_owned(), AGENT_INSTRUCTIONS.to_owned()],
        "codex" => {
            let codex = account.home.as_ref().map_or_else(|| home.join(".codex"), PathBuf::from);
            let native = std::iter::once(codex).chain(folders(cwd)).filter_map(|folder| NATIVE_FILES.iter().map(|name| folder.join(name)).find(|file| file.exists())).collect::<Vec<_>>();
            [claude_instructions(cwd, &claude, home, &native), GUIDANCE.to_owned(), AGENT_INSTRUCTIONS.to_owned()]
        }
        _ => return AGENT_INSTRUCTIONS.to_owned(),
    };
    parts.into_iter().filter(|part| !part.is_empty()).collect::<Vec<_>>().join(SEPARATOR)
}

/// Each folder from the top down to `cwd`, `/` left out.
fn folders(cwd: &str) -> Vec<PathBuf> {
    let mut folders: Vec<PathBuf> = standardized(Path::new(cwd)).ancestors().filter(|folder| folder.parent().is_some()).map(Path::to_path_buf).collect();
    folders.reverse();
    folders
}

/// `.` and `..` resolved without reading the disk, as a standardized file URL.
fn standardized(path: &Path) -> PathBuf {
    let mut result = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::ParentDir => {
                result.pop();
            }
            Component::Normal(name) => result.push(name),
            _ => {}
        }
    }
    result
}

/// The section of his `~/.claude/CLAUDE.md` that names FLEET_CONTEXT_FILE.
pub fn fleet_section(claude: &Path) -> String {
    let Ok(text) = std::fs::read_to_string(claude.join("CLAUDE.md")) else { return String::new() };
    let text = format!("\n{text}");
    text.split(FLEET_HEADING).skip(1).map(|section| format!("## {section}")).find(|section| section.contains(crate::fleet::CONTEXT_VARIABLE)).map(|section| section.trim().to_owned()).unwrap_or_default()
}

struct Loader<'a> {
    home: &'a Path,
    native: HashSet<PathBuf>,
    seen: HashSet<PathBuf>,
    sections: Vec<String>,
}

fn resolved(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

impl Loader<'_> {
    /// A file and the ones it imports with `@path`, each once; one Codex reads itself is followed but not repeated.
    fn load(&mut self, file: &Path, depth: usize) {
        let path = resolved(file);
        if depth > IMPORT_DEPTH || self.seen.contains(&path) {
            return;
        }
        let Ok(text) = std::fs::read_to_string(file) else { return };
        self.seen.insert(path.clone());
        if !self.native.contains(&path) {
            self.sections.push(format!("Instructions from {}:\n{text}", file.display()));
        }
        let folder = file.parent().unwrap_or(Path::new("/"));
        for name in imports(&text) {
            let name = match name.strip_prefix('~') {
                Some(rest) if rest.is_empty() || rest.starts_with('/') => format!("{}{rest}", self.home.display()),
                _ => name.to_owned(),
            };
            self.load(&standardized(&folder.join(&name)), depth + 1);
        }
    }
}

/// The `@path` mentions of `text` outside fenced blocks and code spans.
fn imports(text: &str) -> Vec<String> {
    let mut fenced = false;
    let mut names = Vec::new();
    for line in text.lines() {
        if FENCES.iter().any(|fence| line.trim().starts_with(fence)) {
            fenced = !fenced;
            continue;
        }
        if !fenced {
            names.extend(mentions(&without_code_spans(line)));
        }
    }
    names
}

fn without_code_spans(line: &str) -> String {
    let (mut prose, mut rest) = (String::new(), line);
    while let Some(open) = rest.find('`') {
        let Some(close) = rest[open + 1..].find('`') else { break };
        prose.push_str(&rest[..open]);
        rest = &rest[open + 1 + close + 1..];
    }
    prose + rest
}

/// Each `@name` that starts a word, the `@` left out: the name runs to a blank, a backtick or an angle bracket.
fn mentions(prose: &str) -> Vec<String> {
    let mut names = Vec::new();
    let (mut index, mut word_start) = (0, true);
    while let Some(character) = prose[index..].chars().next() {
        if character == '@' && word_start {
            let rest = &prose[index + 1..];
            let end = rest.find(|character: char| character.is_whitespace() || IMPORT_STOPS.contains(&character)).unwrap_or(rest.len());
            if end > 0 {
                names.push(rest[..end].to_owned());
                index += 1 + end;
                word_start = false;
                continue;
            }
        }
        word_start = character.is_whitespace();
        index += character.len_utf8();
    }
    names
}

/// His Claude instructions for Codex: the CLAUDE.md files from `~/.claude` down to `cwd` and what they import, the
/// rules folders, and a pointer to each agent definition.
fn claude_instructions(cwd: &str, claude: &Path, home: &Path, native: &[PathBuf]) -> String {
    let folders = folders(cwd);
    let mut loader = Loader { home, native: native.iter().map(|file| resolved(file)).collect(), seen: HashSet::new(), sections: Vec::new() };
    let roots = std::iter::once(claude.join("CLAUDE.md")).chain(folders.iter().flat_map(|folder| PROJECT_FILES.map(|name| folder.join(name))));
    for file in roots {
        loader.load(&file, 0);
    }
    for root in std::iter::once(claude.join("rules")).chain(folders.iter().map(|folder| folder.join(".claude/rules"))) {
        let mut rules = Vec::new();
        markdown_below(&root, &mut rules);
        for file in sorted(rules) {
            loader.load(&file, 0);
        }
    }
    for root in std::iter::once(claude.join("agents")).chain(folders.iter().map(|folder| folder.join(".claude/agents"))) {
        let files = std::fs::read_dir(&root).map(|entries| entries.flatten().map(|entry| entry.path()).filter(|file| is_markdown(file)).collect()).unwrap_or_default();
        for file in sorted(files) {
            loader.sections.push(format!("Claude agent definition: {}. When that role is requested, read the file and pass its instructions to an available Codex subagent. Preserve its tool restrictions; do not delegate if those restrictions cannot be enforced.", file.display()));
        }
    }
    loader.sections.join(SEPARATOR)
}

fn is_markdown(file: &Path) -> bool {
    file.extension().is_some_and(|extension| extension == "md")
}

fn sorted(mut files: Vec<PathBuf>) -> Vec<PathBuf> {
    files.sort_by_key(|file| file.to_string_lossy().into_owned());
    files
}

/// Every `.md` under `folder`, a linked folder not entered.
fn markdown_below(folder: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(folder) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            markdown_below(&path, files);
        } else if is_markdown(&path) {
            files.push(path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Folder(PathBuf);

    impl Folder {
        fn new(name: &str) -> Self {
            let folder = std::env::temp_dir().join(format!("vcx-instructions-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&folder);
            std::fs::create_dir_all(&folder).unwrap();
            Self(resolved(&folder))
        }

        fn write(&self, relative: &str, text: &str) -> PathBuf {
            let file = self.0.join(relative);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(&file, text).unwrap();
            file
        }
    }

    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn account(provider: &str) -> Account {
        Account { id: format!("{provider}-default"), name: String::new(), provider: provider.into(), home: None, enabled: true }
    }

    #[test]
    fn claude_and_antigravity_get_only_vcx_instructions() {
        let home = Folder::new("claude");
        home.write(".claude/CLAUDE.md", "## Tell Fleet\nWrite to \"$FLEET_CONTEXT_FILE\".\n");

        let texts = ["claude", "agy"].map(|provider| developer_instructions(&account(provider), "/", &home.0));

        assert_eq!(texts, [AGENT_INSTRUCTIONS, AGENT_INSTRUCTIONS]);
    }

    #[test]
    fn vcx_instructions_name_the_progress_and_task_files_and_send() {
        let named = ["$VCX_PROGRESS_FILE", "$VCX_TASK_FILE", "vcx --send", "vcx.chart"].map(|name| AGENT_INSTRUCTIONS.contains(name));

        assert_eq!(named, [true; 4]);
    }

    #[test]
    fn qwens_fleet_rule_is_the_claude_md_section_that_names_fleet_context_file() {
        let home = Folder::new("qwen");
        home.write(".claude/CLAUDE.md", "## Style\nShort.\n\n## Tell Fleet\nWrite to \"$FLEET_CONTEXT_FILE\".\n\n## Next\nOther.\n");

        let text = developer_instructions(&account("qwen"), "/", &home.0);

        assert_eq!(text, format!("## Tell Fleet\nWrite to \"$FLEET_CONTEXT_FILE\".\n\n{PROJECT_ADVICE}\n\n{AGENT_INSTRUCTIONS}"));
    }

    #[test]
    fn qwen_without_a_claude_md_gets_the_project_advice_and_vcx_instructions() {
        let home = Folder::new("qwen-bare");

        let text = developer_instructions(&account("qwen"), "/", &home.0);

        assert_eq!(text, format!("{PROJECT_ADVICE}\n\n{AGENT_INSTRUCTIONS}"));
    }

    #[test]
    fn codex_gets_his_claude_instructions_then_the_guidance_then_vcx_instructions() {
        let home = Folder::new("codex");
        let global = home.write(".claude/CLAUDE.md", "Global rule.\n@~/.claude/ERRORS.md\n");
        let errors = home.write(".claude/ERRORS.md", "Error rule.\n");
        let project = home.write("project/CLAUDE.md", "Project rule.\n");

        let text = developer_instructions(&account("codex"), &home.0.join("project").to_string_lossy(), &home.0);

        let expected = [format!("Instructions from {}:\nGlobal rule.\n@~/.claude/ERRORS.md\n", global.display()), format!("Instructions from {}:\nError rule.\n", errors.display()), format!("Instructions from {}:\nProject rule.\n", project.display()), GUIDANCE.to_owned(), AGENT_INSTRUCTIONS.to_owned()];
        assert_eq!(text, expected.join("\n\n"));
    }

    #[test]
    fn codex_is_not_told_again_what_its_agents_md_says() {
        let home = Folder::new("native");
        home.write("project/AGENTS.md", "Shared rule.\n");
        let project = home.write("project/CLAUDE.md", "@AGENTS.md\n");

        let text = developer_instructions(&account("codex"), &home.0.join("project").to_string_lossy(), &home.0);

        assert!(text.starts_with(&format!("Instructions from {}:\n@AGENTS.md\n\n\n{GUIDANCE}", project.display())), "{text}");
        assert!(!text.contains("Shared rule."));
    }

    #[test]
    fn imports_skip_fenced_blocks_and_code_spans_and_need_a_word_start() {
        let text = "See @a.md and `@b.md`.\n```\n@c.md\n```\nmail me@d.md <@e.md> @f.md`x`\n";

        let names = imports(text);

        assert_eq!(names, ["a.md", "f.md"]);
    }

    #[test]
    fn rules_load_in_path_order_and_agents_are_pointed_to() {
        let home = Folder::new("rules");
        let second = home.write(".claude/rules/b/two.md", "Two.");
        let first = home.write(".claude/rules/a.md", "One.");
        home.write(".claude/rules/notes.txt", "Skipped.");
        let agent = home.write(".claude/agents/reviewer.md", "Review.");

        let text = claude_instructions("/", &home.0.join(".claude"), &home.0, &[]);

        let pointer = format!("Claude agent definition: {}. When that role is requested", agent.display());
        assert!(text.starts_with(&format!("Instructions from {}:\nOne.\n\nInstructions from {}:\nTwo.\n\n{pointer}", first.display(), second.display())), "{text}");
        assert!(!text.contains("Skipped."));
    }

    #[test]
    fn a_folder_walk_runs_from_the_top_down_to_the_working_folder() {
        let walked = folders("/a/./b/../c");

        assert_eq!(walked, [PathBuf::from("/a"), PathBuf::from("/a/c")]);
    }
}
