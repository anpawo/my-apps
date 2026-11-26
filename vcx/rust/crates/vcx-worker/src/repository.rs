//! The repository footer, as the Swift `refreshRepository` and `refreshPullRequest` read it (Capabilities.swift):
//! the project's name, its branch and state, the changed files, and his open pull request from `gh`.

use serde_json::Value;
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

const GIT: &str = "/usr/bin/git";
const ENV: &str = "/usr/bin/env";
/// A `gh` call that hangs is stopped: the footer then shows no pull request.
const GH_TIMEOUT: Duration = Duration::from_secs(15);
/// A pull request read this recently (seconds) is not asked of `gh` again.
pub const PULL_REQUEST_TTL: f64 = 300.0;
const EDITING_TOOLS: [&str; 4] = ["Edit", "Write", "MultiEdit", "NotebookEdit"];
const PR_FIELDS: &str = "number,url,headRefName,isDraft,reviewDecision";

/// What the footer shows of the session's folder.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Footer {
    pub directory: Option<String>,
    pub repository: String,
    /// The branch, or `detached <commit>`.
    pub branch: String,
    pub status: String,
    pub root: Option<String>,
    pub changes: Vec<String>,
}

/// The pull request label and link, the time they were read, keyed by repository and branch, so sessions on one
/// checkout share a `gh` call and a branch switch reads again.
type Cached = (f64, String, String);

thread_local! {
    static PULL_REQUESTS: RefCell<HashMap<String, Cached>> = RefCell::default();
}

pub fn cached(key: &str) -> Option<Cached> {
    PULL_REQUESTS.with(|cache| cache.borrow().get(key).cloned())
}

pub fn remember(key: &str, entry: Cached) {
    PULL_REQUESTS.with(|cache| cache.borrow_mut().insert(key.to_owned(), entry));
}

async fn git(arguments: &[&str], at: &str) -> Option<String> {
    let output = Command::new(GIT).arg("-C").arg(at).args(arguments).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).output().await.ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn last_component(path: &str) -> String {
    Path::new(path).file_name().map_or_else(|| path.to_owned(), |name| name.to_string_lossy().into_owned())
}

fn parent(path: &str) -> String {
    Path::new(path).parent().map_or_else(|| path.to_owned(), |parent| parent.to_string_lossy().into_owned())
}

fn resolved(path: &str) -> String {
    std::fs::canonicalize(path).map_or_else(|_| path.to_owned(), |path| path.to_string_lossy().into_owned())
}

/// The file an `Edit`, `Write`, `MultiEdit` or `NotebookEdit` command names, as the Swift `editedPath` reads it.
pub fn edited_path(command: &str) -> Option<String> {
    let (tool, input) = command.split_once('\n')?;
    if !EDITING_TOOLS.contains(&tool) {
        return None;
    }
    let input: Value = serde_json::from_str(input).ok()?;
    input.get("file_path").or_else(|| input.get("notebook_path")).and_then(Value::as_str).map(str::to_owned)
}

/// The path after `~/self`, shortened to its outer folder and its last one.
fn path_in_self(path: &str, self_directory: &Path) -> Option<String> {
    let base = resolved(&self_directory.to_string_lossy()) + "/";
    let full = resolved(path);
    let parts: Vec<&str> = full.strip_prefix(&base)?.split('/').filter(|part| !part.is_empty()).collect();
    Some(if parts.len() > 2 { format!("{}/{}", parts[0], parts[parts.len() - 1]) } else { parts.join("/") })
}

/// The Fleet card a `.fleet` file between `here` and the repository root names for `here`: an empty one names its own
/// folder, a listed sub-folder holding `here` names that sub-folder.
fn card(here: &str, base: &str) -> Option<String> {
    let mut folder = here.to_owned();
    while folder == base || folder.starts_with(&format!("{base}/")) {
        if let Ok(text) = std::fs::read_to_string(format!("{folder}/.fleet")) {
            let subs: Vec<&str> = text.lines().map(str::trim).filter(|line| !line.is_empty()).collect();
            if subs.is_empty() && folder != base {
                return Some(last_component(&folder));
            }
            let inside = |sub: &&&str| here == format!("{folder}/{sub}") || here.starts_with(&format!("{folder}/{sub}/"));
            if let Some(sub) = subs.iter().find(inside) {
                return Some(last_component(sub));
            }
        }
        let up = parent(&folder);
        if up == folder {
            break;
        }
        folder = up;
    }
    None
}

/// The project's name: a worktree's main checkout, inside any enclosing repositories, or its Fleet card; under
/// `~/self` its path there; with the folder of the last edit inside `directory` added.
async fn project_name(directory: &str, root: &str, edited: Option<&str>, self_directory: &Path) -> String {
    let common = git(&["rev-parse", "--path-format=absolute", "--git-common-dir"], directory).await.unwrap_or_default();
    let mut top = common.strip_suffix("/.git").map_or_else(|| root.to_owned(), str::to_owned);
    let mut name = last_component(&top);
    while let Some(outer) = git(&["rev-parse", "--show-toplevel"], &parent(&top)).await.filter(|outer| *outer != top) {
        name = format!("{}/{name}", last_component(&outer));
        top = outer;
    }
    let here = resolved(directory);
    if let Some(card) = card(&here, &resolved(root)) {
        name = card;
    }
    let edited_here = edited.map(resolved).filter(|path| path.starts_with(&format!("{here}/")));
    match (path_in_self(edited_here.as_deref().unwrap_or(&here), self_directory), edited_here) {
        (Some(path), _) => path,
        (None, Some(edited)) => format!("{name}/{}", last_component(&edited)),
        (None, None) => name,
    }
}

async fn status(porcelain: Option<&str>, branch: &str, directory: &str) -> String {
    let Some(changes) = porcelain else { return "status unavailable".into() };
    if !changes.is_empty() {
        return "uncommitted".into();
    }
    if branch.is_empty() {
        return String::new();
    }
    if git(&["rev-parse", "--abbrev-ref", "@{u}"], directory).await.is_none() {
        return "local only".into();
    }
    match git(&["rev-list", "--count", "@{u}..HEAD"], directory).await {
        Some(ahead) if ahead == "0" => "up to date".into(),
        Some(_) => "unpushed".into(),
        None => "status unavailable".into(),
    }
}

/// The footer of `directory`; `edited` is the folder of the last file a turn edited.
pub async fn read(directory: &str, edited: Option<&str>, self_directory: &Path) -> Footer {
    let Some(root) = git(&["rev-parse", "--show-toplevel"], directory).await else {
        return Footer { repository: "No repository".into(), ..Footer::default() };
    };
    let name = project_name(directory, &root, edited, self_directory).await;
    let branch = git(&["branch", "--show-current"], directory).await.unwrap_or_default();
    let label = if branch.is_empty() { format!("detached {}", git(&["rev-parse", "--short", "HEAD"], directory).await.unwrap_or_else(|| "?".into())) } else { branch.clone() };
    let porcelain = git(&["status", "--porcelain"], directory).await;
    let status = status(porcelain.as_deref(), &branch, directory).await;
    let changes = porcelain.unwrap_or_default().split('\n').filter(|line| !line.is_empty()).map(|line| line.trim().to_owned()).collect();
    Footer { directory: Some(name), repository: last_component(&root), branch: label, status, root: Some(root), changes }
}

/// `owner/name` of a GitHub remote: `gh` cannot map a remote to its repository when `~/.ssh/config` pins github.com
/// to an IP, so `-R` names it.
fn github_slug(remote: &str) -> String {
    let start = remote.match_indices("github.com").map(|(index, host)| index + host.len()).filter(|end| matches!(remote.as_bytes().get(*end), Some(b':' | b'/'))).last().map_or(0, |end| end + 1);
    let rest = &remote[start..];
    rest.strip_suffix(".git").unwrap_or(rest).to_owned()
}

/// `PR #12 - approved +1`: the pull request of `branch`, else the first of his open ones, and how many others are open.
fn pull_label(list: &[Value], branch: &str) -> Option<(String, String)> {
    let pull = list.iter().find(|pull| pull["headRefName"].as_str() == Some(branch)).or(list.first())?;
    let (number, url) = (pull["number"].as_i64()?, pull["url"].as_str()?);
    let state = if pull["isDraft"] == true {
        "draft"
    } else {
        match pull["reviewDecision"].as_str().unwrap_or_default() {
            "APPROVED" => "approved",
            "CHANGES_REQUESTED" => "changes requested",
            "REVIEW_REQUIRED" => "review required",
            _ => "open",
        }
    };
    let others = if list.len() > 1 { format!(" +{}", list.len() - 1) } else { String::new() };
    Some((format!("PR #{number} - {state}{others}"), url.to_owned()))
}

async fn run(arguments: &[&str], root: &str, environment: &[(String, String)]) -> Option<Vec<u8>> {
    let mut command = Command::new(ENV);
    command.args(arguments).env_clear().envs(environment.iter().map(|(key, value)| (key, value))).current_dir(root);
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true);
    let output = tokio::time::timeout(GH_TIMEOUT, command.output()).await.ok()?.ok()?;
    output.status.success().then_some(output.stdout)
}

/// His open pull request on the repository at `root` for `branch`, label and link, both empty when there is none,
/// the remote is not GitHub's or `gh` cannot answer.
pub async fn pull_request(root: &str, branch: &str, environment: &[(String, String)]) -> (String, String) {
    let Some(remote) = run(&["git", "remote", "get-url", "origin"], root, environment).await else { return Default::default() };
    let remote = String::from_utf8_lossy(&remote).trim().to_owned();
    if !remote.contains("github.com") {
        return Default::default();
    }
    let slug = github_slug(&remote);
    let arguments = ["gh", "pr", "list", "-R", &slug, "--author", "@me", "--state", "open", "--limit", "100", "--json", PR_FIELDS];
    let Some(data) = run(&arguments, root, environment).await else { return Default::default() };
    match serde_json::from_slice(&data) {
        Ok(Value::Array(list)) => pull_label(&list, branch).unwrap_or_default(),
        _ => Default::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::PathBuf;

    fn folder(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("vcx-repository-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(&folder).unwrap();
        folder
    }

    fn block_on<T>(work: impl Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(work)
    }

    fn git_in(folder: &Path, arguments: &[&str]) {
        let status = std::process::Command::new(GIT).arg("-C").arg(folder).args(arguments).stdout(Stdio::null()).stderr(Stdio::null()).status().unwrap();
        assert!(status.success(), "git {arguments:?}");
    }

    #[test]
    fn an_edit_command_names_its_file_and_a_shell_command_names_none() {
        let edit = format!("Write\n{}", json!({"file_path": "/work/a.txt"}));
        let notebook = format!("NotebookEdit\n{}", json!({"notebook_path": "/work/n.ipynb"}));

        let paths = [edit.as_str(), notebook.as_str(), "ls -la", "Read\n{\"file_path\": \"/work/a.txt\"}"].map(edited_path);

        assert_eq!(paths, [Some("/work/a.txt".into()), Some("/work/n.ipynb".into()), None, None]);
    }

    #[test]
    fn a_github_remote_is_named_by_its_owner_and_repository() {
        let slugs = ["git@github.com:owner/name.git", "https://github.com/owner/name", "ssh://git@github.com/owner/name.git"].map(github_slug);

        assert_eq!(slugs, ["owner/name"; 3]);
    }

    #[test]
    fn the_pull_request_of_the_branch_wins_and_the_others_are_counted() {
        let list = [json!({"number": 3, "url": "https://example.test/3", "headRefName": "other", "isDraft": true}), json!({"number": 7, "url": "https://example.test/7", "headRefName": "main", "isDraft": false, "reviewDecision": "CHANGES_REQUESTED"})];

        let (mine, first, alone) = (pull_label(&list, "main"), pull_label(&list, "gone"), pull_label(&list[1..], "main"));

        assert_eq!(mine, Some(("PR #7 - changes requested +1".into(), "https://example.test/7".into())));
        assert_eq!(first.map(|(label, _)| label), Some("PR #3 - draft +1".into()));
        assert_eq!(alone.map(|(label, _)| label), Some("PR #7 - changes requested".into()));
    }

    #[test]
    fn a_fleet_sub_folder_is_named_as_its_card() {
        let root = folder("card");
        std::fs::create_dir_all(root.join("app/src")).unwrap();
        std::fs::write(root.join(".fleet"), "app\n").unwrap();
        let base = resolved(&root.to_string_lossy());

        let (inside, outside) = (card(&format!("{base}/app/src"), &base), card(&base, &base));

        assert_eq!((inside.as_deref(), outside), (Some("app"), None));
    }

    #[test]
    fn a_github_repository_without_gh_on_the_path_shows_no_pull_request() {
        let root = folder("no-gh");
        git_in(&root, &["init", "-b", "main"]);
        git_in(&root, &["remote", "add", "origin", "git@github.com:owner/name.git"]);
        let environment = [("PATH".to_owned(), "/usr/bin:/bin".to_owned())];

        let found = block_on(pull_request(&root.to_string_lossy(), "main", &environment));

        assert_eq!(found, (String::new(), String::new()));
    }

    #[test]
    fn a_folder_outside_any_repository_reads_as_no_repository() {
        let loose = folder("loose");

        let footer = block_on(read(&loose.to_string_lossy(), None, Path::new("/nonexistent/self")));

        assert_eq!(footer, Footer { repository: "No repository".into(), ..Footer::default() });
    }

    #[test]
    fn a_folder_under_self_shows_its_path_there_and_the_edited_folder_is_added_elsewhere() {
        let home = folder("self");
        let project = home.join("self/atlas");
        std::fs::create_dir_all(project.join("app/src")).unwrap();
        git_in(&project, &["init", "-b", "main"]);
        let (cwd, edited) = (project.to_string_lossy().into_owned(), project.join("app/src").to_string_lossy().into_owned());

        let under_self = block_on(read(&edited, None, &home.join("self")));
        let elsewhere = block_on(read(&cwd, Some(&edited), Path::new("/nonexistent/self")));

        assert_eq!(under_self.directory.as_deref(), Some("atlas/src"));
        assert_eq!(elsewhere.directory.as_deref(), Some("atlas/src"));
        assert_eq!((elsewhere.branch.as_str(), elsewhere.status.as_str()), ("main", "local only"));
    }
}
