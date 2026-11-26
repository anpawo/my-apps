'use strict';
// Click to copy, as in Swift: a click on the previewed picture copies the image itself (`ImagePreview.copy`), and with
// ⌘ held a click on a table cell copies its text, a ⌘-double-click the whole row tab-separated (`ProseView.copy`).
// Without ⌘ the cells keep their text selection and their links. The page has no clipboard: the core writes it.
(() => {
  // Swift `ImagePreview`: the Copied label stays 1.5 s; `ProseView`: the cell's veil 1.2 s.
  const IMAGE_COPIED_MS = 1500;
  const CELL_COPIED_MS = 1200;
  const CELL_HINT = '⌘-click copies the cell, ⌘-double-click the row';
  const CHECK = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 6 9 17l-5-5"/></svg>';

  // A sheet of its own: the page's CSP lets no inline style in.
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(`
    #preview img { cursor: copy; }
    #preview .copied { position: absolute; left: 50%; top: 50%; translate: -50% -50%; pointer-events: none; }
    /* Effect: file name chip that copies on click (WT-038), its fill in Swift's green veil. */
    .prose :is(td, th, tr) { transition: background-color 250ms ease-out; }
    .prose :is(td, th, tr).copied { background-color: rgb(52 199 89 / 0.18); }
    @media (prefers-reduced-motion: reduce) { .prose :is(td, th, tr) { transition-duration: 100ms; } }
  `);
  document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];

  const image = document.querySelector('#preview img');
  image.title = 'Click to copy the image';
  image.setAttribute('role', 'button');
  image.setAttribute('aria-label', 'Copy image');

  // ---- Effect: copy to checkmark (WT-020), as the Session ID button shows it: its copied label and check fade in ----
  const fade = (el, opacity) => el.animate({ opacity, scale: opacity[0] ? [1, 0.9] : [0.9, 1] }, { duration: 120, easing: 'ease-out' }).finished;
  let imageTimer;
  function imageCopied() {
    let label = image.parentElement.querySelector('.copied');
    if (!label) {
      label = document.createElement('span');
      label.className = 'b b-outline copied';
      label.setAttribute('role', 'status');
      label.innerHTML = `${CHECK}<span>Copied</span>`;
      image.after(label);
      fade(label, [0, 1]);
    }
    clearTimeout(imageTimer);
    imageTimer = setTimeout(() => fade(label, [1, 0]).then(() => label.remove()), IMAGE_COPIED_MS);
  }
  // ---- End of effect ----

  // Its own listener, so the click copies instead of reaching the document's, which closes the preview.
  image.addEventListener('click', event => {
    event.stopPropagation();
    if (!image.getAttribute('src')) return;
    window.vcx.post({ type: 'copyImage', src: image.getAttribute('src') });
    imageCopied();
  });

  // ---- Effect: file name chip that copies on click (WT-038): marked copied for `hold` ms, a new click starts it again ----
  let marked = null;
  let cellTimer;
  function cellCopied(node) {
    marked?.classList.remove('copied');
    marked = node;
    node.classList.add('copied');
    clearTimeout(cellTimer);
    cellTimer = setTimeout(() => { node.classList.remove('copied'); marked = null; }, CELL_COPIED_MS);
  }
  // ---- End of effect ----

  const cellOf = event => event.metaKey && event.target.closest?.('.prose table :is(td, th)');
  // A ⌘-double-click would select the word under it: the copy takes the click instead.
  document.addEventListener('mousedown', event => { if (cellOf(event)) event.preventDefault(); }, true);
  // Captured first, so a link in the cell is not followed, as the Swift overlay takes the click while ⌘ is down.
  document.addEventListener('click', event => {
    const cell = cellOf(event);
    if (!cell) return;
    event.preventDefault();
    event.stopPropagation();
    const row = cell.parentElement;
    const whole = event.detail >= 2;
    const text = whole ? [...row.cells].map(c => c.innerText.trim()).join('\t') : cell.innerText.trim();
    window.vcx.post({ type: 'copy', text });
    cellCopied(whole ? row : cell);
  }, true);
  document.addEventListener('mouseover', event => {
    const table = event.target.closest?.('.prose table');
    if (table && !table.title) table.title = CELL_HINT;
  });
})();
