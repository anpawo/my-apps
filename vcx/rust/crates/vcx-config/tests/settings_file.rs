//! `settings.json` as the Swift app and `background.py` write it, read and written back on copies in scratch folders.
//! The fixtures were written by the Swift app's own `JSONEncoder` over its `Preferences` and by `background.py`'s
//! `mark_limit`, with made-up accounts.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};
use vcx_config::homes::home_directory;
use vcx_config::json::Json;
use vcx_config::{Account, SettingsFile, Style};

const SWIFT: &[u8] = include_bytes!("fixtures/swift-settings.json");
const PYTHON: &[u8] = include_bytes!("fixtures/python-settings.json");
const BACKGROUND: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../background.py");
/// How long the Python side holds the lock; the Rust write must wait it out.
const HELD: Duration = Duration::from_millis(600);
const WRITERS: usize = 8;

struct Scratch(PathBuf);

impl Scratch {
    fn new(bytes: Option<&[u8]>) -> Scratch {
        let root = std::env::temp_dir().join(format!("vcx-config-settings-{}-{}", std::process::id(), uuid::Uuid::new_v4().simple()));
        vcx_config::private_folder(&root).unwrap();
        if let Some(bytes) = bytes {
            fs::write(root.join("settings.json"), bytes).unwrap();
        }
        Scratch(root)
    }

    fn file(&self) -> SettingsFile {
        SettingsFile::new(&self.0)
    }

    fn bytes(&self) -> Vec<u8> {
        fs::read(self.0.join("settings.json")).unwrap()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// What `background.py`'s own `preferences()` reads from the folder.
fn python_preferences(folder: &Path) -> serde_json::Value {
    let program = format!(
        "import importlib.util, json, sys\nspec = importlib.util.spec_from_file_location('background', {BACKGROUND:?})\nmodule = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\nprint(json.dumps(module.preferences()))"
    );
    let output = Command::new("/usr/bin/python3").args(["-I", "-c", &program]).env("VCX_CONFIG_HOME", folder).env("VCX_STATE_HOME", folder.join("state")).output().unwrap();
    assert!(output.status.success(), "background.py could not read the settings");
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn writes_a_swift_written_file_back_byte_for_byte() {
    let scratch = Scratch::new(Some(SWIFT));

    let settings = scratch.file().update(|_| {}).unwrap();

    assert!(scratch.bytes() == SWIFT, "the Swift file changed on a write with no change");
    assert_eq!(settings.style(), Style::Swift);
    assert_eq!(settings.default_provider(), "claude");
    assert_eq!(settings.accounts().len(), 3);
    assert_eq!(settings.accounts()[2].name, "Compte é \"deux\" 🚀\tTab");
    assert!(!settings.accounts()[2].enabled);
    assert_eq!(settings.limit("claude-default"), Some(1764095623.512978));
    assert!(settings.qwen().wake);
}

#[test]
fn writes_a_python_written_file_back_byte_for_byte() {
    let scratch = Scratch::new(Some(PYTHON));

    let settings = scratch.file().update(|_| {}).unwrap();

    assert!(scratch.bytes() == PYTHON, "the Python file changed on a write with no change");
    assert_eq!(settings.style(), Style::Python);
    assert_eq!(settings.accounts()[2].name, "Compte é \"deux\" 🚀\tTab");
}

#[test]
fn writes_his_own_settings_file_back_byte_for_byte_on_a_copy() {
    let real = home_directory().join("Library/Application Support/VCX/settings.json");
    let Ok(bytes) = fs::read(&real) else {
        eprintln!("no settings file at the default place: only the fixtures were checked");
        return;
    };
    let scratch = Scratch::new(Some(&bytes));

    let settings = scratch.file().update(|_| {}).unwrap();

    // His accounts stay out of the test output: only whether the bytes match is said.
    assert!(scratch.bytes() == bytes, "his settings file did not come back byte for byte");
    assert!(!settings.accounts().is_empty());
}

#[test]
fn changes_only_the_limit_it_sets_and_keeps_a_key_it_does_not_know() {
    let mut original: Vec<u8> = SWIFT[..SWIFT.len() - 1].to_vec();
    original.extend_from_slice(br#","rustOnly":{"x":[1,2]}}"#);
    let scratch = Scratch::new(Some(&original));

    scratch.file().update(|settings| settings.set_limit("codex-default", 1764000300.25).unwrap()).unwrap();

    let written = String::from_utf8(scratch.bytes()).unwrap();
    let expected = String::from_utf8(original).unwrap().replace(r#""codex-default":1764000000"#, r#""codex-default":1764000300.25"#);
    assert_eq!(written, expected);
}

#[test]
fn writes_a_new_account_and_limit_that_background_py_reads() {
    let scratch = Scratch::new(Some(SWIFT));
    let account = Account { id: "A1".into(), name: "Third/é".into(), provider: "codex".into(), home: Some("/tmp/codex home".into()), enabled: true };

    scratch.file().update(|settings| {
        settings.add_account(&account);
        settings.set_limit("A1", 1764000000.0).unwrap();
    }).unwrap();

    let preferences = python_preferences(&scratch.0);
    assert!(String::from_utf8(scratch.bytes()).unwrap().contains(r#"{"id":"A1","name":"Third\/é","provider":"codex","home":"\/tmp\/codex home","enabled":true}"#));
    assert_eq!(preferences["accounts"][3]["home"], "/tmp/codex home");
    assert_eq!(preferences["limits"]["A1"], 1764000000);
    assert_eq!(preferences["defaultProvider"], "claude");
}

#[test]
fn reads_what_background_py_marks_as_limited() {
    let scratch = Scratch::new(Some(SWIFT));
    let program = format!(
        "import importlib.util\nspec = importlib.util.spec_from_file_location('background', {BACKGROUND:?})\nmodule = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\nmodule.mark_limit({{'id': 'claude-default'}})"
    );
    let before = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64();

    let status = Command::new("/usr/bin/python3").args(["-I", "-c", &program]).env("VCX_CONFIG_HOME", &scratch.0).env("VCX_STATE_HOME", scratch.0.join("state")).status().unwrap();

    let settings = scratch.file().load().unwrap();
    assert!(status.success());
    assert_eq!(settings.style(), Style::Python);
    assert!(settings.limit("claude-default").unwrap() > before);
    assert!(settings.available("claude", before).iter().all(|account| account.id != "claude-default"));
}

#[test]
fn waits_for_the_lock_background_py_holds() {
    let scratch = Scratch::new(Some(SWIFT));
    let program = format!("import fcntl, sys, time\nlock = open(sys.argv[1], 'a')\nfcntl.flock(lock, fcntl.LOCK_EX)\nprint('held', flush=True)\ntime.sleep({})", HELD.as_secs_f64());
    let mut holder = Command::new("/usr/bin/python3")
        .args(["-I", "-c", &program])
        .arg(scratch.0.join("settings.lock"))
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut line = String::new();
    std::io::BufRead::read_line(&mut std::io::BufReader::new(holder.stdout.take().unwrap()), &mut line).unwrap();
    let start = Instant::now();

    scratch.file().update(|settings| settings.set_mode("default")).unwrap();

    let waited = start.elapsed();
    holder.wait().unwrap();
    assert_eq!(line.trim(), "held");
    assert!(waited >= HELD / 2, "the write went through while background.py held the lock ({waited:?})");
    assert_eq!(scratch.file().load().unwrap().mode(), "default");
}

#[test]
fn loses_no_write_when_several_writers_race() {
    let scratch = Scratch::new(None);

    std::thread::scope(|scope| {
        for writer in 0..WRITERS {
            let file = scratch.file();
            scope.spawn(move || file.update(|settings| settings.set_limit(&format!("w{writer}"), writer as f64).unwrap()).unwrap());
        }
    });

    let settings = scratch.file().load().unwrap();
    assert_eq!(settings.limits().len(), WRITERS);
    assert_eq!(settings.get("limits").and_then(|limits| limits.get("w3")).and_then(Json::as_f64), Some(3.0));
}

#[test]
fn leaves_a_broken_file_as_it_is() {
    let scratch = Scratch::new(Some(b"{\"mode\":"));

    let refused = scratch.file().update(|settings| settings.set_mode("default"));

    assert!(refused.is_err());
    assert_eq!(scratch.bytes(), b"{\"mode\":");
}

#[test]
fn makes_a_missing_file_in_the_swift_style() {
    let scratch = Scratch::new(None);

    scratch.file().update(|settings| assert!(settings.set_qwen_host("mac"))).unwrap();

    assert_eq!(String::from_utf8(scratch.bytes()).unwrap(), r#"{"qwenURL":"http:\/\/localhost:11434\/api\/chat","qwenProxy":""}"#);
}
