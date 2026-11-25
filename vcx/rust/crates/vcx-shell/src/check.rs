//! The windowless check: the page runs in a window that is never shown, and what it drew is written to a file once
//! the session reached the awaited state and the page said it had drawn it.

use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::time::Duration;

/// What the page drew, read from the live document. Boxes come from layout, so they prove the page was laid out.
/// A window that is not shown gets no frames, so entrance animations are first brought to their end state.
pub const DUMP: &str = r#"(() => {
  for (const animation of document.getAnimations()) {
    if (Number.isFinite(animation.effect.getComputedTiming().endTime)) animation.finish();
  }
  return JSON.stringify({
  title: document.title,
  visibility: document.visibilityState,
  viewport: [innerWidth, innerHeight],
  background: getComputedStyle(document.body).backgroundColor,
  status: document.getElementById('status-text')?.textContent ?? null,
  notice: document.getElementById('notice')?.hidden === false ? document.getElementById('notice').textContent : null,
  chips: [...document.querySelectorAll('.chip')].map(chip => chip.textContent),
  rows: [...document.querySelectorAll('[data-row]')].map(row => {
    const box = row.getBoundingClientRect();
    return { id: row.dataset.row, kind: row.dataset.kind, text: row.innerText, box: [box.x, box.y, box.width, box.height].map(Math.round) };
  }),
  html: document.documentElement.outerHTML,
  });
})()"#;

pub struct Options {
    pub output: PathBuf,
    /// Where to write a picture of the page, taken after the report.
    pub picture: Option<PathBuf>,
    pub timeout: Duration,
    /// Wait for the end of a turn that produced an answer, not only for the first state.
    pub wait_for_answer: bool,
    /// How many template edits the page must have taken before the last report.
    pub edits: u64,
}

pub struct Check {
    pub options: Options,
    settled: Option<u64>,
    rendered: u64,
    /// Template edits the page has taken so far.
    edits: u64,
    /// The edit count carried by the report being read from the page.
    reading: Option<u64>,
    reported: Option<u64>,
}

impl Check {
    pub fn new(options: Options) -> Self {
        Self { options, settled: None, rendered: 0, edits: 0, reading: None, reported: None }
    }

    /// The session reached the awaited state as of page message `serial`. True when the page may now be read.
    pub fn settled(&mut self, serial: u64) -> bool {
        self.settled = Some(serial);
        self.due()
    }

    /// The page drew message `serial`. True when the page may now be read.
    pub fn rendered(&mut self, serial: u64) -> bool {
        self.rendered = self.rendered.max(serial);
        self.due()
    }

    /// The page took a template edit. True when the page may now be read.
    pub fn edited(&mut self) -> bool {
        self.edits += 1;
        self.due()
    }

    /// The page is being loaded again: what the previous one drew no longer counts.
    pub fn reloading(&mut self) {
        self.rendered = 0;
    }

    /// One report per edit count, read once the page drew the settled state.
    pub fn due(&mut self) -> bool {
        let due = self.reading.is_none() && self.reported != Some(self.edits) && self.settled.is_some_and(|serial| self.rendered >= serial);
        if due {
            self.reading = Some(self.edits);
        }
        due
    }

    /// The report was written. True when it is the last one this check waits for.
    pub fn written(&mut self) -> bool {
        self.reported = self.reading.take();
        self.reported.is_some_and(|edits| edits >= self.options.edits)
    }

    pub fn progress(&self) -> String {
        match self.settled {
            Some(serial) => format!("the session settled at page message {serial}, the page drew up to {}", self.rendered),
            None => format!("the session never settled, the page drew up to message {}", self.rendered),
        }
    }

    /// Writes the report in one move, so a reader waiting for it never sees half of it.
    pub fn write(&self, dump: &str, template: &str, reloads: u64) -> Result<(), String> {
        let mut report = unwrap(dump)?;
        report["template"] = json!(template);
        report["edits"] = json!(self.reading);
        report["reloads"] = json!(reloads);
        let text = serde_json::to_string_pretty(&report).expect("a JSON value");
        let output = &self.options.output;
        let draft = output.with_extension("writing");
        fs::write(&draft, text + "\n").and_then(|()| fs::rename(&draft, output)).map_err(|error| format!("Cannot write {}: {error}.", output.display()))
    }
}

pub fn save_picture(path: &PathBuf, picture: Result<Vec<u8>, String>) -> Result<(), String> {
    fs::write(path, picture?).map_err(|error| format!("Cannot write {}: {error}.", path.display()))
}

/// The web view hands a script's result over as JSON; the script's own result is a JSON text, hence one more layer.
fn unwrap(dump: &str) -> Result<Value, String> {
    let invalid = |error: serde_json::Error| format!("The page returned an unreadable dump: {error}.");
    match serde_json::from_str(dump).map_err(invalid)? {
        Value::String(inner) => serde_json::from_str(&inner).map_err(invalid),
        Value::Object(report) => Ok(Value::Object(report)),
        other => Err(format!("The page returned {other} instead of a dump.")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check() -> Check {
        waiting_for(0)
    }

    fn waiting_for(edits: u64) -> Check {
        Check::new(Options { output: PathBuf::new(), picture: None, timeout: Duration::ZERO, wait_for_answer: false, edits })
    }

    #[test]
    fn reads_the_page_once_it_drew_the_settled_state() {
        let mut check = check();

        let early_draw = check.rendered(1);
        let settled = check.settled(2);
        let drawn = check.rendered(2);
        let again = check.rendered(3);

        assert_eq!([early_draw, settled, drawn, again], [false, false, true, false]);
    }

    #[test]
    fn reads_the_page_at_once_when_it_had_already_drawn_the_settled_state() {
        let mut check = check();
        check.rendered(4);

        let settled = check.settled(3);

        assert!(settled);
    }

    #[test]
    fn reads_the_page_again_after_each_template_edit_until_the_awaited_count() {
        let mut check = waiting_for(2);
        check.rendered(1);
        let first = check.settled(1);
        let first_is_last = check.written();

        let restyled = check.edited();
        let second_is_last = check.written();
        check.reloading();
        let reloading = check.edited();
        let reloaded = check.rendered(2);
        let third_is_last = check.written();

        assert_eq!([first, restyled, reloading, reloaded], [true, true, false, true]);
        assert_eq!([first_is_last, second_is_last, third_is_last], [false, false, true]);
    }

    #[test]
    fn unwraps_the_dump_from_the_layer_the_web_view_adds() {
        let from_web_view = r#""{\"title\":\"VCX\"}""#;

        let report = unwrap(from_web_view).unwrap();

        assert_eq!(report["title"], "VCX");
    }
}
