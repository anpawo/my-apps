'use strict';
// The composer: what is typed and attached before a message is sent. Attachments sit in the text as tokens
// ("[Image #1]", "[Paste #1]", "@src/main.rs") that the native undo stack keeps, and show as chips above it.
(() => {
  // Swift's editor: 24 pt for one line, at most 150 pt before it scrolls (`composerMinimumHeight`, `measure`).
  const INPUT_MAX_HEIGHT_PX = 150;
  // A pasted text this long folds into a chip, as in the Swift composer (`Composer.swift`, `paste(from:)`).
  const PASTE_FOLD_CHARACTERS = 20;
  const DRAFT_SAVE_DELAY_MS = 250;
  // The send flight, as One Text's `fly`: 380 ms on an ease-out of the fourth power; a send waits 5 s for its row.
  const FLIGHT_MS = 380;
  const FLIGHT_EASE_POWER = 4;
  const FLIGHT_WAIT_MS = 5000;
  const FLIGHT_FRAME_GRACE_MS = 100;
  // The flying box's frame stands 16 pt around the text it carries.
  const FLIGHT_INSET_PX = 16;
  const COMPOSER_RADIUS_PX = 18;
  const BUBBLE_RADIUS_PX = 17;
  // The palette's list: at most 250 pt, and 90 pt short of the transcript's height (Swift `maxListHeight`).
  const PALETTE_LIST_MAX_PX = 250;
  const PALETTE_LIST_MIN_PX = 40;
  const PALETTE_LIST_MARGIN_PX = 90;
  const IMAGE_MAX_BYTES = 32 * 1024 * 1024;
  // The command palette rises 70 pt as it fades in, as Swift's `.offset(y: 70)` transition.
  const PALETTE_OPEN_MS = 250;
  const PALETTE_OPEN_RISE_PX = 70;
  const PICTURES_SHOW_MS = 250;
  // The address pills' glide, WT-061.
  const PILL_GLIDE_MS = 300;
  const PROVIDERS = ['claude', 'codex', 'qwen', 'agy'];
  // Their values run as soon as they are chosen; the others go into the composer to be read before Return.
  const RUN_AT_ONCE = ['/model ', '/provider ', '/perms ', '/resume '];
  // Swift runs `/attach <image path>` in the window: the picture becomes a chip in the draft, never a message.
  const ATTACH_COMMAND = /^\/attach(?:\s+([\s\S]*))?$/;
  // The commands VCX itself runs, from `Commands.swift` (`appCommands`): name, what it does, takes an argument.
  const APP_COMMANDS = [
    ['model', 'Choose provider, model, and reasoning effort', true], ['codex', 'Switch to Codex and its newest model', false],
    ['fable', 'Switch to Claude Fable', false], ['opus', 'Switch to Claude Opus', false],
    ['account', 'Use, enable, disable, or rename a subscription account', true], ['perms', 'Choose bypass / YOLO or ask for approval', true],
    ['dir', 'Change the working directory', true], ['window', 'Open another window, optionally in a directory', false],
    ['new', 'Start a new conversation; current work stays saved', false], ['clear', 'Start a new conversation', false],
    ['resume', 'Choose a saved conversation', true], ['fork', 'Branch the current Codex conversation', false],
    ['rename', 'Name the current conversation', true], ['plan', 'Use Codex plan mode; off returns to implementation', true],
    ['effort', 'Set reasoning effort for the active model', true], ['reconnect', 'Reconnect the current conversation', false],
    ['stop', 'Interrupt the current response', false], ['settings', 'Show configuration and available settings commands', false],
    ['login', 'Add a Claude or Codex subscription, or cancel sign-in', true], ['profile', 'Import an existing account: claude|codex <folder>', true],
    ['qwen', 'Configure url, proxy, or model', true], ['hooks', 'List provider hooks; add reload to refresh', false],
    ['skills', 'List provider skills; add reload to refresh', false], ['mcp', 'List Model Context Protocol servers; add reload to refresh', false],
    ['instructions', 'List discovered instruction files', false], ['tokens', 'Show reported token and context usage', false],
    ['usage', 'Refresh subscription usage', false], ['repo', 'Show repository and branch', false], ['status', 'Show the current session', false],
    ['details', 'Expand or collapse action details', false], ['focus', 'Expand or collapse action details', false],
    ['attach', 'Attach an image by its path', true], ['preview', 'Preview the last image in the conversation', false],
    ['answer', 'Answer the current question from chat', true], ['allow', 'Approve the pending action', false],
    ['decline', 'Decline the pending action', false], ['help', 'Show commands and keyboard shortcuts', false],
    ['quit', 'Save and close this instance', false], ['exit', 'Save and close this instance', false],
  ];

  const $ = id => document.getElementById(id);
  const post = message => window.ipc.postMessage(JSON.stringify(message));
  const form = $('composer');
  const input = $('input');
  // Commands, paths and code are typed here: WebKit's smart quotes and corrections would change them (Swift's composer turns them off too).
  input.spellcheck = false;
  for (const [name, value] of [['autocorrect', 'off'], ['autocapitalize', 'off'], ['autocomplete', 'off']]) input.setAttribute(name, value);
  const chips = new Map();
  const previews = new Map();
  const prompts = new Map();
  let promptOrder = [];
  let meta = {};
  let generation = 0;
  let saveTimer = 0;
  let history = null;
  let applying = false;
  let fileSerial = 0;
  let imageSerial = 0;
  let flight = null;
  const palette = { kind: '', key: '', start: 0, end: 0, query: '', whole: false, options: [], selected: 0, home: 0, dismissed: '' };

  function make(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // A 24-pixel icon of his templates' stroke set: `paths` are its SVG path data.
  function icon(...paths) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('aria-hidden', 'true');
    for (const d of paths) {
      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      path.setAttribute('d', d);
      svg.append(path);
    }
    return svg;
  }

  // Swift's round buttons: send an arrow on the pink-to-violet gradient, stop a black square on white.
  $('send').className = 'b';
  $('send').append(icon('M12 19V5', 'm5 12 7-7 7 7'));
  $('stop').className = 'b';
  $('stop').append(icon('M6 4h12a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z'));
  $('stop').title = 'Stop generation (Escape)';
  $('send').title = 'Send message (Return)';
  const field = make('div', 'field');
  const marks = make('div', 'marks');
  marks.setAttribute('aria-hidden', 'true');
  input.before(field);
  field.append(marks, input);
  const pictures = make('div');
  pictures.id = 'draft-pictures';
  pictures.hidden = true;
  form.before(pictures);

  const strip = make('div', 'attachments');
  strip.id = 'attachments';
  strip.hidden = true;
  form.prepend(strip);
  const panel = make('div');
  panel.id = 'palette';
  panel.setAttribute('role', 'listbox');
  const list = make('div', 'palette-list');
  const head = make('div', 'palette-head');
  const title = make('span', 'palette-title');
  const count = make('span', 'palette-count');
  head.append(icon('M15 6v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3'), title, count, make('span', 'palette-esc', 'esc'));
  const foot = make('div', 'palette-foot');
  foot.append(make('kbd', '', '↑'), make('kbd', '', '↓'), make('span', '', 'navigate'), make('kbd', '', '↩'), make('span', '', 'select'), make('kbd', '', '⇥'), make('span', '', 'complete'));
  panel.append(head, make('div', 'palette-sep'), list, make('div', 'palette-sep'), foot);
  form.before(panel);

  // ---- Effect: address pills pack onto the fewest lines. Copy from here ----
  // The order that lays items `w` px wide, `gap` apart, on the fewest lines `line` px wide: the widest first, each on
  // the first line with room for it (first-fit decreasing), a line's items in their own order; `last` px kept at the
  // end of the last line.
  function pack(w, line, gap, last = 0) {
    const lines = [], all = w.map((x, n) => [x, n]);
    if (last) all.push([last, -1]);
    for (const [x, n] of all.sort((a, b) => b[0] - a[0])) {
      let at = lines.find(l => l.room >= x);
      if (!at) lines.push(at = { room: line, of: [] });
      at.room -= x + gap;
      at.of.push(n);
    }
    const ends = l => (l.of.includes(-1) ? 1 : 0);
    return lines.sort((a, b) => ends(a) - ends(b)).flatMap(l => l.of.filter(n => n >= 0).sort((a, b) => a - b));
  }
  // Lays the pills of `dd` in that order (their CSS order) whenever it changes size or holds other pills; a pill that
  // moves glides from where it stood in `dur` ms, a new one grows in, and the field eases to its new height.
  function packPills(dd, { dur = 300 } = {}) {
    const was = new Map(), calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
    let tall = 0;
    // its place in the layout, whatever glide is under way
    const at = el => [el.offsetLeft, el.offsetTop];
    const lay = () => {
      const pills = [...dd.children];
      if (pills.length === 0) return void (tall = 0);
      pack(pills.map(p => p.offsetWidth + 1), dd.clientWidth, parseFloat(getComputedStyle(dd).columnGap) || 0)
        .forEach((n, k) => { pills[n].style.order = k; });
      for (const k of pills) {
        const [x, y] = at(k), old = was.get(k);
        if (!old) k.animate({ opacity: [0, 1], scale: [0.85, 1] }, { duration: calm ? 100 : dur * 0.7, easing: 'ease-out' });
        else if (!calm && (old[0] !== x || old[1] !== y)) k.animate({ translate: [`${old[0] - x}px ${old[1] - y}px`, '0 0'] }, { duration: dur, easing: 'cubic-bezier(.2,.8,.2,1)' });
        was.set(k, [x, y]);
      }
      // the height its pills take, whatever the height animation shows meanwhile
      const h = Math.max(...pills.map(k => k.offsetTop + k.offsetHeight)) - Math.min(...pills.map(k => k.offsetTop));
      if (tall && h !== tall && !calm) {
        const from = dd.getAnimations().length ? dd.offsetHeight : tall;
        dd.getAnimations().forEach(a => a.cancel());
        dd.animate({ height: [from + 'px', h + 'px'], overflow: ['clip', 'clip'] }, { duration: dur, easing: 'cubic-bezier(.2,.8,.2,1)' });
      }
      tall = h;
    };
    new ResizeObserver(lay).observe(dd);
    new MutationObserver(lay).observe(dd, { childList: true });
  }
  // ---- End of effect ----
  packPills(strip, { dur: PILL_GLIDE_MS });

  // Swift's `commandWordPattern`: a "/" word not inside a path or a URL.
  const COMMAND_WORD = /(?<![\w/:.\-])\/([\w\-]+(?::[\w\-]+)*)(?![\w/\-]|[.:]\w)/g;
  const imageToken = number => `[Image #${number}]`;
  const pasteToken = number => `[Paste #${number}]`;
  const mentionToken = (path, folder) => {
    const shown = folder && !path.endsWith('/') ? `${path}/` : path;
    return /\s/.test(shown) ? `@"${shown}"` : `@${shown}`;
  };

  // Each place a chip's token stands in the text, in order; a token typed over or cut in half is plain text again.
  function placed(text = input.value) {
    const found = [];
    for (const [token, chip] of chips) {
      for (let at = text.indexOf(token); at >= 0; at = text.indexOf(token, at + token.length)) found.push({ at, token, chip });
    }
    found.sort((a, b) => a.at - b.at);
    let reached = 0;
    return found.filter(place => place.at >= reached && (reached = place.at + place.token.length));
  }

  function nextNumber(kind) {
    let highest = 0;
    for (const chip of chips.values()) if (chip.kind === kind) highest = Math.max(highest, chip.number || 0);
    return highest + 1;
  }

  // The draft as the worker keeps it (`draftContent` in Swift): text, local images, folded pastes.
  function pieces() {
    const text = input.value;
    const out = [];
    const add = piece => {
      const last = out[out.length - 1];
      if (piece.type === 'text' && !piece.attachment && last && last.type === 'text' && !last.attachment) last.text += piece.text;
      else if (piece.type !== 'text' || piece.text) out.push(piece);
    };
    let at = 0;
    for (const place of placed(text)) {
      add({ type: 'text', text: text.slice(at, place.at) });
      const { chip } = place;
      if (chip.kind === 'image') add({ type: 'localImage', path: chip.path });
      else if (chip.kind === 'paste') add({ type: 'paste', text: chip.text, number: chip.number });
      else add({ type: 'text', text: place.token, attachment: chip.kind, path: chip.path });
      at = place.at + place.token.length;
    }
    add({ type: 'text', text: text.slice(at) });
    return out;
  }

  // What is sent: a folded paste goes as its text, an image as "[Image #N]" numbered by its place (Swift's `message()`).
  function message() {
    let text = '';
    const images = [];
    for (const piece of pieces()) {
      if (piece.type === 'localImage') {
        images.push(piece.path);
        text += imageToken(images.length);
      } else text += piece.text;
    }
    return { text: text.trim(), images };
  }

  function restore(draft) {
    chips.clear();
    let text = '';
    let images = 0;
    for (const piece of draft || []) {
      if (piece.type === 'localImage' || (piece.path && typeof piece.text !== 'string')) {
        images += 1;
        chips.set(imageToken(images), { kind: 'image', path: piece.path, number: images });
        text += imageToken(images);
      } else if (piece.type === 'paste' && typeof piece.text === 'string') {
        const number = piece.number || nextNumber('paste');
        chips.set(pasteToken(number), { kind: 'paste', text: piece.text, number });
        text += pasteToken(number);
      } else if (typeof piece.text === 'string') {
        if (piece.attachment && piece.path) chips.set(piece.text, { kind: piece.attachment, path: piece.path });
        text += piece.text;
      }
    }
    return text;
  }

  // ---- Effect: text area that grows. Copy from here ----
  // The text area takes its text's height on each input: measured at no height, then eased from the old one. Past
  // INPUT_MAX_HEIGHT_PX it stops growing and scrolls.
  function grow(instant = false) {
    // Measuring at no height lets the transcript grow for one layout, and WebKit clamps its scroll there: kept as it was.
    const transcript = document.getElementById('transcript'), scrolled = transcript.scrollTop;
    const was = instant ? '' : input.style.height;
    input.style.transition = 'none';
    input.style.height = '0';
    const full = input.scrollHeight + input.offsetHeight - input.clientHeight;
    const tall = `${Math.min(full, INPUT_MAX_HEIGHT_PX)}px`;
    input.style.height = was || tall;
    void input.offsetHeight;
    transcript.scrollTop = scrolled;
    input.style.transition = '';
    input.style.height = tall;
    input.style.overflowY = full > INPUT_MAX_HEIGHT_PX ? 'auto' : 'hidden';
  }
  // ---- End of effect ----

  function refresh(instant = false) {
    grow(instant);
    drawStrip();
    drawMarks();
    drawPictures();
    dimSend();
    updatePalette();
  }

  // Swift's `commandWords`: every command's name and insert without its "/", terminal ones aside.
  function commandWords() {
    const words = new Set();
    for (const command of catalog()) {
      if (String(command.source || '').endsWith(' terminal')) continue;
      for (const name of [command.name, command.insert.trim()]) if (name.startsWith('/')) words.add(name.slice(1));
    }
    return words;
  }

  // A "/word" naming a command takes the purple tint while typed, the grey chip once a blank follows it (Swift's
  // `highlightCommands` and `CommandChip`); drawn on the layer under the text, never stored in it.
  function drawMarks() {
    const text = input.value;
    const words = text.includes('/') ? commandWords() : null;
    const nodes = [];
    let at = 0;
    for (const match of words ? text.matchAll(COMMAND_WORD) : []) {
      if (!words.has(match[1])) continue;
      const end = match.index + match[0].length;
      nodes.push(text.slice(at, match.index), make('span', /\s/.test(text[end] || '') ? 'locked' : 'command', match[0]));
      at = end;
    }
    // A text ending on a new line needs one more line under it, as the text area draws one.
    nodes.push(`${text.slice(at)}\n`);
    marks.replaceChildren(...nodes);
    marks.scrollTop = input.scrollTop;
  }

  // The draft's pictures as Swift's `PictureView` cards, in their order in the text; a click previews one.
  function drawPictures() {
    const shown = placed().filter(place => place.chip.kind === 'image');
    const key = shown.map(place => `${place.chip.path}\n${place.chip.preview ? 1 : 0}`).join('\n');
    if (key === pictures.dataset.key) return;
    const appearing = pictures.hidden && shown.length > 0;
    pictures.dataset.key = key;
    pictures.replaceChildren(...shown.map((place, index) => {
      const button = make('button', 'picture');
      button.type = 'button';
      button.addEventListener('mousedown', event => event.preventDefault());
      if (place.chip.preview) {
        button.dataset.src = place.chip.preview;
        const image = make('img');
        image.alt = '';
        image.src = place.chip.preview;
        button.append(image);
      } else button.append(make('span', 'missing', '?'));
      const words = make('span', 'words');
      words.append(make('span', 'name', `Image #${index + 1}`), make('span', 'hint', 'Click to preview'));
      const expand = icon('M15 3h6v6', 'M9 21H3v-6', 'M21 3l-7 7', 'M3 21l7-7');
      expand.classList.add('expand');
      button.append(words, expand);
      button.title = place.chip.path;
      return button;
    }));
    pictures.hidden = shown.length === 0;
    if (appearing && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      pictures.animate({ opacity: [0, 1], translate: ['0 12px', '0 0'] }, { duration: PICTURES_SHOW_MS, easing: 'ease-out' });
    }
  }

  // Dimmed while the session cannot take a message, a command aside (Swift's `.disabled` on send).
  function dimSend() {
    $('send').classList.toggle('dim', !input.value.startsWith('/') && (!meta.ready || Boolean(meta.changing)));
  }

  // Through the editing commands, so ⌘Z takes it back like typing; `applying` keeps it from counting as his edit.
  function replace(start, end, text) {
    input.focus();
    input.setSelectionRange(start, end);
    applying = true;
    const done = text ? document.execCommand('insertText', false, text) : start === end || document.execCommand('delete');
    applying = false;
    if (!done) input.setRangeText(text, start, end, 'end');
    edited();
  }

  function setText(text) {
    replace(0, input.value.length, text);
  }

  function insert(text) {
    const before = input.value.slice(0, input.selectionStart);
    replace(input.selectionStart, input.selectionEnd, (before && !/\s$/.test(before) ? ' ' : '') + text);
  }

  function edited() {
    generation += 1;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(save, DRAFT_SAVE_DELAY_MS);
    refresh();
  }

  function save() {
    clearTimeout(saveTimer);
    saveTimer = 0;
    post({ type: 'draft', draft: pieces(), generation });
  }

  function chipLabel(place, images) {
    const { chip } = place;
    const name = (chip.path || '').replace(/\/$/, '').split('/').pop();
    if (chip.kind === 'image') return `Image #${images} · ${name}`;
    if (chip.kind === 'paste') {
      const lines = chip.text.split('\n').length;
      return `Paste #${chip.number} · ${lines > 1 ? `${lines} lines` : `${chip.text.length} characters`}`;
    }
    return chip.kind === 'folder' ? `${name}/` : name;
  }

  function chipNode(place, images) {
    const { chip, token } = place;
    const node = make('span', `attachment ${chip.kind}`);
    node.dataset.token = token;
    node.title = chip.kind === 'paste' ? chip.text.slice(0, 600) : chip.path;
    if (chip.preview) {
      const picture = make('img');
      picture.src = chip.preview;
      picture.alt = '';
      node.append(picture);
    }
    const label = chipLabel(place, images);
    node.append(make('span', 'attachment-label', label));
    const remove = make('button', 'attachment-remove');
    remove.append(icon('M18 6 6 18', 'm6 6 12 12'));
    remove.type = 'button';
    remove.setAttribute('aria-label', `Remove ${label}`);
    remove.addEventListener('mousedown', event => event.preventDefault());
    remove.addEventListener('click', () => removeToken(token));
    node.append(remove);
    return node;
  }

  function drawStrip() {
    const seen = new Set();
    const shown = placed().filter(place => !seen.has(place.token) && seen.add(place.token));
    const key = shown.map(place => place.token).join('\n');
    if (key === strip.dataset.key) return;
    strip.dataset.key = key;
    // A pill whose token and label stay is kept, so the packing glides it rather than growing it in again.
    const kept = new Map([...strip.children].map(node => [`${node.dataset.token}\n${node.querySelector('.attachment-label').textContent}`, node]));
    let images = 0;
    const nodes = shown.map(place => {
      if (place.chip.kind === 'image') images += 1;
      const node = chipNode(place, images);
      return kept.get(`${place.token}\n${node.querySelector('.attachment-label').textContent}`) || node;
    });
    strip.hidden = shown.length === 0;
    strip.replaceChildren(...nodes);
  }

  function removeToken(token) {
    const at = input.value.indexOf(token);
    if (at < 0) return;
    const end = at + token.length + (input.value[at + token.length] === ' ' ? 1 : 0);
    replace(at, end, '');
  }

  // The word ending at the caret that starts with `sign`, at the start of the text or after a blank (Swift's `slashWord`).
  function caretWord(sign) {
    const text = input.value;
    const caret = input.selectionEnd;
    if (input.selectionStart !== caret || (caret < text.length && !/\s/.test(text[caret]))) return null;
    let start = caret;
    while (start > 0 && !/\s/.test(text[start - 1])) start -= 1;
    if (start === caret || text[start] !== sign) return null;
    return { start, end: caret, word: text.slice(start, caret) };
  }

  // Dictation ends a lone "/sm" with a period ("/sm."), which matched no command.
  const undictated = text => (text.startsWith('/') && !/\s/.test(text) ? text.replace(/[.,!?;:]+$/, '') : text);

  function commandAt() {
    const text = input.value;
    const trimmed = text.replace(/^\n+|\n+$/g, '');
    const atEnd = input.selectionStart === text.length && input.selectionEnd === text.length;
    if (trimmed.startsWith('/') && !trimmed.includes('\n') && atEnd) {
      return { start: text.indexOf('/'), end: text.length, query: undictated(trimmed), whole: true };
    }
    const word = caretWord('/');
    return word && { start: word.start, end: word.end, query: undictated(word.word), whole: false };
  }

  function provider() {
    const label = (meta.providerLabel || '').toLowerCase();
    return label.startsWith('antigravity') ? 'agy' : PROVIDERS.find(name => label.startsWith(name)) || label;
  }

  function catalog() {
    const commands = APP_COMMANDS.map(([name, detail, argument]) => ({ name: `/${name}`, detail, source: 'vcx', insert: `/${name}${argument ? ' ' : ''}` }));
    for (const command of meta.providerCommands || []) {
      if (command && typeof command.name === 'string') commands.push({ name: command.name, detail: command.detail || '', source: command.source || meta.providerLabel || '', insert: command.insert || command.name });
    }
    if (['claude', 'codex'].includes(provider())) {
      commands.push({ name: '/compact', detail: 'Compact the current context', source: meta.providerLabel, insert: '/compact' });
      commands.push({ name: '/review', detail: 'Review uncommitted changes or custom instructions', source: meta.providerLabel, insert: '/review ' });
    }
    return commands;
  }
  window.vcxCatalog = catalog;

  // Swift's `commandOptions`: exact names first, then names that start with the query, then names and details that hold it.
  function commandOptions(query) {
    const space = query.indexOf(' ');
    if (space >= 0) return argumentOptions(query.slice(0, space).replace('/vcx:', '/'), query.slice(space + 1).toLowerCase(), query.toLowerCase());
    const lower = query.toLowerCase();
    const needle = lower.replace('/vcx:', '/');
    const rank = command => {
      const name = command.name.toLowerCase();
      const insert = command.insert.trim().toLowerCase();
      if (name === needle || insert === lower) return 0;
      if (name.startsWith(needle) || insert.startsWith(lower)) return 1;
      return name.includes(needle) ? 2 : 3;
    };
    const names = new Set();
    return catalog()
      .filter(command => needle === '/' || command.name.toLowerCase().includes(needle) || command.insert.toLowerCase().startsWith(lower) || command.detail.toLowerCase().includes(needle.slice(1)))
      .filter(command => !names.has(command.name.toLowerCase()) && names.add(command.name.toLowerCase()))
      .map(command => [rank(command), command])
      .sort((a, b) => a[0] - b[0])
      .map(([, command]) => command);
  }

  function argumentOptions(verb, argument, query) {
    const option = (value, detail, label, current) => ({ name: label || value, detail, source: '', insert: `${verb} ${value}`, current: Boolean(current) });
    let choices;
    switch (verb) {
      case '/model':
      case '/provider':
        return modelOptions(argument, option);
      case '/perms':
        choices = [option('bypass', 'YOLO: no tool approval prompts', '', meta.activeMode === 'bypass'), option('ask', 'Ask before actions that need permission', '', meta.activeMode === 'ask')];
        break;
      case '/plan':
        choices = [option('on', 'Plan without implementing'), option('off', 'Return to implementation')];
        break;
      case '/effort':
        choices = ((meta.modelEfforts || {})[meta.model] || []).map(effort => option(effort, 'Reasoning effort', '', effort === meta.effort));
        break;
      case '/login':
        choices = ['claude', 'codex', 'cancel'].map(value => option(value, value === 'cancel' ? 'Cancel sign-in' : 'Sign in with subscription'));
        break;
      case '/resume':
        choices = (meta.recent || []).filter(saved => saved && saved.id).map(saved => option(saved.id, '', saved.title || saved.id));
        break;
      default:
        return [];
    }
    return choices.filter(choice => !argument || choice.name.toLowerCase().includes(argument) || choice.insert.toLowerCase().includes(query));
  }

  // Swift's `modelName`: "claude-opus-5-5" reads "Opus 5.5".
  function modelName(id) {
    return id.replace(/^(claude[- ]|codex[- ])/i, '').replace(/-(\d+)-(\d+)$/, ' $1.$2').replace(/-/g, ' ')
      .replace(/\S+/g, word => word[0].toUpperCase() + word.slice(1).toLowerCase());
  }

  function modelOptions(argument, option) {
    const args = argument.split(' ');
    const efforts = model => (meta.modelEfforts || {})[model] || [];
    if (args.length === 1) {
      return PROVIDERS.filter(name => !argument || name.includes(argument)).map(name => option(`${name} `, `Choose ${name === 'agy' ? 'an Antigravity' : `a ${name[0].toUpperCase()}${name.slice(1)}`} model`, name === 'agy' ? 'Antigravity' : `${name[0].toUpperCase()}${name.slice(1)}`, name === provider()));
    }
    const [chosen, model, effort = ''] = args;
    if (chosen !== provider() && chosen !== 'auto') return [];
    if (args.length === 2) {
      // Claude lists its newest models only as aliases ("opus" runs claude-opus-5-5), so the row names what the alias runs.
      const aliases = meta.modelAliases || {};
      const resolved = id => (aliases[id] && aliases[id] !== id ? aliases[id] : '');
      const matches = id => !model || id.toLowerCase().includes(model) || (resolved(id) && (resolved(id).toLowerCase().includes(model) || modelName(resolved(id)).toLowerCase().includes(model)));
      return (meta.models || []).filter(matches).map(id => option(`${chosen} ${id}${efforts(id).length ? ' ' : ''}`, resolved(id) || 'Choose model', resolved(id) ? `${id} · ${modelName(resolved(id))}` : id, id === meta.model || aliases[id] === meta.model));
    }
    return efforts(model).filter(name => !effort || name.includes(effort)).map(name => option(`${chosen} ${model} ${name}`, 'Reasoning effort', name, model === meta.model && name === meta.effort));
  }

  function openPalette(kind, place, options, key) {
    const fresh = key !== palette.key || kind !== palette.kind;
    Object.assign(palette, { kind, key, start: place.start, end: place.end, query: place.query || '', whole: Boolean(place.whole), options });
    if (fresh) {
      palette.home = Math.max(0, options.findIndex(option => option.current));
      palette.selected = palette.home;
    }
    palette.selected = Math.min(palette.selected, Math.max(0, options.length - 1));
    drawPalette();
  }

  function closePalette() {
    palette.kind = '';
    palette.key = '';
    panel.getAnimations().forEach(motion => motion.cancel());
    panel.classList.remove('open');
    form.removeAttribute('aria-expanded');
  }

  function updatePalette() {
    const command = commandAt();
    if (command) {
      const key = `/${command.query}`;
      const options = commandOptions(command.query);
      if (key === palette.dismissed || ((command.query.includes(' ') || !command.whole) && options.length === 0)) return closePalette();
      palette.dismissed = '';
      return openPalette('command', command, options, key);
    }
    const mention = caretWord('@');
    if (mention) {
      const key = mention.word;
      if (key === palette.dismissed) return closePalette();
      palette.dismissed = '';
      if (key !== palette.key) {
        fileSerial += 1;
        post({ type: 'files', id: fileSerial, query: mention.word.slice(1) });
      }
      return openPalette('file', { start: mention.start, end: mention.end, query: mention.word }, key === palette.key ? palette.options : [], key);
    }
    palette.dismissed = '';
    closePalette();
  }

  function drawPalette() {
    const files = palette.kind === 'file';
    title.textContent = files ? 'Files' : 'Commands';
    count.textContent = String(palette.options.length);
    const transcript = $('transcript');
    if (transcript) panel.style.setProperty('--list-max', `${Math.max(PALETTE_LIST_MIN_PX, Math.min(PALETTE_LIST_MAX_PX, transcript.clientHeight - PALETTE_LIST_MARGIN_PX))}px`);
    list.replaceChildren(...palette.options.flatMap((option, index) => {
      const row = make('div', `palette-option${option.detail ? '' : ' bare'}${index === palette.selected ? ' selected' : ''}`);
      row.setAttribute('role', 'option');
      row.setAttribute('aria-selected', String(index === palette.selected));
      const text = make('div', 'palette-option-text');
      text.append(make('div', 'palette-option-name', option.name));
      if (option.detail) text.append(make('div', 'palette-option-detail', option.detail));
      row.append(text);
      if (option.source) row.append(make('span', 'palette-option-source', option.source));
      row.addEventListener('mousedown', event => event.preventDefault());
      row.addEventListener('click', () => choose(option));
      return index > 0 && !option.detail ? [make('div', 'palette-divider'), row] : [row];
    }));
    if (palette.options.length === 0) list.append(make('div', 'palette-option-none', files ? 'Looking for files…' : 'No matching commands'));
    if (!panel.classList.contains('open')) {
      panel.classList.add('open');
      const calm = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      if (!calm) panel.animate({ opacity: [0, 1], translate: [`0 ${PALETTE_OPEN_RISE_PX}px`, '0 0'] }, { duration: PALETTE_OPEN_MS, easing: 'ease-out' });
    }
    form.setAttribute('aria-expanded', 'true');
    list.querySelectorAll('.palette-option')[palette.selected]?.scrollIntoView({ block: 'nearest' });
  }

  function move(direction) {
    if (palette.options.length === 0) return;
    palette.selected = (palette.selected + direction + palette.options.length) % palette.options.length;
    drawPalette();
  }

  function choose(option) {
    if (!option) return;
    if (palette.kind === 'file') return chooseFile(option);
    const value = option.insert.trim();
    replace(palette.start, palette.end, option.insert);
    if (value.includes(' ') && !option.insert.endsWith(' ') && RUN_AT_ONCE.some(verb => value.startsWith(verb))) submit();
  }

  function chooseFile(option) {
    const token = mentionToken(option.path, option.folder);
    chips.set(token, { kind: option.folder ? 'folder' : 'file', path: option.absolute || option.path });
    palette.dismissed = '';
    replace(palette.start, palette.end, `${token} `);
  }

  // Return with the list open runs the command written in full, or else completes the highlighted one (Swift's `typedCommand`).
  function enterInPalette() {
    const highlighted = palette.options[palette.selected];
    if (palette.kind === 'file') return choose(highlighted);
    const typed = palette.query.trim();
    const exact = option => option.name.toLowerCase() === typed.toLowerCase() || option.insert.trim() === typed;
    if (exact(highlighted) || (palette.selected === palette.home && palette.options.some(exact))) return submit();
    choose(highlighted);
  }

  function submit() {
    const { text, images } = message();
    if (!text && images.length === 0) return;
    const attaching = images.length === 0 && text.match(ATTACH_COMMAND);
    if (attaching) {
      post({ type: 'attachPath', path: attaching[1] || '' });
      closePalette();
      return setText('');
    }
    // An open question card (questions.js) takes the typed text as its answer instead of a new message.
    const answered = Boolean(window.vcxQuestions?.open && text && images.length === 0 && window.vcxQuestions.reply(text));
    if (!answered) {
      const sending = window.vcxCodeEdits?.attach(text) ?? text;
      post({ type: 'send', text: sending, images, draft: pieces(), generation });
      prepareFlight(sending, images);
    }
    clearTimeout(saveTimer);
    saveTimer = 0;
    chips.clear();
    history = null;
    input.value = '';
    generation += 1;
    closePalette();
    // The empty composer shrinks at once, so the bubble's place is measured with the composer at its final size.
    refresh(true);
    document.dispatchEvent(new CustomEvent('vcx:sent'));
  }

  // Up arrow on an empty composer brings back the prompts sent before, newest first; Down goes forward again.
  function recall(direction) {
    const sent = promptOrder.map(id => prompts.get(id)).filter(Boolean);
    if ((history === null && (input.value !== '' || direction > 0)) || sent.length === 0) return false;
    const index = Math.max(0, Math.min(sent.length, (history ?? sent.length) + direction));
    const prompt = sent[index];
    chips.clear();
    let text = prompt ? prompt.text : '';
    (prompt ? prompt.images : []).forEach((path, place) => {
      const token = imageToken(place + 1);
      chips.set(token, { kind: 'image', path, number: place + 1 });
      if (!text.includes(token)) text += token;
    });
    setText(text);
    history = index < sent.length ? index : null;
    return true;
  }

  // Tab right after a folded paste puts its text back in its place.
  function unfold() {
    const caret = input.selectionStart;
    if (caret !== input.selectionEnd) return false;
    const before = input.value.slice(0, caret);
    for (const [token, chip] of chips) {
      // The space a fold puts after its token goes back with it.
      const folded = before.endsWith(`${token} `) ? `${token} ` : token;
      if (chip.kind === 'paste' && before.endsWith(folded)) {
        replace(caret - folded.length, caret, chip.text);
        return true;
      }
    }
    return false;
  }

  function fold(text) {
    const number = nextNumber('paste');
    chips.set(pasteToken(number), { kind: 'paste', text, number });
    replace(input.selectionStart, input.selectionEnd, `${pasteToken(number)} `);
  }

  function keydown(event) {
    // Keys pressed while an input method composes belong to it: Return confirms the character, it does not send.
    if (event.isComposing || event.keyCode === 229 || event.metaKey || event.ctrlKey) return;
    const listed = Boolean(palette.kind);
    const handled = (() => {
      switch (event.key) {
        case 'Enter':
          if (event.shiftKey && input.value === '' && meta.busy) return post({ type: 'sendNow' }), true;
          if (event.shiftKey || event.altKey) return false;
          return listed ? enterInPalette() : submit(), true;
        case 'Tab':
          if (event.shiftKey || event.altKey) return false;
          return listed ? (choose(palette.options[palette.selected]), true) : unfold();
        case 'Escape':
          if (!listed) return false;
          palette.dismissed = palette.key;
          closePalette();
          return true;
        case 'ArrowUp':
        case 'ArrowDown':
          if (event.shiftKey || event.altKey) return false;
          if (listed) return move(event.key === 'ArrowUp' ? -1 : 1), true;
          return recall(event.key === 'ArrowUp' ? -1 : 1);
        default:
          return false;
      }
    })();
    if (handled) event.preventDefault();
  }

  function paste(event) {
    const data = event.clipboardData;
    if (!data) return;
    const images = [...data.files].filter(file => file.type.startsWith('image/'));
    if (images.length > 0) {
      event.preventDefault();
      images.forEach(attachImage);
      return;
    }
    const text = data.getData('text/plain');
    if (text.length >= PASTE_FOLD_CHARACTERS && text.trim()) {
      event.preventDefault();
      fold(text);
    }
  }

  // The page cannot name a file on disk: the core writes the image and hands back its path in an `attach` message.
  function attachImage(file) {
    if (file.size > IMAGE_MAX_BYTES) return;
    const reader = new FileReader();
    reader.addEventListener('load', () => {
      const url = String(reader.result);
      imageSerial += 1;
      previews.set(imageSerial, url);
      post({ type: 'image', id: imageSerial, name: file.name || 'image.png', data: url.slice(url.indexOf(',') + 1) });
    });
    reader.readAsDataURL(file);
  }

  function attach(items) {
    for (const item of items || []) {
      if (!item || typeof item.path !== 'string') continue;
      if (item.kind === 'image') {
        const number = nextNumber('image');
        chips.set(imageToken(number), { kind: 'image', path: item.path, number, preview: previews.get(item.id) || item.src });
        previews.delete(item.id);
        insert(`${imageToken(number)} `);
      } else {
        const folder = item.kind === 'folder';
        const token = mentionToken(item.relative || item.path, folder);
        chips.set(token, { kind: folder ? 'folder' : 'file', path: item.path });
        insert(`${token} `);
      }
    }
  }

  function filesArrived(message) {
    if (palette.kind !== 'file' || message.id !== fileSerial) return;
    const options = (message.files || []).map(file => ({ name: file.folder ? `${file.path}/` : file.path, detail: '', source: file.folder ? 'folder' : '', path: file.path, absolute: file.absolute, folder: Boolean(file.folder) }));
    openPalette('file', palette, options, palette.key);
  }

  function noteRow(row) {
    if (row.kind !== 'user') return;
    const item = (row.items || []).find(piece => piece.type === 'userMessage');
    if (item) prompts.set(row.id, { text: item.text || '', images: item.images || [] });
  }

  function track(message) {
    if (message.type === 'full') prompts.clear();
    for (const row of message.rows || []) noteRow(row);
    if (message.type === 'full') promptOrder = (message.rows || []).map(row => row.id);
    else if (message.order) promptOrder = message.order;
    else for (const row of message.rows || []) if (!promptOrder.includes(row.id)) promptOrder.push(row.id);
    promptOrder = promptOrder.filter(id => prompts.has(id));
  }

  function describe(next) {
    meta = next || {};
    $('stop').hidden = !meta.busy;
    $('send').title = meta.busy ? 'Send guidance' : 'Send message (Return)';
    dimSend();
    if (palette.kind === 'command') updatePalette();
  }

  // Another window of the same session wrote a newer draft; one with no generation only fills an empty composer.
  function takeDraft(draft, theirs, full) {
    if (!Array.isArray(draft)) return;
    if (typeof theirs === 'number' ? theirs <= generation : !full || input.value !== '' || draft.length === 0) return;
    if (typeof theirs === 'number') generation = theirs;
    input.value = restore(draft);
    history = null;
    refresh();
  }

  function endFlight() {
    clearTimeout(flight?.timer);
    flight = null;
    form.classList.remove('flying');
  }

  // The sent message leaves the composer as its bubble (One Text's `fly`, Swift's `FlyingMessage`): a copy of the bubble
  // goes from the composer's text, 16 pt around it, to the bubble's place, which it tracks every frame while the
  // transcript scrolls and the composer shrinks; the composer's grey blends into the bubble's tint on the way. The bubble
  // stays hidden until the copy lands on it. A message taller than the transcript lands on its last lines. One already
  // shown before the send never flies.
  function prepareFlight(text, images) {
    endFlight();
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const box = field.getBoundingClientRect();
    const origin = { left: box.left - FLIGHT_INSET_PX, top: box.top - FLIGHT_INSET_PX, width: box.width + 2 * FLIGHT_INSET_PX, height: box.height + 2 * FLIGHT_INSET_PX };
    flight = { text, images, previous: new Set(prompts.keys()), origin, sent: performance.now(), timer: setTimeout(endFlight, FLIGHT_WAIT_MS) };
    form.classList.add('flying');
  }

  // Where the bubble shows in the transcript now, and whether only its last lines fit. Exactly where it stands: Swift
  // lifted it 28 pt for a scroll that came after, and here the copy landed above the bubble and then dropped onto it.
  function landing(bubble) {
    const measured = bubble.getBoundingClientRect();
    const view = ($('transcript') || document.body).getBoundingClientRect();
    const top = Math.max(measured.top, view.top);
    const bottom = Math.max(top, Math.min(measured.bottom, view.bottom));
    return { left: measured.left, top, width: measured.width, height: bottom - top, tall: bottom - top < measured.height };
  }

  function land() {
    if (!flight) return;
    if (performance.now() - flight.sent > FLIGHT_WAIT_MS) return endFlight();
    const same = prompt => prompt.text === flight.text && prompt.images.join('\n') === flight.images.join('\n');
    const id = [...prompts.keys()].find(key => !flight.previous.has(key) && same(prompts.get(key)));
    const bubble = id && document.querySelector(`[data-row="${CSS.escape(id)}"] .bubble`);
    if (!bubble) return;
    const { origin } = flight;
    endFlight();
    const first = landing(bubble);
    if (first.width === 0 || first.height === 0) return;
    const ghost = flyingBox(bubble, first, id);
    const shade = ghost.querySelector('.flight-shade');
    // The row can be drawn again mid-flight (the provider's echo): its bubble is looked up on every frame.
    const selector = `[data-row="${CSS.escape(id)}"] .bubble`;
    let target = bubble;
    target.style.visibility = 'hidden';
    const started = performance.now();
    let landed = false;
    const finish = () => {
      if (landed) return;
      landed = true;
      target.style.visibility = '';
      ghost.remove();
    };
    // A hidden or covered window gets no frames: the bubble shows once the flight's time is up whatever was drawn.
    setTimeout(finish, FLIGHT_MS + FLIGHT_FRAME_GRACE_MS);
    const step = now => {
      if (landed) return;
      const progress = Math.min(1, (now - started) / FLIGHT_MS);
      const eased = 1 - (1 - progress) ** FLIGHT_EASE_POWER;
      const mix = (from, to) => from + (to - from) * eased;
      const current = document.querySelector(selector);
      if (current && current !== target) {
        target.style.visibility = '';
        target = current;
        target.style.visibility = 'hidden';
      }
      const to = target.isConnected ? landing(target) : first;
      Object.assign(ghost.style, { left: `${mix(origin.left, to.left)}px`, top: `${mix(origin.top, to.top)}px`, width: `${mix(origin.width, to.width)}px`,
        height: `${mix(origin.height, to.height)}px`, borderRadius: `${mix(COMPOSER_RADIUS_PX, BUBBLE_RADIUS_PX)}px` });
      shade.style.opacity = String(1 - eased);
      if (progress < 1) return void requestAnimationFrame(step);
      finish();
    };
    step(started);
  }

  // A copy of the bubble's content at its own width, so it never rewraps, over the composer's grey.
  function flyingBox(bubble, first, id) {
    const ghost = make('div', `${bubble.className} flight-box`);
    ghost.dataset.flight = id;
    ghost.setAttribute('aria-hidden', 'true');
    Object.assign(ghost.style, { position: 'fixed', margin: '0', padding: '0', boxSizing: 'border-box', overflow: 'hidden', zIndex: '40', pointerEvents: 'none', transform: 'none' });
    const content = make('div');
    Object.assign(content.style, { position: 'absolute', left: `${FLIGHT_INSET_PX}px`, width: `${first.width - 2 * FLIGHT_INSET_PX}px`, [first.tall ? 'bottom' : 'top']: `${FLIGHT_INSET_PX}px` });
    for (const child of bubble.children) if (!child.matches('button')) content.append(child.cloneNode(true));
    const shade = make('div', 'flight-shade');
    Object.assign(shade.style, { position: 'absolute', inset: '0', background: 'linear-gradient(rgb(0 0 0 / .065), rgb(0 0 0 / .065)), var(--page, #fff)' });
    ghost.append(shade, content);
    document.body.append(ghost);
    return ghost;
  }

  function receive(message) {
    window.vcxRun?.receive(message);
    if (message.type === 'full' || message.type === 'patch') {
      track(message);
      // After app.js has drawn the rows of this message, before the page paints them.
      if (flight) queueMicrotask(land);
      if (message.meta) describe(message.meta);
      takeDraft(message.draft, message.draftGeneration, message.type === 'full');
    } else if (message.type === 'files') filesArrived(message);
    else if (message.type === 'attach') attach(message.items);
    else if (message.type === 'commandQuery') {
      setText(message.text);
      input.focus();
    }
  }

  function editable(target) {
    return target instanceof HTMLElement && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));
  }

  // A key typed, or Return, while nothing editable has the focus goes to the composer, as in the Swift window.
  document.addEventListener('keydown', event => {
    if (event.defaultPrevented || editable(event.target) || event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === 'Enter') {
      event.preventDefault();
      input.focus();
    } else if (event.key.length === 1 && event.key !== ' ') input.focus();
  });
  // Space and a character typed with Option too (Swift `sendEvent`): Space only focuses, as Return does; the character
  // lands in the composer once it has the focus.
  document.addEventListener('keydown', event => {
    if (event.defaultPrevented || editable(event.target) || event.ctrlKey || event.metaKey) return;
    if (event.key === ' ' && !event.altKey && !event.shiftKey) {
      event.preventDefault();
      input.focus();
    } else if (event.altKey && event.key.length === 1) input.focus();
  });
  // ⌘V goes to the menu, whose Paste reaches the page on whatever has the focus: outside anything editable, it lands in
  // the composer, folded or attached as a paste there is.
  document.addEventListener('paste', event => {
    if (event.defaultPrevented || editable(event.target)) return;
    input.focus();
    paste(event);
    if (event.defaultPrevented) return;
    event.preventDefault();
    const text = event.clipboardData && event.clipboardData.getData('text/plain');
    if (text) document.execCommand('insertText', false, text);
  });
  // Image data dragged in with no file (a picture from a browser) reaches the page, not the core, which takes file paths
  // only: it becomes a picture chip, as a pasted image does (Swift's composer takes .png and .tiff drags).
  const draggedImages = event => [...((event.dataTransfer && event.dataTransfer.files) || [])].filter(file => file.type.startsWith('image/'));
  addEventListener('dragover', event => {
    if (event.dataTransfer && [...event.dataTransfer.types].includes('Files')) event.preventDefault();
  });
  addEventListener('drop', event => {
    const images = draggedImages(event);
    if (!images.length) return;
    event.preventDefault();
    images.forEach(attachImage);
    input.focus();
  });
  // A click on a blank spot focuses the composer; a click that selected text keeps its selection.
  document.addEventListener('click', event => {
    const blank = [document.body, document.documentElement, $('transcript'), $('rows'), form, form.parentElement].includes(event.target);
    if (blank && document.getSelection().isCollapsed) input.focus();
  });
  form.addEventListener('submit', event => {
    event.preventDefault();
    submit();
  });
  for (const button of form.querySelectorAll('button')) button.addEventListener('mousedown', event => event.preventDefault());
  $('stop').addEventListener('click', () => post({ type: 'stop' }));
  // Escape with nothing open stops the turn (Swift `onExitCommand`). Whatever is open, its own Escape handler closes it
  // and so changes the page: the observer, started before any handler runs, tells the two apart without a list of them.
  const escapeWatch = new MutationObserver(() => {});
  addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    escapeWatch.disconnect();
    escapeWatch.observe(document.documentElement, { attributes: true, childList: true, subtree: true });
  }, true);
  addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    const changed = escapeWatch.takeRecords().length > 0;
    escapeWatch.disconnect();
    if (!changed && !event.defaultPrevented && !event.isComposing && meta.busy) post({ type: 'stop' });
  });
  input.addEventListener('keydown', keydown);
  input.addEventListener('paste', paste);
  input.addEventListener('input', () => {
    if (!applying) history = null;
    if (!applying) edited();
  });
  input.addEventListener('scroll', () => { marks.scrollTop = input.scrollTop; }, { passive: true });
  input.addEventListener('select', updatePalette);
  input.addEventListener('click', updatePalette);
  input.addEventListener('keyup', event => (event.key.startsWith('Arrow') || event.key === 'Home' || event.key === 'End') && !palette.kind && updatePalette());
  window.addEventListener('pagehide', () => saveTimer && save());

  window.composer = { receive };
  input.focus();
})();
