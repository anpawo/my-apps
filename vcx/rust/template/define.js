'use strict';
// Define, as the Swift composer (`Composer.swift`, `controlDrag`, `sendEvent`): a Control-click on a word of the
// transcript asks the agent what it means here; held, the drag widens it word by word and the release asks about all of
// it, Escape dropping it. While Control alone is held, each word under the pointer is gathered, and a Control-click on
// one of them asks about every gathered group; letting go of Control drops them. A Control-click inside a selection of
// a few words asks about the selection.
(() => {
  const NAME = 'vcx-define';
  // Swift asks about a selection only when it is this short.
  const MAX_SELECTED_WORDS = 6;
  // WebKit may follow a Control mousedown with a contextmenu event for the same click: it must not ask twice.
  const SAME_CLICK_MS = 500;
  const SCOPE = '#rows';
  const segmenter = new Intl.Segmenter(undefined, { granularity: 'word' });
  const painted = typeof Highlight === 'function' && window.CSS && CSS.highlights;
  let gathered = [];
  let drag = null;
  let askedAt = -Infinity;

  if (painted) {
    // A sheet of its own: the page's CSP lets no inline style in, and the transcript's sheets are not this file's.
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(`::highlight(${NAME}) { background: rgb(0 122 255 / 0.22); }`);
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  }

  const controlOnly = event => event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey;

  function paint(ranges) {
    if (!painted) return;
    if (ranges.length) CSS.highlights.set(NAME, new Highlight(...ranges));
    else CSS.highlights.delete(NAME);
  }

  function inside(range, x, y) {
    return [...range.getClientRects()].some(box => x >= box.left && x <= box.right && y >= box.top && y <= box.bottom);
  }

  // The word under the pointer in the transcript, as a range; none over a gap or outside the rows.
  function wordAt(x, y) {
    const caret = document.caretRangeFromPoint(x, y);
    const node = caret && caret.startContainer;
    if (!node || node.nodeType !== Node.TEXT_NODE || !node.parentElement || !node.parentElement.closest(SCOPE)) return null;
    for (const part of segmenter.segment(node.data)) {
      if (!part.isWordLike || caret.startOffset < part.index || caret.startOffset > part.index + part.segment.length) continue;
      const range = document.createRange();
      range.setStart(node, part.index);
      range.setEnd(node, part.index + part.segment.length);
      if (inside(range, x, y)) return range;
    }
    return null;
  }

  function union(first, second) {
    const range = first.cloneRange();
    if (second.compareBoundaryPoints(Range.START_TO_START, first) < 0) range.setStart(second.startContainer, second.startOffset);
    if (second.compareBoundaryPoints(Range.END_TO_END, first) > 0) range.setEnd(second.endContainer, second.endOffset);
    return range;
  }

  const meets = (range, other) => range.compareBoundaryPoints(Range.END_TO_START, other) <= 0 && range.compareBoundaryPoints(Range.START_TO_END, other) >= 0;

  // Only blanks between them: one group of words.
  function touches(range, word) {
    const between = document.createRange();
    const before = range.compareBoundaryPoints(Range.START_TO_START, word) < 0;
    const [left, right] = before ? [range, word] : [word, range];
    between.setStart(left.endContainer, left.endOffset);
    between.setEnd(right.startContainer, right.startOffset);
    return !between.collapsed && /^\s*$/.test(between.toString()) || meets(range, word);
  }

  function gather(word) {
    if (gathered.some(range => meets(range, word))) return;
    const index = gathered.findIndex(range => touches(range, word));
    if (index < 0) gathered.push(word);
    else gathered[index] = union(gathered[index], word);
    paint(gathered);
  }

  function drop() {
    gathered = [];
    drag = null;
    paint([]);
  }

  function define(groups) {
    const words = groups.map(group => group.trim()).filter(Boolean);
    if (!words.length) return;
    askedAt = performance.now();
    window.vcx.post({ type: 'send', text: `Define ${words.map(group => `"${group}"`).join(', ')} as used here, in at most 3 short lines.` });
  }

  // A Control-click: on a gathered word, every group; inside a short selection, the selection; on a word, the start
  // of a drag. True when the click was Define's.
  function press(x, y, canDrag) {
    const word = wordAt(x, y);
    if (word && gathered.some(range => meets(range, word))) {
      define(gathered.map(range => range.toString()));
      drop();
      return true;
    }
    const selection = getSelection();
    const selected = selection.rangeCount ? selection.getRangeAt(0) : null;
    const text = selected ? selected.toString().trim() : '';
    if (text && inside(selected, x, y) && text.split(/\s+/).length <= MAX_SELECTED_WORDS) {
      define([text]);
      return true;
    }
    if (!word) return false;
    if (!canDrag) {
      define([word.toString()]);
      return true;
    }
    drag = { start: word, range: word, cancelled: false };
    paint([word]);
    return true;
  }

  addEventListener('mousedown', event => {
    if (event.button !== 0 || !controlOnly(event)) return;
    if (press(event.clientX, event.clientY, true)) event.preventDefault();
  }, true);

  addEventListener('mousemove', event => {
    if (drag) {
      if (drag.cancelled) return;
      const word = wordAt(event.clientX, event.clientY);
      if (word) paint([drag.range = union(drag.start, word)]);
    } else if (controlOnly(event) && event.buttons === 0) {
      const word = wordAt(event.clientX, event.clientY);
      if (word) gather(word);
    }
  }, true);

  addEventListener('mouseup', () => {
    if (!drag) return;
    const { range, cancelled } = drag;
    drop();
    if (!cancelled) define([range.toString()]);
  }, true);

  // Control-click is also the context menu's click: the menu never opens over the transcript, and a click WebKit hands
  // only as a contextmenu event still asks.
  addEventListener('contextmenu', event => {
    if (!controlOnly(event) || !event.target.closest || !event.target.closest(SCOPE)) return;
    event.preventDefault();
    if (!drag && performance.now() - askedAt > SAME_CLICK_MS) press(event.clientX, event.clientY, false);
  }, true);

  addEventListener('keydown', event => {
    if (event.key === 'Escape' && drag) {
      // The drag's own Escape: it stops neither the turn nor a panel.
      event.stopImmediatePropagation();
      event.preventDefault();
      drag.cancelled = true;
      paint([]);
    }
  }, true);

  addEventListener('keyup', event => {
    if (event.key === 'Control' && !drag) drop();
  }, true);
  addEventListener('blur', () => drag || drop());
})();
