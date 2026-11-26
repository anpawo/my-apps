//! The slash commands the worker answers itself, ported from the Swift `Session.command` (Commands.swift): an error
//! becomes a notice, as the Swift worker shows it, and a command that needs a choice answers the menu to open.

use super::{Object, SessionBackend, object};
use crate::fallback;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;
use vcx_config::settings::QWEN_HOSTS;
use vcx_config::{Account, SettingsFile};

/// What a command answers: nothing, or the composer's menu to open (`/model `).
type Reply = Option<String>;

const FRONTEND_COMMANDS: [&str; 7] = ["/window", "/settings", "/login", "/attach", "/preview", "/quit", "/exit"];
const PROVIDER_CHOICES: [&str; 5] = ["auto", "claude", "codex", "qwen", "agy"];
const MODEL_SHORTCUTS: [(&str, &str); 3] = [("/codex", "codex"), ("/fable", "claude fable"), ("/opus", "claude opus")];
const MODE_TIMEOUT: Duration = Duration::from_secs(20);
const RELEASE_DATE_DIGITS: usize = 8;
const QUESTION: &str = "item/tool/requestUserInput";
const QWEN_SETTINGS: [&str; 4] = ["url", "proxy", "model", "host"];
const CHANGING: &str = "A connection change is already in progress.";
const NOT_REPORTED: &str = "Not reported";
/// What Swift shows for a folder outside any repository, until the worker reads repositories.
const HELP_KEYS: &str = "\nType / to search. ↑/↓ select. Tab completes. Return completes the highlighted command; the next Return runs it. Escape dismisses the popup. Shift+Return adds a line. /vcx:<command> explicitly selects vcx commands.";

const APP_COMMANDS: [(&str, &str); 39] = [
    ("model", "Choose provider, model, and reasoning effort"),
    ("account", "Use, enable, disable, or rename a subscription account"),
    ("perms", "Choose bypass / YOLO or ask for approval"),
    ("dir", "Change the working directory"),
    ("window", "Open another window, optionally in a directory"),
    ("new", "Start a new conversation; current work stays saved"),
    ("clear", "Start a new conversation"),
    ("resume", "Choose a saved conversation"),
    ("fork", "Branch the current Codex conversation"),
    ("rename", "Name the current conversation"),
    ("plan", "Use Codex plan mode; off returns to implementation"),
    ("effort", "Set reasoning effort for the active model"),
    ("codex", "Switch to Codex and its newest model"),
    ("fable", "Switch to Claude Fable"),
    ("opus", "Switch to Claude Opus"),
    ("reconnect", "Reconnect the current conversation"),
    ("stop", "Interrupt the current response"),
    ("settings", "Show configuration and available settings commands"),
    ("login", "Add a Claude or Codex subscription, or cancel sign-in"),
    ("profile", "Import an existing account: claude|codex <folder>"),
    ("qwen", "Configure url, proxy, or model"),
    ("hooks", "List provider hooks; add reload to refresh"),
    ("skills", "List provider skills; add reload to refresh"),
    ("mcp", "List Model Context Protocol servers; add reload to refresh"),
    ("instructions", "List discovered instruction files"),
    ("tokens", "Show reported token and context usage"),
    ("usage", "Refresh subscription usage"),
    ("repo", "Show repository and branch"),
    ("status", "Show the current session"),
    ("details", "Expand or collapse action details"),
    ("focus", "Expand or collapse action details"),
    ("attach", "Attach an image by its path"),
    ("preview", "Preview the last image in the conversation"),
    ("answer", "Answer the current question from chat"),
    ("allow", "Approve the pending action"),
    ("decline", "Decline the pending action"),
    ("help", "Show commands and keyboard shortcuts"),
    ("quit", "Save and close this instance"),
    ("exit", "Save and close this instance"),
];

// shortcut: Codex 0.166.0's built-ins and the Claude CLI reference, as Commands.swift lists them; refresh both together.
const CODEX_NATIVE: &str = "model presets daybreak ide permissions keymap vim setup-default-sandbox experimental approve memories skills import hooks review rename new archive delete resume fork worktree app init compact config recap plan voice goal agents side btw copy export raw tui diff mention status daemon warnings cd pwd usage debug-config title statusline theme pets mcp apps plugins logout quit exit feedback ps stop clear subagents cwd pet clean";
const CLAUDE_NATIVE: &str = "add-dir advisor agents artifact-capabilities artifact-diagramming artifacts auto-mode-setup autocompact autofix-pr background batch branch btw bug cd chrome claude-api claude-in-chrome clear code-review color compact config context copy cost dataviz debug deep-research design design-login design-sync desktop diff doctor effort exit export fast feedback fewer-permission-prompts focus fork goal heapdump help hooks ide import init insights install-github-app install-slack-app keybindings list-agents login logout loop mcp memory mobile model output-style passes permissions plan plugin plugin-authoring powerup pr-comments privacy-settings radio rate-limit-options recap release-notes reload-plugins reload-skills remote-control remote-env rename restart resume review rewind run run-skill-generator sandbox schedule scroll-speed security-review setup-bedrock setup-vertex simplify skill-doctor skills slides stats status statusline stickers stop subtask tasks team-onboarding teleport terminal-setup theme tui ultraplan ultrareview update-config upgrade usage usage-credits verify vim voice web-setup workflow-authoring workflows";
const CLAUDE_ALIASES: [(&str, &str); 9] = [("permissions", "perms"), ("config", "settings"), ("cd", "dir"), ("context", "tokens"), ("cost", "tokens"), ("memory", "instructions"), ("restart", "reconnect"), ("reload-skills", "skills"), ("reload-plugins", "reconnect")];
const CODEX_ALIASES: [(&str, &str); 3] = [("pwd", "dir"), ("cwd", "dir"), ("clean", "stop")];

fn listed(catalog: &str, name: &str) -> bool {
    catalog.split(' ').any(|known| known == name)
}

fn alias(provider: &str, name: &str) -> Option<&'static str> {
    let codex = if provider == "codex" { CODEX_ALIASES.iter().find(|(from, _)| *from == name) } else { None };
    codex.or_else(|| CLAUDE_ALIASES.iter().find(|(from, _)| *from == name)).map(|(_, to)| *to)
}

/// The vcx command `original` names for `provider`: `/vcx:x` is vcx's own, `/codex:x` and `/claude:x` a native name,
/// and a native alias (`/cwd`, `/permissions`) its vcx command.
fn resolve(provider: &str, original: &str) -> String {
    let mut verb = original.replace("/vcx:", "/");
    let explicit = original.starts_with("/vcx:");
    let bare = original.strip_prefix('/').unwrap_or(original);
    if provider == "codex" {
        match original.strip_prefix("/codex:").filter(|name| listed(CODEX_NATIVE, name)) {
            Some(name) => verb = format!("/{}", alias("codex", name).unwrap_or(name)),
            None if !explicit => verb = alias("codex", bare).map_or(verb, |mapped| format!("/{mapped}")),
            None => {}
        }
    }
    if provider == "claude" || provider == "codex" {
        match original.strip_prefix("/claude:").filter(|name| listed(CLAUDE_NATIVE, name)) {
            Some(name) => verb = format!("/{}", alias("claude", name).unwrap_or(name)),
            None if provider == "claude" && !explicit => verb = alias("claude", bare).map_or(verb, |mapped| format!("/{mapped}")),
            None => {}
        }
    }
    verb
}

/// "gpt-6.2-sol" → ("gpt-*-sol", [6, 2]); "claude-haiku-4-5-20251001" → ("claude-haiku-*", [4, 5]); none without a version.
fn model_version(id: &str) -> Option<(String, Vec<i64>)> {
    let (mut family, mut number) = (Vec::new(), Vec::new());
    for token in id.to_lowercase().split('-') {
        if token.len() == RELEASE_DATE_DIGITS && token.parse::<i64>().is_ok() {
            continue;
        }
        match token.split('.').map(|part| part.parse::<i64>().ok()).collect::<Option<Vec<_>>>() {
            Some(parts) => {
                if number.is_empty() {
                    family.push("*".to_owned());
                }
                number.extend(parts);
            }
            None => family.push(token.to_owned()),
        }
    }
    (!number.is_empty()).then(|| (family.join("-"), number))
}

fn is_newer(version: &[i64], other: &[i64]) -> bool {
    let at = |list: &[i64], index: usize| list.get(index).copied().unwrap_or(0);
    (0..version.len().max(other.len())).map(|index| (at(version, index), at(other, index))).find(|(left, right)| left != right).is_some_and(|(left, right)| left > right)
}

/// Each model family's newest version only, in the catalog's order (gpt-6.2-sol hides gpt-6.1-sol).
fn latest_models(models: &[String]) -> Vec<String> {
    let versions: Vec<_> = models.iter().map(|model| model_version(model)).collect();
    let mut newest: HashMap<&str, &[i64]> = HashMap::new();
    for (family, number) in versions.iter().flatten() {
        if newest.get(family.as_str()).is_none_or(|known| is_newer(number, known)) {
            newest.insert(family, number);
        }
    }
    models.iter().zip(&versions).filter(|(_, version)| version.as_ref().is_none_or(|(family, number)| newest.get(family.as_str()) == Some(&number.as_slice()))).map(|(model, _)| model.clone()).collect()
}

fn help(provider: &str) -> String {
    let available = |name: &str| APP_COMMANDS.iter().any(|(known, _)| *known == name) || ["compact", "review"].contains(&name);
    let native = |catalog: &str, source: &str, unavailable: &str| -> Vec<String> {
        catalog.split(' ').map(|name| {
            let mapped = alias(provider, name).unwrap_or(name);
            if available(mapped) { format!("/{name} · {source}: Use through vcx /{mapped}") } else { format!("/{name} · {source} terminal: Unavailable in vcx ({unavailable})") }
        }).collect()
    };
    let mut lines: Vec<String> = APP_COMMANDS.iter().map(|(name, detail)| format!("/{name} · vcx: {detail}")).collect();
    match provider {
        "codex" => lines.extend(native(CODEX_NATIVE, "Codex", "Codex terminal action")),
        "claude" => lines.extend(native(CLAUDE_NATIVE, "Claude", "Claude CLI reference")),
        _ => {}
    }
    lines.join("\n") + HELP_KEYS
}

fn unquoted(text: &str) -> &str {
    let quoted = text.len() >= 2 && ((text.starts_with('"') && text.ends_with('"')) || (text.starts_with('\'') && text.ends_with('\'')));
    if quoted { &text[1..text.len() - 1] } else { text }
}

/// The Swift `resolvedPath`: `~` is his home, a relative path starts at `cwd`, and `.` and `..` are folded away.
fn resolved_path(cwd: &str, text: &str) -> PathBuf {
    let text = unquoted(text);
    let expanded = match text.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => format!("{}{rest}", vcx_config::homes::home_directory().display()),
        _ => text.to_owned(),
    };
    let mut path = PathBuf::new();
    for component in Path::new(cwd).join(expanded).components() {
        match component {
            Component::ParentDir => {
                path.pop();
            }
            Component::CurDir => {}
            other => path.push(other),
        }
    }
    path
}

/// An http or https URL with a host and no credentials, as Swift's `URL` check for `/qwen url` reads it.
fn valid_ollama_url(text: &str) -> bool {
    let Some((scheme, rest)) = text.split_once("://") else { return false };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host = match authority.strip_prefix('[') {
        Some(bracketed) => bracketed.split(']').next(),
        None => authority.split(':').next(),
    };
    ["http", "https"].contains(&scheme.to_ascii_lowercase().as_str()) && !authority.contains('@') && host.is_some_and(|host| !host.is_empty())
}

impl SessionBackend {
    /// The `command` action, as the Swift worker answers it: the frontend's own commands are refused, any other
    /// answers a menu to open or nothing, its error shown as a notice.
    pub(super) async fn command(self: Rc<Self>, text: &str) -> Result<Object, String> {
        if let Some(skill) = self.skill(text) {
            return self.send_as(&skill.text.clone(), &[], None, None, false, Some(skill)).await;
        }
        let token = text.split_whitespace().next().unwrap_or_default().to_lowercase();
        let verb = format!("/{}", token.rsplit(':').next().unwrap_or_default().trim_matches('/'));
        if FRONTEND_COMMANDS.contains(&verb.as_str()) {
            return Err("This command belongs to the frontend.".into());
        }
        match self.run_command(text).await {
            Ok(Some(query)) => Ok(object(json!({"commandQuery": query}))),
            Ok(None) => Ok(Object::new()),
            Err(error) => {
                self.session.borrow_mut().notice(&error);
                Ok(Object::new())
            }
        }
    }

    async fn run_command(self: &Rc<Self>, text: &str) -> Result<Reply, String> {
        let provider = self.session.borrow().provider.clone();
        let original = text.split_whitespace().next().unwrap_or_default();
        let verb = resolve(&provider, original);
        let typed = text.split_once(char::is_whitespace).map_or("", |(_, rest)| rest.trim());
        let argument = if ["/reload-skills", "/claude:reload-skills"].contains(&original) { "reload" } else { typed };
        match verb.as_str() {
            "/provider" | "/model" | "/codex" | "/fable" | "/opus" => self.change_provider(&verb, text, argument).await,
            "/perms" => self.change_mode(argument).await,
            "/account" if argument.is_empty() => Ok(Some("/account ".into())),
            "/account" => {
                self.idle()?;
                self.change_account(argument).await.map(|()| None)
            }
            "/new" | "/clear" => {
                self.idle()?;
                self.switch_thread(None, true).await;
                Ok(None)
            }
            "/resume" if argument.is_empty() => {
                self.idle()?;
                self.refresh_catalog().await;
                Ok(Some("/resume ".into()))
            }
            "/resume" => {
                self.idle()?;
                self.switch_thread(Some(argument), true).await;
                Ok(None)
            }
            "/fork" => self.fork().await.map(|()| None),
            "/reconnect" => {
                self.idle()?;
                let name = original.rsplit(':').next().unwrap_or_default().trim_matches('/');
                let reason = if name == "reload-plugins" { "plugins reloaded".to_owned() } else { format!("{name} requested") };
                self.reconnect(&reason).await.map(|()| None)
            }
            "/stop" => {
                Rc::clone(self).stop("Stop command").await;
                Ok(None)
            }
            "/dir" | "/rename" | "/plan" | "/effort" | "/profile" | "/qwen" => self.conversation_setting(&verb, argument).await,
            "/hooks" | "/skills" | "/mcp" | "/instructions" | "/tokens" | "/usage" | "/repo" | "/status" | "/help" => self.report(&verb, argument).await.map(|()| None),
            "/compact" | "/review" => self.native_action(&verb, argument).await.map(|()| None),
            "/allow" | "/decline" | "/answer" => self.answer_pending(&verb, argument).map(|()| None),
            "/details" | "/focus" => Ok(None),
            _ if (provider == "codex" && listed(CODEX_NATIVE, &verb[1..])) || (provider == "claude" && listed(CLAUDE_NATIVE, &verb[1..])) => {
                let catalog = if provider == "codex" { "the Codex terminal catalog" } else { "the Claude CLI reference" };
                self.session.borrow_mut().notice(&format!("{verb} is listed from {catalog} but is not implemented in vcx. It was not sent to the model. Use /help for available vcx actions."));
                Ok(None)
            }
            // Skills that are not the worker's yet: the agent reads them as typed.
            _ => Rc::clone(self).send(text, &[], None, None, false).await.map(|_| None),
        }
    }

    async fn conversation_setting(self: &Rc<Self>, verb: &str, argument: &str) -> Result<Reply, String> {
        match verb {
            "/dir" if argument.is_empty() => {
                let cwd = self.session.borrow().cwd.clone();
                self.session.borrow_mut().notice(&format!("{cwd}\nUse /dir <folder> to change directory."));
            }
            "/dir" => self.change_directory(argument).await?,
            "/rename" => self.rename(argument).await?,
            "/plan" => self.plan(argument).await?,
            "/effort" => {
                self.idle()?;
                let model = self.session.borrow().model.clone();
                let efforts = self.efforts(&model);
                if !efforts.iter().any(|effort| effort == argument) {
                    return Err(format!("Choose an effort supported by the active model: {}", efforts.join(", ")));
                }
                self.change_model(&model, Some(argument.to_owned())).await?;
            }
            "/profile" => self.add_profile(argument)?,
            _ => return self.set_qwen(argument).await,
        }
        Ok(None)
    }

    fn efforts(&self, model: &str) -> Vec<String> {
        let session = self.session.borrow();
        session.model_efforts.get(model).and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect()
    }

    /// `/provider`, `/model` and the shortcuts (`/codex` takes Codex's newest model, `/opus high` Claude Opus at high).
    async fn change_provider(self: &Rc<Self>, verb: &str, source: &str, argument: &str) -> Result<Reply, String> {
        let shortcut = MODEL_SHORTCUTS.iter().find(|(name, _)| *name == verb).map(|(_, args)| *args);
        if argument.is_empty() && shortcut.is_none() {
            return Ok(Some("/model ".into()));
        }
        if self.session.borrow().changing {
            return Err(CHANGING.into());
        }
        let mut args: Vec<String> = format!("{} {argument}", shortcut.unwrap_or_default()).split_whitespace().map(str::to_owned).collect();
        if self.session.borrow().busy || self.transferring.get() {
            return Ok(self.queue_model_change(shortcut.is_some(), source, argument, &args));
        }
        let choice = args[0].clone();
        if !PROVIDER_CHOICES.contains(&choice.as_str()) {
            if !self.session.borrow().ready {
                return Err("Reconnect before changing models.".into());
            }
            return self.change_model(argument, None).await.map(|()| None);
        }
        self.take_provider(&choice).await?;
        if verb == "/codex" {
            let newest = latest_models(&self.session.borrow().models).into_iter().next().ok_or("Codex listed no model.")?;
            args.insert(1, newest);
        }
        if args.len() == 1 {
            return Ok(Some(format!("/model {choice} ")));
        }
        if args.len() > 3 || !self.session.borrow().models.contains(&args[1]) {
            return Err("Choose a model from the menu.".into());
        }
        let efforts = self.efforts(&args[1]);
        if args.len() == 2 && !efforts.is_empty() && shortcut.is_none() {
            return Ok(Some(format!("/model {choice} {} ", args[1])));
        }
        if args.get(2).is_some_and(|effort| !efforts.contains(effort)) {
            return Err("Choose an effort from the menu.".into());
        }
        // A shortcut keeps the effort chosen earlier when the new model has it, else the model's default.
        let kept = shortcut.and_then(|_| self.session.borrow().effort.clone().filter(|effort| efforts.contains(effort)));
        self.change_model(&args[1], args.get(2).cloned().or(kept)).await.map(|()| None)
    }

    /// During a turn the current provider's menus still open; the final choice waits for the turn to end.
    fn queue_model_change(&self, shortcut: bool, source: &str, argument: &str, args: &[String]) -> Reply {
        let current = self.session.borrow().provider == args[0];
        if !shortcut && current && args.len() == 1 {
            return Some(format!("/model {} ", args[0]));
        }
        if !shortcut && current && args.len() == 2 && self.session.borrow().models.contains(&args[1]) && !self.efforts(&args[1]).is_empty() {
            return Some(format!("/model {argument} "));
        }
        *self.pending_command.borrow_mut() = Some(if shortcut { source.to_owned() } else { format!("/model {argument}") });
        self.session.borrow_mut().notice(&format!("Model change queued: {} applies when the current turn ends.", args.join(" ")));
        None
    }

    /// The provider `choice` takes the conversation over unless it already runs it; its account is the one `/account`
    /// chose, else its first.
    async fn take_provider(self: &Rc<Self>, choice: &str) -> Result<(), String> {
        let settings = self.settings();
        let previous = self.provider_choice.replace(Some(choice.to_owned()));
        let candidates = if choice == "auto" { self.available(&settings) } else { settings.candidates(choice).into_iter().filter(|account| account.provider == choice).collect() };
        let chosen = self.account_choice.borrow().clone();
        let next = candidates.iter().find(|account| choice != "auto" && Some(&account.id) == chosen.as_ref()).or(candidates.first()).cloned();
        let Some(next) = next else {
            *self.provider_choice.borrow_mut() = previous;
            return Err(format!("No enabled account is available for {choice}. Enable one with /account or add one with /login."));
        };
        let (current, ready) = {
            let session = self.session.borrow();
            (session.account["id"].clone(), session.ready)
        };
        if current != json!(next.id) || !ready {
            if let Err(error) = self.activate(&next, None, Some("provider changed")).await {
                *self.provider_choice.borrow_mut() = previous;
                return Err(error);
            }
            self.refresh_catalog().await;
        }
        if choice != "auto" && settings.limit(&next.id).is_some_and(|reset| reset > fallback::now()) {
            self.rest(&next.id, 0.0);
        }
        Ok(())
    }

    /// `/perms`: Codex takes the mode with its next turn, the adapters at once; an agent that is not ready or refuses
    /// the switch is reconnected in the new mode.
    async fn change_mode(self: &Rc<Self>, argument: &str) -> Result<Reply, String> {
        if argument.is_empty() {
            return Ok(Some("/perms ".into()));
        }
        let mode = match argument {
            "bypass" | "yolo" => "bypass",
            "ask" => "ask",
            _ => return Err("Use /perms bypass or /perms ask.".into()),
        };
        self.idle()?;
        *self.mode_choice.borrow_mut() = Some(mode.to_owned());
        self.apply_mode(mode).await.map(|()| None)
    }

    /// The Swift `switchMode`: Codex takes `mode` with its next turn, the adapters at once; an agent that is not
    /// ready or refuses it is reconnected in it.
    async fn apply_mode(self: &Rc<Self>, mode: &str) -> Result<(), String> {
        let (ready, codex) = {
            let session = self.session.borrow();
            (session.ready, session.provider == "codex")
        };
        let switched = match (ready, codex) {
            (false, _) => false,
            (true, true) => true,
            (true, false) => self.request("vcx/mode", json!({"mode": mode}), MODE_TIMEOUT).await.is_ok(),
        };
        if !switched {
            return self.reconnect("permission mode changed").await;
        }
        let mut session = self.session.borrow_mut();
        session.mode_override |= codex;
        session.active_mode = mode.to_owned();
        let label = if mode == "bypass" { "Bypass / YOLO" } else { "Ask for approval" };
        session.notice(&format!("Permission mode changed to {label}."));
        Ok(())
    }

    /// A mode changed in Settings, applied before the next turn; a failed reconnect is told and leaves it unready.
    pub(super) async fn switch_mode(self: &Rc<Self>, mode: &str) {
        if let Err(error) = self.apply_mode(mode).await {
            self.session.borrow_mut().notice(&error);
        }
    }

    /// A new conversation under a new record in `folder`, on the first available account; the old record is
    /// archived once it opens, and kept if it fails.
    async fn new_conversation(self: &Rc<Self>, folder: &str) -> Result<(), String> {
        self.recover_incomplete_archive().await?;
        let previous = self.begin_record_transition()?;
        {
            let mut session = self.session.borrow_mut();
            session.cwd = folder.to_owned();
            session.conversation_directory = folder.to_owned();
        }
        let opened = match self.available(&self.settings()).into_iter().next() {
            Some(next) => self.activate_rows(&next, None, None, false).await,
            None => Err("No enabled account is available.".into()),
        };
        match opened {
            Ok(()) => {
                self.archive_retired(previous).await;
                self.refresh_catalog().await;
                Ok(())
            }
            Err(error) if self.closed.get() => {
                self.discard(previous);
                Err(error)
            }
            Err(error) => {
                self.rollback(previous);
                Err(error)
            }
        }
    }

    /// The Swift `changeDirectory`: the conversation starts over in the folder.
    async fn change_directory(self: &Rc<Self>, argument: &str) -> Result<(), String> {
        let previous = {
            let session = self.session.borrow();
            if session.busy || session.changing {
                return Err("Stop the current turn before changing directory.".into());
            }
            (session.cwd.clone(), session.conversation_directory.clone())
        };
        let path = resolved_path(&previous.0, argument);
        if !path.is_dir() {
            return Err("Directory does not exist.".into());
        }
        if let Err(error) = self.new_conversation(&path.to_string_lossy()).await {
            let mut session = self.session.borrow_mut();
            (session.cwd, session.conversation_directory) = previous;
            drop(session);
            *self.pending_activation.borrow_mut() = None;
            return Err(error);
        }
        Ok(())
    }

    async fn rename(self: &Rc<Self>, name: &str) -> Result<(), String> {
        self.idle()?;
        let (ready, codex, thread) = {
            let session = self.session.borrow();
            (session.ready, session.provider == "codex", session.thread_id.clone().unwrap_or_default())
        };
        if !ready || name.is_empty() {
            return Err("Use /rename <name> in a connected conversation.".into());
        }
        if codex {
            self.request("thread/name/set", json!({"threadId": thread, "name": name}), super::REQUEST_TIMEOUT).await?;
        }
        self.session.borrow_mut().conversation_name = Some(name.to_owned());
        self.refresh_catalog().await;
        Ok(())
    }

    /// `/plan [on|off|<prompt>]`: Codex's plan mode, kept for the next turns; Claude reads `/plan` itself.
    async fn plan(self: &Rc<Self>, argument: &str) -> Result<(), String> {
        self.idle()?;
        let (ready, provider, label) = {
            let session = self.session.borrow();
            (session.ready, session.provider.clone(), session.provider_label.clone())
        };
        if !ready {
            return Err("Reconnect first.".into());
        }
        if provider == "claude" {
            let text = if argument.is_empty() { "/plan".to_owned() } else { format!("/plan {argument}") };
            return Rc::clone(self).send(&text, &[], None, None, false).await.map(|_| ());
        }
        if provider != "codex" {
            return Err(format!("{label} has no native plan mode in VCX."));
        }
        let planning = !["off", "execute", "default"].contains(&argument);
        self.session.borrow_mut().planning = planning;
        if !argument.is_empty() && !["on", "off", "execute", "default"].contains(&argument) {
            return Rc::clone(self).send(argument, &[], None, None, false).await.map(|_| ());
        }
        self.session.borrow_mut().notice(if planning { "Plan mode enabled. Use /plan off to implement." } else { "Implementation mode enabled." });
        Ok(())
    }

    /// `/profile claude|codex <folder>`: an existing provider home becomes an account.
    fn add_profile(&self, argument: &str) -> Result<(), String> {
        let (provider, folder) = argument.split_once(' ').filter(|(provider, folder)| ["claude", "codex"].contains(provider) && !folder.trim().is_empty()).ok_or("Use /profile claude|codex <profile directory>.")?;
        let path = resolved_path(&self.session.borrow().cwd, folder.trim());
        if !path.is_dir() {
            return Err("Profile directory does not exist.".into());
        }
        let home = path.to_string_lossy().into_owned();
        let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
        SettingsFile::new(&self.config.settings).update(|settings| {
            if !settings.accounts().iter().any(|account| account.home.as_deref() == Some(home.as_str()) && account.provider == provider) {
                let account = Account { id: uuid::Uuid::new_v4().to_string().to_uppercase(), name, provider: provider.to_owned(), home: Some(home.clone()), enabled: true };
                settings.add_account(&account);
            }
        })?;
        self.session.borrow_mut().notice("Profile added. Select it with /account.");
        Ok(())
    }

    /// `/qwen url|proxy|model|host <value>` changes his Qwen settings; a running Qwen reconnects to them.
    async fn set_qwen(self: &Rc<Self>, argument: &str) -> Result<Reply, String> {
        self.idle()?;
        let Some((key, given)) = argument.split_once(' ').filter(|(key, _)| QWEN_SETTINGS.contains(key)) else { return Ok(Some("/qwen ".into())) };
        let value = if given == "none" { "" } else { given };
        let refusal = match key {
            "model" if value.is_empty() => Some("Model names cannot be empty."),
            "host" if !QWEN_HOSTS.iter().any(|(host, _, _)| *host == value) => Some("Use /qwen host mac or /qwen host pc."),
            "url" if !valid_ollama_url(value) => Some("Enter an HTTP or HTTPS Ollama URL without credentials."),
            "proxy" if !value.is_empty() && !matches!(vcx_agents::http::proxy(value), Ok(Some(_))) => Some("Use socks5://host:port without credentials, or none."),
            _ => None,
        };
        if let Some(refusal) = refusal {
            return Err(refusal.into());
        }
        SettingsFile::new(&self.config.settings).update(|settings| {
            let mut qwen = settings.qwen();
            match key {
                "host" => {
                    settings.set_qwen_host(value);
                    return;
                }
                "url" => qwen.url = value.to_owned(),
                "proxy" => qwen.proxy = value.to_owned(),
                _ => qwen.model = value.to_owned(),
            }
            settings.set_qwen(&qwen);
        })?;
        if self.session.borrow().provider == "qwen" {
            if key == "model" {
                self.session.borrow_mut().model = value.to_owned();
            }
            if let Err(error) = self.reconnect("Qwen settings changed").await {
                self.session.borrow_mut().notice(&error);
            }
        }
        self.session.borrow_mut().notice("Qwen setting saved.");
        Ok(None)
    }

    async fn report(self: &Rc<Self>, verb: &str, argument: &str) -> Result<(), String> {
        let message = match verb {
            "/hooks" | "/skills" | "/mcp" | "/instructions" => {
                let name = &verb[1..];
                if argument == "reload" {
                    self.idle()?;
                    if let Err(error) = self.reconnect(&format!("{name} reloaded")).await {
                        self.session.borrow_mut().notice(&error);
                    }
                }
                // The worker reads none of these catalogs yet: Swift's answer for an empty one.
                format!("No entries reported for {name}.")
            }
            "/tokens" => {
                let session = self.session.borrow();
                let tokens = if session.tokens.is_empty() { NOT_REPORTED } else { &session.tokens };
                if session.context.is_empty() { tokens.to_owned() } else { format!("{tokens}\n{}", session.context) }
            }
            "/usage" => {
                self.refresh_usage(true).await;
                let usage = self.session.borrow().usage.clone();
                if usage.is_empty() { "The provider has not reported subscription usage yet.".to_owned() } else { usage }
            }
            "/repo" => {
                Rc::clone(self).refresh_repository().await;
                let session = self.session.borrow();
                let label = if session.branch.is_empty() { "not a repo".to_owned() } else if session.repository_status.is_empty() { format!("@{}", session.branch) } else { format!("@{} - {}", session.branch, session.repository_status) };
                std::iter::once(format!("{} · {label}", session.repository)).chain(session.repository_changes.iter().cloned()).collect::<Vec<_>>().join("\n")
            }
            "/status" => self.status_text(),
            _ => help(&self.session.borrow().provider),
        };
        self.session.borrow_mut().notice(&message);
        Ok(())
    }

    fn status_text(&self) -> String {
        let session = self.session.borrow();
        let mode = if session.active_mode == "bypass" { "Bypass / YOLO" } else { "Ask for approval" };
        let tokens = if session.tokens.is_empty() { NOT_REPORTED } else { &session.tokens };
        let usage = if session.usage.is_empty() { NOT_REPORTED } else { &session.usage };
        let account = session.account["name"].as_str().unwrap_or_default();
        format!("Directory: {}\nProvider: {} · {account}\nMode: {mode}\nModel: {}\nTokens: {tokens}\nUsage: {usage}\nRepository: {} · {}", session.cwd, session.provider_label, session.model, session.repository, session.branch)
    }

    /// `/compact` and `/review` (uncommitted changes, or the instructions given): Codex's own requests, Claude's own
    /// commands.
    async fn native_action(self: &Rc<Self>, verb: &str, argument: &str) -> Result<(), String> {
        self.idle()?;
        let (ready, provider, thread) = {
            let session = self.session.borrow();
            (session.ready, session.provider.clone(), session.thread_id.clone().unwrap_or_default())
        };
        if !ready {
            return Err("Reconnect first.".into());
        }
        match provider.as_str() {
            "codex" if verb == "/compact" => self.request("thread/compact/start", json!({"threadId": thread}), super::REQUEST_TIMEOUT).await.map(|_| ()),
            "codex" => {
                let target = if argument.is_empty() { json!({"type": "uncommittedChanges"}) } else { json!({"type": "custom", "instructions": argument}) };
                self.request("review/start", json!({"threadId": thread, "target": target, "delivery": "inline"}), super::REQUEST_TIMEOUT).await.map(|_| ())
            }
            "claude" => {
                let text = if argument.is_empty() { verb.to_owned() } else { format!("{verb} {argument}") };
                Rc::clone(self).send(&text, &[], None, None, false).await.map(|_| ())
            }
            _ => Err("Qwen has no native compact/review command. Ask it to review in a message.".into()),
        }
    }

    /// `/allow`, `/decline` and `/answer <text>` answer the first pending approval or question; several questions
    /// take a JSON object of answers by question id.
    fn answer_pending(&self, verb: &str, argument: &str) -> Result<(), String> {
        let pending = self.session.borrow().permissions.first().cloned().ok_or("No pending question or approval.")?;
        let result = if pending.method != QUESTION {
            json!({"decision": if verb == "/allow" { "accept" } else { "decline" }})
        } else if verb == "/decline" {
            json!({"answers": {}})
        } else {
            if verb != "/answer" || argument.is_empty() {
                return Err("Use /answer <text> for the next question.".into());
            }
            let questions = pending.params.get("questions").and_then(Value::as_array).cloned().unwrap_or_default();
            let ids: Vec<&str> = questions.iter().filter_map(|question| question.get("id").and_then(Value::as_str)).collect();
            let answers: Vec<(String, String)> = match ids.as_slice() {
                [id] if questions.len() == 1 => vec![((*id).to_owned(), argument.to_owned())],
                _ => {
                    let values: HashMap<String, String> = serde_json::from_str(argument).unwrap_or_default();
                    if ids.len() != questions.len() || !ids.iter().all(|id| values.get(*id).is_some_and(|value| !value.is_empty())) {
                        return Err("Use /answer followed by a JSON object mapping every question ID to an answer.".into());
                    }
                    values.into_iter().collect()
                }
            };
            json!({"answers": answers.into_iter().map(|(id, value)| (id, json!({"answers": [value]}))).collect::<Object>()})
        };
        let permission = self.session.borrow_mut().take_permission(&pending.rpc_id, &pending.method).ok_or("No pending question or approval.")?;
        if let Err(error) = self.agent()?.respond(&permission.rpc_id, result) {
            self.session.borrow_mut().notice(&format!("Could not send your answer: {error}"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_model_family_and_its_version_without_the_release_date() {
        let (sol, haiku, plain) = (model_version("gpt-6.2-sol"), model_version("claude-haiku-4-5-20251001"), model_version("fixture-model"));

        assert_eq!(sol, Some(("gpt-*-sol".to_owned(), vec![6, 2])));
        assert_eq!(haiku, Some(("claude-haiku-*".to_owned(), vec![4, 5])));
        assert_eq!(plain, None);
    }

    #[test]
    fn keeps_only_the_newest_model_of_each_family() {
        let models: Vec<String> = ["gpt-6.1-sol", "gpt-6.2-sol", "gpt-6.2-sol-mini", "fixture-model"].map(str::to_owned).into();

        let latest = latest_models(&models);

        assert_eq!(latest, ["gpt-6.2-sol", "gpt-6.2-sol-mini", "fixture-model"]);
    }

    #[test]
    fn maps_native_names_and_aliases_to_vcx_commands() {
        let (codex_alias, claude_alias, native, explicit) = (resolve("codex", "/cwd"), resolve("claude", "/permissions"), resolve("codex", "/codex:pwd"), resolve("codex", "/vcx:status"));

        assert_eq!((codex_alias.as_str(), claude_alias.as_str(), native.as_str(), explicit.as_str()), ("/dir", "/perms", "/dir", "/status"));
        assert_eq!(resolve("qwen", "/permissions"), "/permissions", "only Claude and Codex have these aliases");
    }

    #[test]
    fn resolves_a_folder_against_the_working_directory() {
        let (relative, parent, quoted) = (resolved_path("/a/b", "c"), resolved_path("/a/b", "../c/./d"), resolved_path("/a", "'/x y'"));

        assert_eq!((relative, parent, quoted), (PathBuf::from("/a/b/c"), PathBuf::from("/a/c/d"), PathBuf::from("/x y")));
    }

    #[test]
    fn accepts_an_ollama_url_only_over_http_with_a_host_and_no_credentials() {
        let accepted = ["http://localhost:11434/api/chat", "https://[::1]:1/x"].map(valid_ollama_url);
        let refused = ["ftp://host", "http://user:pass@host", "http://", "localhost:11434"].map(valid_ollama_url);

        assert_eq!((accepted, refused), ([true, true], [false; 4]));
    }
}
