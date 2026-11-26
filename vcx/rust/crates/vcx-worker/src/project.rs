//! The project a session works in, as the Swift `Session` follows it (Directory.swift, `routeProject`): the project a
//! turn edited files in, the folders his Claude settings add, and the project the first prompt of a window opened at
//! `/` or `~` is about, which Haiku picks. A `cd` is read by `vcx_agents::directory`.

use crate::provider;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;
use vcx_agents::directory::working_directory;
use vcx_config::Account;

/// Haiku through his `claude`, as the Swift router runs it.
pub const ROUTER: [&str; 2] = ["/usr/bin/env", "claude"];
const ROUTER_ARGUMENTS: [&str; 11] = ["--model", "haiku", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands", "--tools", "", "--no-session-persistence", "--output-format", "text"];
/// Haiku answers in 2 to 3 s; one that hangs is stopped and the prompt starts at `/`.
const ROUTE_TIMEOUT: Duration = Duration::from_secs(10);
const FIRST_PROMPT_CHARS: usize = 4000;
const LATER_PROMPT_CHARS: usize = 1000;
const LATER_PROMPTS: usize = 5;
const SKILL_DESCRIPTION_CHARS: usize = 160;
const DESCRIPTION: &str = "description:";
const ANSWER_TRIM: &str = "`'\"/.";
/// Fleet would take a `claude` carrying it for the window's own shell; the Fleet files are never passed.
const FLEET_SHELL: &str = "FLEET_SHELL";
pub const SELF_FOLDER: &str = "self";
const RULES: &str = "Pick the project folder under ~/self that this chat is about. <request> is the first message of a new chat window and weighs most; <later> holds the messages that followed, if any. They rarely name their folder: judge from what they talk about.
Reply with the folder's path relative to ~/self and nothing else (e.g. s14/stele, my-apps/vcx, epitech), or none. When a sub-folder row fits, reply the sub-folder, not its parent.
A message, mail or call about a project's work (someone's message about the ledger, a reply on a recon break) belongs to that project.
Reply none when the request is general (a question, an errand, mail, money, papers, the Mac itself), spans several folders, or when you are unsure: a wrong folder is worse than none.
The chat window is VCX (my-apps/vcx). Fleet (my-apps/fleet) is the separate board that shows every session as a card, in groups, beside his mail, todos and crons: a request about those cards, groups or that board is my-apps/fleet.
Folders, one per row:
";

/// The folders his Claude settings add (`permissions.additionalDirectories`): Claude Code keeps a `cd` that ends in one.
pub fn added_directories(home: &Path) -> Vec<String> {
    let Some(Value::Object(settings)) = std::fs::read(home.join(".claude/settings.json")).ok().and_then(|data| serde_json::from_slice(&data).ok()) else { return Vec::new() };
    let added = settings.get("permissions").and_then(|permissions| permissions.get("additionalDirectories")).and_then(Value::as_array);
    added.into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect()
}

fn standardized(path: &str) -> String {
    let mut parts = PathBuf::from("/");
    for component in Path::new(path).components() {
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

fn parent(path: &str) -> String {
    Path::new(path).parent().map_or_else(String::new, |parent| parent.to_string_lossy().into_owned())
}

/// The nearest folder above `path` holding `.git`, or its `.fleet` sub-folder `path` is in (an empty `.fleet` names
/// the root); none at or above `home`.
fn project_root(path: &str, home: &str) -> Option<String> {
    let mut folder = standardized(path);
    while folder != "/" && folder != home {
        if Path::new(&folder).join(".git").exists() {
            let fleet = std::fs::read_to_string(Path::new(&folder).join(".fleet")).unwrap_or_default();
            let inside = |sub: &String| path == sub || path.starts_with(&format!("{sub}/"));
            let subs: Vec<String> = fleet.split('\n').map(str::trim).filter(|sub| !sub.is_empty()).map(|sub| format!("{folder}/{sub}")).collect();
            return Some(subs.into_iter().find(inside).unwrap_or(folder));
        }
        folder = parent(&folder);
    }
    None
}

/// The project a turn edited files in (`edits`, in order): the git root or `.fleet` sub-folder edited most, the latest
/// on a tie, kept only inside `initial` or an added folder; none when the session already stands in it.
pub fn turn_directory(edits: &[String], current: &str, initial: &str, added: &[String], home: &str) -> Option<String> {
    let (mut counts, mut roots) = (HashMap::<String, (usize, usize)>::new(), HashMap::<String, Option<String>>::new());
    let allowed: Vec<&str> = std::iter::once(initial).chain(added.iter().map(String::as_str)).collect();
    for (index, path) in edits.iter().enumerate() {
        let root = roots.entry(parent(path)).or_insert_with(|| project_root(path, home)).clone();
        let Some(root) = root.filter(|root| allowed.iter().any(|within| working_directory(root, within).is_some())) else { continue };
        let count = counts.entry(root).or_insert((0, index));
        *count = (count.0 + 1, index);
    }
    let best = counts.into_iter().max_by_key(|(_, count)| *count)?.0;
    (current != best && !current.starts_with(&format!("{best}/"))).then_some(best)
}

/// `name: description`, the description cut to its first characters; a folded block (`>-`, `|`) carries it on the
/// indented lines under.
fn skill_line(name: &str, text: &str) -> Option<String> {
    let lines: Vec<&str> = text.split('\n').collect();
    let at = lines.iter().position(|line| line.starts_with(DESCRIPTION))?;
    let mut value = lines[at][DESCRIPTION.len()..].trim().to_owned();
    if value.is_empty() || value.starts_with('>') || value.starts_with('|') {
        value = lines[at + 1..].iter().take_while(|line| line.starts_with(' ')).map(|line| line.trim()).collect::<Vec<_>>().join(" ");
    }
    Some(format!("{name}: {}", value.chars().take(SKILL_DESCRIPTION_CHARS).collect::<String>()))
}

/// His skills, whose descriptions carry the words a project's tasks come in ("recon", "Middle Office": s14).
fn skills(home: &Path) -> String {
    let folder = home.join(".claude/skills");
    let mut names: Vec<String> = std::fs::read_dir(&folder).into_iter().flatten().flatten().map(|entry| entry.file_name().to_string_lossy().into_owned()).collect();
    names.sort();
    let lines = names.iter().filter_map(|name| skill_line(name, &std::fs::read_to_string(folder.join(name).join("SKILL.md")).ok()?));
    lines.collect::<Vec<_>>().join("\n")
}

fn prefix(text: &str, count: usize) -> String {
    text.chars().take(count).collect()
}

/// What Haiku is asked: the self-map's table, the apps inside my-apps, his skills, then the prompts, the first weighing most.
fn question(prompts: &[String], home: &Path) -> String {
    let map = std::fs::read_to_string(home.join(".claude/skills/self-map/SKILL.md")).unwrap_or_default();
    let rows: Vec<&str> = map.split('\n').filter(|line| line.starts_with("| ") && !line.starts_with("| Folder")).collect();
    let fleet = std::fs::read_to_string(home.join(SELF_FOLDER).join("my-apps/.fleet")).unwrap_or_default();
    let apps: Vec<String> = fleet.split(['\n', '\r']).filter(|line| !line.is_empty()).map(|app| format!("my-apps/{app}")).collect();
    let later = prompts.iter().skip(1).rev().take(LATER_PROMPTS).rev().map(|prompt| format!("\n<later>{}</later>", prefix(prompt, LATER_PROMPT_CHARS))).collect::<String>();
    let first = prompts.first().map_or_else(String::new, |prompt| prefix(prompt, FIRST_PROMPT_CHARS));
    format!(
        "{RULES}{}\nApps inside my-apps, each its own folder: {}\nHis skills, whose descriptions say which work belongs where:\n{}\n<request>{first}</request>{later}",
        rows.join("\n"),
        apps.join(", "),
        skills(home)
    )
}

/// The folder Haiku named under `root`, when it exists there.
fn answer(output: &str, root: &str) -> Option<String> {
    let answer = output.trim_matches(|character: char| character.is_whitespace() || ANSWER_TRIM.contains(character));
    if answer.is_empty() || answer.eq_ignore_ascii_case("none") || answer.contains("..") {
        return None;
    }
    working_directory(&format!("{root}/{}", answer.replace("~/self/", "")), root)
}

/// The folder under `~/self` the prompts are about; none for none or several. `router` is Haiku's command (a test's
/// fixture agent in its place), run under `account`'s environment.
pub async fn route(router: &[String], prompts: &[String], account: &Account, home: &Path) -> Option<String> {
    let (program, fixed) = router.split_first()?;
    let environment = provider::environment(account, home, "").into_iter().filter(|(key, _)| key != FLEET_SHELL);
    let mut command = Command::new(program);
    command.args(fixed).arg("-p").arg(question(prompts, home)).args(ROUTER_ARGUMENTS).env_clear().envs(environment);
    command.current_dir(std::env::temp_dir()).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true);
    let child = command.spawn().ok()?;
    let output = tokio::time::timeout(ROUTE_TIMEOUT, child.wait_with_output()).await.ok()?.ok()?;
    answer(&String::from_utf8_lossy(&output.stdout), &home.join(SELF_FOLDER).to_string_lossy())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> PathBuf {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!("vcx-project-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn a_turn_moves_to_the_project_it_edited_most_a_fleet_sub_folder_included() {
        let root = folder("turn");
        let (beta, start) = (root.join("beta"), root.join("start"));
        for path in [beta.join("app/src"), beta.join(".git"), start.clone()] {
            std::fs::create_dir_all(path).unwrap();
        }
        std::fs::write(beta.join(".fleet"), "app\n").unwrap();
        let (root, app, start) = (root.to_string_lossy().into_owned(), beta.join("app").to_string_lossy().into_owned(), start.to_string_lossy().into_owned());
        let edits = vec![format!("{app}/src/new.swift"), format!("{app}/src/other.swift")];

        let moved = turn_directory(&edits, &start, &root, &[], "/nonexistent");
        let inside = turn_directory(&edits, &format!("{app}/src"), &root, &[], "/nonexistent");
        let outside = turn_directory(&edits, &start, &start, &[], "/nonexistent");
        let added = turn_directory(&edits, &start, &start, &[root.clone()], "/nonexistent");

        assert_eq!(moved.as_deref(), Some(app.as_str()));
        assert_eq!((inside, outside), (None, None));
        assert_eq!(added.as_deref(), Some(app.as_str()));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn an_edit_outside_any_repository_moves_nothing() {
        let root = folder("loose");
        let loose = root.to_string_lossy().into_owned();

        let moved = turn_directory(&[format!("{loose}/notes.md")], "/", "/", &[], "/nonexistent");

        assert_eq!(moved, None);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn the_answer_names_an_existing_folder_under_self_or_nothing() {
        let root = folder("answer");
        std::fs::create_dir_all(root.join("s14/stele")).unwrap();
        let root_text = root.to_string_lossy().into_owned();

        let named = answer("`s14/stele/`\n", &root_text);
        let prefixed = answer("~/self/s14", &root_text);
        let refused = ["none", "None.", "../etc", "missing", ""].map(|output| answer(output, &root_text));

        assert_eq!(named, Some(format!("{root_text}/s14/stele")));
        assert_eq!(prefixed, Some(format!("{root_text}/s14")));
        assert_eq!(refused, [None, None, None, None, None]);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_skill_description_folded_on_indented_lines_is_read_whole() {
        let inline = skill_line("sm", "---\nname: sm\ndescription: Summarize an answer.\n---\n");
        let folded = skill_line("recon", "---\ndescription: >-\n  S14 trade\n  reconciliation.\nname: recon\n");

        assert_eq!(inline.as_deref(), Some("sm: Summarize an answer."));
        assert_eq!(folded.as_deref(), Some("recon: S14 trade reconciliation."));
    }

    #[test]
    fn the_question_keeps_the_first_prompt_and_the_last_five_later_ones() {
        let prompts: Vec<String> = (0..8).map(|index| format!("prompt {index}")).collect();

        let asked = question(&prompts, Path::new("/nonexistent"));

        assert!(asked.starts_with(RULES) && asked.contains("<request>prompt 0</request>\n<later>prompt 3</later>"), "{asked}");
        assert!(asked.ends_with("<later>prompt 7</later>") && !asked.contains("prompt 2"));
    }
}
