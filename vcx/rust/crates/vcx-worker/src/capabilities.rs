//! The command palette's and the sidebar's lists, ported from `Capabilities.swift` and `ClaudeCompatibility.swift`:
//! skills, commands, hooks, MCP servers and instruction files, and what a typed skill sends to the agent.

use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::{Component, Path, PathBuf};
use vcx_agents::capabilities::{self as agent, Catalog, Provider, hook_summary};
use vcx_config::Account;

/// How deep `@` imports are followed from an instruction file, as Claude Code does.
const IMPORT_DEPTH: usize = 5;
/// vcx's own commands: a skill of the same bare name is inserted under its provider's namespace.
const APP_COMMANDS: [&str; 39] = [
    "model", "account", "perms", "dir", "window", "new", "clear", "resume", "fork", "rename", "plan", "effort", "codex", "fable", "opus",
    "reconnect", "stop", "settings", "login", "profile", "qwen", "hooks", "skills", "mcp", "instructions", "tokens", "usage", "repo", "status",
    "details", "focus", "attach", "preview", "answer", "allow", "decline", "help", "quit", "exit",
];
const CLAUDE_INSTRUCTIONS: [&str; 3] = ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"];
const CODEX_INSTRUCTIONS: [&str; 2] = ["AGENTS.md", "AGENTS.override.md"];

/// A palette entry in the Swift `ChatCommand`'s shape.
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Command {
    pub name: String,
    pub detail: String,
    pub source: String,
    pub insert: String,
    #[serde(rename = "isCurrent")]
    pub is_current: bool,
}

#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Capabilities {
    pub hooks: Vec<String>,
    pub skills: Vec<String>,
    pub builtin_commands: Vec<String>,
    pub mcp: Vec<String>,
    pub instructions: Vec<String>,
    pub skill_paths: BTreeMap<String, String>,
    /// Claude commands Codex has no skill for, sent as a prompt that runs their file.
    pub legacy_command_paths: BTreeMap<String, String>,
    pub provider_commands: Vec<Command>,
}

/// What a typed skill sends: the text, the Codex skill piece, and the text the chat shows.
#[derive(Debug, PartialEq)]
pub struct Skill {
    pub text: String,
    pub piece: Option<Value>,
    pub shown: String,
}

/// What vcx reads from his files for a provider, before the agent's own lists.
pub struct Local {
    pub instructions: Vec<String>,
    pub hooks: Vec<String>,
    pub legacy: BTreeMap<String, String>,
}

fn skill_insert(provider: &str, name: &str) -> String {
    if APP_COMMANDS.contains(&name) { format!("/{provider}:skill:{name} ") } else { format!("/{name} ") }
}

fn command(name: &str, detail: &str, source: &str, provider: &str) -> Command {
    Command { name: format!("/{name}"), detail: detail.to_owned(), source: source.to_owned(), insert: skill_insert(provider, name), is_current: false }
}

/// `/claude:skill:sm` and `/codex:sm` name the skill `/sm` names.
fn without_namespace(text: &str) -> String {
    ["/claude:", "/codex:"].iter().find_map(|prefix| text.strip_prefix(prefix)).map_or_else(|| text.to_owned(), |rest| format!("/{}", rest.strip_prefix("skill:").unwrap_or(rest)))
}

fn unavailable(error: &str) -> Vec<String> {
    vec![format!("Catalog unavailable: {error}")]
}

impl Capabilities {
    /// Claude's `vcx/catalog` (`applyClaudeCatalog`); returns the permission mode it reports.
    pub fn claude_catalog(&mut self, catalog: &Value) -> Option<String> {
        let read = agent::claude_catalog(catalog);
        if let Some(commands) = catalog["commands"].as_array() {
            self.provider_commands = commands.iter().flat_map(|entry| {
                let detail = entry["description"].as_str().unwrap_or("Claude command");
                let aliases = entry["aliases"].as_array().into_iter().flatten().filter_map(Value::as_str);
                entry["name"].as_str().into_iter().chain(aliases).map(|name| command(name, detail, "Claude", "claude")).collect::<Vec<_>>()
            }).collect();
            self.skills = read.skills;
            self.builtin_commands = read.commands;
        }
        if catalog["mcp_servers"].is_array() {
            self.mcp = read.mcp;
        }
        read.mode
    }

    /// Claude's refresh: hooks and instructions from his files, the rest from its catalog.
    pub fn claude(&mut self, local: Local, catalog: Result<Value, String>) -> Option<String> {
        self.hooks = local.hooks;
        self.instructions = local.instructions;
        match catalog {
            Ok(catalog) => self.claude_catalog(&catalog),
            Err(error) => {
                self.mcp = unavailable(&error);
                None
            }
        }
    }

    /// Any other provider's refresh. Codex's skills come with their files (`listed`, its `skills/list`), and a Claude
    /// command no skill replaces joins them; agy and Qwen say where theirs live.
    pub fn agent(&mut self, provider: Provider, local: Local, catalog: Catalog, listed: Option<&Value>) {
        (self.hooks, self.mcp) = (catalog.hooks, catalog.mcp);
        if provider != Provider::Codex {
            self.skills = catalog.skills;
            self.instructions = catalog.notes;
            return;
        }
        self.skills = catalog.skills;
        if let Some(listed) = listed {
            let entries: Vec<&Value> = listed["data"].as_array().into_iter().flatten().flat_map(|group| group["skills"].as_array().into_iter().flatten()).filter(|skill| skill["enabled"] != false).collect();
            self.skill_paths = entries.iter().filter_map(|skill| Some((skill["name"].as_str()?.to_owned(), skill["path"].as_str()?.to_owned()))).rev().collect();
            self.provider_commands = entries.iter().filter_map(|skill| Some(command(skill["name"].as_str()?, skill["description"].as_str().unwrap_or("Codex skill"), "Codex skill", "codex"))).collect();
            self.legacy_command_paths = local.legacy.into_iter().filter(|(name, _)| !self.skill_paths.contains_key(name)).collect();
            let legacy = self.legacy_command_paths.keys().map(|name| command(name, "Claude command translated for Codex", "Claude command", "codex"));
            self.provider_commands.extend(legacy);
            let names: BTreeSet<String> = entries.iter().filter_map(|skill| skill["name"].as_str().map(str::to_owned)).chain(self.legacy_command_paths.keys().cloned()).collect();
            self.skills = names.into_iter().collect();
        }
        let instructions: BTreeSet<String> = local.instructions.into_iter().collect();
        self.instructions = instructions.into_iter().collect();
    }

    /// The Swift `providerSkill` and its send: a Codex skill goes as `$name` with its skill piece, a Claude command
    /// Codex lacks as a prompt that runs its file, anything else as `/name`; the chat shows it without its namespace.
    pub fn skill(&self, provider: &str, source: &str) -> Option<Skill> {
        let (original, argument) = source.split_once(' ').map_or((source, ""), |(original, argument)| (original, argument.trim()));
        if original.starts_with("/vcx:") {
            return None;
        }
        let verb = without_namespace(original);
        let owned = original.strip_prefix('/').is_some_and(|name| APP_COMMANDS.contains(&name));
        let found = self.provider_commands.iter().find(|command| command.name == verb && (verb != original || !owned))?;
        let name = &found.name[1..];
        let shown = without_namespace(source);
        if let Some(path) = self.legacy_command_paths.get(name) {
            let text = format!("Run the Claude command /{name} from {path} using the available Codex tools. Read the complete command file first. Substitute $ARGUMENTS with the following arguments, and $1, $2, etc. with their positional values. Preserve the command's restrictions and use normal approval checks for shell commands. If an instruction cannot be enforced, stop and explain it.\nArguments: {argument}");
            return Some(Skill { text, piece: None, shown });
        }
        let prefix = if provider == "codex" { "$" } else { "/" };
        let text = if argument.is_empty() { format!("{prefix}{name}") } else { format!("{prefix}{name} {argument}") };
        let piece = self.skill_paths.get(name).map(|path| json!({"type": "skill", "name": name, "path": path}));
        Some(Skill { text, piece, shown })
    }
}

/// Codex keeps a skill prompt as the `$name` it was sent as; the chat shows the `/name` that was typed.
pub fn typed_skill(item: &mut serde_json::Map<String, Value>) {
    let Some(Value::Array(content)) = item.get_mut("content") else { return };
    let Some(name) = content.iter().find(|piece| piece["type"] == "skill").and_then(|piece| piece["name"].as_str()).map(|name| format!("${name}")) else { return };
    let typed = content.iter_mut().filter_map(|piece| piece.get_mut("text")).find(|text| text.as_str().is_some_and(|text| text == name || text.starts_with(&format!("{name} "))));
    if let Some(text) = typed {
        *text = json!(format!("/{}", &text.as_str().unwrap_or_default()[1..]));
    }
}

/// The provider's own folder: the account's, else his `~/.claude` or `~/.codex`.
pub fn provider_home(account: &Account, home: &Path) -> PathBuf {
    account.home.as_ref().map_or_else(|| home.join(if account.provider == "claude" { ".claude" } else { ".codex" }), PathBuf::from)
}

impl Local {
    /// `base` is the provider's folder, `home` his home, `flags` the settings files vcx layers over Claude's.
    pub fn read(provider: Provider, base: &Path, home: &Path, cwd: &Path, flags: &[PathBuf]) -> Self {
        let folders = folders(cwd);
        let tilde = |paths: Vec<PathBuf>| -> Vec<String> { paths.iter().map(|path| path.to_string_lossy().replace(&*home.to_string_lossy(), "~")).collect() };
        match provider {
            Provider::Claude => Self { instructions: tilde(claude_instructions(base, cwd, home)), hooks: claude_hooks(base, &folders, flags), legacy: BTreeMap::new() },
            Provider::Codex => {
                let native = std::iter::once(base.join("AGENTS.md")).chain(folders.iter().flat_map(|folder| CODEX_INSTRUCTIONS.map(|name| folder.join(name)))).filter(|path| path.exists()).collect();
                let claude = home.join(".claude");
                let instructions = tilde(native).into_iter().chain(tilde(claude_instructions(&claude, cwd, home))).collect();
                Self { instructions, hooks: Vec::new(), legacy: legacy_commands(&claude, cwd) }
            }
            Provider::Agy | Provider::Qwen => Self { instructions: Vec::new(), hooks: Vec::new(), legacy: BTreeMap::new() },
        }
    }
}

/// `path` with its `.` and `..` resolved, as `standardizedFileURL` does.
fn normalize(path: &Path) -> PathBuf {
    let mut normal = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normal.pop();
            }
            other => normal.push(other),
        }
    }
    normal
}

/// From `/` down to `cwd`.
fn folders(cwd: &Path) -> Vec<PathBuf> {
    let mut folders: Vec<PathBuf> = normalize(cwd).ancestors().map(Path::to_path_buf).collect();
    folders.reverse();
    folders
}

/// The project folders Claude reads instructions and commands from: those of `folders` but `/`.
fn project_folders(cwd: &Path) -> Vec<PathBuf> {
    folders(cwd).into_iter().filter(|folder| folder.parent().is_some()).collect()
}

/// Every file under `root` whose name ends in `.md`, sorted, symbolic links to folders not followed.
fn markdown_files(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(folder) = pending.pop() {
        for entry in std::fs::read_dir(&folder).into_iter().flatten().flatten() {
            let path = entry.path();
            if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                pending.push(path.clone());
            }
            if path.extension().is_some_and(|extension| extension == "md") {
                files.push(path);
            }
        }
    }
    files.sort();
    files
}

/// `ClaudeCompatibility.commands`: `name` or `group:name` for each command file, a project's over his own.
fn legacy_commands(claude: &Path, cwd: &Path) -> BTreeMap<String, String> {
    let roots = std::iter::once(claude.join("commands")).chain(project_folders(cwd).into_iter().map(|folder| folder.join(".claude/commands")));
    let mut commands = BTreeMap::new();
    for root in roots {
        for file in markdown_files(&root).into_iter().filter(|file| file.symlink_metadata().is_ok_and(|meta| meta.is_file())) {
            let Some(relative) = file.strip_prefix(&root).ok().and_then(Path::to_str).and_then(|relative| relative.strip_suffix(".md")) else { continue };
            commands.insert(relative.replace('/', ":"), file.to_string_lossy().into_owned());
        }
    }
    commands
}

/// The `@path` imports of an instruction file, outside code fences and inline code.
fn imports(text: &str) -> Vec<String> {
    let mut fenced = false;
    let mut found = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            fenced = !fenced;
            continue;
        }
        if fenced {
            continue;
        }
        let mut prose = String::new();
        let mut rest = line;
        while let Some((before, after)) = rest.split_once('`').and_then(|(before, after)| after.split_once('`').map(|(_, after)| (before, after))) {
            prose.push_str(before);
            rest = after;
        }
        prose.push_str(rest);
        let names = prose.split_whitespace().filter_map(|word| word.strip_prefix('@')).filter_map(|word| word.split(['`', '<', '>']).next()).filter(|name| !name.is_empty());
        found.extend(names.map(str::to_owned));
    }
    found
}

/// `ClaudeCompatibility.instructions().paths`: his and each project's CLAUDE files, their rules and what they import.
fn claude_instructions(claude: &Path, cwd: &Path, home: &Path) -> Vec<PathBuf> {
    let folders = project_folders(cwd);
    let mut loader = Loader { home, seen: HashSet::new(), paths: Vec::new() };
    loader.load(&claude.join("CLAUDE.md"), 0);
    for file in folders.iter().flat_map(|folder| CLAUDE_INSTRUCTIONS.map(|name| folder.join(name))) {
        loader.load(&file, 0);
    }
    for root in std::iter::once(claude.join("rules")).chain(folders.iter().map(|folder| folder.join(".claude/rules"))) {
        for file in markdown_files(&root) {
            loader.load(&file, 0);
        }
    }
    loader.paths
}

struct Loader<'a> {
    home: &'a Path,
    seen: HashSet<PathBuf>,
    paths: Vec<PathBuf>,
}

impl Loader<'_> {
    fn load(&mut self, file: &Path, depth: usize) {
        let resolved = std::fs::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
        if depth > IMPORT_DEPTH || self.seen.contains(&resolved) {
            return;
        }
        let Ok(text) = std::fs::read_to_string(file) else { return };
        self.seen.insert(resolved);
        self.paths.push(file.to_path_buf());
        let folder = file.parent().unwrap_or(Path::new("/")).to_path_buf();
        for name in imports(&text) {
            let expanded = match name.strip_prefix('~') {
                Some(rest) if rest.is_empty() || rest.starts_with('/') => self.home.join(rest.trim_start_matches('/')),
                _ => PathBuf::from(&name),
            };
            self.load(&normalize(&folder.join(expanded)), depth + 1);
        }
    }
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

fn hook_summaries(config: &Value, plugin: Option<&str>) -> Vec<String> {
    let Some(events) = config["hooks"].as_object() else { return Vec::new() };
    let mut names: Vec<&String> = events.keys().collect();
    names.sort();
    names.into_iter().flat_map(|event| {
        events[event].as_array().into_iter().flatten().flat_map(move |group| {
            group["hooks"].as_array().into_iter().flatten().map(move |hook| hook_summary(hook, event, group["matcher"].as_str(), plugin))
        })
    }).collect()
}

/// The Swift `claudeHooks`: his settings, each project folder's, vcx's own layered over them, then enabled plugins'.
fn claude_hooks(claude: &Path, folders: &[PathBuf], flags: &[PathBuf]) -> Vec<String> {
    let mut paths: Vec<PathBuf> = Vec::new();
    let candidates = std::iter::once(claude.join("settings.json")).chain(folders.iter().flat_map(|folder| [".claude/settings.json", ".claude/settings.local.json"].map(|name| folder.join(name)))).chain(flags.iter().cloned());
    for path in candidates.map(|path| normalize(&path)) {
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    let settings: Vec<Value> = paths.iter().filter_map(|path| read_json(path)).collect();
    let mut enabled = BTreeMap::new();
    for value in &settings {
        enabled.extend(value["enabledPlugins"].as_object().into_iter().flatten().map(|(id, on)| (id.clone(), on.as_bool() == Some(true))));
    }
    let installed = read_json(&claude.join("plugins/installed_plugins.json")).unwrap_or_default();
    let projects: HashSet<PathBuf> = folders.iter().map(|folder| normalize(folder)).collect();
    let plugins = enabled.into_iter().filter(|(_, on)| *on).flat_map(|(id, _)| {
        let entries = installed["plugins"][&id].as_array().cloned().unwrap_or_default();
        let root = entries.iter().find(|entry| entry["projectPath"].as_str().is_none_or(|project| projects.contains(&normalize(Path::new(project)))))
            .and_then(|entry| entry["installPath"].as_str().map(PathBuf::from));
        root.map(|root| plugin_hooks(&root, id.split('@').next().unwrap_or(&id))).unwrap_or_default()
    });
    let mut hooks: Vec<String> = settings.iter().flat_map(|value| hook_summaries(value, None)).collect();
    hooks.extend(plugins);
    hooks
}

fn plugin_hooks(root: &Path, name: &str) -> Vec<String> {
    let declared = read_json(&root.join(".claude-plugin/plugin.json")).map(|manifest| manifest["hooks"].clone()).unwrap_or_default();
    let named: Vec<String> = match &declared {
        Value::String(file) => vec![file.clone()],
        Value::Array(files) => files.iter().filter_map(Value::as_str).map(str::to_owned).collect(),
        _ => Vec::new(),
    };
    let mut files: Vec<PathBuf> = Vec::new();
    for file in std::iter::once("hooks/hooks.json".to_owned()).chain(named).map(|file| normalize(&root.join(file))) {
        if !files.contains(&file) {
            files.push(file);
        }
    }
    let configs = files.iter().filter_map(|file| read_json(file)).chain(declared.is_object().then_some(declared.clone()));
    configs.flat_map(|config| hook_summaries(&config, Some(name))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("vcx-capabilities-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn codex_skill(name: &str, path: Option<&str>) -> Capabilities {
        let mut capabilities = Capabilities { provider_commands: vec![command(name, "Fixture", "Codex skill", "codex")], ..Capabilities::default() };
        capabilities.skill_paths.extend(path.map(|path| (name.to_owned(), path.to_owned())));
        capabilities
    }

    #[test]
    fn sends_a_codex_skill_as_its_dollar_name_with_the_skill_piece_and_shows_the_slash() {
        let capabilities = codex_skill("sm", Some("/fixture/SKILL.md"));

        let skill = capabilities.skill("codex", "/codex:skill:sm be brief").unwrap();

        assert_eq!(skill, Skill { text: "$sm be brief".into(), piece: Some(json!({"type": "skill", "name": "sm", "path": "/fixture/SKILL.md"})), shown: "/sm be brief".into() });
    }

    #[test]
    fn runs_a_claude_command_codex_lacks_from_its_file_with_the_arguments() {
        let mut capabilities = codex_skill("release", None);
        capabilities.legacy_command_paths.insert("release".into(), "/home/.claude/commands/release.md".into());

        let skill = capabilities.skill("codex", "/claude:skill:release staging").unwrap();

        assert!(skill.text.starts_with("Run the Claude command /release from /home/.claude/commands/release.md ") && skill.text.ends_with("Arguments: staging"), "{}", skill.text);
        assert_eq!((skill.piece, skill.shown.as_str()), (None, "/release staging"));
    }

    #[test]
    fn leaves_a_bare_vcx_command_to_vcx_unless_a_namespace_names_the_skill() {
        let capabilities = codex_skill("stop", None);

        assert_eq!(capabilities.skill("codex", "/stop"), None);
        assert_eq!(capabilities.skill("codex", "/codex:stop").map(|skill| skill.text), Some("$stop".into()));
        assert_eq!(capabilities.provider_commands[0].insert, "/codex:skill:stop ");
    }

    #[test]
    fn lists_claude_commands_with_their_aliases_and_keeps_mcp_when_the_catalog_has_none() {
        let mut capabilities = Capabilities { mcp: vec!["kept".into()], ..Capabilities::default() };
        let catalog = json!({"commands": [{"name": "review", "aliases": ["rv"], "description": "Review"}, {"name": "compact", "builtin": true}], "current_permission_mode": "default"});

        let mode = capabilities.claude_catalog(&catalog);

        let names: Vec<&str> = capabilities.provider_commands.iter().map(|command| command.name.as_str()).collect();
        assert_eq!(names, ["/review", "/rv", "/compact"]);
        assert_eq!((capabilities.skills, capabilities.builtin_commands, capabilities.mcp, mode), (vec!["review".into()], vec!["compact".into()], vec!["kept".into()], Some("ask".into())));
    }

    #[test]
    fn shows_a_codex_skill_prompt_from_history_as_typed() {
        let mut item = json!({"type": "userMessage", "content": [{"type": "text", "text": "$sm be brief"}, {"type": "skill", "name": "sm", "path": "/p"}]});

        typed_skill(item.as_object_mut().unwrap());

        assert_eq!(item["content"][0]["text"], "/sm be brief");
    }

    #[test]
    fn follows_instruction_imports_and_rules_once_each_but_not_inside_code() {
        let root = folder("instructions");
        let (claude, project) = (root.join(".claude"), root.join("work/app"));
        write(&claude.join("CLAUDE.md"), "Rules @~/.claude/ERRORS.md and `@ignored.md`\n```\n@fenced.md\n```\n");
        write(&claude.join("ERRORS.md"), "@CLAUDE.md");
        write(&claude.join("ignored.md"), "");
        write(&claude.join("rules/style.md"), "");
        write(&project.join("CLAUDE.md"), "");

        let paths = claude_instructions(&claude, &project, &root);

        assert_eq!(paths, [claude.join("CLAUDE.md"), claude.join("ERRORS.md"), project.join("CLAUDE.md"), claude.join("rules/style.md")]);
    }

    #[test]
    fn reads_hooks_from_settings_and_enabled_plugins_and_commands_by_their_folder() {
        let root = folder("hooks");
        let (claude, plugin) = (root.join(".claude"), root.join("plugin"));
        let hook = |command: &str| json!({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": command}]}]}});
        let mut settings = hook("python3 /hooks/gateguard.py");
        settings["enabledPlugins"] = json!({"tool@market": true, "off@market": false});
        write(&claude.join("settings.json"), &settings.to_string());
        write(&claude.join("plugins/installed_plugins.json"), &json!({"plugins": {"tool@market": [{"installPath": plugin}]}}).to_string());
        write(&plugin.join("hooks/hooks.json"), &hook("bash /p/check.sh").to_string());
        write(&claude.join("commands/frontend/review.md"), "");

        let hooks = claude_hooks(&claude, &folders(&root), &[]);
        let commands = legacy_commands(&claude, &root);

        assert_eq!(hooks.len(), 2, "{hooks:?}");
        assert!(hooks[0].starts_with("gateguard.py · PreToolUse") && hooks[1].ends_with("Plugin: tool"), "{hooks:?}");
        assert_eq!(commands.keys().collect::<Vec<_>>(), ["frontend:review"]);
    }
}
