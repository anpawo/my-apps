'use strict';
// The window around the transcript and the composer, as the Swift `CXView` draws it: the status line, the status bar
// and its popovers, the permission prompt, the task bar, notices and the title. It reads the messages app.js reads.
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
  const PROVIDERS = ['auto', 'claude', 'codex', 'qwen', 'agy'];
  // Qwen and agy report no plan usage, so the bar shows no Usage chip for them.
  const UNMETERED = ['qwen', 'agy'];
  const MODES = [['bypass', 'YOLO: no tool approval prompts'], ['ask', 'Ask before actions that need permission']];
  const TASK_STATES = { working: 'working', question: 'waiting for you', done: 'done' };
  const TASK_MARKS = { working: '…', question: '?', done: '✓' };
  const COLORS = {
    directory: 'rgb(71 92 179)', model: 'rgb(173 46 115)', mode: 'rgb(191 38 38)', tokens: 'rgb(33 99 171)',
    pullRequest: 'rgb(107 64 179)', ready: 'rgb(26 115 46)', uncommitted: 'rgb(173 46 97)', unpushed: 'rgb(140 92 20)', plain: 'rgb(0 0 0 / 0.6)',
  };
  const DEBATE_COLORS = { claude: 'rgb(199 97 56)', codex: 'rgb(10 122 102)', qwen: 'rgb(51 97 209)', agy: 'rgb(133 77 199)', gemini: 'rgb(209 64 128)' };

  const $ = id => document.getElementById(id);
  const post = message => window.ipc.postMessage(JSON.stringify(message));
  const state = { meta: {}, rows: new Map(), order: [], notes: { link: '', problem: '' }, progress: null, update: null, tasks: null, quota: null };
  const shown = { bar: '', tasks: '', title: '' };
  let popover = null;
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

  function tinted(node, color) {
    node.style.setProperty('--tint', color);
    return node;
  }

  // The elements index.html does not carry: placed once, beside the ones app.js keeps drawing until it lets go of them.
  function place() {
    const status = $('status');
    status.append(make('span', '', ''), make('span', '', ''));
    status.children[2].id = 'status-doing';
    status.children[3].id = 'status-elapsed';
    const note = make('p');
    note.id = 'status-note';
    note.hidden = true;
    const permission = make('section');
    permission.id = 'permission';
    permission.hidden = true;
    status.before(permission);
    status.after(note);
    const tasks = make('aside');
    tasks.id = 'tasks';
    const layer = make('div');
    layer.id = 'popover';
    layer.hidden = true;
    document.body.append(tasks, layer);
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
    if (meta.directoryLabel) return meta.directoryLabel;
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
    $('status-text').textContent = activity(meta);
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

  // The bar's chips as plain data, so the bar is drawn again only when one of them changed.
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

  function chip(spec) {
    if (spec.glide) {
      const node = make('span', 'chip glide');
      node.dataset.chip = spec.kind;
      node.append(make('b', '', spec.label), make('span', 'dim', '·'), make('span', '', spec.text));
      const bar = make('i', 'bar');
      bar.style.setProperty('width', `${Math.round(Math.min(1, Math.max(0, spec.fraction)) * 1000) / 10}%`);
      node.append(bar);
      return node;
    }
    const node = tinted(button('chip', '', CHIP_ACTIONS[spec.kind]), spec.color);
    node.dataset.chip = spec.kind;
    node.title = spec.title || '';
    if (spec.loading) node.append(make('span', 'spinner'));
    node.append(spec.text);
    return node;
  }

  function drawBar() {
    const list = chips(), signature = JSON.stringify(list);
    // app.js still draws its own chips into the bar on each state; they are replaced until it stops.
    if (signature === shown.bar && $('chips').querySelector('[data-chip]')) return;
    shown.bar = signature;
    const nodes = [];
    for (const spec of list) {
      if (nodes.length) nodes.push(make('span', 'sep', '|'));
      nodes.push(chip(spec));
    }
    $('chips').replaceChildren(...nodes);
    if (popover) drawPopover();
  }

  function answer(request, decision) {
    answering = request.id;
    post({ type: 'answer', rpcID: request.rpcID, method: request.method, result: { decision } });
    drawPermission();
  }

  // Swift `PermissionView`: the first pending approval; a question is drawn by the transcript's question card.
  function drawPermission() {
    const request = (state.meta.requests || [])[0];
    const card = $('permission');
    card.hidden = !request || request.kind !== 'approval';
    if (card.hidden) return card.replaceChildren();
    const sent = answering === request.id;
    const title = make('h2', '', 'Permission requested');
    const body = make('div', 'body');
    body.append(make('p', 'reason', request.reason), make('pre', 'detail', request.detail));
    const actions = make('div', 'actions');
    const choices = [['cancel', 'Cancel'], ['decline', 'Decline'], ['accept', 'Allow']].map(([decision, label]) => {
      const choice = button(decision === 'accept' ? 'allow' : '', label, () => answer(request, decision));
      choice.dataset.decision = decision;
      choice.disabled = sent || (decision === 'accept' && request.canAllow === false);
      return choice;
    });
    actions.append(choices[0], make('span', 'spacer'), choices[1], choices[2]);
    card.dataset.request = request.id;
    card.replaceChildren(title, body, actions);
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

  function option(label, current, action, detail) {
    const node = button(current ? 'option current' : 'option', '', action);
    node.append(make('span', 'name', label));
    if (detail) node.append(make('span', 'detail', detail));
    return node;
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
    const meta = state.meta, own = provider(meta), panel = [heading('PROVIDER')];
    const providers = make('div', 'row');
    providers.append(...PROVIDERS.map(name => option(name, name === own, () => command(`/model ${name}`))));
    panel.push(providers);
    const models = latestModels(meta.models || []);
    if (models.length) {
      panel.push(heading('MODEL'));
      panel.push(...models.map(model => option(modelName(aliased(model)), model === meta.model, () => command(['/model', own, model, effortFor(model)].filter(Boolean).join(' ')), model)));
    }
    const efforts = (meta.modelEfforts || {})[meta.model] || [];
    if (efforts.length) {
      panel.push(heading('EFFORT'));
      const row = make('div', 'row');
      row.append(...efforts.map(effort => option(effort, effort === effectiveEffort(meta), () => command(`/model ${own} ${meta.model} ${effort}`))));
      panel.push(row);
    }
    return panel;
  }

  function modePanel() {
    const current = state.meta.activeMode === 'bypass' ? 'bypass' : 'ask';
    return [heading('PERMISSIONS'), ...MODES.map(([mode, detail]) => option(mode, mode === current, () => command(`/perms ${mode}`), detail))];
  }

  // Swift `DebateModelList`: each model beside its debate color, this session's own first.
  function modelsPanel() {
    const models = debateModels() || [];
    return [heading('MODELS IN THIS CONVERSATION'), ...models.map((model, index) => {
      const speaker = index === 0 ? provider(state.meta) : model.split(' ')[0].toLowerCase();
      const line = tinted(make('div', 'model'), DEBATE_COLORS[speaker] || COLORS.plain);
      line.append(make('i', 'swatch'), make('span', 'name', model));
      if (index === 0) line.append(make('span', 'own', 'this session'));
      return line;
    })];
  }

  // Swift `QuotaOverview`: the 5-hour and weekly quota of every agent on this Mac, read by the core.
  function quotaPanel() {
    const grid = make('div', 'quota');
    grid.append(...['Agent', '5 hours', 'Week'].map(title => make('span', 'head', title)), make('hr'));
    const lines = state.quota || [];
    if (!lines.length) grid.append(make('span', 'head', 'Loading…'));
    for (const line of lines) grid.append(make('span', '', line.agent), make('span', '', line.fiveHour), make('span', '', line.week));
    const change = button('link', "Change this window's model…", () => toggle('model'));
    return [make('p', 'title', 'Quota on this Mac'), grid, change];
  }

  const PANELS = { model: modelPanel, mode: modePanel, models: modelsPanel, quota: quotaPanel };
  const ANCHORS = { model: 'model', mode: 'mode', models: 'models', quota: 'tokens' };

  function drawPopover() {
    const layer = $('popover');
    const anchor = popover && ($('chips').querySelector(`[data-chip="${popover === 'quota' && state.quotaFrom ? state.quotaFrom : ANCHORS[popover]}"]`) || $('chips'));
    layer.hidden = !popover;
    if (!popover) return layer.replaceChildren();
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

  function taskRow(entry) {
    const row = tinted(button(entry.current ? 'task current' : 'task', '', () => post({ type: 'focus', id: entry.id })), `var(--task-${entry.state})`);
    row.dataset.state = entry.state;
    row.title = entry.current ? `This window: ${TASK_STATES[entry.state]}` : `Bring this session to the front: ${TASK_STATES[entry.state]}`;
    row.setAttribute('aria-label', `${entry.task}, ${TASK_STATES[entry.state]}`);
    row.append(make('i', 'mark', TASK_MARKS[entry.state]), make('span', 'text', entry.task));
    return row;
  }

  function drawTasks() {
    const entries = (state.tasks || []).filter(entry => TASK_STATES[entry.state]);
    const signature = JSON.stringify(entries);
    if (signature === shown.tasks) return;
    shown.tasks = signature;
    const header = make('header');
    header.append(make('span', 'icon', '☰'), make('span', 'name', 'TASKS'), make('span', 'count', entries.length ? String(entries.length) : ''));
    const list = make('div', 'list');
    if (!entries.length) list.append(make('p', 'empty', 'No task yet.'));
    const grouped = groups(entries);
    for (const group of grouped) {
      if (grouped.length > 1) list.append(make('p', 'group', group.group.split('/').filter(Boolean).pop() || group.group));
      list.append(...group.entries.map(taskRow));
    }
    $('tasks').replaceChildren(header, list);
  }

  // The connection's state and the last problem are told apart, so one clearing does not hide the other.
  function drawNotice() {
    const shownText = [state.notes.link, state.notes.problem].filter(Boolean).join(' ');
    const notice = $('notice');
    notice.textContent = shownText;
    notice.hidden = !shownText;
    notice.dataset.tone = state.notes.problem ? 'problem' : 'link';
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
    if (popover) drawPopover();
  }

  // What the chrome shows, for a windowless check to read.
  function dump() {
    const text = id => ($(id) && !$(id).hidden ? $(id).textContent : null);
    const bar = [...$('chips').querySelectorAll('[data-chip]')].map(node => ({ kind: node.dataset.chip, text: node.textContent, color: getComputedStyle(node).color }));
    const card = $('permission');
    return {
      status: text('status-text'), tone: $('status').dataset.tone, doing: text('status-doing'), elapsed: text('status-elapsed'), note: text('status-note'),
      chips: bar, title: document.title, notice: text('notice'), popover: popover && { kind: popover, text: $('popover').innerText },
      permission: card.hidden ? null : { request: card.dataset.request, text: card.innerText, disabled: [...card.querySelectorAll('button')].filter(node => node.disabled).map(node => node.dataset.decision) },
      tasks: [...$('tasks').querySelectorAll('.task')].map(node => ({ text: node.textContent, state: node.dataset.state, current: node.classList.contains('current') })),
      groups: [...$('tasks').querySelectorAll('.group')].map(node => node.textContent),
    };
  }

  function close(event) {
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
    if (event.key !== 'Escape' || !popover) return;
    event.preventDefault();
    event.stopPropagation();
    popover = null;
    drawPopover();
  }, true);
  window.vcxChrome = { dump, setClock: next => { clock = next; drawStatus(); } };
  draw();
})();
