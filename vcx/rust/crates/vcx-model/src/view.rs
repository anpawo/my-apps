//! The data contract between the core and the page template. A template states the contract version it was written
//! for; the shell refuses one it does not speak and keeps the last template that worked.

use crate::item::{self, text};
use crate::{assets, markdown, requests};
use crate::state::{Changes, Object, Row, SessionState};
use serde_json::{Value, json};
use std::collections::HashSet;

pub const CONTRACT_VERSION: u32 = 1;

/// Metadata the page may read: the transcript's, the composer's (its palette and model lists) and the chrome's (status
/// bar, popovers, session panel). The rest of the worker's metadata (state paths, the account) stays in the core.
const PAGE_META_KEYS: [&str; 39] = [
    "model", "providerLabel", "status", "ready", "busy", "needsAttention", "cwd", "conversationName", "repository", "branch", "contextUsed", "contextLimit",
    "usagePercent", "activeMode", "effort", "backgroundTasks", "providerCommands", "models", "modelEfforts", "modelDefaultEfforts", "modelAliases",
    "defaultEffort", "recent", "usage", "usageLoading", "repositoryStatus", "repositoryChanges", "repositoryDirectory", "pullRequest", "pullRequestURL",
    "changing", "threadID", "hooks", "skills", "builtinCommands", "mcp", "instructions", "recalledRules", "recalledRuleSections",
];
const MODEL_PREFIXES: [&str; 4] = ["claude-", "claude ", "codex-", "codex "];
const AGENT_PROVIDERS: [&str; 5] = ["claude", "codex", "qwen", "agy", "agent"];

pub fn full(state: &SessionState) -> Value {
    json!({
        "contract": CONTRACT_VERSION,
        "meta": meta(state),
        "rows": state.rows.iter().map(|row| row_view(state, row)).collect::<Vec<_>>(),
        "draft": state.draft,
        "draftGeneration": state.draft_generation,
    })
}

/// Only what a patch changed: redrawn rows whole, the order when rows came or went, the metadata when it moved.
pub fn patch(state: &SessionState, changes: &Changes) -> Value {
    let mut view = Object::new();
    if changes.meta {
        view.insert("meta".into(), meta(state));
    }
    if changes.order {
        view.insert("order".into(), json!(state.rows.iter().map(|row| &row.id).collect::<Vec<_>>()));
    }
    let rows: HashSet<&str> = changes.rows.iter().map(String::as_str).collect();
    let items: HashSet<&str> = changes.items.iter().map(String::as_str).collect();
    let redrawn: Vec<Value> = state
        .rows
        .iter()
        .filter(|row| rows.contains(row.id.as_str()) || row.items.iter().any(|item| items.contains(item.as_str())))
        .map(|row| row_view(state, row))
        .collect();
    if !redrawn.is_empty() {
        view.insert("rows".into(), Value::Array(redrawn));
    }
    if changes.draft {
        view.insert("draft".into(), json!(state.draft));
        view.insert("draftGeneration".into(), json!(state.draft_generation));
    }
    Value::Object(view)
}

fn meta(state: &SessionState) -> Value {
    let mut view: Object = PAGE_META_KEYS.iter().filter_map(|key| state.meta.get(*key).map(|value| ((*key).to_owned(), value.clone()))).collect();
    view.insert("modelLabel".into(), json!(model_label(&state.meta)));
    if let Some(provider) = state.meta.get("account").and_then(|account| account.get("provider")).filter(|provider| provider.is_string()) {
        view.insert("provider".into(), provider.clone());
    }
    view.insert("requests".into(), Value::Array(requests::views(state.meta.get("permissions"))));
    Value::Object(view)
}

/// The model's name as the status bar and the debates show it, ported from `Session.modelLabel`.
fn model_label(meta: &Object) -> String {
    let model = text(meta, "model").unwrap_or_default();
    if model.is_empty() || (meta.get("ready") != Some(&Value::Bool(true)) && model == "Codex") {
        return "Not connected".into();
    }
    model_name(meta.get("modelAliases").and_then(|aliases| aliases.get(model)).and_then(Value::as_str).unwrap_or(model))
}

/// The Swift `modelName`: `claude-opus-5-5` reads "Opus 5.5".
fn model_name(id: &str) -> String {
    let lowered = id.to_ascii_lowercase();
    let bare = MODEL_PREFIXES.iter().find(|prefix| lowered.starts_with(*prefix)).map_or(id, |prefix| &id[prefix.len()..]);
    let numbered = version(bare).unwrap_or_else(|| bare.to_owned());
    numbered.replace('-', " ").split(' ').map(capitalized).collect::<Vec<_>>().join(" ")
}

/// `-(\d+)-(\d+)$` read as " $1.$2".
fn version(id: &str) -> Option<String> {
    let (rest, minor) = id.rsplit_once('-')?;
    let (head, major) = rest.rsplit_once('-')?;
    let digits = |part: &str| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit());
    (digits(major) && digits(minor)).then(|| format!("{head} {major}.{minor}"))
}

/// Foundation's `capitalized` on one word: its first letter upper case, the rest lower case.
fn capitalized(word: &str) -> String {
    let mut letters = word.chars();
    letters.next().map(|first| first.to_uppercase().chain(letters.flat_map(char::to_lowercase)).collect()).unwrap_or_default()
}

fn row_view(state: &SessionState, row: &Row) -> Value {
    let data: Vec<&Object> = row.items.iter().filter_map(|id| state.items.get(id)).collect();
    let kind = item::row_kind(&row.kind, &data);
    let items: Vec<Value> = data.iter().map(|item| item_view(kind, item)).collect();
    json!({"id": row.id, "kind": kind, "items": items})
}

fn item_view(row_kind: &str, data: &Object) -> Value {
    let kind = item::kind(data);
    let mut view = json!({"id": text(data, "id").unwrap_or_default(), "type": kind});
    match (row_kind, kind) {
        (_, "agentMessage") => {
            view["html"] = json!(markdown::to_html(text(data, "text").unwrap_or_default()));
            view["provider"] = json!(text(data, "provider"));
            view["endedTurn"] = json!(data.get("endedTurn") == Some(&Value::Bool(true)));
        }
        (_, "userMessage") => user_view(data, &mut view),
        ("notice", _) => {
            view["text"] = json!(text(data, "text").unwrap_or_default());
            if let Some(link) = text(data, "link") {
                view["link"] = json!({"path": link, "label": home_relative(link)});
            }
        }
        ("debate", _) => {
            let turns = item::debate_turns(&item::output(data));
            view["turns"] = Value::Array(turns.into_iter().map(|turn| json!({"speaker": turn.speaker, "model": turn.model, "html": markdown::to_html(&turn.text)})).collect());
            tool_view(data, &mut view);
        }
        _ => tool_view(data, &mut view),
    }
    view
}

fn tool_view(data: &Object, view: &mut Value) {
    let title = item::title(data);
    let command = text(data, "command").filter(|command| *command != title);
    view["title"] = json!(title);
    view["output"] = json!(item::output(data));
    view["failed"] = json!(item::failed(data));
    view["status"] = json!(text(data, "status").unwrap_or_default());
    if let Some(command) = command {
        view["command"] = json!(command);
    }
    if item::kind(data) == "peerMessage" {
        view["text"] = json!(text(data, "text").unwrap_or_default());
        view["direction"] = json!(text(data, "direction").unwrap_or("received"));
    }
    // Qwen's steps: a live counter while one runs, its duration once done.
    if let Some(started) = data.get("stepStartedAt").and_then(Value::as_f64).filter(|_| text(data, "status") == Some("inProgress")) {
        view["startedAt"] = json!(started);
    } else if let Some(seconds) = data.get("seconds").and_then(Value::as_i64) {
        view["seconds"] = json!(seconds);
    }
}

fn user_view(data: &Object, view: &mut Value) {
    let joined: String = pieces(data, "text", "text").collect();
    view["queued"] = json!(data.get("queued") == Some(&Value::Bool(true)));
    view["images"] = json!(pieces(data, "localImage", "path").collect::<Vec<_>>());
    if let Some(recalled) = data.get("recalled").and_then(Value::as_array).filter(|lines| !lines.is_empty()) {
        view["recalled"] = json!(recalled);
    }
    if let Some(message) = agent_message(&joined) {
        view["text"] = json!(message.body);
        view["from"] = json!(format!("{}-{}", message.provider, message.name));
        view["content"] = json!([{"type": "text", "text": message.body}]);
        return;
    }
    view["text"] = json!(joined);
    view["content"] = Value::Array(content_runs(data));
}

/// Pictures pasted together share a run; each is numbered across the message, as the Swift `PictureRow` numbers them.
fn content_runs(data: &Object) -> Vec<Value> {
    let mut runs: Vec<Value> = Vec::new();
    let mut number = 0;
    for piece in data.get("content").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_object) {
        if text(piece, "type") == Some("text") {
            runs.push(json!({"type": "text", "text": text(piece, "text").unwrap_or_default()}));
            continue;
        }
        number += 1;
        let source = text(piece, "path").map(|path| format!("vcx://image/{}", assets::image(path)));
        let picture = json!({"title": format!("Image #{number}"), "src": source});
        match runs.last_mut() {
            Some(run) if run["type"] == "pictures" => run["pictures"].as_array_mut().expect("a pictures run holds an array").push(picture),
            _ => runs.push(json!({"type": "pictures", "pictures": [picture]})),
        }
    }
    runs
}

struct AgentMessage<'a> {
    provider: &'a str,
    name: &'a str,
    body: &'a str,
}

/// Another window's agent wrote it, shaped `claude from [<window name>]: "<text>"`, as `AgentMessages.parse` reads it.
fn agent_message(text: &str) -> Option<AgentMessage<'_>> {
    let (provider, rest) = text.split_once(" from [")?;
    let (name, quoted) = rest.split_once("]: \"")?;
    let body = quoted.strip_suffix('"')?;
    AGENT_PROVIDERS.contains(&provider).then_some(AgentMessage { provider, name, body })
}

fn home_relative(path: &str) -> String {
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && path.starts_with(&home) => format!("~{}", &path[home.len()..]),
        _ => path.to_owned(),
    }
}

fn pieces<'a>(data: &'a Object, kind: &'a str, key: &'a str) -> impl Iterator<Item = &'a str> {
    data.get("content").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_object).filter(move |piece| text(piece, "type") == Some(kind)).filter_map(move |piece| text(piece, key))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> SessionState {
        let snapshot = json!({
            "model": "fable", "busy": true, "stateDirectory": "/private/state", "account": {"name": "secret"},
            "rows": [
                {"id": "R1", "kind": "user", "items": [{"id": "u1", "type": "userMessage", "content": [{"type": "text", "text": "show "}, {"type": "localImage", "path": "/tmp/a.png"}, {"type": "text", "text": "this"}]}]},
                {"id": "R2", "kind": "activity", "items": [{"id": "t1", "type": "commandExecution", "command": "ls", "aggregatedOutput": "a\nb", "exitCode": 0}]},
                {"id": "R3", "kind": "assistant", "items": [{"id": "a1", "type": "agentMessage", "text": "**done**"}]}
            ]
        });
        SessionState::from_snapshot(snapshot.as_object().unwrap())
    }

    #[test]
    fn gives_the_page_rendered_rows_and_only_the_allowed_metadata() {
        let view = full(&state());

        assert_eq!(view["contract"], CONTRACT_VERSION);
        assert_eq!(view["meta"], json!({"model": "fable", "busy": true, "modelLabel": "Fable", "requests": []}));
        assert_eq!(view["rows"][0]["items"][0]["text"], "show this");
        assert_eq!(view["rows"][0]["items"][0]["images"], json!(["/tmp/a.png"]));
        assert_eq!(view["rows"][1]["items"][0]["title"], "ls");
        assert_eq!(view["rows"][1]["items"][0]["output"], "a\nb\nExit: 0");
        assert_eq!(view["rows"][2]["items"][0]["html"], "<p><strong>done</strong></p>\n");
    }

    #[test]
    fn redraws_only_the_row_whose_item_changed() {
        let mut state = state();
        let update = json!({"items": [{"id": "a1", "type": "agentMessage", "text": "done, really"}]});

        let changes = state.apply_patch(update.as_object().unwrap());
        let view = patch(&state, &changes);

        assert_eq!(view, json!({"rows": [{"id": "R3", "kind": "assistant", "items": [{"id": "a1", "type": "agentMessage", "html": "<p>done, really</p>\n", "provider": null, "endedTurn": false}]}]}));
    }

    #[test]
    fn sends_the_order_when_a_row_arrives() {
        let mut state = state();
        let update = json!({"items": [{"id": "n1", "text": "Stopped."}], "rowUpdates": [{"id": "R4", "kind": "notice", "itemIDs": ["n1"]}], "rowOrder": ["R1", "R2", "R3", "R4"]});

        let changes = state.apply_patch(update.as_object().unwrap());
        let view = patch(&state, &changes);

        assert_eq!(view["order"], json!(["R1", "R2", "R3", "R4"]));
        assert_eq!(view["rows"], json!([{"id": "R4", "kind": "notice", "items": [{"id": "n1", "type": "activity", "text": "Stopped."}]}]));
    }

    #[test]
    fn numbers_the_pictures_of_a_message_and_serves_them_by_a_registered_name() {
        let view = full(&state());

        let content = &view["rows"][0]["items"][0]["content"];
        let source = content[1]["pictures"][0]["src"].as_str().unwrap();
        assert_eq!((&content[0]["text"], &content[1]["pictures"][0]["title"], &content[2]["text"]), (&json!("show "), &json!("Image #1"), &json!("this")));
        assert_eq!(assets::image_path(source.strip_prefix("vcx://image/").unwrap()).unwrap().to_str(), Some("/tmp/a.png"));
    }

    #[test]
    fn tells_a_message_from_another_window_by_its_sender() {
        let snapshot = json!({"rows": [{"id": "R1", "kind": "user", "items": [{"id": "u1", "type": "userMessage", "content": [{"type": "text", "text": "codex from [Rust app]: \"done here\""}]}]}]});

        let view = full(&SessionState::from_snapshot(snapshot.as_object().unwrap()));

        let item = &view["rows"][0]["items"][0];
        assert_eq!((&item["from"], &item["text"]), (&json!("codex-Rust app"), &json!("done here")));
    }

    #[test]
    fn draws_a_debate_command_as_turns_and_names_the_model_as_the_status_bar_does() {
        let output = "<<debate claude>>\n**mine**\n<<debate codex gpt-6.2>>\ntheirs";
        let snapshot = json!({"model": "claude-fable-5-2", "ready": true, "rows": [{"id": "R1", "kind": "activity", "items": [{"id": "d1", "type": "commandExecution", "command": "ask-codex.sh brief", "aggregatedOutput": output, "exitCode": 0}]}]});

        let view = full(&SessionState::from_snapshot(snapshot.as_object().unwrap()));

        assert_eq!(view["rows"][0]["kind"], "debate");
        assert_eq!(view["rows"][0]["items"][0]["turns"][0], json!({"speaker": "claude", "model": "", "html": "<p><strong>mine</strong></p>\n"}));
        assert_eq!(view["rows"][0]["items"][0]["turns"][1]["model"], "gpt-6.2");
        assert_eq!(view["meta"]["modelLabel"], "Fable 5.2");
    }

    #[test]
    fn gives_an_action_its_command_and_its_duration() {
        let snapshot = json!({"rows": [{"id": "R1", "kind": "activity", "items": [
            {"id": "t1", "type": "commandExecution", "command": "Read\n{\"file_path\": \"/a/b.rs\"}", "seconds": 75, "status": "completed"},
            {"id": "t2", "type": "reasoning", "description": "Thinking", "stepStartedAt": 1700000000.5, "status": "inProgress"}
        ]}]});

        let view = full(&SessionState::from_snapshot(snapshot.as_object().unwrap()));

        let items = &view["rows"][0]["items"];
        assert_eq!((&items[0]["title"], &items[0]["command"], &items[0]["seconds"]), (&json!("Read b.rs"), &json!("Read\n{\"file_path\": \"/a/b.rs\"}"), &json!(75)));
        assert_eq!((&items[1]["startedAt"], items[1].get("command")), (&json!(1700000000.5), None));
    }

    #[test]
    fn hands_the_page_the_pending_question_from_the_metadata() {
        let snapshot = json!({"permissions": [{"id": "P1", "rpcID": 3, "method": "item/tool/requestUserInput", "params": {"questions": [{"id": "q", "question": "Which?", "options": [{"label": "A"}]}]}}], "rows": []});

        let view = full(&SessionState::from_snapshot(snapshot.as_object().unwrap()));

        assert_eq!(view["meta"]["requests"][0]["questions"][0]["question"], "Which?");
        assert!(view["meta"].get("permissions").is_none(), "the raw request stays in the core");
    }

    #[test]
    fn names_a_model_as_the_swift_status_bar_does() {
        let names = ["claude-opus-5-5", "fable-5-2", "Codex gpt-6.2-sol", "claude-sonnet-5"].map(model_name);

        assert_eq!(names, ["Opus 5.5", "Fable 5.2", "Gpt 6.2 Sol", "Sonnet 5"]);
    }

    #[test]
    fn hands_the_page_the_provider_of_the_account_and_the_draft_generation() {
        let snapshot = json!({"account": {"provider": "claude", "name": "secret"}, "draft": [], "draftGeneration": 4, "rows": []});

        let view = full(&SessionState::from_snapshot(snapshot.as_object().unwrap()));

        assert_eq!((&view["meta"]["provider"], &view["draftGeneration"]), (&json!("claude"), &json!(4)));
        assert!(view["meta"].get("account").is_none(), "the account itself stays in the core");
    }
}
