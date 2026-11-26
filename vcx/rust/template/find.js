'use strict';
// Find in the transcript (⌘F), as the Swift `TranscriptFind`: only the questions and the answers are searched, case and
// accents ignored. Matches are painted with CSS highlights, so the rows are never rewritten to mark them.
(() => {
  // Rows streaming in while the bar is open are searched again once they pause.
  const REFRESH_MS = 150;
  // A match scrolled to lands this far down the transcript, not under its top edge.
  const LANDING_SHARE = 1 / 3;
  const SCOPE = '.row[data-kind="user"] .message, .row.final > .answer-item > .prose';
  const ASCII = /^[\x00-\x7f]*$/;
  const MARKS = /\p{M}/gu;
  const $ = id => document.getElementById(id);
  const bar = $('find');
  const input = $('find-input');
  const count = $('find-count');
  const transcript = $('transcript');
  const painted = typeof Highlight === 'function' && window.CSS && CSS.highlights;
  let matches = [];
  let current = -1;
  let timer = 0;

  // The folded text of one node, and for each folded letter the offset it came from in the node.
  function folded(text) {
    if (ASCII.test(text)) return { text: text.toLowerCase(), at: null };
    let out = '';
    const at = [];
    for (let index = 0; index < text.length; index++) {
      const piece = text[index].normalize('NFD').replace(MARKS, '').toLowerCase();
      out += piece;
      for (let letter = 0; letter < piece.length; letter++) at.push(index);
    }
    return { text: out, at };
  }

  function segments(element) {
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    const found = [];
    let text = '';
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const fold = folded(node.data);
      found.push({ node, start: text.length, at: fold.at, length: fold.text.length });
      text += fold.text;
    }
    return { text, found };
  }

  function point(found, index, end) {
    let low = 0;
    let high = found.length - 1;
    while (low < high) {
      const middle = (low + high + 1) >> 1;
      if (found[middle].start <= index) low = middle;
      else high = middle - 1;
    }
    const segment = found[low];
    const local = index - segment.start;
    const offset = segment.at ? segment.at[local] : local;
    return { node: segment.node, offset: end ? offset + 1 : offset };
  }

  function search(query) {
    const needle = folded(query).text;
    const ranges = [];
    if (!needle) return ranges;
    for (const element of document.querySelectorAll(SCOPE)) {
      const { text, found } = segments(element);
      for (let index = text.indexOf(needle); index >= 0; index = text.indexOf(needle, index + needle.length)) {
        const start = point(found, index, false);
        const end = point(found, index + needle.length - 1, true);
        const range = document.createRange();
        range.setStart(start.node, start.offset);
        range.setEnd(end.node, Math.min(end.offset, end.node.length));
        ranges.push(range);
      }
    }
    return ranges;
  }

  function paint() {
    if (painted) {
      CSS.highlights.set('vcx-find', new Highlight(...matches));
      if (matches[current]) CSS.highlights.set('vcx-find-current', new Highlight(matches[current]));
      else CSS.highlights.delete('vcx-find-current');
    }
    count.textContent = !input.value ? '' : matches.length ? `${current + 1} of ${matches.length}` : 'No match';
  }

  function land() {
    const range = matches[current];
    if (!range) return;
    const bubble = range.startContainer.parentElement && range.startContainer.parentElement.closest('.bubble.long');
    if (bubble) bubble.classList.add('open');
    const box = range.getBoundingClientRect();
    const view = transcript.getBoundingClientRect();
    if (box.top < view.top || box.bottom > view.bottom) transcript.scrollTop += box.top - view.top - view.height * LANDING_SHARE;
  }

  function run(keep) {
    const before = current;
    matches = search(input.value);
    current = matches.length ? (keep ? Math.min(Math.max(before, 0), matches.length - 1) : 0) : -1;
    paint();
    if (!keep) land();
  }

  function step(by) {
    if (!matches.length) return;
    current = (current + by + matches.length) % matches.length;
    paint();
    land();
  }

  function open() {
    bar.hidden = false;
    input.focus();
    input.select();
    if (input.value) run(true);
  }

  function close() {
    bar.hidden = true;
    matches = [];
    current = -1;
    if (painted) {
      CSS.highlights.delete('vcx-find');
      CSS.highlights.delete('vcx-find-current');
    }
    const composer = $('input');
    if (composer) composer.focus();
  }

  // Called after each message the page draws: the matches follow the rows that changed.
  function refresh() {
    if (bar.hidden || !input.value) return;
    clearTimeout(timer);
    timer = setTimeout(() => run(true), REFRESH_MS);
  }

  input.addEventListener('input', () => run(false));
  input.addEventListener('keydown', event => {
    if (event.key === 'Enter') step(event.shiftKey ? -1 : 1);
    else if (event.key === 'Escape') close();
    else return;
    event.preventDefault();
    event.stopPropagation();
  });
  $('find-next').addEventListener('click', () => step(1));
  $('find-previous').addEventListener('click', () => step(-1));
  $('find-close').addEventListener('click', close);
  addEventListener('keydown', event => {
    if (!event.metaKey || event.ctrlKey || event.altKey) return;
    const key = event.key.toLowerCase();
    if (key === 'f') open();
    else if (key === 'g' && !bar.hidden) step(event.shiftKey ? -1 : 1);
    else return;
    event.preventDefault();
    event.stopPropagation();
  }, true);

  window.vcxFind = { open, close, refresh, step, get state() { return { query: input.value, count: matches.length, current, shown: count.textContent } } };
})();
