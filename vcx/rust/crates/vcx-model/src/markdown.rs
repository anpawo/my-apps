use crate::assets;
use pulldown_cmark::{CodeBlockKind, CowStr, Event, Options, Parser, Tag, TagEnd, html};

/// Link targets the page may follow; anything else (`javascript:`, `data:`) is cut.
const SAFE_SCHEMES: [&str; 4] = ["http://", "https://", "mailto:", "file://"];
const BLOCKED_TARGET: &str = "#";
/// A fence longer than three marks exists only to hold nested fences: its content is a Markdown document.
const PLAIN_FENCE: usize = 3;
const MARKDOWN_LANGUAGES: [&str; 2] = ["md", "markdown"];
/// The copy icon, and the check it turns into once copied (the dashboard's button, WT-033).
const COPY_ICONS: &str = r#"<svg class="ready" viewBox="0 0 24 24"><rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/></svg><svg class="done" viewBox="0 0 24 24"><path d="M20 6 9 17l-5-5"/></svg>"#;

/// The answer lines Marius's replies open and close with, each drawn as its own coloured band.
const ANSWER_LINES: [(&str, &str, &str); 3] = [("⟶ Next:", "next", "+ Next:"), ("⟶ ", "short", ""), ("✓ Done:", "done", "✓ Done:")];

/// Agent Markdown as HTML the page can insert as is: raw HTML in the source comes out as text.
pub fn to_html(markdown: &str) -> String {
    let options = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    let mut parser = Parser::new_ext(markdown, options).into_offset_iter();
    let mut events = Vec::new();
    while let Some((event, range)) = parser.next() {
        match event {
            Event::Start(Tag::CodeBlock(kind)) => {
                let mut code = String::new();
                for (inner, _) in parser.by_ref() {
                    match inner {
                        Event::Text(text) => code.push_str(&text),
                        Event::End(TagEnd::CodeBlock) => break,
                        _ => {}
                    }
                }
                events.push(Event::Html(code_block(&kind, &code, &markdown[range]).into()));
            }
            Event::Html(raw) | Event::InlineHtml(raw) => events.push(Event::Text(raw)),
            Event::Start(Tag::Link { link_type, dest_url, title, id }) => events.push(Event::Start(Tag::Link { link_type, dest_url: safe_target(dest_url), title, id })),
            Event::Start(Tag::Image { link_type, dest_url, title, id }) => events.push(Event::Start(Tag::Image { link_type, dest_url: safe_target(dest_url), title, id })),
            other => events.push(other),
        }
    }
    mark_answer_lines(&mut events);
    let events = number_tables(events);
    let mut output = String::with_capacity(markdown.len() * 3 / 2);
    html::push_html(&mut output, events.into_iter());
    output
}

fn mark_answer_lines(events: &mut [Event<'_>]) {
    for index in 1..events.len() {
        if !matches!(events[index - 1], Event::Start(Tag::Paragraph)) {
            continue;
        }
        let Event::Text(text) = &events[index] else { continue };
        let Some((prefix, class, shown)) = ANSWER_LINES.iter().find(|(prefix, ..)| text.starts_with(prefix)) else { continue };
        let rest = format!("{shown}{}", &text[prefix.len()..]);
        events[index] = Event::Text(rest.into());
        events[index - 1] = Event::Html(format!("<p class=\"answer {class}\">").into());
    }
}

/// Each table in its card, its rows numbered so Marius can answer "row 3", as Swift's `numberedTable`; a table whose
/// first header is already `#` keeps its own numbers.
fn number_tables(events: Vec<Event<'_>>) -> Vec<Event<'_>> {
    let mut numbered = Vec::with_capacity(events.len());
    let mut own_numbers = false;
    let mut row = 0;
    let mut events = events.into_iter().peekable();
    while let Some(event) = events.next() {
        match event {
            Event::Start(Tag::Table(_)) => {
                numbered.push(Event::Html("<div class=\"table\">".into()));
                numbered.push(event);
                row = 0;
                own_numbers = false;
            }
            Event::End(TagEnd::Table) => {
                numbered.push(event);
                numbered.push(Event::Html("</div>".into()));
            }
            Event::Start(Tag::TableHead) => {
                numbered.push(event);
                if let Some(Event::Start(Tag::TableCell)) = events.peek() {
                    numbered.push(events.next().expect("peeked"));
                    let first: Vec<Event<'_>> = std::iter::from_fn(|| events.next_if(|next| !matches!(next, Event::End(TagEnd::TableCell)))).collect();
                    own_numbers = matches!(first.as_slice(), [Event::Text(text)] if text.trim() == "#");
                    if !own_numbers {
                        let cell = numbered.pop().expect("the first cell");
                        numbered.push(Event::Html("<th class=\"number\">#</th>".into()));
                        numbered.push(cell);
                    }
                    numbered.extend(first);
                }
            }
            Event::Start(Tag::TableRow) => {
                numbered.push(event);
                row += 1;
                if !own_numbers {
                    numbered.push(Event::Html(format!("<td class=\"number\">{row}</td>").into()));
                }
            }
            other => numbered.push(other),
        }
    }
    numbered
}

fn code_block(kind: &CodeBlockKind<'_>, code: &str, source: &str) -> String {
    let info = match kind {
        CodeBlockKind::Fenced(info) => info.as_ref(),
        CodeBlockKind::Indented => "",
    };
    let tags: Vec<String> = info.split_whitespace().map(str::to_lowercase).collect();
    let language = info.split_whitespace().next().unwrap_or_default();
    let (fence, closed) = fence(source);
    if tags.first().map(String::as_str) == Some("chart") && closed {
        let id = assets::chart(code);
        let pin = tags.iter().any(|tag| tag == "pin");
        return format!("<div class=\"chart\" data-chart=\"{id}\" data-pin=\"{pin}\"><iframe sandbox=\"allow-scripts\" src=\"vcx://chart/{id}\" title=\"Chart\"></iframe></div>");
    }
    let markdown = matches!(kind, CodeBlockKind::Fenced(_)) && (MARKDOWN_LANGUAGES.contains(&tags.first().map(String::as_str).unwrap_or_default()) || fence > PLAIN_FENCE);
    let label = match (language.is_empty(), markdown) {
        (false, _) => escape(language),
        (true, true) => "Markdown".to_owned(),
        (true, false) => "Code".to_owned(),
    };
    let head = format!("<figcaption><span class=\"language\">{label}</span><button type=\"button\" class=\"copy b b-ghost icon sm\" aria-label=\"Copy code\" title=\"Copy code\">{COPY_ICONS}</button></figcaption>");
    if markdown {
        return format!("<figure class=\"code markdown\">{head}<div class=\"prose\">{}</div><pre class=\"source\" hidden><code>{}</code></pre></figure>", to_html(code), escape(code));
    }
    let class = if language.is_empty() { String::new() } else { format!(" class=\"language-{}\"", escape(language)) };
    format!("<figure class=\"code\">{head}<pre><code{class}>{}</code></pre></figure>", escape(code))
}

/// The length of the block's opening fence, and whether a fence closes it: a chart still streaming in stays code.
fn fence(source: &str) -> (usize, bool) {
    let mut lines = source.lines().map(str::trim).filter(|line| !line.is_empty());
    let Some(first) = lines.next() else { return (0, false) };
    let Some(mark) = first.chars().next().filter(|mark| matches!(mark, '`' | '~')) else { return (0, true) };
    let length = first.chars().take_while(|letter| *letter == mark).count();
    let closed = lines.last().is_some_and(|last| last.chars().all(|letter| letter == mark) && last.chars().count() >= length);
    (length, closed)
}

fn escape(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len() + text.len() / 8);
    for letter in text.chars() {
        match letter {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            other => escaped.push(other),
        }
    }
    escaped
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

        assert!(html.contains("<div class=\"table\"><table>"), "{html}");
        assert!(html.contains("<th class=\"number\">#</th><th>a</th>"), "{html}");
        assert!(html.contains("<tr><td class=\"number\">1</td><td>1</td>"), "{html}");
        assert!(html.contains("<code class=\"language-rust\">let x = 1;"), "{html}");
    }

    #[test]
    fn keeps_the_row_numbers_of_a_table_that_already_has_them() {
        let html = to_html("| # | a |\n|---|---|\n| 7 | x |\n");

        assert!(!html.contains("class=\"number\""), "{html}");
        assert!(html.contains("<th>#</th><th>a</th>"), "{html}");
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

    #[test]
    fn gives_a_code_block_its_language_and_a_copy_button() {
        let html = to_html("```sh\necho \"<hi>\"\n```\n\n    indented\n");

        assert!(html.contains("<span class=\"language\">sh</span><button type=\"button\" class=\"copy b b-ghost icon sm\""), "{html}");
        assert!(html.contains("<code class=\"language-sh\">echo &quot;&lt;hi&gt;&quot;\n</code>"), "{html}");
        assert!(html.contains("<span class=\"language\">Code</span>"), "{html}");
    }

    #[test]
    fn draws_a_long_fence_as_formatted_markdown_holding_its_nested_fences() {
        let html = to_html("````\n# Title\n\n```js\nx()\n```\n````\n");

        assert!(html.contains("<figure class=\"code markdown\">"), "{html}");
        assert!(html.contains("<h1>Title</h1>"), "{html}");
        assert!(html.contains("<code class=\"language-js\">x()"), "{html}");
    }

    #[test]
    fn turns_a_closed_chart_block_into_a_sandboxed_frame_served_by_the_core() {
        let html = to_html("```chart pin\n<p>chart</p>\n```\n");

        let id = assets::chart("<p>chart</p>\n");
        assert!(html.contains(&format!("<iframe sandbox=\"allow-scripts\" src=\"vcx://chart/{id}\"")), "{html}");
        assert!(html.contains("data-pin=\"true\""), "{html}");
    }

    #[test]
    fn keeps_a_chart_still_streaming_in_as_code() {
        let html = to_html("```chart\n<p>half");

        assert!(!html.contains("<iframe"), "{html}");
        assert!(html.contains("<span class=\"language\">chart</span>"), "{html}");
    }

    #[test]
    fn marks_the_answer_lines_with_their_band() {
        let html = to_html("⟶ It works.\n\nDetails.\n\n✓ Done: shipped.\n\n⟶ Next: ship it?");

        assert!(html.contains("<p class=\"answer short\">It works.</p>"), "{html}");
        assert!(html.contains("<p class=\"answer done\">✓ Done: shipped.</p>"), "{html}");
        assert!(html.contains("<p class=\"answer next\">+ Next: ship it?</p>"), "{html}");
        assert!(html.contains("<p>Details.</p>"), "{html}");
    }
}
