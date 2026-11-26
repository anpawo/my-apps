//! The command palette's and the sidebar's lists, as the Swift `refreshCapabilities` fills them: the skills and hooks
//! the Codex fixture reads from its home, his instruction files, and a skill typed as `/name` going to Codex as
//! `$name` with its skill piece. The home is the test worker's own runtime folder.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use vcx_conformance::Target;
use vcx_conformance::peer::Held;
use vcx_model::SessionState;
use vcx_testkit::{RUNTIME, RustWorker};

const SKILL: &str = "fixture-skill";
const HOOK: &str = "gateguard.py · PreToolUse · configured · Checks a tool call before it runs. · Matches: Bash";

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// One skill, one hook and one instruction file in the worker's Codex home; returns the skill's file.
fn home_files(worker: &RustWorker) -> PathBuf {
    let codex = worker.directory.join(RUNTIME).join(".codex");
    let skill = codex.join("skills").join(SKILL).join("SKILL.md");
    write(&skill, &format!("---\nname: {SKILL}\ndescription: Fixture skill\n---\nSay done.\n"));
    let hooks = json!({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 /hooks/gateguard.py"}]}]}});
    write(&codex.join("hooks.json"), &hooks.to_string());
    write(&codex.join("AGENTS.md"), "Fixture instructions.\n");
    skill
}

fn listed(state: &SessionState) -> bool {
    meta(state, "skills") == &json!([SKILL])
}

fn open(name: &str) -> (RustWorker, PathBuf, Held) {
    let worker = RustWorker::start_with_history(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), name);
    let skill = home_files(&worker);
    let mut held = Held::open(&Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() });
    held.follow(listed);
    (worker, skill, held)
}

#[test]
fn lists_the_skill_hook_and_instruction_file_of_its_home() {
    let (_worker, skill, held) = open("capabilities");

    let state = held.replica.state().unwrap();

    assert_eq!(meta(state, "hooks"), &json!([HOOK]));
    assert_eq!(meta(state, "instructions"), &json!(["~/.codex/AGENTS.md"]));
    assert_eq!(meta(state, "skillPaths"), &json!({SKILL: skill}));
    let command = json!({"name": format!("/{SKILL}"), "detail": "Fixture skill", "source": "Codex skill", "insert": format!("/{SKILL} "), "isCurrent": false});
    assert_eq!(meta(state, "providerCommands"), &json!([command]));
}

#[test]
fn sends_a_typed_skill_as_its_codex_name_with_the_skill_and_shows_it_as_typed() {
    let (worker, skill, mut held) = open("skill-send");

    held.turn(&format!("/codex:skill:{SKILL} go"));

    let state = held.replica.state().unwrap();
    let shown = state.rows.iter().find(|row| row.kind == "user").and_then(|row| state.items.get(&row.items[0])).unwrap();
    assert_eq!(shown["content"][0]["text"], format!("/{SKILL} go"));
    let history: Value = serde_json::from_str(&std::fs::read_to_string(worker.directory.join("history.json")).unwrap()).unwrap();
    let sent = history.as_object().unwrap().values().flat_map(|turns| turns.as_array().unwrap()).flat_map(|turn| turn["items"].as_array().unwrap())
        .find(|item| item["type"] == "userMessage").map(|item| item["content"].clone()).unwrap();
    assert_eq!(sent, json!([{"type": "text", "text": format!("${SKILL} go")}, {"type": "skill", "name": SKILL, "path": skill}]));
}
