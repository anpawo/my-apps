//! The shell run with `--check`: its window is never shown, and what the page drew is read from the report it writes.

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use vcx_testkit::SwiftWorker;

const CHECK_TIMEOUT_SECONDS: &str = "40";

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!("vcx-shell-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn source(relative: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join(relative)
}

/// Runs the shell windowless and gives back the report of what its page drew.
fn check(scratch: &Path, arguments: &[&str]) -> Value {
    let report = scratch.join("report.json");
    let status = Command::new(env!("CARGO_BIN_EXE_vcx-shell")).args(arguments).arg("--check").arg(&report).args(["--check-timeout", CHECK_TIMEOUT_SECONDS]).status().unwrap();
    assert!(status.success(), "the shell ended with {status}");
    serde_json::from_str(&fs::read_to_string(report).unwrap()).unwrap()
}

fn kinds(report: &Value) -> Vec<&str> {
    report["rows"].as_array().unwrap().iter().map(|row| row["kind"].as_str().unwrap()).collect()
}

#[test]
fn draws_a_saved_session_in_a_window_that_is_never_shown() {
    let scratch = Scratch::new("saved");
    let picture = scratch.0.join("page.png");

    let report = check(&scratch.0, &["--demo", source("fixtures/demo_state.json").to_str().unwrap(), "--picture", picture.to_str().unwrap()]);

    assert_eq!(report["visibility"], "hidden");
    assert_eq!(kinds(&report), ["user", "activity", "assistant", "notice", "user"]);
    assert_eq!(report["rows"][1]["text"].as_str().unwrap().trim(), "3 actions");
    assert_eq!(report["status"], "Ready");
    assert_eq!(report["chips"][0], "vcx");
    let html = report["html"].as_str().unwrap();
    assert!(html.contains("<table>") && !html.contains("<script>alert"), "the answer's Markdown is drawn and its raw HTML is not");
    let widest = report["viewport"][0].as_i64().unwrap();
    for row in report["rows"].as_array().unwrap() {
        let (left, width, height) = (row["box"][0].as_i64().unwrap(), row["box"][2].as_i64().unwrap(), row["box"][3].as_i64().unwrap());
        assert!(height > 0 && left >= 0 && left + width <= widest, "row {} is laid out inside the page: {}", row["id"], row["box"]);
    }
    assert_eq!(fs::read(&picture).unwrap()[..8], *b"\x89PNG\r\n\x1a\n");
}

#[test]
fn draws_a_turn_of_a_swift_worker_from_prompt_to_answer() {
    let Some(worker) = SwiftWorker::start("shell") else {
        eprintln!("skipped: no Swift VCX binary (set VCX_SWIFT_BINARY)");
        return;
    };
    let scratch = Scratch::new("turn");

    let report = check(&scratch.0, &["--socket", worker.socket.to_str().unwrap(), "--cwd", worker.directory.to_str().unwrap(), "--prompt", "hello from the shell"]);

    assert_eq!(kinds(&report), ["user", "activity", "assistant"], "{:#}", report["rows"]);
    assert_eq!(report["rows"][0]["text"].as_str().unwrap().trim(), "hello from the shell");
    assert_eq!(report["rows"][1]["text"].as_str().unwrap().trim(), "echo fixture");
    assert!(report["rows"][2]["text"].as_str().unwrap().contains("Fixture answer"));
    assert!(report["html"].as_str().unwrap().contains("<strong>bold</strong>"));
    assert_eq!(report["notice"], Value::Null);
}

#[test]
fn returns_to_the_built_in_template_when_the_folder_one_never_starts() {
    let scratch = Scratch::new("broken");
    let folder = scratch.0.join("template");
    fs::create_dir(&folder).unwrap();
    for file in ["index.html", "style.css"] {
        fs::copy(source("template").join(file), folder.join(file)).unwrap();
    }
    fs::write(folder.join("manifest.json"), r#"{"name": "broken edit", "contract": 1}"#).unwrap();
    fs::write(folder.join("app.js"), "throw new Error('a broken edit');").unwrap();

    let report = check(&scratch.0, &["--demo", source("fixtures/demo_state.json").to_str().unwrap(), "--template", folder.to_str().unwrap()]);

    assert_eq!(report["template"], "VCX default");
    assert!(report["notice"].as_str().unwrap().contains("did not start"), "{}", report["notice"]);
    assert_eq!(kinds(&report).len(), 5);
}
