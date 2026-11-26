//! Where a window's transcript was scrolled, kept across a live update (Swift `RuntimeUpdate` saved the scroll and
//! the exchange at the top edge): the page is read for the row at its top edge and how far that row sits above it,
//! and the new image's page is scrolled so the same row sits there again once it is drawn.

use serde_json::Value;

/// The page's anchor: `{pinned}` at the end, `{row, offset}` for the row at the top edge, `{top}` with no row.
pub const READ: &str = r#"(() => {
  const t = document.getElementById('transcript');
  if (!t) return null;
  if (t.scrollHeight - t.scrollTop - t.clientHeight < 2) return { pinned: true };
  const top = t.getBoundingClientRect().top;
  // A sticky row (a turn's heading) sits at the top edge wherever the transcript is scrolled.
  const row = [...t.querySelectorAll('[data-row]')].find(node => getComputedStyle(node).position !== 'sticky' && node.getBoundingClientRect().bottom > top);
  return row ? { row: row.dataset.row, offset: row.getBoundingClientRect().top - top } : { top: t.scrollTop };
})()"#;

/// Scrolls the page back to `anchor`; the script answers `false` while the anchor's row is not drawn yet, or the
/// transcript below it is still too short for the row to sit where it did.
pub fn restore(anchor: &Value) -> String {
    format!(
        r#"((a) => {{
  const t = document.getElementById('transcript');
  if (!t) return false;
  if (a.pinned) {{ t.scrollTop = t.scrollHeight; return true; }}
  if (a.row === undefined) {{ t.scrollTop = a.top; return true; }}
  const row = [...t.querySelectorAll('[data-row]')].find(node => node.dataset.row === a.row);
  if (!row) return false;
  t.scrollTop += row.getBoundingClientRect().top - t.getBoundingClientRect().top - a.offset;
  return Math.abs(row.getBoundingClientRect().top - t.getBoundingClientRect().top - a.offset) < 1;
}})({anchor})"#
    )
}

/// The anchor the page answered, as the web view encodes it; nothing when the page had no transcript.
pub fn anchor(answer: &str) -> Option<Value> {
    serde_json::from_str::<Value>(answer).ok().filter(Value::is_object)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn keeps_an_anchor_the_page_answered_and_nothing_from_a_page_without_a_transcript() {
        let answers = [r#"{"row":"item-4","offset":-120.5}"#, "null", ""];

        let anchors: Vec<Option<Value>> = answers.iter().map(|answer| anchor(answer)).collect();

        assert_eq!(anchors, [Some(json!({"row": "item-4", "offset": -120.5})), None, None]);
    }
}
