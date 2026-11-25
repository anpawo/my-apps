//! What each provider can do and what it has loaded, read the way `Capabilities.swift` and the Swift adapters'
//! request switches tell them apart: the actions a session may offer, the models with their efforts, and the
//! skills, hooks and MCP servers the agent reports.

use crate::Connection;
use crate::rpc::AgentError;
use serde_json::{Value, json};
use std::time::Duration;

const CATALOG_TIMEOUT: Duration = Duration::from_secs(15);
const CLAUDE_CATALOG_TIMEOUT: Duration = Duration::from_secs(25);
const MCP_PAGE: u64 = 100;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provider {
    Codex,
    Claude,
    Agy,
    Qwen,
}

impl Provider {
    pub fn named(name: &str) -> Option<Self> {
        Some(match name {
            "codex" => Self::Codex,
            "claude" => Self::Claude,
            "agy" => Self::Agy,
            "qwen" => Self::Qwen,
            _ => return None,
        })
    }

    /// The actions each adapter answers instead of refusing, as their Swift request switches do.
    pub fn features(self) -> Features {
        let codex = self == Self::Codex;
        let claude = self == Self::Claude;
        Features {
            steer: codex || claude,
            compact: codex,
            review: codex,
            send_now: claude,
            unsend: claude,
            images: true,
            effort: codex || claude,
            resume: self != Self::Qwen,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Features {
    /// A message sent during a turn joins it (`turn/steer`) instead of waiting for its end.
    pub steer: bool,
    pub compact: bool,
    pub review: bool,
    /// A queued message can interrupt the turn to go now (`cx/sendNow`) or be taken back (`cx/unsend`).
    pub send_now: bool,
    pub unsend: bool,
    pub images: bool,
    pub effort: bool,
    /// The agent keeps the conversation, so a reopened session continues it.
    pub resume: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Model {
    pub id: String,
    pub name: String,
    pub efforts: Vec<String>,
    pub default_effort: Option<String>,
}

/// `model/list` in Codex's shape, which every adapter answers in.
pub fn models(list: &Value) -> Vec<Model> {
    list["data"].as_array().into_iter().flatten().filter_map(|entry| {
        let id = entry["id"].as_str().or_else(|| entry["model"].as_str())?.to_owned();
        let efforts = entry["supportedReasoningEfforts"].as_array().into_iter().flatten()
            .filter_map(|effort| effort["reasoningEffort"].as_str().or_else(|| effort.as_str()).map(str::to_owned)).collect();
        let name = entry["displayName"].as_str().unwrap_or(&id).to_owned();
        Some(Model { id, name, efforts, default_effort: entry["defaultReasoningEffort"].as_str().map(str::to_owned) })
    }).collect()
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Catalog {
    pub skills: Vec<String>,
    /// Built-in slash commands (Claude's), without the hidden ones.
    pub commands: Vec<String>,
    pub hooks: Vec<String>,
    pub mcp: Vec<String>,
    /// Lines that say where agy and Qwen keep what VCX cannot list.
    pub notes: Vec<String>,
    /// Claude's current permission mode as VCX names it (`bypass` or `ask`).
    pub mode: Option<String>,
}

pub fn mcp_summary(server: &Value) -> Option<String> {
    let name = server["name"].as_str()?;
    let status = ["status", "runtimeStatus", "authStatus"].iter().find_map(|key| server[*key].as_str()).unwrap_or("configured");
    let mut tools: Vec<String> = match &server["tools"] {
        Value::Object(tools) => tools.keys().cloned().collect(),
        Value::Array(tools) => tools.iter().filter_map(|tool| tool["name"].as_str().map(str::to_owned)).collect(),
        _ => Vec::new(),
    };
    tools.sort();
    let detail = server["description"].as_str().map(str::to_owned).unwrap_or_else(|| if tools.is_empty() { String::new() } else { format!("Tools: {}", tools.join(", ")) });
    Some([name, status, &detail].into_iter().filter(|part| !part.is_empty()).collect::<Vec<_>>().join(" · "))
}

pub fn hook_summary(hook: &Value, event: &str, matcher: Option<&str>, plugin: Option<&str>) -> String {
    let described = match event.to_lowercase().as_str() {
        "sessionstart" => "Loads context when a session starts.",
        "sessionend" => "Runs cleanup when a session ends.",
        "userpromptsubmit" => "Checks a prompt before it is sent.",
        "pretooluse" => "Checks a tool call before it runs.",
        "posttooluse" => "Runs after a tool call completes.",
        "posttoolusefailure" => "Handles a failed tool call.",
        "permissionrequest" => "Handles tool permission requests.",
        "notification" => "Handles session notifications.",
        "stop" => "Runs when the agent finishes responding.",
        "precompact" => "Preserves context before compaction.",
        "configchange" => "Responds to configuration changes.",
        "messagedisplay" => "Formats messages for display.",
        _ => "",
    };
    let command = hook["command"].as_str().unwrap_or_default();
    let script = command.split(|c: char| c.is_whitespace() || c == '"' || c == '\'').filter_map(|word| word.rsplit('/').next())
        .find(|word| [".py", ".sh", ".bash", ".zsh", ".mjs", ".js", ".rb", ".pl", ".ps1"].iter().any(|end| word.len() > end.len() && word.ends_with(end)));
    let name = hook["name"].as_str().or(script).or(plugin).or(hook["tool"].as_str()).unwrap_or(event);
    let status = if hook["enabled"] == false { "disabled" } else { hook["trustStatus"].as_str().unwrap_or("configured") };
    let fallback = format!("Runs on {event}.");
    let detail = hook["description"].as_str().or(hook["statusMessage"].as_str()).unwrap_or(if described.is_empty() { &fallback } else { described });
    let mut parts = vec![name.to_owned(), event.to_owned(), status.to_owned(), detail.to_owned()];
    if let Some(matcher) = matcher.or(hook["matcher"].as_str()).filter(|matcher| !matcher.is_empty()) {
        parts.push(format!("Matches: {matcher}"));
    }
    if let Some(plugin) = plugin {
        parts.push(format!("Plugin: {plugin}"));
    }
    parts.join(" · ")
}

/// Claude's `cx/catalog`: its skills (commands not built in), its visible built-ins, its MCP servers and mode.
pub fn claude_catalog(catalog: &Value) -> Catalog {
    let commands = catalog["commands"].as_array().cloned().unwrap_or_default();
    let names = |builtin: bool| -> Vec<String> {
        let mut names: Vec<String> = commands.iter().filter(|command| (command["builtin"] == true) == builtin).filter_map(|command| command["name"].as_str().map(str::to_owned)).filter(|name| !(builtin && name.starts_with('_'))).collect();
        names.sort();
        names
    };
    let mut mcp: Vec<String> = catalog["mcp_servers"].as_array().into_iter().flatten().filter_map(mcp_summary).collect();
    mcp.sort();
    let mode = catalog["current_permission_mode"].as_str().map(|mode| if mode == "bypassPermissions" { "bypass" } else { "ask" }.to_owned());
    Catalog { skills: names(false), commands: names(true), mcp, mode, ..Catalog::default() }
}

/// What the agent reports it has loaded. Codex lists its own; Claude's comes from its catalog (its hooks are read from
/// its settings files, not here); agy and Qwen list none, so the notes say where theirs live.
pub async fn catalog(connection: &Connection, provider: Provider, cwd: &str, thread: &str) -> Result<Catalog, AgentError> {
    match provider {
        Provider::Claude => Ok(claude_catalog(&connection.request("cx/catalog", json!({}), CLAUDE_CATALOG_TIMEOUT).await?)),
        Provider::Agy => Ok(Catalog {
            hooks: vec!["GateGuard and session-start memory: ~/.gemini/config/hooks.json".into()],
            skills: vec!["~/.gemini/config/skills (Claude's skills)".into()],
            mcp: vec!["lightpanda, agents-council: ~/.gemini/config/mcp_config.json".into()],
            notes: vec!["~/.gemini/GEMINI.md (CLAUDE.md)".into(), "~/.gemini/AGENTS.md (ERRORS.md)".into(), "Project CLAUDE.md files, by the SessionStart hook".into()],
            ..Catalog::default()
        }),
        Provider::Qwen => Ok(Catalog {
            hooks: vec!["Not supported by the Qwen adapter".into()],
            skills: vec!["No native skill catalog".into()],
            mcp: vec!["No MCP servers; run_command is built in".into()],
            notes: vec!["Project instructions are read by Qwen when working".into()],
            ..Catalog::default()
        }),
        Provider::Codex => {
            let unavailable = |error: AgentError| vec![format!("Catalog unavailable: {}", error.message)];
            let skills = connection.request("skills/list", json!({"cwds": [cwd], "forceReload": true}), CATALOG_TIMEOUT).await.map(|result| {
                let mut names: Vec<String> = result["data"].as_array().into_iter().flatten().flat_map(|group| group["skills"].as_array().cloned().unwrap_or_default())
                    .filter(|skill| skill["enabled"] != false).filter_map(|skill| skill["name"].as_str().map(str::to_owned)).collect();
                names.sort();
                names
            });
            let hooks = connection.request("hooks/list", json!({"threadId": thread}), CATALOG_TIMEOUT).await.map(|result| {
                result["data"].as_array().into_iter().flatten().flat_map(|group| group["hooks"].as_array().cloned().unwrap_or_default())
                    .map(|hook| hook_summary(&hook, hook["eventName"].as_str().unwrap_or("Hook"), None, None)).collect()
            });
            let mcp = mcp_servers(connection, thread).await;
            Ok(Catalog { skills: skills.unwrap_or_else(unavailable), hooks: hooks.unwrap_or_else(unavailable), mcp: mcp.unwrap_or_else(unavailable), ..Catalog::default() })
        }
    }
}

async fn mcp_servers(connection: &Connection, thread: &str) -> Result<Vec<String>, AgentError> {
    let (mut cursor, mut servers): (Option<String>, Vec<Value>) = (None, Vec::new());
    loop {
        let mut params = json!({"threadId": thread, "limit": MCP_PAGE, "detail": "toolsAndAuthOnly"});
        if let Some(cursor) = &cursor {
            params["cursor"] = cursor.clone().into();
        }
        let result = connection.request("mcpServerStatus/list", params, CATALOG_TIMEOUT).await?;
        servers.extend(result["data"].as_array().cloned().unwrap_or_default());
        cursor = result["nextCursor"].as_str().map(str::to_owned);
        if cursor.is_none() {
            let mut summaries: Vec<String> = servers.iter().filter_map(mcp_summary).collect();
            summaries.sort();
            return Ok(summaries);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offers_steer_and_send_now_only_where_the_adapter_answers_them() {
        let (codex, claude, agy, qwen) = (Provider::Codex.features(), Provider::Claude.features(), Provider::Agy.features(), Provider::Qwen.features());

        assert!(codex.steer && codex.compact && !codex.send_now);
        assert!(claude.steer && claude.send_now && claude.unsend && !claude.compact);
        assert!(!agy.steer && !agy.effort && agy.resume);
        assert!(!qwen.steer && !qwen.resume);
    }

    #[test]
    fn reads_models_and_their_efforts_from_a_model_list() {
        let list = json!({"data": [
            {"id": "gpt-5.5", "displayName": "GPT-5.5", "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "high"}], "defaultReasoningEffort": "high"},
            {"id": "qwen3.5-9b-abl"},
        ]});

        let models = models(&list);

        assert_eq!(models[0], Model { id: "gpt-5.5".into(), name: "GPT-5.5".into(), efforts: vec!["low".into(), "high".into()], default_effort: Some("high".into()) });
        assert_eq!((models[1].name.as_str(), models[1].efforts.len()), ("qwen3.5-9b-abl", 0));
    }

    #[test]
    fn sums_up_a_hook_by_its_script_and_an_mcp_server_by_its_tools() {
        let hook = json!({"command": "python3 ~/.claude/hooks/gateguard.py --strict"});
        let server = json!({"name": "lightpanda", "status": "connected", "tools": [{"name": "goto"}, {"name": "click"}]});

        assert_eq!(hook_summary(&hook, "PreToolUse", Some("Bash"), None), "gateguard.py · PreToolUse · configured · Checks a tool call before it runs. · Matches: Bash");
        assert_eq!(mcp_summary(&server).unwrap(), "lightpanda · connected · Tools: click, goto");
    }

    #[test]
    fn reads_claude_skills_builtins_and_mode_from_its_catalog() {
        let catalog = json!({"commands": [{"name": "compact", "builtin": true}, {"name": "_hidden", "builtin": true}, {"name": "fixture-skill", "builtin": false}],
            "mcp_servers": [{"name": "fixture-mcp", "status": "connected"}], "current_permission_mode": "bypassPermissions"});

        let read = claude_catalog(&catalog);

        assert_eq!((read.skills, read.commands), (vec!["fixture-skill".to_owned()], vec!["compact".to_owned()]));
        assert_eq!((read.mcp, read.mode), (vec!["fixture-mcp · connected".to_owned()], Some("bypass".to_owned())));
    }
}
