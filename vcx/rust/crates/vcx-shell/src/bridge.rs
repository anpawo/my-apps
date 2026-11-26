//! What crosses between the page and the core: the page posts JSON messages, the core calls `vcx.receive`.

use crate::chart;
use serde_json::{Value, json};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const TEMPLATE_ORIGIN: &str = "vcx://template/";
const EXTERNAL_SCHEMES: [&str; 3] = ["https://", "http://", "mailto:"];
const FILE_SCHEME: &str = "file://";
const OPEN: &str = "/usr/bin/open";
const PBCOPY: &str = "/usr/bin/pbcopy";
/// Files a click would run rather than show: they are only revealed in the Finder.
const RUNNABLE_EXTENSIONS: [&str; 16] = ["app", "command", "tool", "sh", "bash", "zsh", "py", "rb", "pl", "pkg", "mpkg", "scpt", "applescript", "workflow", "terminal", "jar"];
const EXECUTABLE_BITS: u32 = 0o111;
/// What the page may ask the worker to read again, and the worker action that does it.
const REFRESHES: [(&str, &str); 4] = [("usage", "refreshUsage"), ("repository", "refreshRepository"), ("capabilities", "refreshCapabilities"), ("catalog", "refreshCatalog")];

#[derive(Debug, PartialEq)]
pub enum FromPage {
    Ready { contract: u64 },
    /// The draft and its generation let the worker drop the saved draft this message came from.
    Send { text: String, images: Vec<String>, draft: Option<Value>, generation: Option<i64> },
    Stop,
    Rendered { serial: u64 },
    Restyled { version: u64 },
    Open { href: String },
    /// An answer to a request the worker holds open: `{rpcID, method, result}`, the worker action `answer`'s params.
    Answer { params: Value },
    Copy { text: String },
    /// The composer's own requests (`draft`, `files`, `image`, `sendNow`), the whole message.
    Composer(Value),
    /// A slash command from the chrome's popovers, as typed: `/model claude opus high`.
    Command { text: String },
    Title { text: String },
    /// Another window's card in the task bar.
    Focus { id: String },
    Quota,
    /// The worker action that reads `what` again: `refreshUsage`, `refreshRepository`, `refreshCapabilities`, `refreshCatalog`.
    Refresh { action: &'static str },
    ChooseDirectory,
}

/// What a link in the transcript opens.
#[derive(Debug, PartialEq)]
pub enum Target {
    Web(String),
    /// A document or a folder, opened with its app.
    File(PathBuf),
    /// An app or a script: shown in the Finder, never run.
    Reveal(PathBuf),
}

pub fn parse(body: &str) -> Option<FromPage> {
    let message: Value = serde_json::from_str(body).ok()?;
    let text = |key: &str| message.get(key).and_then(Value::as_str).map(str::to_owned);
    let number = |key: &str| message.get(key).and_then(Value::as_u64);
    match message.get("type")?.as_str()? {
        "ready" => Some(FromPage::Ready { contract: number("contract")? }),
        "send" => {
            let images = match message.get("images") {
                None => Vec::new(),
                Some(images) => images.as_array()?.iter().map(|image| image.as_str().map(str::to_owned)).collect::<Option<_>>()?,
            };
            let draft = message.get("draft").filter(|draft| draft.is_array()).cloned();
            Some(FromPage::Send { text: text("text")?, images, draft, generation: message.get("generation").and_then(Value::as_i64) })
        }
        "stop" => Some(FromPage::Stop),
        "rendered" => Some(FromPage::Rendered { serial: number("serial")? }),
        "restyled" => Some(FromPage::Restyled { version: number("version")? }),
        "open" => Some(FromPage::Open { href: text("href")? }),
        "answer" => Some(FromPage::Answer { params: json!({"rpcID": message.get("rpcID")?, "method": text("method")?, "result": message.get("result").filter(|result| result.is_object())?}) }),
        "copy" => Some(FromPage::Copy { text: text("text")? }),
        "draft" | "files" | "image" | "sendNow" | "dropped" | "run" | "runInput" | "runStop" => Some(FromPage::Composer(message)),
        "command" => Some(FromPage::Command { text: text("text")? }),
        "title" => Some(FromPage::Title { text: text("text")? }),
        "focus" => Some(FromPage::Focus { id: text("id")? }),
        "quota" => Some(FromPage::Quota),
        "refresh" => Some(FromPage::Refresh { action: REFRESHES.iter().find(|(what, _)| Some(*what) == message.get("what").and_then(Value::as_str))?.1 }),
        "chooseDirectory" => Some(FromPage::ChooseDirectory),
        _ => None,
    }
}

/// The script that hands a message to the page. A page still loading has no `vcx` yet and gets a full state once ready.
pub fn deliver(message: &Value) -> String {
    format!("window.vcx&&vcx.receive({message})")
}

/// Only the template's own pages may talk to the core or be navigated to: an embedded frame is neither.
pub fn is_template(uri: &str) -> bool {
    uri.starts_with(TEMPLATE_ORIGIN)
}

/// What the web view may load: the template, and chart frames inside it. wry asks for every frame, not only the page.
pub fn may_load(uri: &str) -> bool {
    is_template(uri) || chart::is_frame(uri)
}

/// A link the system may open: a web page or a mail, never a file or an app scheme chosen by an agent's answer.
pub fn is_external(href: &str) -> bool {
    EXTERNAL_SCHEMES.iter().any(|scheme| href.starts_with(scheme))
}

/// What a link opens, as the Swift `LinkText` does: a web page or a mail, or a file on this Mac by its absolute path
/// (`~/` is the home folder). A relative path or another scheme opens nothing, and nor does a file that is not there.
pub fn target(href: &str, home: Option<&Path>) -> Option<Target> {
    if is_external(href) {
        return Some(Target::Web(href.to_owned()));
    }
    let path = match href.strip_prefix(FILE_SCHEME) {
        Some(rest) => PathBuf::from(decoded(rest.split(['?', '#']).next().unwrap_or_default())?),
        None if href.starts_with('/') => PathBuf::from(href),
        None => home?.join(href.strip_prefix("~/")?),
    };
    // A path written with a line anchor (`main.rs#L12`) names the file before it.
    let path = if path.exists() { path } else { PathBuf::from(path.to_str()?.split('#').next()?) };
    let meta = path.metadata().ok()?;
    let runnable = path.extension().and_then(|extension| extension.to_str()).is_some_and(|extension| RUNNABLE_EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str()));
    let executable = meta.is_file() && meta.permissions().mode() & EXECUTABLE_BITS != 0;
    Some(if runnable || executable { Target::Reveal(path) } else { Target::File(path) })
}

/// `%20` and the like in a `file://` link. A broken escape or bytes that are not UTF-8 open nothing.
fn decoded(text: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(text.len());
    let mut rest = text.bytes();
    while let Some(byte) = rest.next() {
        if byte != b'%' {
            bytes.push(byte);
            continue;
        }
        let pair = [rest.next()?, rest.next()?];
        bytes.push(u8::from_str_radix(std::str::from_utf8(&pair).ok()?, 16).ok()?);
    }
    String::from_utf8(bytes).ok()
}

pub fn open(target: &Target) {
    let mut command = Command::new(OPEN);
    match target {
        Target::Web(url) => command.arg(url),
        Target::File(path) => command.arg(path),
        Target::Reveal(path) => command.arg("-R").arg(path),
    };
    if let Err(error) = command.spawn() {
        eprintln!("vcx: cannot open {target:?}: {error}");
    }
}

/// Puts a code block's text on the pasteboard, when Marius clicked its copy button.
pub fn copy(text: &str) {
    let child = Command::new(PBCOPY).stdin(Stdio::piped()).spawn();
    let written = child.and_then(|mut child| {
        child.stdin.take().expect("a piped stdin").write_all(text.as_bytes())?;
        child.wait()
    });
    if let Err(error) = written {
        eprintln!("vcx: cannot copy: {error}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_each_message_the_page_posts() {
        let bodies = [
            r#"{"type":"ready","contract":1}"#, r#"{"type":"send","text":"hi"}"#, r#"{"type":"stop"}"#, r#"{"type":"rendered","serial":7}"#, r#"{"type":"restyled","version":2}"#,
            r#"{"type":"open","href":"https://example.com"}"#, r#"{"type":"answer","rpcID":7,"method":"item/tool/requestUserInput","result":{"answers":{}}}"#, r#"{"type":"copy","text":"ls"}"#,
        ];

        let parsed: Vec<FromPage> = bodies.iter().filter_map(|body| parse(body)).collect();

        let expected = [
            FromPage::Ready { contract: 1 },
            FromPage::Send { text: "hi".into(), images: Vec::new(), draft: None, generation: None },
            FromPage::Stop,
            FromPage::Rendered { serial: 7 },
            FromPage::Restyled { version: 2 },
            FromPage::Open { href: "https://example.com".into() },
            FromPage::Answer { params: json!({"rpcID": 7, "method": "item/tool/requestUserInput", "result": {"answers": {}}}) },
            FromPage::Copy { text: "ls".into() },
        ];
        assert_eq!(parsed, expected);
    }

    #[test]
    fn ignores_what_is_not_a_known_message() {
        let bodies = ["not json", r#"{"type":"eval","code":"1"}"#, r#"{"type":"send"}"#, r#"{"type":"rendered"}"#, r#"{"type":"answer","rpcID":7,"method":"m","result":"yes"}"#, r#"{"type":"answer","method":"m","result":{}}"#, r#"{"type":"send","text":"hi","images":[3]}"#, r#"{"type":"refresh","what":"everything"}"#];

        let parsed: Vec<FromPage> = bodies.iter().filter_map(|body| parse(body)).collect();

        assert_eq!(parsed, []);
    }

    #[test]
    fn reads_the_composer_and_chrome_messages() {
        let bodies = [
            r#"{"type":"send","text":"hi","images":["/tmp/a.png"],"draft":[],"generation":4}"#, r#"{"type":"sendNow"}"#, r#"{"type":"command","text":"/model claude opus high"}"#,
            r#"{"type":"title","text":"Fix the bar"}"#, r#"{"type":"focus","id":"A1"}"#, r#"{"type":"quota"}"#, r#"{"type":"refresh","what":"usage"}"#, r#"{"type":"chooseDirectory"}"#,
        ];

        let parsed: Vec<FromPage> = bodies.iter().filter_map(|body| parse(body)).collect();

        let expected = [
            FromPage::Send { text: "hi".into(), images: vec!["/tmp/a.png".into()], draft: Some(json!([])), generation: Some(4) },
            FromPage::Composer(json!({"type": "sendNow"})),
            FromPage::Command { text: "/model claude opus high".into() },
            FromPage::Title { text: "Fix the bar".into() },
            FromPage::Focus { id: "A1".into() },
            FromPage::Quota,
            FromPage::Refresh { action: "refreshUsage" },
            FromPage::ChooseDirectory,
        ];
        assert_eq!(parsed, expected);
    }

    #[test]
    fn hands_the_page_a_message_as_one_call() {
        let script = deliver(&json!({"text": "it's \"quoted\""}));

        assert_eq!(script, r#"window.vcx&&vcx.receive({"text":"it's \"quoted\""})"#);
    }

    #[test]
    fn accepts_only_the_template_as_a_page() {
        assert!(is_template("vcx://template/index.html"));
        assert!(!is_template("vcx://chart/1"));
        assert!(!is_template("https://example.com/vcx://template/"));
    }

    #[test]
    fn loads_chart_frames_beside_the_template_and_nothing_else() {
        assert!(may_load("vcx://template/index.html"));
        assert!(may_load("vcx://chart/0123456789abcdef"));
        assert!(!may_load("vcx://image/0123456789abcdef"));
        assert!(!may_load("https://example.com"));
    }

    struct Folder(PathBuf);

    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn folder(name: &str) -> Folder {
        let path = std::env::temp_dir().join(format!("vcx-bridge-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(path.join("Tool.app")).unwrap();
        std::fs::write(path.join("notes file.md"), "notes").unwrap();
        std::fs::write(path.join("run"), "#!/bin/sh").unwrap();
        std::fs::set_permissions(path.join("run"), std::fs::Permissions::from_mode(0o755)).unwrap();
        Folder(path)
    }

    #[test]
    fn opens_a_document_by_its_path_and_only_reveals_what_would_run() {
        let folder = folder("targets");
        let notes = folder.0.join("notes file.md");

        let by_path = target(&format!("{}#L3", notes.display()), None);
        let by_url = target(&format!("file://{}", notes.display()).replace(' ', "%20"), None);
        let by_home = target("~/notes file.md", Some(&folder.0));
        let app = target(&folder.0.join("Tool.app").to_string_lossy(), None);
        let script = target(&folder.0.join("run").to_string_lossy(), None);

        assert_eq!(by_path, Some(Target::File(notes.clone())));
        assert_eq!(by_url, Some(Target::File(notes.clone())));
        assert_eq!(by_home, Some(Target::File(notes)));
        assert_eq!(app, Some(Target::Reveal(folder.0.join("Tool.app"))));
        assert_eq!(script, Some(Target::Reveal(folder.0.join("run"))));
    }

    #[test]
    fn opens_nothing_for_a_relative_path_a_missing_file_or_another_scheme() {
        let folder = folder("refused");

        let refused = ["docs/a.md", "notes file.md", "/no/such/file", "javascript:alert(1)", "vcx://template/index.html", "file:///bad%zz"].map(|href| target(href, Some(&folder.0)));

        assert_eq!(refused, [None, None, None, None, None, None]);
        assert_eq!(target("https://example.com/a", None), Some(Target::Web("https://example.com/a".into())));
    }

    #[test]
    fn opens_only_web_and_mail_links_outside() {
        assert!(is_external("https://example.com"));
        assert!(is_external("mailto:someone@example.com"));
        assert!(!is_external("file:///etc/passwd"));
        assert!(!is_external("javascript:alert(1)"));
    }
}
