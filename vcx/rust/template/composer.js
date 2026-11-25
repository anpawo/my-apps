'use strict';
// The composer: what is typed and attached before a message is sent. Attachments sit in the text as tokens
// ("[Image #1]", "[Paste #1]", "@src/main.rs") that the native undo stack keeps, and show as chips above it.
(() => {
  const INPUT_MAX_HEIGHT_PX = 220;
  // A pasted text this long folds into a chip, as in the Swift composer (`Composer.swift`, `paste(from:)`).
  const PASTE_FOLD_CHARACTERS = 20;
  const DRAFT_SAVE_DELAY_MS = 250;
  // The send flight, as in the Swift `SendAnimation`: how long the bubble glides, and how long a send waits for its row.
  const FLIGHT_MS = 420;
  const FLIGHT_WAIT_MS = 5000;
  const IMAGE_MAX_BYTES = 32 * 1024 * 1024;
  const PROVIDERS = ['claude', 'codex', 'qwen', 'agy'];
  // Their values run as soon as they are chosen; the others go into the composer to be read before Return.
  const RUN_AT_ONCE = ['/model ', '/provider ', '/perms ', '/resume '];
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

  const strip = make('div', 'attachments');
  strip.id = 'attachments';
  strip.hidden = true;
  form.prepend(strip);
  const panel = make('div');
  panel.id = 'palette';
  panel.setAttribute('role', 'listbox');
  const head = make('div', 'palette-head');
  const title = make('span', 'palette-title');
  const count = make('span', 'palette-count');
  head.append(title, count, make('span', 'palette-esc', 'esc'));
  const list = make('div', 'palette-list');
  const foot = make('div', 'palette-foot');
  for (const [key, what] of [['↑', ''], ['↓', 'navigate'], ['↩', 'select'], ['⇥', 'complete']]) foot.append(make('kbd', '', key), what ? make('span', '', what) : '');
  panel.append(head, list, foot);
  form.before(panel);

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

  function grow() {
    input.style.height = 'auto';
    input.style.height = `${Math.min(input.scrollHeight, INPUT_MAX_HEIGHT_PX)}px`;
  }

  function refresh() {
    grow();
    drawStrip();
    updatePalette();
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
    const remove = make('button', 'attachment-remove', '×');
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
    const before = new Set((strip.dataset.key || '').split('\n'));
    strip.dataset.key = key;
    let images = 0;
    strip.replaceChildren(...shown.map(place => {
      if (place.chip.kind === 'image') images += 1;
      const node = chipNode(place, images);
      if (!before.has(place.token)) node.classList.add('enter');
      return node;
    }));
    strip.hidden = shown.length === 0;
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

  function modelOptions(argument, option) {
    const args = argument.split(' ');
    const efforts = model => (meta.modelEfforts || {})[model] || [];
    if (args.length === 1) {
      return PROVIDERS.filter(name => !argument || name.includes(argument)).map(name => option(`${name} `, `Choose ${name === 'agy' ? 'an Antigravity' : `a ${name[0].toUpperCase()}${name.slice(1)}`} model`, name === 'agy' ? 'Antigravity' : `${name[0].toUpperCase()}${name.slice(1)}`, name === provider()));
    }
    const [chosen, model, effort = ''] = args;
    if (chosen !== provider() && chosen !== 'auto') return [];
    if (args.length === 2) {
      return (meta.models || []).filter(id => !model || id.toLowerCase().includes(model)).map(id => option(`${chosen} ${id}${efforts(id).length ? ' ' : ''}`, 'Choose model', id, id === meta.model));
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
    list.replaceChildren(...palette.options.map((option, index) => {
      const row = make('div', index === palette.selected ? 'palette-option selected' : 'palette-option');
      row.setAttribute('role', 'option');
      row.setAttribute('aria-selected', String(index === palette.selected));
      const text = make('div', 'palette-option-text');
      text.append(make('div', 'palette-option-name', option.name));
      if (option.detail) text.append(make('div', 'palette-option-detail', option.detail));
      row.append(text);
      if (option.source) row.append(make('span', 'palette-option-source', option.source));
      row.addEventListener('mousedown', event => event.preventDefault());
      row.addEventListener('click', () => choose(option));
      return row;
    }));
    if (palette.options.length === 0) list.append(make('div', 'palette-option-none', files ? 'Looking for files…' : 'No matching commands'));
    panel.classList.add('open');
    form.setAttribute('aria-expanded', 'true');
    list.children[palette.selected]?.scrollIntoView({ block: 'nearest' });
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
    post({ type: 'send', text, images, draft: pieces(), generation });
    prepareFlight(text, images);
    clearTimeout(saveTimer);
    saveTimer = 0;
    chips.clear();
    history = null;
    input.value = '';
    generation += 1;
    closePalette();
    refresh();
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
      if (chip.kind === 'paste' && before.endsWith(token)) {
        replace(caret - token.length, caret, chip.text);
        return true;
      }
    }
    return false;
  }

  function fold(text) {
    const number = nextNumber('paste');
    chips.set(pasteToken(number), { kind: 'paste', text, number });
    replace(input.selectionStart, input.selectionEnd, pasteToken(number));
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
        chips.set(imageToken(number), { kind: 'image', path: item.path, number, preview: previews.get(item.id) });
        previews.delete(item.id);
        insert(imageToken(number));
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

  // The sent message's bubble glides in from where the composer stood; one already shown before the send never does.
  function prepareFlight(text, images) {
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    flight = reduced ? null : { text, images, previous: new Set(prompts.keys()), origin: form.getBoundingClientRect(), sent: performance.now() };
  }

  function land() {
    if (!flight) return;
    if (performance.now() - flight.sent > FLIGHT_WAIT_MS) return void (flight = null);
    const same = prompt => prompt.text === flight.text && prompt.images.join('\n') === flight.images.join('\n');
    const id = [...prompts.keys()].find(key => !flight.previous.has(key) && same(prompts.get(key)));
    const bubble = id && document.querySelector(`[data-row="${CSS.escape(id)}"] .bubble`);
    if (!bubble) return;
    const { origin } = flight;
    flight = null;
    const target = bubble.getBoundingClientRect();
    if (target.width === 0) return;
    const from = `translate(${origin.left - target.left}px, ${origin.top - target.top}px)`;
    bubble.animate([{ transform: from, opacity: 0.4 }, { transform: 'none', opacity: 1 }], { duration: FLIGHT_MS, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)' });
  }

  function receive(message) {
    if (message.type === 'full' || message.type === 'patch') {
      track(message);
      // After app.js has drawn the rows of this message.
      if (flight) setTimeout(land, 0);
      if (message.meta) describe(message.meta);
      takeDraft(message.draft, message.draftGeneration, message.type === 'full');
    } else if (message.type === 'files') filesArrived(message);
    else if (message.type === 'attach') attach(message.items);
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
  input.addEventListener('keydown', keydown);
  input.addEventListener('paste', paste);
  input.addEventListener('input', () => {
    if (!applying) history = null;
    if (!applying) edited();
  });
  input.addEventListener('select', updatePalette);
  input.addEventListener('click', updatePalette);
  input.addEventListener('keyup', event => (event.key.startsWith('Arrow') || event.key === 'Home' || event.key === 'End') && !palette.kind && updatePalette());
  window.addEventListener('pagehide', () => saveTimer && save());

  window.composer = { receive };
  input.focus();
})();
