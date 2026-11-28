//! Where a window's transcript was scrolled, kept across a live update with its details toggle and composer selection
//! (Swift `RuntimeUpdate` saved the scroll and the exchange at the top edge): the page is read for the row at its top
//! edge and how far that row sits above it, and the new image's page is scrolled so the same row sits there again
//! once it is drawn.

use serde_json::Value;

/// The page's anchor: `{pinned}` at the end, `{row, offset}` for the row at the top edge, `{top}` with no row; with
/// whether details are on and the composer's selection, which Swift kept too (`RuntimeUpdate.state`).
pub const READ: &str = r#"(() => {
  const t = document.getElementById('transcript');
  if (!t) return null;
  const input = document.getElementById('input');
  const kept = { details: Boolean(window.vcx && vcx.details), selection: input ? [input.selectionStart, input.selectionEnd] : [0, 0] };
  if (t.scrollHeight - t.scrollTop - t.clientHeight < 2) return { ...kept, pinned: true };
  const top = t.getBoundingClientRect().top;
  // A sticky row (a turn's heading) sits at the top edge wherever the transcript is scrolled.
  const row = [...t.querySelectorAll('[data-row]')].find(node => getComputedStyle(node).position !== 'sticky' && node.getBoundingClientRect().bottom > top);
  return { ...kept, ...(row ? { row: row.dataset.row, offset: row.getBoundingClientRect().top - top } : { top: t.scrollTop }) };
})()"#;

/// Puts the page back as `anchor` says; the script answers `false` while the anchor's row is not drawn yet, or the
/// transcript below it is still too short for the row to sit where it did. The selection is set when the draft, which
/// comes with the same state as the rows, holds it.
pub fn restore(anchor: &Value) -> String {
    format!(
        r#"((a) => {{
  const t = document.getElementById('transcript');
  if (!t) return false;
  if (a.details && window.vcx && !vcx.details) vcx.toggleDetails();
  const input = document.getElementById('input');
  const [start, end] = a.selection || [0, 0];
  if (input && end <= input.value.length) input.setSelectionRange(start, end);
  if (a.pinned) {{ t.scrollTop = t.scrollHeight; return true; }}
  document.dispatchEvent(new CustomEvent('vcx:reading'));
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
