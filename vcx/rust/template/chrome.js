'use strict';
// The window around the transcript and the composer, as the Swift `VCXView` draws it: the status line, the status bar
// and its popovers, the permission prompt, the task bar, notices and the title. It reads the messages app.js reads.
// Each element is one of his web templates (~/self/templates/web), named where its effect is copied.
(() => {
  // Swift `ProgressChip` and `UpdateChip` cut their words past this many characters.
  const LONGEST_CHIP_WORDS = 40;
  const ELAPSED_TICK_MS = 1000;
  const SECONDS_PER_MINUTE = 60;
  const SECONDS_PER_HOUR = 3600;
  // A token of eight digits in a model id is its release date, not its version (Swift `releaseDateDigits`).
  const RELEASE_DATE_DIGITS = 8;
  const MILLION = 1_000_000;
  const THOUSAND = 1000;
  const POPOVER_GAP_PX = 6;
  const DIALOG_POP_MS = 100;
  const TITLE_MIN_PX = 12;
  const PROVIDERS = ['auto', 'claude', 'codex', 'qwen', 'agy'];
  // Qwen and agy report no plan usage, so the bar shows no Usage chip for them.
  const UNMETERED = ['qwen', 'agy'];
  const MODES = [['bypass', 'YOLO: no tool approval prompts'], ['ask', 'Ask before actions that need permission']];
  const TASK_STATES = { working: 'working', question: 'waiting for you', done: 'done' };
  const TASK_MARKS = { working: '…', question: '?', done: '✓' };
  // The status pill's own fills (WT-037): violet, orange, grey and green.
  const TONE_FILLS = { busy: '#b4a5e7', pending: '#e28e4f', off: '#afb2b7', ready: '#88cb9e' };
  const COLORS = {
    directory: 'rgb(71 92 179)', model: 'rgb(173 46 115)', mode: 'rgb(191 38 38)', tokens: 'rgb(33 99 171)',
    pullRequest: 'rgb(107 64 179)', ready: 'rgb(26 115 46)', uncommitted: 'rgb(173 46 97)', unpushed: 'rgb(140 92 20)', plain: 'rgb(0 0 0 / 0.6)',
  };
  const DEBATE_COLORS = { claude: 'rgb(199 97 56)', codex: 'rgb(10 122 102)', qwen: 'rgb(51 97 209)', agy: 'rgb(133 77 199)', gemini: 'rgb(209 64 128)' };
  const TASK_COLORS = { working: 'rgb(237 128 26)', question: 'rgb(51 115 230)', done: 'rgb(51 166 77)' };
  // Swift `sessionPanel`: what the session loaded, in this order, and what each card is called.
  const CAPABILITIES = [['Hooks', 'HOOKS'], ['Skills', 'SKILLS'], ['Commands', 'COMMANDS'], ['MCP', 'MCP'], ['Instructions', 'MD FILES'], ['RAG', 'RAG']];
  // These lists show names only; the full text shows beside the row under the pointer.
  const DETAIL_BESIDE = ['RAG', 'Skills'];
  // A short dwell, so a pointer crossing the panel opens nothing; a grace, so it can cross from a card to its list.
  const HOVER_OPEN_MS = 60;
  const HOVER_CLOSE_MS = 100;
  const CARD_COLOR = 'rgb(222 225 229)';
  const ICONS = {
    settings: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9 7 7M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1"/>',
    copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
    check: '<path d="M20 6 9 17l-5-5"/>',
    search: '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
    close: '<path d="M18 6 6 18M6 6l12 12"/>',
  };
  // An ERRORS line starts with its date, then a colon or a dash (Swift `capabilityItems`).
  const RULE_DATE = /^[0-9/, -]+?(: | \u2014 )/;
  const SETTINGS_TABS = ['Session', 'Accounts', 'Qwen', 'Background', 'Keys'];
  const QWEN_HOSTS = { mac: 'This Mac', pc: 'Windows PC' };
  // Swift `SettingsPopup`'s own figures: the resends after a dropped connection, the conversation a new turn is handed.
  const NETWORK_RESUMES = 3;
  const RECENT_KB = 48;
  const MS_PER_SECOND = 1000;
  // Swift `SettingsPopup.shortcuts`.
  const SHORTCUTS = [
    [['\u21a9'], 'Send the prompt'], [['\u21e7', '\u21a9'], 'New line; on an empty composer, send the waiting prompt now'], [['\u2325', '\u21a9'], 'New line'],
    [['\u2191'], 'Withdraw the unread prompt, or recall the previous one'], [['\u2193'], 'Next prompt in history'], [['\u21e5'], 'Expand the last paste, or complete a command'],
    [['esc'], 'Close find, a preview or a panel, else stop the turn'], [['1\u20139'], 'Pick an option of the open question'],
    [['\u2318', 'F'], 'Find in the transcript'], [['\u2318', ','], 'Settings'], [['\u2318', '\u21e7', 'N'], 'New window'], [['\u2318', 'O'], 'Open project'],
    [['\u2318', 'W'], 'Close window'], [['\u2318', 'Q'], 'Close session'], [['\u2325', 'click'], 'Define the word; drag to widen it'], [['\u2325'], 'Held, select the word under the pointer'],
  ];

  const $ = id => document.getElementById(id);
  const post = message => window.ipc.postMessage(JSON.stringify(message));
  const state = { meta: {}, rows: new Map(), order: [], notes: { link: '', problem: '' }, progress: null, update: null, tasks: null, quota: null, settings: null, login: null };
  const sheet = { open: false, signature: '' };
  const shown = { chips: new Map(), tasks: '', title: '', status: '', request: '', empty: false };
  let popover = null;
  const capability = { open: null, hovered: null, opening: 0, inPanel: false, choose: null, signature: '' };
  let busySince = null;
  let ticking = null;
  let answering = null;
  let clock = () => Date.now();

  function make(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function button(className, text, action) {
    const node = make('button', className, text);
    node.type = 'button';
    node.addEventListener('click', event => {
      event.stopPropagation();
      action(event);
    });
    return node;
  }

  // ---- Effect: status pill (WT-037) ----
  // Gives a pill a new word and fill: the word fades out, swaps and fades in while the pill eases to its new width.
  async function setPill(pill, word, fill, dur = 300) {
    const from = pill.offsetWidth;
    pill.classList.add('swap');
    await new Promise(r => setTimeout(r, dur / 2));
    pill.querySelector('span').textContent = word;
    pill.style.setProperty('--fill', fill);
    const to = pill.offsetWidth;
    if (!matchMedia('(prefers-reduced-motion: reduce)').matches) pill.animate([{ width: from + 'px' }, { width: to + 'px' }], { duration: dur, easing: 'ease-out' });
    pill.classList.remove('swap');
  }
  // ---- End of effect ----

  // ---- Effect: progress bar (WT-104) ----
  function progress(el, value) {
    el.style.setProperty('--value', value);
    el.ariaValueNow = value;
  }
  // ---- End of effect ----

  // ---- Effect: dialog with a sticky title bar and a footer bar (WT-072) ----
  // Holds `title` (the bar's <p>) on one line: back to its CSS size, then as much smaller as its line asks, `min` px
  // at least, at every change of its size.
  function oneLine(title, { min = 18 } = {}) {
    const fit = () => {
      title.style.fontSize = '';
      const size = parseFloat(getComputedStyle(title).fontSize);
      if (title.scrollWidth > title.clientWidth) title.style.fontSize = `${Math.max(min, Math.floor(size * title.clientWidth / title.scrollWidth * 10) / 10)}px`;
    };
    new ResizeObserver(fit).observe(title);
    return fit;
  }
  // ---- End of effect ----

  // ---- Effect: table from data rows (WT-085) ----
  // rows: [{column: value, tone?}]; set(rows) redraws the table.
  function table(el) {
    const make = (tag, props) => Object.assign(document.createElement(tag), props);
    return rows => {
      const cols = Object.keys(rows[0] || {}).filter(k => k !== 'tone');
      const num = cols.map(c => rows.some(r => typeof r[c] === 'number') && rows.every(r => r[c] == null || typeof r[c] === 'number'));
      const places = cols.map((c, i) => num[i] ? Math.max(0, ...rows.map(r => Math.min(2, (String(r[c] ?? '').split('.')[1] || '').length))) : 0);
      const text = (v, i) => num[i] && typeof v === 'number' ? v.toLocaleString('en-US', { minimumFractionDigits: places[i], maximumFractionDigits: places[i] }) : v ?? '';
      const tr = (tag, values, tone) => {
        const row = make('tr', { className: tone ? 't-' + tone : '' });
        row.append(...values.map((v, i) => make(tag, { className: num[i] ? 'num' : '', textContent: tag === 'th' ? v : text(v, i) })));
        return row;
      };
      el.tHead.replaceChildren(tr('th', cols));
      el.tBodies[0].replaceChildren(...rows.map(r => tr('td', cols.map(c => r[c]), r.tone)));
    };
  }
  // ---- End of effect ----

  // ---- Effect: side bar of count cards with a sliding glass selector (WT-050) ----
  // bar: the panel; onChoose(card) is told each card clicked. A card's number is its data-count. On the first draw each
  // number counts up from 0 (a second, half the way in its first fifth), rising out of its box from 95 % of its size.
  // A click lays the glass on the card, sliding from the card that had it, and opens the bar's outline along it. A
  // card, title or warning added to or taken from the bar fades in or out, the others move to their new place, and
  // the bar's height follows, clipped to it. Returns choose(card), to choose one from code.
  function cardBar(bar, { slide = 300, count = 1000, onChoose } = {}) {
    const how = { duration: slide, easing: 'cubic-bezier(.16, 1, .3, 1)' };
    const still = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
    const number = card => {
      const n = card.dataset.count;
      if (n === undefined || card.querySelector('.num')) return;
      const box = document.createElement('span'), digits = document.createElement('span');
      box.className = 'num'; box.style.minWidth = `${n.length}ch`; box.append(digits); digits.textContent = n;
      card.querySelector('.name').before(box);
      // room after the name for a second digit: the bar keeps its width from 9 to 10
      card.querySelector('.name').style.paddingRight = `${Math.max(0, 2 - n.length)}ch`;
      return [digits, Number(n)];
    };
    const counting = [...bar.querySelectorAll('.card')].map(number).filter(Boolean);
    if (!still()) {
      const start = performance.now();
      requestAnimationFrame(function step(now) {
        const t = Math.min(1, Math.max(0, (now - start) / count)), k = 1 - (1 - t) ** 4;
        for (const [el, to] of counting) { el.textContent = Math.round(to * k); el.style.scale = .95 + .05 * k; el.style.translate = `0 ${.3 * (1 - k)}em`; }
        if (t < 1) requestAnimationFrame(step);
      });
    }

    // where the outline opens: from the top of the glass's upper curve to the foot of its lower one
    const opening = (card, glass) => {
      const top = bar.clientTop + card.offsetTop + card.clientTop + glass.offsetTop - 12;
      return [top, top + glass.offsetHeight + 24];
    };
    const open = () => {
      const card = bar.querySelector('.card[aria-current]');
      const [a, b] = card ? opening(card, card.querySelector('.card-glass')) : [0, 0];
      bar.style.setProperty('--cut-a', `${a}px`); bar.style.setProperty('--cut-b', `${b}px`);
    };
    new ResizeObserver(open).observe(bar);
    const choose = card => {
      const was = bar.querySelector('.card[aria-current]');
      if (was === card) return;
      if (was) {
        // the card it leaves turns lighter at once, the glass alone moves
        was.style.transition = 'none'; was.removeAttribute('aria-current');
        void getComputedStyle(was, '::after').backgroundColor; was.style.transition = '';
      }
      card.setAttribute('aria-current', 'true');
      open();
      const from = was?.isConnected ? was : bar.querySelector('.card');
      const d = from.getBoundingClientRect().top - card.getBoundingClientRect().top;
      if (!d || still()) return;
      const glass = card.querySelector('.card-glass'), [a, b] = opening(card, glass);
      card.style.zIndex = 1;
      glass.animate([{ transform: `translateY(${d}px)` }, { transform: 'none' }], how).finished.finally(() => { card.style.zIndex = ''; });
      bar.animate([{ '--cut-a': `${a + d}px`, '--cut-b': `${b + d}px` }, { '--cut-a': `${a}px`, '--cut-b': `${b}px` }], how);
    };
    bar.addEventListener('click', e => {
      const card = e.target.closest('.card');
      if (card && !card.disabled) { choose(card); onChoose?.(card); }
    });

    // what comes and goes: items known by their tag and their name
    const read = () => new Map([...bar.querySelectorAll('h2, .card, [role=alert]')].filter(e => !e.dataset.ghost)
      .map(e => [`${e.tagName}:${e.dataset.card ?? e.textContent}`, { el: e, top: e.offsetTop, left: e.offsetLeft, width: e.offsetWidth }]));
    let at = read(), tall = bar.offsetHeight, grow;
    new MutationObserver(changes => {
      if (!changes.some(c => [...c.addedNodes, ...c.removedNodes].some(n => n instanceof HTMLElement && !n.dataset.ghost))) return;
      for (const card of bar.querySelectorAll('.card')) number(card);
      const now = read(), calm = still();
      for (const [k, was] of at) {
        const e = was.el;
        if (now.has(k) || (e.isConnected && bar.contains(e))) continue;
        e.dataset.ghost = '1'; e.inert = true;
        Object.assign(e.style, { position: 'absolute', top: `${was.top}px`, left: `${was.left}px`, width: `${was.width}px`, margin: '0', pointerEvents: 'none' });
        bar.append(e);
        e.animate([{ opacity: 1 }, { opacity: 0 }], { ...how, duration: slide * 2 / 3, fill: 'forwards' }).finished.finally(() => e.remove());
      }
      for (const [k, is] of now) {
        const was = at.get(k);
        if (!was) is.el.animate([{ opacity: 0, transform: 'scale(.97)' }, { opacity: 1, transform: 'none' }], how);
        else if (!calm && was.top !== is.top) is.el.animate([{ transform: `translateY(${was.top - is.top}px)` }, { transform: 'none' }], { ...how, composite: 'add' });
      }
      const from = grow?.playState === 'running' ? bar.offsetHeight : tall;
      grow?.cancel();
      at = now; tall = bar.offsetHeight;
      if (calm || from === tall) return;
      Object.assign(bar.style, { overflow: 'clip', overflowClipMargin: '1px' });
      grow = bar.animate([{ height: `${from}px` }, { height: `${tall}px` }], how);
      grow.finished.then(() => Object.assign(bar.style, { overflow: '', overflowClipMargin: '' }), () => {});
    }).observe(bar, { childList: true, subtree: true });
    return choose;
  }
  // ---- End of effect ----

  // ---- Effect: empty state (WT-102) ----
  // Shows (show = true) or hides the empty block with a short fade and scale; the list it stands for swaps the other way.
  async function emptyState(el, show, { dur = 250 } = {}) {
    const d = matchMedia('(prefers-reduced-motion: reduce)').matches ? 1 : dur;
    el.classList.remove('hidden');
    await el.animate({ opacity: [0, 1], scale: [0.98, 1] }, { duration: d, easing: 'ease-out', direction: show ? 'normal' : 'reverse', fill: 'both' }).finished;
    el.classList.toggle('hidden', !show);
    el.getAnimations().forEach(a => a.cancel());
  }
  // ---- End of effect ----

  // ---- Effect: search field and filter button with value lists (WT-030) ----
  // The search lets through the rows whose text holds what is typed. A click on the button opens the lists under it,
  // centred on it: a block per list, its name on a grey band over its values, each with a checkbox and the count of
  // rows holding it, the most first. In a list any value ticked lets a row through, none ticked all of them; the lists
  // narrow each other and the search. While values are ticked the button turns blue and says how many, the number
  // sliding in from no width; the lists stay open while values are ticked, and Escape, the button or a pointerdown
  // outside closes them. `at`: the button's
  // wrapper, or null for the search alone; `lists`: [[name, row => its value]]; `text(row)`: what the search reads;
  // `show(row, on)` shows or hides a row; `reset`, if given, clears the search and the ticks and is disabled while
  // there are none.
  function tableFilter({ find, at, rows, lists = [], text, show, reset }) {
    const input = find.querySelector('input'), btn = at?.querySelector('.lists-btn'), box = at?.querySelector('.lists');
    const ticked = Object.fromEntries(lists.map(([l]) => [l, new Set()]));
    const query = () => input.value.trim().toLowerCase();
    const fits = r => (!query() || text(r).toLowerCase().includes(query())) && lists.every(([l, of]) => !ticked[l].size || ticked[l].has(of(r)));
    const open = on => { box.hidden = !on; btn.ariaExpanded = on; };
    const draw = () => box.replaceChildren(...lists.map(([l, of]) => {
      const count = new Map();
      for (const r of rows) count.set(of(r), (count.get(of(r)) ?? 0) + 1);
      const block = document.createElement('div'), name = document.createElement('p'), values = document.createElement('div');
      block.className = 'list'; block.role = 'group'; block.ariaLabel = l; name.textContent = l;
      values.append(...[...count].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([v, n]) => {
        const label = document.createElement('label'), tick = document.createElement('input'), word = document.createElement('span'), k = document.createElement('small');
        tick.type = 'checkbox'; tick.checked = ticked[l].has(v);
        tick.onchange = () => { ticked[l].has(v) ? ticked[l].delete(v) : ticked[l].add(v); refresh(false); };
        word.textContent = v; k.textContent = n;
        label.append(tick, word, k);
        return label;
      }));
      block.append(name, values);
      return block;
    }));
    // a tick leaves the lists open and drawn as they are, so a scrolled list keeps its place
  const refresh = (redraw = true) => {
      const n = Object.values(ticked).reduce((n, s) => n + s.size, 0);
      if (reset) reset.disabled = !n && !query();
      for (const r of rows) show(r, fits(r));
      if (!at) return;
      btn.classList.toggle('chosen', n > 0);
      if (n) btn.querySelector('.count span').textContent = n; // closing, it keeps the last number, not a 0
      if (redraw) draw();
    };
    input.addEventListener('input', refresh);
    if (reset) reset.onclick = () => { input.value = ''; Object.values(ticked).forEach(s => s.clear()); refresh(); };
    if (at) {
      btn.onclick = () => open(box.hidden);
      addEventListener('pointerdown', e => !box.hidden && !at.contains(e.target) && open(false));
      addEventListener('keydown', e => e.key === 'Escape' && !box.hidden && open(false));
    }
    refresh();
  }
  // ---- End of effect ----

  // ---- Effect: copy to checkmark (WT-020); the page has no clipboard of its own, so the core writes it ----
  // A click on button copies `text`; its copy icon turns into a check and its label into the copied one for `show` ms.
  // button holds the two labels (`b`, the second hidden) and the two icons (`.go`, the second, the check, hidden).
  function copyCheck(button, text, { show = 1500 } = {}) {
    // the svgs have no hidden property, so the attribute is toggled
    const [label, done, icon, tick] = button.querySelectorAll('b, .go');
    // the old pair fades out, then the new one fades in where it was
    const fade = (els, opacity) => Promise.all(els.map(el => el.animate({ opacity }, { duration: 120, easing: 'ease-out' }).finished));
    const copied = async on => {
      await fade(on ? [label, icon] : [done, tick], [1, 0]);
      for (const el of [label, icon]) el.toggleAttribute('hidden', on);
      for (const el of [done, tick]) el.toggleAttribute('hidden', !on);
      fade(on ? [done, tick] : [label, icon], [0, 1]);
    };
    button.addEventListener('click', () => Promise.resolve(post({ type: 'copy', text: typeof text === 'function' ? text() : text })).then(() => {
      copied(true);
      setTimeout(() => copied(false), show);
    }));
  }
  // ---- End of effect ----

  // The elements index.html does not carry: placed once, beside the ones app.js keeps drawing until it lets go of them.
  function place() {
    const status = $('status');
    const pill = make('span', 'pill');
    pill.id = 'status-pill';
    const word = $('status-text');
    word.replaceWith(pill);
    pill.append(word);
    const doing = make('span');
    doing.id = 'status-doing';
    const elapsedNode = make('span');
    elapsedNode.id = 'status-elapsed';
    status.append(doing, elapsedNode);
    const note = make('p');
    note.id = 'status-note';
    note.hidden = true;
    const permission = make('section', 'dialog light');
    permission.id = 'permission';
    permission.hidden = true;
    status.before(permission);
    status.before(loginPanel());
    status.after(note);
    $('notice').classList.add('pill');
    const tasks = make('aside');
    tasks.id = 'tasks';
    const header = make('header');
    header.append(make('span', 'name', 'TASKS'), make('span', 'count'));
    const bar = make('div', 'bar');
    const empty = make('div', 'empty hidden');
    empty.append(make('p', 'empty-title', 'No task yet.'));
    tasks.append(header, empty, bar);
    cardBar(bar, { onChoose: card => post({ type: 'focus', id: card.dataset.id }) });
    const layer = make('div', 'pop');
    layer.id = 'popover';
    layer.hidden = true;
    document.body.append(sessionPanel(), tasks, layer, capabilityPanel(), settingsSheet());
  }

  function icon(name, className = 'go') {
    return `<svg class="${className}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
  }

  // Swift `sessionPanel`: Settings, a count card for each thing the session loaded, the session's ID to copy.
  function sessionPanel() {
    const panel = make('aside');
    panel.id = 'session';
    const settings = button('b b-outline wide', '', openSettings);
    settings.id = 'settings-button';
    settings.title = 'Settings (⌘,)';
    settings.innerHTML = `${icon('settings')}<b>SETTINGS</b>`;
    const bar = make('div', 'bar');
    const group = make('section', 'bar-group');
    group.append(...CAPABILITIES.map(([title, label]) => {
      const card = make('button', 'card');
      card.type = 'button';
      card.dataset.card = title;
      card.dataset.count = '0';
      card.style.setProperty('--full', CARD_COLOR);
      card.title = title === 'RAG' ? "ERRORS lines sent with this session's prompts" : `Browse ${title.toLowerCase()}`;
      const glass = make('span', 'card-glass');
      glass.ariaHidden = 'true';
      card.append(glass, make('span', 'name', label));
      card.addEventListener('pointerenter', () => hoverCapability(title));
      card.addEventListener('pointerleave', () => leaveCapability(title));
      return card;
    }));
    bar.append(group);
    const copy = make('button', 'b b-outline wide');
    copy.type = 'button';
    copy.id = 'session-id';
    copy.innerHTML = `<span><b>SESSION ID</b><b hidden>COPIED</b></span>${icon('copy')}${icon('check').replace('<svg', '<svg hidden')}`;
    copyCheck(copy, () => state.meta.threadID || '');
    panel.append(settings, bar, copy);
    capability.choose = cardBar(bar, { onChoose: card => openCapability(card.dataset.card) });
    return panel;
  }

  function capabilityPanel() {
    const panel = make('section', 'light');
    panel.id = 'capability';
    panel.hidden = true;
    panel.addEventListener('pointerenter', () => { capability.inPanel = true; });
    panel.addEventListener('pointerleave', () => {
      capability.inPanel = false;
      closeCapabilityLater();
    });
    return panel;
  }

  // Swift `Session.modelName`; run again on a name already shown, it leaves it as it is.
  function modelName(id) {
    const words = id.replace(/^(claude[- ]|codex[- ])/i, '').replace(/-(\d+)-(\d+)$/, ' $1.$2').replaceAll('-', ' ');
    return words.split(' ').map(word => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()).join(' ');
  }

  function aliased(model) {
    return (state.meta.modelAliases || {})[model] || model;
  }

  function modelLabel(meta) {
    const label = meta.modelLabel || '';
    return !label || label === 'Not connected' ? 'Not connected' : modelName(label);
  }

  function provider(meta) {
    return meta.provider || (meta.providerLabel || '').toLowerCase();
  }

  function effectiveEffort(meta) {
    return meta.effort || meta.defaultEffort || (meta.modelDefaultEfforts || {})[meta.model] || (provider(meta) === 'qwen' ? 'off' : null);
  }

  // Until the provider reports its model, the effort read from settings may belong to another model.
  function modelLoading(meta) {
    return meta.ready === true && meta.model === meta.providerLabel;
  }

  function modelStatus(meta) {
    if (modelLoading(meta)) return 'Loading…';
    const effort = effectiveEffort(meta);
    return modelLabel(meta) + (effort ? ` - ${effort}` : '');
  }

  // Swift `Session.directoryLabel`: the repository's name, else the folder under ~/self as outer/last, else ~-relative.
  function directoryLabel(meta) {
    if (meta.repositoryDirectory) return meta.repositoryDirectory;
    const cwd = meta.cwd || '';
    const inSelf = cwd.match(/^\/Users\/[^/]+\/self\/(.+)$/);
    if (inSelf) {
      const parts = inSelf[1].split('/').filter(Boolean);
      return parts.length > 2 ? `${parts[0]}/${parts.at(-1)}` : parts.join('/');
    }
    const home = cwd.match(/^\/Users\/[^/]+(\/.*)?$/);
    return home ? `~${home[1] || ''}` : cwd;
  }

  function contextLabel(meta) {
    const used = meta.contextUsed, limit = meta.contextLimit;
    if (!(limit > 0)) return `${(used || 0).toLocaleString('en-US')} tokens`;
    const capacity = limit >= MILLION ? `${+(limit / MILLION).toPrecision(6)}M` : `${Math.round(limit / THOUSAND)}K`;
    return `${typeof used === 'number' ? Math.round((used / limit) * 100) : 0}% token - ${capacity}`;
  }

  function repositoryLabel(meta) {
    if (!meta.branch) return 'not a repo';
    return `@${meta.branch}${meta.repositoryStatus ? ` - ${meta.repositoryStatus}` : ''}`;
  }

  function repositoryColor(meta) {
    return { uncommitted: COLORS.uncommitted, unpushed: COLORS.unpushed, 'up to date': COLORS.ready }[meta.repositoryStatus] || COLORS.plain;
  }

  function showsUsage(meta) {
    return !UNMETERED.includes(provider(meta)) && (meta.usageLoading === true || !!meta.usage);
  }

  // Green at no usage, through amber, to red at the whole plan, as the Swift chip's hue.
  function usageColor(meta) {
    if (typeof meta.usagePercent !== 'number') return COLORS.plain;
    const hue = (1 - Math.min(100, Math.max(0, meta.usagePercent)) / 100) / 3;
    return hsb(hue, 0.85, 0.45);
  }

  function hsb(hue, saturation, brightness) {
    const channel = n => {
      const k = (n + hue * 6) % 6;
      return Math.round(255 * (brightness - brightness * saturation * Math.max(0, Math.min(k, 4 - k, 1))));
    };
    return `rgb(${channel(5)} ${channel(3)} ${channel(1)})`;
  }

  // Swift `Session.activityLabel`.
  function activity(meta) {
    if (meta.busy) return meta.status === 'Reconnecting…' ? meta.status : 'Thinking';
    if (!meta.ready) return 'Not connected';
    if (meta.needsAttention || meta.status === 'Stopped') return meta.status;
    return meta.backgroundTasks > 0 ? 'Pending action' : 'Ready';
  }

  // What runs now: the newest step the agent has not finished.
  function doing() {
    for (const id of [...state.order].reverse()) {
      const row = state.rows.get(id);
      const running = row && [...row.items].reverse().find(item => item.status === 'inProgress' && item.title);
      if (running) return running.title;
    }
    return '';
  }

  function elapsed() {
    if (busySince === null) return '';
    const seconds = Math.max(0, Math.floor((clock() - busySince) / THOUSAND));
    const minutes = Math.floor((seconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE), rest = String(seconds % SECONDS_PER_MINUTE).padStart(2, '0');
    return seconds >= SECONDS_PER_HOUR ? `${Math.floor(seconds / SECONDS_PER_HOUR)}:${String(minutes).padStart(2, '0')}:${rest}` : `${minutes}:${rest}`;
  }

  function drawStatus() {
    const meta = state.meta;
    const pending = !meta.busy && !meta.needsAttention && meta.backgroundTasks > 0;
    const tone = meta.busy ? 'busy' : !meta.ready ? 'off' : pending ? 'pending' : 'ready';
    $('dot').className = tone;
    $('status').dataset.tone = tone;
    const pill = $('status-pill'), word = activity(meta) || '';
    // app.js still writes its own word on each state; ours goes back at once unless it changed, then it swaps in.
    if (shown.status && word !== shown.status) setPill(pill, word, TONE_FILLS[tone]);
    else {
      $('status-text').textContent = word;
      pill.style.setProperty('--fill', TONE_FILLS[tone]);
    }
    shown.status = word;
    const running = meta.busy ? doing() : '';
    $('status-doing').textContent = running ? `· ${running}` : '';
    $('status-elapsed').textContent = meta.busy ? `· ${elapsed()}` : '';
    const requests = meta.requests || [];
    const asking = requests.length > 0 && requests[0].kind !== 'question';
    const note = asking ? 'Your answer is needed' : !meta.ready && meta.status ? meta.status : '';
    $('status-note').textContent = note;
    $('status-note').hidden = !note;
  }

  // The clock runs only while a turn does; hidden windows keep their timers, they only lose frames.
  function tick() {
    if (state.meta.busy && busySince === null) busySince = clock();
    if (!state.meta.busy) busySince = null;
    if (state.meta.busy && !ticking) ticking = setInterval(drawStatus, ELAPSED_TICK_MS);
    if (!state.meta.busy && ticking) {
      clearInterval(ticking);
      ticking = null;
    }
  }

  // Each model that spoke in this conversation's debates, this session's own first; null when there was none.
  function debateModels() {
    const others = state.order.map(id => state.rows.get(id)).filter(row => row && row.kind === 'debate')
      .flatMap(row => row.items.flatMap(item => item.turns || [])).filter(turn => turn.speaker !== 'claude');
    if (!others.length) return null;
    const names = [modelLabel(state.meta)];
    for (const turn of others) {
      const name = turn.speaker.charAt(0).toUpperCase() + turn.speaker.slice(1) + (turn.model ? ` ${turn.model}` : '');
      if (!names.includes(name)) names.push(name);
    }
    return names;
  }

  function cut(words) {
    return words.length > LONGEST_CHIP_WORDS ? `${words.slice(0, LONGEST_CHIP_WORDS - 1)}…` : words;
  }

  // The bar's chips as plain data, in the Swift bar's order.
  function chips() {
    const meta = state.meta, list = [];
    if (state.update) list.push({ kind: 'update', glide: true, label: 'updating', text: cut(state.update.words || ''), fraction: state.update.fraction || 0 });
    if (state.progress) list.push({ kind: 'progress', glide: true, label: cut(state.progress.label || ''), text: state.progress.detail || '', fraction: state.progress.fraction || 0 });
    list.push({ kind: 'directory', text: directoryLabel(meta), color: COLORS.directory, title: 'Change the working directory' });
    list.push({ kind: 'model', text: modelStatus(meta), color: COLORS.model, loading: modelLoading(meta), title: 'Provider, model and effort' });
    list.push({ kind: 'mode', text: meta.activeMode === 'bypass' ? 'bypass' : 'ask', color: COLORS.mode, title: 'Permissions' });
    const models = debateModels();
    if (models) list.push({ kind: 'models', text: `${models.length} models`, color: DEBATE_COLORS.codex, title: "Models in this conversation's debates" });
    list.push({ kind: 'tokens', text: contextLabel(meta), color: COLORS.tokens, title: 'Quota on this Mac' });
    if (showsUsage(meta)) list.push({ kind: 'usage', text: meta.usage || (meta.usageLoading ? 'Loading…' : 'Not reported'), color: usageColor(meta), loading: meta.usageLoading === true, title: 'Quota on this Mac' });
    list.push({ kind: 'repo', text: repositoryLabel(meta), color: repositoryColor(meta), title: (meta.repositoryChanges || []).join('\n') || '/repo' });
    if (meta.pullRequest) list.push({ kind: 'pullRequest', text: meta.pullRequest, color: COLORS.pullRequest, title: meta.pullRequestURL || '' });
    return list;
  }

  const CHIP_ACTIONS = {
    directory: () => post({ type: 'chooseDirectory' }),
    model: () => toggle('model'),
    mode: () => toggle('mode'),
    models: () => toggle('models'),
    tokens: () => openQuota(false),
    usage: () => openQuota(true),
    repo: () => post({ type: 'command', text: '/repo' }),
    pullRequest: () => state.meta.pullRequestURL && post({ type: 'open', href: state.meta.pullRequestURL }),
  };

  // A chip's fill: its Swift colour washed into white, as the status pill washes its sheet colour.
  function wash(color) {
    return `color-mix(in srgb, ${color} 22%, white)`;
  }

  function newChip(spec) {
    if (spec.glide) {
      const node = make('span', 'pill glide');
      const bar = make('div', 'pg');
      bar.setAttribute('role', 'progressbar');
      bar.append(make('div', 'pg-bar'));
      node.append(make('span'), bar);
      return node;
    }
    const node = button('pill', '', CHIP_ACTIONS[spec.kind]);
    node.append(make('span'));
    return node;
  }

  // Each chip stays the same node while its kind is in the bar, so a new word swaps in as the status pill does.
  function drawChip(spec) {
    const known = shown.chips.get(spec.kind);
    const node = known ? known.node : newChip(spec);
    node.dataset.chip = spec.kind;
    node.title = spec.title || '';
    if (spec.glide) {
      node.firstElementChild.replaceChildren(make('b', '', spec.label), make('span', 'dim', ' · '), spec.text);
      progress(node.querySelector('.pg'), Math.round(Math.min(1, Math.max(0, spec.fraction)) * 1000) / 10);
    } else {
      node.style.setProperty('--tint', spec.color);
      node.classList.toggle('loading', !!spec.loading);
      if (known && known.text !== spec.text) setPill(node, spec.text, wash(spec.color));
      else {
        node.querySelector('span').textContent = spec.text;
        node.style.setProperty('--fill', wash(spec.color));
      }
    }
    shown.chips.set(spec.kind, { node, text: spec.text });
    return node;
  }

  function drawBar() {
    const list = chips(), kinds = new Set(list.map(spec => spec.kind));
    for (const kind of [...shown.chips.keys()]) if (!kinds.has(kind)) shown.chips.delete(kind);
    const nodes = list.map(drawChip);
    // app.js still draws its own chips into the bar on each state; they are replaced until it stops.
    const bar = $('chips');
    if (nodes.length !== bar.children.length || nodes.some((node, index) => bar.children[index] !== node)) bar.replaceChildren(...nodes);
  }

  function answer(request, decision) {
    answering = request.id;
    post({ type: 'answer', rpcID: request.rpcID, method: request.method, result: { decision } });
    drawPermission();
  }

  // Swift `PermissionView`, in the bar dialog: the first pending approval; a question is drawn by the transcript's
  // question card.
  function drawPermission() {
    const request = (state.meta.requests || [])[0];
    const card = $('permission');
    card.hidden = !request || request.kind !== 'approval';
    if (card.hidden) {
      shown.request = '';
      return card.replaceChildren();
    }
    const sent = answering === request.id;
    const head = make('div', 'bar'), name = make('div'), title = make('p', '', 'Permission requested');
    name.append(title);
    head.append(name);
    const body = make('div', 'body');
    body.append(make('p', 'reason', request.reason), make('pre', 'detail', request.detail));
    const foot = make('div', 'foot');
    foot.append(...[['cancel', 'Cancel', 'ub outline first'], ['decline', 'Decline', 'ub outline'], ['accept', 'Allow', 'ub primary']].map(([decision, label, className]) => {
      const choice = button(className, label, () => answer(request, decision));
      choice.dataset.decision = decision;
      choice.disabled = sent || (decision === 'accept' && request.canAllow === false);
      return choice;
    }));
    card.dataset.request = request.id;
    card.replaceChildren(head, body, foot);
    oneLine(title, { min: TITLE_MIN_PX });
    if (shown.request === request.id) return;
    shown.request = request.id;
    if (!matchMedia('(prefers-reduced-motion: reduce)').matches) card.animate({ opacity: [0, 1], scale: [0.95, 1] }, { duration: DIALOG_POP_MS, easing: 'ease-out' });
  }

  function toggle(kind) {
    popover = popover === kind ? null : kind;
    drawPopover();
  }

  function openQuota(usage) {
    if (usage) post({ type: 'refresh', what: 'usage' });
    if (popover !== 'quota') post({ type: 'quota' });
    toggle('quota');
  }

  function command(text) {
    post({ type: 'command', text });
    popover = null;
    drawPopover();
  }

  function heading(text) {
    return make('p', 'heading', text);
  }

  // A row of choices as the toggle chips (WT-034): the pressed one is the one in use.
  function chipRow(names, current, action) {
    const row = make('div', 'chips');
    row.append(...names.map(name => {
      const chip = button('option', name, () => action(name));
      chip.ariaPressed = String(name === current);
      return chip;
    }));
    return row;
  }

  // A one-choice list as the single pick's (WT-046): the one in use white on blue.
  function choiceList(entries) {
    const list = make('ul', 'choices');
    list.setAttribute('role', 'listbox');
    list.append(...entries.map(({ label, detail, current, action }) => {
      const item = make('li'), choice = button('choice', '', action);
      choice.ariaCurrent = String(!!current);
      choice.append(make('span', 'name', label));
      if (detail) choice.append(make('span', 'detail', detail));
      item.append(choice);
      return item;
    }));
    return list;
  }

  // Swift `modelVersion`: the family is the words around the version, the version its numbers.
  function modelVersion(id) {
    const family = [], number = [];
    for (const token of id.toLowerCase().split('-')) {
      if (token.length === RELEASE_DATE_DIGITS && /^\d+$/.test(token)) continue;
      const parts = token.split('.');
      if (parts.every(part => /^\d+$/.test(part))) {
        if (!number.length) family.push('*');
        number.push(...parts.map(Number));
      } else family.push(token);
    }
    return number.length ? { family: family.join('-'), number } : null;
  }

  function newer(left, right) {
    for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
      const a = left[index] || 0, b = right[index] || 0;
      if (a !== b) return a > b;
    }
    return false;
  }

  // Swift `latestModels`: each family's newest version only.
  function latestModels(models) {
    const versions = models.map(model => modelVersion(aliased(model)));
    const newest = {};
    for (const version of versions) {
      if (version && (!newest[version.family] || newer(version.number, newest[version.family]))) newest[version.family] = version.number;
    }
    return models.filter((model, index) => !versions[index] || newest[versions[index].family] === versions[index].number);
  }

  // A new model keeps the effort in use when it has it, else takes its own default (Swift `ModelControl.drain`).
  function effortFor(model) {
    const efforts = (state.meta.modelEfforts || {})[model] || [];
    if (!efforts.length) return null;
    const current = effectiveEffort(state.meta);
    return efforts.includes(current) ? current : (state.meta.modelDefaultEfforts || {})[model] || efforts[0];
  }

  function modelPanel() {
    const meta = state.meta, own = provider(meta);
    const panel = [heading('PROVIDER'), chipRow(PROVIDERS, own, name => command(`/model ${name}`))];
    const models = latestModels(meta.models || []);
    if (models.length) {
      panel.push(heading('MODEL'), choiceList(models.map(model => ({
        label: modelName(aliased(model)), detail: model, current: model === meta.model,
        action: () => command(['/model', own, model, effortFor(model)].filter(Boolean).join(' ')),
      }))));
    }
    const efforts = (meta.modelEfforts || {})[meta.model] || [];
    if (efforts.length) panel.push(heading('EFFORT'), chipRow(efforts, effectiveEffort(meta), effort => command(`/model ${own} ${meta.model} ${effort}`)));
    return panel;
  }

  function modePanel() {
    const current = state.meta.activeMode === 'bypass' ? 'bypass' : 'ask';
    return [heading('PERMISSIONS'), choiceList(MODES.map(([mode, detail]) => ({ label: mode, detail, current: mode === current, action: () => command(`/perms ${mode}`) })))];
  }

  // Swift `DebateModelList`: each model beside its debate color, this session's own first.
  function modelsPanel() {
    const models = debateModels() || [];
    return [heading('MODELS IN THIS CONVERSATION'), ...models.map((model, index) => {
      const speaker = index === 0 ? provider(state.meta) : model.split(' ')[0].toLowerCase();
      const line = make('div', 'model');
      line.style.setProperty('--tint', DEBATE_COLORS[speaker] || COLORS.plain);
      line.append(make('i', 'swatch'), make('span', 'name', model));
      if (index === 0) line.append(make('span', 'own', 'this session'));
      return line;
    })];
  }

  // Swift `QuotaOverview`: the 5-hour and weekly quota of every agent on this Mac, read by the core.
  function quotaPanel() {
    const lines = state.quota || [];
    const panel = [make('p', 'vcx-title', 'Quota on this Mac')];
    if (!lines.length) panel.push(make('p', 'loading', 'Loading…'));
    else {
      const grid = make('table', 'vcx-table');
      grid.append(make('thead'), make('tbody'));
      table(grid)(lines.map(line => ({ Agent: line.agent, '5 hours': line.fiveHour, Week: line.week })));
      panel.push(grid);
    }
    panel.push(button('link', "Change this window's model…", () => toggle('model')));
    return panel;
  }

  const PANELS = { model: modelPanel, mode: modePanel, models: modelsPanel, quota: quotaPanel };
  const ANCHORS = { model: 'model', mode: 'mode', models: 'models', quota: 'tokens' };

  // The single pick's list, opened above its chip: the status bar sits at the window's foot.
  function drawPopover() {
    const layer = $('popover');
    for (const node of $('chips').querySelectorAll('[aria-expanded]')) node.ariaExpanded = 'false';
    layer.hidden = !popover;
    if (!popover) return layer.replaceChildren();
    const anchor = $('chips').querySelector(`[data-chip="${ANCHORS[popover]}"]`) || $('chips');
    anchor.ariaExpanded = 'true';
    layer.dataset.kind = popover;
    layer.replaceChildren(...PANELS[popover]());
    const box = anchor.getBoundingClientRect();
    layer.style.setProperty('left', `${Math.max(POPOVER_GAP_PX, Math.min(box.left, innerWidth - layer.offsetWidth - POPOVER_GAP_PX))}px`);
    layer.style.setProperty('bottom', `${innerHeight - box.top + POPOVER_GAP_PX}px`);
  }

  // Swift `TaskBoard.groups`: projects in the order their first window opened, each keeping its windows' order.
  function groups(entries) {
    const order = [];
    for (const entry of entries) if (!order.includes(entry.group)) order.push(entry.group);
    return order.map(group => ({ group, entries: entries.filter(entry => entry.group === group) }));
  }

  function taskCard(entry) {
    const card = make('button', 'card');
    card.type = 'button';
    card.dataset.card = entry.id;
    card.dataset.id = entry.id;
    card.dataset.state = entry.state;
    card.style.setProperty('--full', TASK_COLORS[entry.state]);
    if (entry.current) card.setAttribute('aria-current', 'true');
    card.title = entry.current ? `This window: ${TASK_STATES[entry.state]}` : `Bring this session to the front: ${TASK_STATES[entry.state]}`;
    card.setAttribute('aria-label', `${entry.task}, ${TASK_STATES[entry.state]}`);
    const glass = make('span', 'card-glass');
    glass.ariaHidden = 'true';
    card.append(glass, make('i', 'mark', TASK_MARKS[entry.state]), make('span', 'name', entry.task));
    return card;
  }

  function drawTasks() {
    const entries = (state.tasks || []).filter(entry => TASK_STATES[entry.state]);
    const signature = JSON.stringify(entries);
    if (signature === shown.tasks) return;
    shown.tasks = signature;
    const tasks = $('tasks'), bar = tasks.querySelector('.bar');
    tasks.querySelector('header .count').textContent = entries.length ? String(entries.length) : '';
    const grouped = groups(entries);
    bar.replaceChildren(...grouped.map(group => {
      const section = make('section', 'bar-group');
      if (grouped.length > 1) section.append(make('h2', 'bar-head', group.group.split('/').filter(Boolean).pop() || group.group));
      section.append(...group.entries.map(taskCard));
      return section;
    }));
    bar.hidden = !entries.length;
    if (shown.empty === !entries.length) return;
    shown.empty = !entries.length;
    emptyState(tasks.querySelector('.empty'), shown.empty);
  }

  // The commands the composer offers, without the provider's skills or the terminal's own (Swift `capabilityCommands`).
  function capabilityCommands() {
    const provided = new Set((state.meta.providerCommands || []).map(command => command.name));
    const builtins = state.meta.builtinCommands || [];
    const names = new Set();
    return (window.vcxCatalog ? window.vcxCatalog() : []).filter(command => !(command.source || '').endsWith(' terminal')
      && (!provided.has(command.name) || builtins.includes(command.name.slice(1))) && !names.has(command.name) && names.add(command.name));
  }

  function byName(left, right) {
    return left.name.localeCompare(right.name, undefined, { numeric: true, sensitivity: 'base' });
  }

  // Swift `capabilityItems`: each list as name and detail, a hook's events gathered under its name.
  function capabilityItems(title) {
    const meta = state.meta;
    if (title === 'Commands') return capabilityCommands().map(command => ({ name: command.name.slice(1), detail: command.detail || '' })).sort(byName);
    if (title === 'RAG') {
      // The heading each line sits under in its ERRORS file, read by the core (Swift `ErrorsRecall.section`).
      const sections = meta.recalledRuleSections || {};
      return (meta.recalledRules || []).map(rule => {
        const date = rule.match(RULE_DATE);
        return { name: sections[rule] || 'ERRORS line', detail: date ? rule.slice(date[0].length) : rule };
      });
    }
    const items = (({ Hooks: meta.hooks, Skills: meta.skills, MCP: meta.mcp, Instructions: meta.instructions })[title] || []).map(value => {
      const parts = value.split(' · '), name = parts[0];
      const summary = parts.slice(1).filter(part => title !== 'Hooks' || part !== 'trusted').join(' · ');
      if (title === 'Instructions') return { name: value.split('/').pop(), detail: value };
      if (title === 'Skills') return { name, detail: ((meta.providerCommands || []).find(command => command.name === `/${name}`) || {}).detail || 'Provider skill' };
      return { name, detail: summary || (title === 'Hooks' ? 'Provider hook' : 'Configured MCP server') };
    });
    if (title !== 'Hooks') return items;
    const grouped = [];
    for (const item of items) {
      const known = grouped.find(other => other.name === item.name);
      if (known) known.detail += `\n\n${item.detail}`;
      else grouped.push({ ...item });
    }
    return grouped;
  }

  function capabilityCount(title) {
    const meta = state.meta;
    const listed = { Skills: meta.skills, MCP: meta.mcp, Instructions: meta.instructions, RAG: meta.recalledRules }[title];
    return listed ? listed.length : capabilityItems(title).length;
  }

  function drawSession() {
    for (const card of $('session').querySelectorAll('.card')) {
      const count = String(capabilityCount(card.dataset.card));
      card.dataset.count = count;
      const digits = card.querySelector('.num > span');
      if (digits) digits.textContent = count;
    }
    const id = state.meta.threadID;
    const copy = $('session-id');
    copy.disabled = !id;
    copy.title = id ? `Copy ${id}` : 'No session yet';
    if (capability.open) drawCapability();
  }

  function hoverCapability(title) {
    capability.hovered = title;
    // Once a list is open, moving to another card switches at once.
    if (capability.open) return openCapability(title);
    clearTimeout(capability.opening);
    capability.opening = setTimeout(() => capability.hovered === title && openCapability(title), HOVER_OPEN_MS);
  }

  function leaveCapability(title) {
    if (capability.hovered === title) capability.hovered = null;
    closeCapabilityLater();
  }

  function closeCapabilityLater() {
    setTimeout(() => !capability.hovered && !capability.inPanel && closeCapability(), HOVER_CLOSE_MS);
  }

  function openCapability(title) {
    if (capability.open === title) return;
    capability.open = title;
    capability.choose($('session').querySelector(`.card[data-card="${title}"]`));
    drawCapability(true);
  }

  function closeCapability() {
    if (!capability.open) return;
    capability.open = null;
    // A list closed under a card the pointer just reached stays closed until the pointer comes back.
    clearTimeout(capability.opening);
    const bar = $('session').querySelector('.bar');
    bar.querySelector('.card[aria-current]')?.removeAttribute('aria-current');
    bar.style.setProperty('--cut-a', '0px');
    bar.style.setProperty('--cut-b', '0px');
    $('capability').hidden = true;
    $('capability').replaceChildren();
  }

  function itemRow(title, item) {
    const row = make('div', 'item');
    row.append(make('b', 'name', item.name));
    if (title === 'Hooks') {
      for (const detail of item.detail.split('\n\n')) {
        const line = make('div', 'line');
        line.title = detail;
        line.append(make('span', '', detail.split(' · ')[0]));
        if (detail.split(' · ').includes('disabled')) line.append(make('span', 'off', 'disabled'));
        row.append(line);
      }
    } else if (!DETAIL_BESIDE.includes(title) && item.detail) row.append(make('p', 'detail', item.detail));
    if (DETAIL_BESIDE.includes(title)) {
      row.addEventListener('pointerenter', () => showBeside(row, item.detail));
      row.addEventListener('pointerleave', () => showBeside(null));
    }
    if (title === 'Instructions') row.addEventListener('click', () => post({ type: 'open', href: item.detail }));
    return row;
  }

  function showBeside(row, text) {
    const beside = $('capability').querySelector('.beside');
    beside.hidden = !row;
    if (!row) return;
    beside.textContent = text;
    beside.style.top = `${row.offsetTop}px`;
  }

  // Swift `CapabilityPopup`: the list with its search, which keeps what was typed while the session changes under it.
  function drawCapability(fresh = false) {
    const title = capability.open, panel = $('capability');
    const listed = capabilityItems(title).sort(byName);
    const signature = JSON.stringify([title, listed]);
    if (!fresh && signature === capability.signature) return;
    capability.signature = signature;
    const typed = fresh ? '' : panel.querySelector('input')?.value || '';
    const focused = !fresh && document.activeElement === panel.querySelector('input');
    const head = make('header');
    head.append(make('h2', '', title === 'Instructions' ? 'MD Files' : title), button('b b-ghost icon', '', closeCapability));
    head.lastChild.innerHTML = icon('close');
    head.lastChild.ariaLabel = `Close ${title.toLowerCase()}`;
    const find = make('label', 'find');
    find.innerHTML = `${icon('search', 'ico')}<input type="search">`;
    const input = find.querySelector('input');
    input.placeholder = `Search ${title.toLowerCase()}`;
    input.value = typed;
    const items = listed.map(item => ({ ...item, el: itemRow(title, item) }));
    const list = make('div', 'items');
    list.append(...items.map(item => item.el));
    const none = make('p', 'none');
    const beside = make('p', 'beside');
    beside.hidden = true;
    panel.replaceChildren(head, find, list, none, beside);
    panel.hidden = false;
    tableFilter({ find, at: null, rows: items, text: item => `${item.name} ${item.detail}`, show: (item, on) => { item.el.hidden = !on; } });
    const tell = () => {
      const empty = !items.some(item => !item.el.hidden);
      none.hidden = !empty;
      none.textContent = input.value ? 'No matches' : title === 'RAG' ? 'No ERRORS line sent yet' : 'None reported';
    };
    input.addEventListener('input', tell);
    tell();
    if (fresh || focused) input.focus();
  }

  // ---- Effect: tabs (WT-105) ----
  // tabs(root): the n-th .tb-trigger shows the n-th .tb-panel.
  function tabs(root) {
    const triggers = [...root.querySelectorAll('.tb-trigger')], panels = [...root.querySelectorAll('.tb-panel')];
    triggers.forEach((t, i) => t.addEventListener('click', () => {
      if (t.classList.contains('on')) return;
      triggers.forEach((x, k) => { x.classList.toggle('on', k === i); x.ariaSelected = k === i; });
      panels.forEach((p, k) => p.classList.toggle('on', k === i));
    }));
  }
  // ---- End of effect ----

  // Swift `SettingsPopup`, as the bar dialog (WT-072) with the tabs (WT-105); each setting is a name and value block (WT-055).
  function settingsSheet() {
    const node = make('section', 'dialog light');
    node.id = 'settings';
    node.hidden = true;
    node.role = 'dialog';
    node.ariaLabel = 'Settings';
    const bar = make('header', 'bar');
    const title = make('div');
    title.append(make('p', '', 'Settings'));
    const shut = button('b b-ghost icon', '', closeSettings);
    shut.innerHTML = icon('close');
    shut.ariaLabel = 'Close settings';
    bar.append(title, shut);
    const list = make('div', 'tb-list');
    list.role = 'tablist';
    list.ariaLabel = 'Settings section';
    const body = make('div', 'body');
    for (const [index, name] of SETTINGS_TABS.entries()) {
      const trigger = make('button', index ? 'tb-trigger' : 'tb-trigger on', name);
      trigger.type = 'button';
      trigger.role = 'tab';
      trigger.ariaSelected = !index;
      const panel = make('div', index ? 'tb-panel' : 'tb-panel on');
      panel.dataset.tab = name;
      list.append(trigger);
      body.append(panel);
    }
    node.append(bar, list, body);
    tabs(node);
    return node;
  }

  function openSettings() {
    closeCapability();
    popover = null;
    drawPopover();
    sheet.open = true;
    sheet.signature = '';
    $('settings').querySelector('.tb-trigger').click();
    // The core answers with the accounts, the limits, Qwen and what runs in the background.
    post({ type: 'settings' });
    drawSettings();
    $('settings').focus();
  }

  function closeSettings() {
    sheet.open = false;
    $('settings').hidden = true;
  }

  // Swift `showCommands`: the command goes into the composer, which opens its palette on it.
  function showCommands(text) {
    closeSettings();
    const input = $('input');
    input.focus();
    input.select();
    if (!document.execCommand('insertText', false, text)) {
      input.value = text;
      input.dispatchEvent(new Event('input'));
    }
  }

  function fact(name, value, command, fill) {
    const block = make('div', 'fact');
    block.role = 'button';
    block.tabIndex = 0;
    const words = make('span', fill ? `val f-${fill}` : 'val');
    words.title = value;
    words.append(make('span', '', value));
    const dd = make('dd');
    dd.append(words);
    block.append(make('dt', '', name), dd);
    block.addEventListener('click', () => showCommands(command));
    block.addEventListener('keydown', event => (event.key === 'Enter' || event.key === ' ') && (event.preventDefault(), showCommands(command)));
    const line = make('dl');
    line.append(block);
    return line;
  }

  function capitalized(word) {
    return word ? word[0].toUpperCase() + word.slice(1) : '';
  }

  function sessionFacts() {
    const meta = state.meta, modelCommand = `/model ${provider(meta)} `, effort = effectiveEffort(meta);
    return [
      fact('Provider', meta.providerLabel || 'Not connected', '/model '),
      fact('Model', modelLabel(meta), modelCommand),
      effort && fact('Effort', effort, `${modelCommand}${meta.model || ''} `),
      fact('Permissions', meta.activeMode === 'bypass' ? 'Bypass / YOLO' : 'Ask for approval', '/perms '),
      fact('Working directory', meta.cwd || '', '/dir '),
    ].filter(Boolean);
  }

  function accountFacts() {
    const known = state.settings;
    const facts = known ? [] : [make('p', 'none', 'Reading the accounts…')];
    for (const account of (known && known.accounts) || []) {
      facts.push(fact(account.name, `${capitalized(account.provider)} · ${account.enabled ? 'enabled' : 'disabled'}`, '/account ', account.enabled ? 'green' : ''));
      if (account.home) facts.push(fact('Profile', account.home, `/profile ${account.provider} `));
      const reset = (account.availableAfter || 0) * MS_PER_SECOND;
      if (reset > clock()) facts.push(fact('Available after', new Date(reset).toLocaleString(undefined, { dateStyle: 'short', timeStyle: 'short' }), '/usage', 'orange'));
    }
    facts.push(fact('Add account', 'Claude or Codex', '/login '), fact('Import profile', 'Existing account folder', '/profile '));
    return facts;
  }

  function qwenFacts() {
    const qwen = state.settings && state.settings.qwen;
    if (!qwen) return [make('p', 'none', 'Reading the Qwen settings…')];
    return [
      fact('Runs on', QWEN_HOSTS[qwen.host] || 'Custom endpoint', '/qwen host '),
      fact('Endpoint', qwen.url || '', '/qwen url '),
      fact('Proxy', qwen.proxy || 'None', '/qwen proxy '),
      fact('Model', qwen.model || '', '/qwen model '),
    ];
  }

  // A described block (WT-055's Descriptions tick).
  function job(title, status, detail) {
    const block = make('div', 'fact described');
    const words = make('span', 'val f-blue');
    words.append(make('span', '', status));
    const dd = make('dd');
    dd.append(words);
    block.append(make('dt', '', title), dd, make('dd', 'about', detail));
    return block;
  }

  function backgroundJobs() {
    const known = state.settings || {}, meta = state.meta, account = known.account || 'the account';
    const running = meta.backgroundTasks || 0, retries = known.rateLimitRetries || [], fallbacks = known.fallbacks || [];
    const routing = ['/', known.home].includes(meta.cwd) && ![...state.rows.values()].some(row => row.kind === 'user');
    return [
      make('p', 'intro', 'Work VCX starts without a prompt from you. Each one spends tokens on the account named.'),
      job('Agent background tasks', running ? `${running} running` : 'None running', `Commands and subagents the agent left running keep spending ${account}'s tokens after its reply; when one finishes, Claude starts a turn by itself.`),
      job('Project routing', routing ? 'Armed in this window' : 'Done for this window', `The first prompt of a window opened in / or ~ goes to Claude Haiku on ${known.routeAccount || 'no Claude account'}, with the ~/self folder map and the skill list, to pick its project. It runs while you type and again on Enter if the prompt grew by more than a quarter.`),
      job('Rate limit retries', `${retries.length} at most`, `A turn stopped by a rate limit (not the plan's usage limit) is resent as "Keep going" on the same account after ${retries.map(seconds => `${Math.trunc(seconds)} s`).join(', ')}.`),
      job('Network resume', `${NETWORK_RESUMES} at most`, 'A turn a dropped connection killed is resent as "Keep going" once the internet answers again.'),
      job('Usage limit fallback', fallbacks.length ? fallbacks.join(', ') : 'No fallback', `When an account reaches its usage limit mid-turn, the next enabled account takes the last prompt, with up to ${RECENT_KB} KB of the recent conversation.`),
      job('Resume recovery', 'When needed', `When Claude cannot resume a saved conversation, a new one starts and gets the pending prompt with up to ${RECENT_KB} KB of recent messages.`),
    ];
  }

  // The keyboard shortcuts (WT-121).
  function shortcutRows() {
    return SHORTCUTS.map(([keys, action]) => {
      const row = make('div', 'key');
      const caps = make('span', 'caps');
      caps.append(...keys.map(key => make('kbd', '', key)));
      row.append(caps, make('span', 'action', action));
      return row;
    });
  }

  function drawSettings() {
    const node = $('settings');
    if (!sheet.open) return;
    const signature = JSON.stringify([state.meta, state.settings, state.rows.size]);
    node.hidden = false;
    if (signature === sheet.signature) return;
    sheet.signature = signature;
    const content = { Session: sessionFacts, Accounts: accountFacts, Qwen: qwenFacts, Background: backgroundJobs, Keys: shortcutRows };
    for (const panel of node.querySelectorAll('.tb-panel')) panel.replaceChildren(...content[panel.dataset.tab]());
  }

  // Swift `loginStatus`, above the composer as the permission prompt is: the bar dialog (WT-072) with one button.
  function loginPanel() {
    const node = make('section', 'dialog light');
    node.id = 'login';
    node.hidden = true;
    const bar = make('header', 'bar');
    const title = make('div');
    title.append(make('p'));
    const body = make('pre', 'body');
    const foot = make('div', 'foot');
    foot.append(button('ub outline', '', () => {
      // `/login cancel` stops the sign-in under way, `/login dismiss` clears the message (Swift `Commands`).
      command(state.login && state.login.signingIn ? '/login cancel' : '/login dismiss');
      state.login = null;
      drawLogin();
    }));
    node.append(bar, body, foot);
    bar.append(title);
    return node;
  }

  function drawLogin() {
    const node = $('login'), login = state.login;
    node.hidden = !(login && login.text);
    if (node.hidden) return;
    node.querySelector('.bar p').textContent = login.signingIn ? 'Account sign-in' : 'Account status';
    node.querySelector('.body').textContent = login.text;
    node.querySelector('.foot button').textContent = login.signingIn ? 'Cancel' : 'Dismiss';
  }

  // The connection's state and the last problem are told apart, so one clearing does not hide the other.
  function drawNotice() {
    const shownText = [state.notes.link, state.notes.problem].filter(Boolean).join(' ');
    const notice = $('notice');
    notice.textContent = shownText;
    notice.hidden = !shownText;
    notice.classList.toggle('f-red', !!state.notes.problem);
    notice.classList.toggle('f-orange', !state.notes.problem);
  }

  // Swift `updateTitle`: the folder, then the app's name; the core puts it on the window.
  function drawTitle() {
    const folder = (state.meta.cwd || '').split('/').filter(Boolean).pop();
    const title = folder ? `${folder} · Vibe Code X` : 'Vibe Code X';
    document.title = title;
    if (title === shown.title) return;
    shown.title = title;
    post({ type: 'title', text: title });
  }

  function take(message) {
    if (message.type === 'full') {
      // A whole new state shows its words at once; only a change within one swaps in.
      shown.status = '';
      shown.chips.clear();
      state.rows = new Map(message.rows.map(row => [row.id, row]));
      state.order = message.rows.map(row => row.id);
    } else if (message.type === 'patch') {
      for (const row of message.rows || []) {
        if (!state.rows.has(row.id) && !message.order) state.order.push(row.id);
        state.rows.set(row.id, row);
      }
      if (message.order) {
        state.order = message.order.filter(id => state.rows.has(id));
        for (const id of [...state.rows.keys()]) if (!message.order.includes(id)) state.rows.delete(id);
      }
    } else if (message.type === 'link') state.notes.link = message.state === 'connected' ? '' : message.detail || '';
    else if (message.type === 'notice') state.notes.problem = message.text || '';
    else if (message.type === 'progress') state.progress = message.label ? message : null;
    else if (message.type === 'update') state.update = message.words ? message : null;
    else if (message.type === 'tasks') state.tasks = message.entries || [];
    else if (message.type === 'quota') state.quota = message.lines || [];
    else if (message.type === 'settings') state.settings = message;
    // A typed /settings: the core asks the page to open the sheet (Swift `showingSettings`).
    else if (message.type === 'openSettings' && !sheet.open) openSettings();
    else if (message.type === 'login') state.login = message.text ? message : null;
    if (message.meta) {
      state.meta = message.meta;
      if (!(state.meta.requests || []).some(request => request.id === answering)) answering = null;
    }
  }

  function draw() {
    tick();
    drawStatus();
    drawBar();
    drawPermission();
    drawTasks();
    drawNotice();
    drawTitle();
    drawSession();
    drawSettings();
    drawLogin();
    if (popover) drawPopover();
  }

  // What the chrome shows, for a windowless check to read.
  function dump() {
    const text = id => ($(id) && !$(id).hidden ? $(id).textContent : null);
    const bar = [...$('chips').querySelectorAll('[data-chip]')].map(node => ({ kind: node.dataset.chip, text: node.textContent, color: node.style.getPropertyValue('--tint') }));
    const card = $('permission');
    const cards = [...$('tasks').querySelectorAll('.card:not([data-ghost])')];
    return {
      status: text('status-text'), tone: $('status').dataset.tone, doing: text('status-doing'), elapsed: text('status-elapsed'), note: text('status-note'),
      chips: bar, title: document.title, notice: text('notice'), popover: popover && { kind: popover, text: $('popover').innerText },
      permission: card.hidden ? null : { request: card.dataset.request, text: card.innerText, disabled: [...card.querySelectorAll('button')].filter(node => node.disabled).map(node => node.dataset.decision) },
      tasks: cards.map(node => ({ text: node.textContent, state: node.dataset.state, current: node.hasAttribute('aria-current') })),
      groups: [...$('tasks').querySelectorAll('.bar-head:not([data-ghost])')].map(node => node.textContent),
      empty: !$('tasks').querySelector('.empty').classList.contains('hidden'),
      capabilities: [...$('session').querySelectorAll('.card')].map(node => ({ title: node.dataset.card, count: Number(node.dataset.count), open: node.hasAttribute('aria-current') })),
      capability: capability.open && {
        title: capability.open,
        rows: [...$('capability').querySelectorAll('.item:not([hidden])')].map(node => node.innerText.trim().split('\n').filter(Boolean)),
        none: $('capability').querySelector('.none').hidden ? null : $('capability').querySelector('.none').textContent,
      },
      settings: sheet.open ? {
        tab: $('settings').querySelector('.tb-trigger.on').textContent,
        rows: [...$('settings').querySelectorAll('.tb-panel.on > *')].map(node => node.innerText.trim().split('\n').filter(Boolean)),
      } : null,
      login: text('login') && { title: $('login').querySelector('.bar p').textContent, text: $('login').querySelector('.body').textContent, button: $('login').querySelector('.foot button').textContent },
      sessionID: { label: [...$('session-id').querySelectorAll('b:not([hidden])')].map(node => node.textContent).join(''), disabled: $('session-id').disabled },
    };
  }

  function close(event) {
    if (capability.open && !event.target.closest('#capability, #session .card')) closeCapability();
    if (!popover || event.target.closest('#popover')) return;
    popover = null;
    drawPopover();
  }

  place();
  const inner = window.vcx.receive;
  window.vcx.receive = message => {
    take(message);
    inner(message);
    draw();
  };
  document.addEventListener('click', close);
  document.addEventListener('vcx:sent', () => {
    state.notes.problem = '';
    drawNotice();
  });
  document.addEventListener('keydown', event => {
    if (event.key === ',' && event.metaKey) {
      event.preventDefault();
      return sheet.open ? closeSettings() : openSettings();
    }
    if (event.key !== 'Escape' || !(popover || capability.open || sheet.open)) return;
    event.preventDefault();
    event.stopPropagation();
    if (sheet.open) closeSettings();
    else if (popover) {
      popover = null;
      drawPopover();
    } else closeCapability();
  }, true);
  window.vcxChrome = { dump, setClock: next => { clock = next; drawStatus(); } };
  draw();
})();
