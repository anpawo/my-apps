//! The shell run with `--check`: its window is never shown, and what the page drew is read from the report it writes.

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::thread;
use std::time::{Duration, Instant};
use vcx_testkit::SwiftWorker;

const CHECK_TIMEOUT_SECONDS: &str = "40";
const REPORT_WAIT: Duration = Duration::from_secs(30);
const REPORT_POLL: Duration = Duration::from_millis(50);

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

/// The whole built-in template, every file its page loads, into `folder`.
fn copy_template(folder: &Path) {
    let status = Command::new("/bin/cp").arg("-R").arg(source("template")).arg(folder).status().unwrap();
    assert!(status.success(), "cannot copy the template");
}

/// Runs the shell windowless and gives back the report of what its page drew.
fn check(scratch: &Path, arguments: &[&str]) -> Value {
    let report = scratch.join("report.json");
    let status = Command::new(env!("CARGO_BIN_EXE_vcx-shell")).args(arguments).arg("--check").arg(&report).args(["--check-timeout", CHECK_TIMEOUT_SECONDS]).status().unwrap();
    assert!(status.success(), "the shell ended with {status}");
    serde_json::from_str(&fs::read_to_string(report).unwrap()).unwrap()
}

/// A shell left running by a failed test is stopped with it.
struct Shell(Child);

impl Drop for Shell {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Waits for the report the shell writes once its page took `edits` template edits.
fn report_after(report: &Path, edits: u64) -> Value {
    let deadline = Instant::now() + REPORT_WAIT;
    loop {
        let read: Option<Value> = fs::read_to_string(report).ok().and_then(|text| serde_json::from_str(&text).ok());
        match read {
            Some(read) if read["edits"] == edits => return read,
            _ if Instant::now() > deadline => panic!("no report after {edits} template edits"),
            _ => thread::sleep(REPORT_POLL),
        }
    }
}

fn append(file: &Path, text: &str) {
    fs::write(file, fs::read_to_string(file).unwrap() + text).unwrap();
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
    // Tool activity folds into one closed block that shows its count, as the Swift WorkBlock.
    assert!(report["html"].as_str().unwrap().contains(r#"<span class="count">3 actions</span>"#));
    assert_eq!(report["status"], "Ready");
    assert_eq!(report["chips"][0], "vcx");
    let html = report["html"].as_str().unwrap();
    assert!(html.contains("<table>") && !html.contains("<script>alert"), "the answer's Markdown is drawn and its raw HTML is not");
    let widest = report["viewport"][0].as_i64().unwrap();
    for row in report["rows"].as_array().unwrap().iter().filter(|row| row["kind"] != "activity") {
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
    assert!(report["html"].as_str().unwrap().contains(r#"<span class="title">echo fixture</span>"#));
    assert!(report["rows"][2]["text"].as_str().unwrap().contains("Fixture answer"));
    assert!(report["html"].as_str().unwrap().contains("<strong>bold</strong>"));
    assert_eq!(report["notice"], Value::Null);
}

#[test]
fn takes_real_keys_and_a_real_click_in_a_window_that_is_never_shown() {
    const TYPED: &str = "typed with real keys 42";
    let Some(worker) = SwiftWorker::start("keys") else {
        eprintln!("skipped: no Swift VCX binary (set VCX_SWIFT_BINARY)");
        return;
    };
    let scratch = Scratch::new("keys");

    let report = check(&scratch.0, &["--socket", worker.socket.to_str().unwrap(), "--cwd", worker.directory.to_str().unwrap(), "--check-type", TYPED]);

    assert_eq!(kinds(&report), ["user", "activity", "assistant"], "{:#}", report["rows"]);
    assert_eq!(report["rows"][0]["text"].as_str().unwrap().trim(), TYPED, "the worker got the keys in order, sent by the click");
    assert!(report["rows"][2]["text"].as_str().unwrap().contains("Fixture answer"));
}

#[test]
fn takes_text_composed_by_an_input_method_in_a_window_that_is_never_shown() {
    const COMPOSED: &str = "かな変換é";
    let Some(worker) = SwiftWorker::start("ime") else {
        eprintln!("skipped: no Swift VCX binary (set VCX_SWIFT_BINARY)");
        return;
    };
    let scratch = Scratch::new("ime");

    let report = check(&scratch.0, &["--socket", worker.socket.to_str().unwrap(), "--cwd", worker.directory.to_str().unwrap(), "--check-type", COMPOSED]);

    assert_eq!(report["rows"][0]["text"].as_str().unwrap().trim(), COMPOSED);
    assert!(report["html"].as_str().unwrap().contains(r#"data-composed="5""#), "each character went through a composition");
    assert_eq!(kinds(&report), ["user", "activity", "assistant"], "the marked text sent nothing before the click: {:#}", report["rows"]);
}

#[test]
fn returns_to_the_built_in_template_when_the_folder_one_never_starts() {
    let scratch = Scratch::new("broken");
    let folder = scratch.0.join("template");
    copy_template(&folder);
    fs::write(folder.join("manifest.json"), r#"{"name": "broken edit", "contract": 1}"#).unwrap();
    fs::write(folder.join("app.js"), "throw new Error('a broken edit');").unwrap();

    let report = check(&scratch.0, &["--demo", source("fixtures/demo_state.json").to_str().unwrap(), "--template", folder.to_str().unwrap()]);

    assert_eq!(report["template"], "VCX default");
    assert!(report["notice"].as_str().unwrap().contains("did not start"), "{}", report["notice"]);
    assert_eq!(kinds(&report).len(), 5);
}

#[test]
fn applies_template_edits_to_the_open_page_and_survives_a_broken_one() {
    const EDITED_BACKGROUND: &str = "rgb(1, 2, 3)";
    let scratch = Scratch::new("edits");
    let folder = scratch.0.join("template");
    copy_template(&folder);
    let report = scratch.0.join("report.json");
    let demo = source("fixtures/demo_state.json");
    let arguments = ["--demo", demo.to_str().unwrap(), "--template", folder.to_str().unwrap(), "--check", report.to_str().unwrap(), "--check-after-edits", "3", "--check-timeout", CHECK_TIMEOUT_SECONDS];
    let mut shell = Shell(Command::new(env!("CARGO_BIN_EXE_vcx-shell")).args(arguments).spawn().unwrap());

    let opened = report_after(&report, 0);
    append(&folder.join("style.css"), &format!("\nbody {{ background: {EDITED_BACKGROUND}; }}\n"));
    let restyled = report_after(&report, 1);
    append(&folder.join("app.js"), "\ndocument.body.dataset.edited = 'yes';\n");
    let reloaded = report_after(&report, 2);
    fs::write(folder.join("app.js"), "throw new Error('a broken edit');").unwrap();
    let status = shell.0.wait().unwrap();
    let broken = report_after(&report, 3);

    assert!(status.success(), "the shell ended with {status}");
    assert_ne!(opened["background"], EDITED_BACKGROUND);
    let script_edited = |report: &Value| report["html"].as_str().unwrap().contains(r#"data-edited="yes""#);
    assert_eq!((&restyled["background"], &restyled["reloads"], script_edited(&restyled)), (&json!(EDITED_BACKGROUND), &json!(0), false), "a style edit is applied without loading the page again");
    assert_eq!((&reloaded["background"], &reloaded["reloads"], script_edited(&reloaded)), (&json!(EDITED_BACKGROUND), &json!(1), true));
    assert_eq!(kinds(&reloaded).len(), 5, "the page loaded again shows the session again");
    assert_eq!((script_edited(&broken), kinds(&broken).len()), (true, 5), "the broken edit gave way to the page before it");
    assert!(broken["notice"].as_str().unwrap().contains("did not start"), "{}", broken["notice"]);
}
