use pulldown_cmark::{CowStr, Event, Options, Parser, Tag, html};

/// Link targets the page may follow; anything else (`javascript:`, `data:`) is cut.
const SAFE_SCHEMES: [&str; 4] = ["http://", "https://", "mailto:", "file://"];
const BLOCKED_TARGET: &str = "#";

/// Agent Markdown as HTML the page can insert as is: raw HTML in the source comes out as text.
pub fn to_html(markdown: &str) -> String {
    let options = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    let events = Parser::new_ext(markdown, options).map(|event| match event {
        Event::Html(raw) | Event::InlineHtml(raw) => Event::Text(raw),
        Event::Start(Tag::Link { link_type, dest_url, title, id }) => Event::Start(Tag::Link { link_type, dest_url: safe_target(dest_url), title, id }),
        Event::Start(Tag::Image { link_type, dest_url, title, id }) => Event::Start(Tag::Image { link_type, dest_url: safe_target(dest_url), title, id }),
        other => other,
    });
    let mut output = String::with_capacity(markdown.len() * 3 / 2);
    html::push_html(&mut output, events);
    output
}

fn safe_target(target: CowStr<'_>) -> CowStr<'_> {
    let lowered = target.trim_start().to_ascii_lowercase();
    let has_scheme = lowered.split(['/', '?', '#']).next().is_some_and(|head| head.contains(':'));
    if !has_scheme || SAFE_SCHEMES.iter().any(|scheme| lowered.starts_with(scheme)) { target } else { CowStr::Borrowed(BLOCKED_TARGET) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_a_table_and_a_code_block() {
        let html = to_html("| a | b |\n|---|---|\n| 1 | 2 |\n\n```rust\nlet x = 1;\n```\n");

        assert!(html.contains("<table>"), "{html}");
        assert!(html.contains("<code class=\"language-rust\">let x = 1;"), "{html}");
    }

    #[test]
    fn shows_raw_html_as_text_instead_of_running_it() {
        let html = to_html("before <script>alert(1)</script> after\n\n<img src=x onerror=alert(1)>\n");

        assert!(!html.contains("<script>"), "{html}");
        assert!(!html.contains("<img"), "{html}");
        assert!(html.contains("&lt;script&gt;"), "{html}");
    }

    #[test]
    fn cuts_a_javascript_link_target() {
        let html = to_html("[click](javascript:alert(1)) and [ok](https://example.com/a?b=1)");

        assert!(!html.contains("javascript:"), "{html}");
        assert!(html.contains("href=\"https://example.com/a?b=1\""), "{html}");
    }

    #[test]
    fn keeps_a_local_path_link() {
        let html = to_html("[notes](/Users/me/notes.md) [rel](docs/a.md#top)");

        assert!(html.contains("href=\"/Users/me/notes.md\""), "{html}");
        assert!(html.contains("href=\"docs/a.md#top\""), "{html}");
    }
}
