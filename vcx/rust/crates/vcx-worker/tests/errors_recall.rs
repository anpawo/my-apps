//! The ERRORS lines the worker recalls with a prompt, as the Swift `ErrorsRecall`: sent to the agent once, kept off
//! the shown prompt, and listed with the heading each sits under. The ERRORS file is the test folder's own.

use serde_json::{Value, json};
use std::path::Path;
use vcx_conformance::Target;
use vcx_conformance::peer::Held;
use vcx_model::SessionState;
use vcx_testkit::{RUNTIME, RustWorker};

const RULE: &str = "Build the vcx worker through build-stack, one build at a time.";
const OTHER_RULES: usize = 20;

fn meta<'a>(state: &'a SessionState, key: &str) -> &'a Value {
    state.meta.get(key).unwrap_or(&Value::Null)
}

fn errors_file(worker: &RustWorker) {
    let claude = worker.directory.join(RUNTIME).join(".claude");
    std::fs::create_dir_all(&claude).unwrap();
    let others: Vec<String> = (0..OTHER_RULES).map(|index| format!("- Unrelated rule number {index} about mail folders.")).collect();
    std::fs::write(claude.join("ERRORS.md"), format!("# Errors\n\n## Builds\n- {RULE}\n\n## Other\n{}\n", others.join("\n"))).unwrap();
}

#[test]
fn recalls_a_matching_errors_line_keeps_it_off_the_prompt_and_names_its_section() {
    let worker = RustWorker::start_with_history(Path::new(env!("CARGO_BIN_EXE_vcx-worker")), "errors-recall");
    errors_file(&worker);
    let mut held = Held::open(&Target { socket: worker.socket.clone(), directory: worker.directory.clone(), pid: worker.pid() });

    held.turn("build the vcx worker through build-stack, one build at a time");

    let state = held.replica.state().unwrap();
    assert_eq!(meta(state, "recalledRules"), &json!([RULE]));
    assert_eq!(meta(state, "recalledRuleSections"), &json!({RULE: "Builds"}));
    let prompt = state.rows.iter().find(|row| row.kind == "user").and_then(|row| state.items.get(&row.items[0])).unwrap();
    assert!(!prompt["content"].to_string().contains("VCX note"), "{prompt:?}");
    assert_eq!(prompt["recalled"], json!([RULE]));
}
