//! What crosses between the page and the core: the page posts JSON messages, the core calls `vcx.receive`.

use serde_json::Value;

const TEMPLATE_ORIGIN: &str = "vcx://template/";
const EXTERNAL_SCHEMES: [&str; 3] = ["https://", "http://", "mailto:"];

#[derive(Debug, PartialEq)]
pub enum FromPage {
    Ready { contract: u64 },
    Send { text: String },
    Stop,
    Rendered { serial: u64 },
    Open { href: String },
}

pub fn parse(body: &str) -> Option<FromPage> {
    let message: Value = serde_json::from_str(body).ok()?;
    let text = |key: &str| message.get(key).and_then(Value::as_str).map(str::to_owned);
    let number = |key: &str| message.get(key).and_then(Value::as_u64);
    match message.get("type")?.as_str()? {
        "ready" => Some(FromPage::Ready { contract: number("contract")? }),
        "send" => Some(FromPage::Send { text: text("text")? }),
        "stop" => Some(FromPage::Stop),
        "rendered" => Some(FromPage::Rendered { serial: number("serial")? }),
        "open" => Some(FromPage::Open { href: text("href")? }),
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

/// A link the system may open: a web page or a mail, never a file or an app scheme chosen by an agent's answer.
pub fn is_external(href: &str) -> bool {
    EXTERNAL_SCHEMES.iter().any(|scheme| href.starts_with(scheme))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_each_message_the_page_posts() {
        let bodies = [r#"{"type":"ready","contract":1}"#, r#"{"type":"send","text":"hi"}"#, r#"{"type":"stop"}"#, r#"{"type":"rendered","serial":7}"#, r#"{"type":"open","href":"https://example.com"}"#];

        let parsed: Vec<FromPage> = bodies.iter().filter_map(|body| parse(body)).collect();

        let expected = [
            FromPage::Ready { contract: 1 },
            FromPage::Send { text: "hi".into() },
            FromPage::Stop,
            FromPage::Rendered { serial: 7 },
            FromPage::Open { href: "https://example.com".into() },
        ];
        assert_eq!(parsed, expected);
    }

    #[test]
    fn ignores_what_is_not_a_known_message() {
        let bodies = ["not json", r#"{"type":"eval","code":"1"}"#, r#"{"type":"send"}"#, r#"{"type":"rendered"}"#];

        let parsed: Vec<FromPage> = bodies.iter().filter_map(|body| parse(body)).collect();

        assert_eq!(parsed, []);
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
    fn opens_only_web_and_mail_links_outside() {
        assert!(is_external("https://example.com"));
        assert!(is_external("mailto:someone@example.com"));
        assert!(!is_external("file:///etc/passwd"));
        assert!(!is_external("javascript:alert(1)"));
    }
}
