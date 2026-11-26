'use strict';
// Editing a code block of an answer, as the Swift `CodeBlock` and `CodeEdits`: the pencil opens the block in a text
// area, Escape or a click away closes it, copy takes his version, and his next message carries each block edited since
// the last one. Edits are kept by the block's original text, so a block drawn again comes back edited.
(() => {
  const EDITED = ' · edited';
  const EDIT_HINT = 'Edit: copy takes your version, and your next message sends it';
  const ICONS = '<svg class="ready" viewBox="0 0 24 24"><path d="M21.17 6.81a1 1 0 0 0-3.99-3.98L3.84 16.17a2 2 0 0 0-.5.83l-1.32 4.35a.5.5 0 0 0 .62.62l4.35-1.32a2 2 0 0 0 .83-.5z"/></svg>'
    + '<svg class="done" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/></svg>';

  const edits = new Map();
  let unsent = [];
  const blocks = new WeakMap();

  function set(original, edited) {
    if (edited === original) edits.delete(original);
    else edits.set(original, edited);
    unsent = unsent.filter(block => block !== original);
    if (edited !== original) unsent.push(original);
  }

  // The Swift `attach(to:)`, in its words: each block in ``` fences (```` when it holds ```), then the prompt.
  function attach(prompt) {
    if (prompt.startsWith('/')) return prompt;
    const versions = unsent.map(original => edits.get(original)).filter(text => text !== undefined);
    unsent = [];
    const told = versions.map(block => {
      const fence = block.includes('```') ? '````' : '```';
      return `I edited your code block. My version:\n${fence}\n${block}\n${fence}`;
    });
    return [...told, prompt].filter(Boolean).join('\n\n');
  }

  // ---- Effect: text area that grows. Copy from here ----
  // The text area takes its text's height on each input: measured at no height, then eased from the old one.
  function growArea(area) {
    const fit = () => {
      const was = area.style.height;
      area.style.transition = 'none';
      area.style.height = '0';
      const tall = area.scrollHeight + area.offsetHeight - area.clientHeight + 'px';
      area.style.height = was || tall;
      void area.offsetHeight;
      area.style.transition = '';
      area.style.height = tall;
    };
    area.addEventListener('input', fit);
    fit();
    return fit;
  }
  // ---- End of effect ----

  function show(figure) {
    const block = blocks.get(figure);
    const edited = edits.get(block.original);
    block.code.textContent = edited ?? block.source;
    block.label.textContent = block.name + (edited === undefined ? '' : EDITED);
  }

  function toggle(figure, editing) {
    const block = blocks.get(figure);
    if (Boolean(block.area) === editing) return;
    figure.classList.toggle('editing', editing);
    block.button.classList.toggle('editing', editing);
    block.button.title = editing ? 'Done editing' : EDIT_HINT;
    block.button.ariaLabel = editing ? 'Done editing' : 'Edit code';
    const pre = block.code.closest('pre');
    if (!editing) {
      const area = block.area;
      block.area = null;
      area.remove();
      pre.hidden = false;
      return show(figure);
    }
    const area = document.createElement('textarea');
    area.className = 'edit-area';
    area.value = edits.get(block.original) ?? block.original;
    area.spellcheck = false;
    area.setAttribute('autocorrect', 'off');
    area.setAttribute('autocapitalize', 'off');
    area.ariaLabel = 'Your version of the code';
    block.area = area;
    pre.hidden = true;
    pre.after(area);
    area.addEventListener('input', () => {
      set(block.original, area.value);
      show(figure);
    });
    area.addEventListener('keydown', event => {
      if (event.key !== 'Escape') return;
      event.preventDefault();
      event.stopPropagation();
      toggle(figure, false);
    });
    area.addEventListener('blur', () => toggle(figure, false));
    growArea(area);
    area.focus();
  }

  // Code blocks are drawn by app.js; each one of an answer gets its pencil once, before copy and after run.js's Run.
  function decorate() {
    for (const figure of document.querySelectorAll('#rows .answer-item figure.code:not(.markdown)')) {
      if (blocks.has(figure)) continue;
      const code = figure.querySelector('pre code');
      const copy = figure.querySelector('figcaption button.copy');
      const label = figure.querySelector('figcaption .language');
      if (!code || !copy || !label) continue;
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'edit b b-ghost icon sm';
      button.title = EDIT_HINT;
      button.ariaLabel = 'Edit code';
      button.innerHTML = ICONS;
      // The text area keeps the focus on a press here, so its blur does not close it before the click toggles it.
      button.addEventListener('mousedown', event => event.preventDefault());
      copy.before(button);
      blocks.set(figure, { code, label, button, name: label.textContent, source: code.textContent, original: code.textContent.replace(/\n$/, ''), area: null });
      if (edits.has(blocks.get(figure).original)) show(figure);
    }
  }

  document.addEventListener('click', event => {
    const button = event.target.closest('#rows figure.code button.edit');
    if (!button) return;
    const figure = button.closest('figure.code');
    toggle(figure, !blocks.get(figure).area);
  });
  const rows = document.getElementById('rows');
  if (rows) new MutationObserver(decorate).observe(rows, { childList: true, subtree: true });

  window.vcxCodeEdits = { attach, get edited() { return Object.fromEntries(edits) } };
})();
