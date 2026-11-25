'use strict';
(() => {
  const CONTRACT = 1;
  // New content keeps the view pinned to the end only when the reader was already this close to it.
  const PINNED_DISTANCE_PX = 48;
  const INPUT_MAX_HEIGHT_PX = 220;

  const $ = id => document.getElementById(id);
  const post = message => window.ipc.postMessage(JSON.stringify(message));
  const transcript = $('transcript');
  const list = $('rows');
  const input = $('input');
  const rows = new Map();
  const unfolded = new Set();
  const notes = { link: '', problem: '' };
  let meta = {};

  function make(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // A fold remembers that the reader opened it, so a redraw of its row does not close it.
  function fold(key, className, title) {
    const details = make('details', className);
    details.open = unfolded.has(key);
    details.addEventListener('toggle', () => (details.open ? unfolded.add(key) : unfolded.delete(key)));
    details.append(make('summary', '', title));
    return details;
  }

  function userItem(item) {
    const bubble = make('div', item.queued ? 'bubble queued' : 'bubble');
    for (const path of item.images || []) bubble.append(make('span', 'attachment', path.split('/').pop()));
    bubble.append(item.text || '');
    return bubble;
  }

  function answerItem(item) {
    const block = make('div');
    block.append(make('p', 'label', `✦ ${item.provider || meta.providerLabel || 'Assistant'}`));
    const prose = make('div', 'prose');
    prose.innerHTML = item.html;
    block.append(prose);
    return block;
  }

  function toolItem(item) {
    const tool = fold(item.id, item.failed ? 'tool failed' : 'tool', item.title || item.type);
    if (item.output) tool.append(make('pre', '', item.output));
    return tool;
  }

  function activity(row) {
    const title = row.items.length === 1 ? row.items[0].title || row.items[0].type : `${row.items.length} actions`;
    const group = fold(row.id, 'activity', title);
    group.append(...row.items.map(toolItem));
    return group;
  }

  function content(row) {
    if (row.kind === 'activity') return [activity(row)];
    return row.items.map(item => {
      if (item.type === 'userMessage') return userItem(item);
      if (item.type === 'agentMessage') return answerItem(item);
      if (row.kind === 'notice') return make('span', '', item.text);
      return toolItem(item);
    });
  }

  function draw(row) {
    let node = rows.get(row.id);
    if (!node) {
      node = make('div', 'row enter');
      node.dataset.row = row.id;
      rows.set(row.id, node);
    }
    node.dataset.kind = row.kind;
    node.replaceChildren(...content(row));
    return node;
  }

  function order(ids) {
    const kept = new Set(ids);
    for (const [id, node] of rows) {
      if (kept.has(id)) continue;
      node.remove();
      rows.delete(id);
    }
    let cursor = list.firstElementChild;
    for (const id of ids) {
      const node = rows.get(id);
      if (!node) continue;
      if (node === cursor) cursor = cursor.nextElementSibling;
      else list.insertBefore(node, cursor);
    }
  }

  function chip(kind, text) {
    return text ? [make('span', `chip ${kind}`, text)] : [];
  }

  function percent(part, whole) {
    return whole > 0 ? `${Math.round((100 * part) / whole)}% context` : '';
  }

  function describe(next) {
    meta = next;
    const state = meta.needsAttention ? 'attention' : meta.busy ? 'busy' : meta.ready ? 'ready' : '';
    $('dot').className = state;
    $('status-text').textContent = meta.status || (meta.busy ? 'Working' : meta.ready ? 'Ready' : 'Starting');
    $('stop').hidden = !meta.busy;
    document.title = meta.conversationName || 'VCX';
    $('chips').replaceChildren(
      ...chip('project', (meta.cwd || '').split('/').filter(Boolean).pop()),
      ...chip('model', [meta.model, meta.effort].filter(Boolean).join(' · ')),
      ...chip('mode', meta.activeMode),
      ...chip('context', percent(meta.contextUsed, meta.contextLimit)),
      ...chip('usage', typeof meta.usagePercent === 'number' ? `${Math.round(meta.usagePercent)}% used` : ''),
      ...chip('branch', meta.branch),
    );
  }

  // The connection's state and the last problem are told apart, so one clearing does not hide the other.
  function note(slot, text) {
    notes[slot] = text || '';
    const shown = [notes.link, notes.problem].filter(Boolean).join(' ');
    $('notice').textContent = shown;
    $('notice').hidden = !shown;
  }

  function apply(message) {
    if (message.type === 'full') {
      order([]);
      describe(message.meta);
      for (const row of message.rows) list.append(draw(row));
    } else if (message.type === 'patch') {
      const fresh = (message.rows || []).filter(row => !rows.has(row.id)).map(row => row.id);
      for (const row of message.rows || []) draw(row);
      order(message.order || [...rows.keys()].filter(id => rows.get(id).isConnected).concat(fresh));
      if (message.meta) describe(message.meta);
    } else if (message.type === 'link') {
      note('link', message.state === 'connected' ? '' : message.detail);
    } else if (message.type === 'notice') {
      note('problem', message.text);
    }
  }

  // Applied at once, with no requestAnimationFrame: a window that is hidden or covered gets no frames.
  function receive(message) {
    const pinned = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < PINNED_DISTANCE_PX;
    apply(message);
    $('empty').hidden = rows.size > 0;
    if (pinned) transcript.scrollTop = transcript.scrollHeight;
    post({ type: 'rendered', serial: message.serial });
  }

  function restyle(version) {
    for (const link of document.querySelectorAll('link[rel="stylesheet"]')) {
      link.href = `${link.href.split('?')[0]}?v=${version}`;
    }
  }

  function grow() {
    input.style.height = 'auto';
    input.style.height = `${Math.min(input.scrollHeight, INPUT_MAX_HEIGHT_PX)}px`;
  }

  function submit() {
    const text = input.value.trim();
    if (!text) return;
    post({ type: 'send', text });
    note('problem', '');
    input.value = '';
    grow();
  }

  $('composer').addEventListener('submit', event => {
    event.preventDefault();
    submit();
  });
  input.addEventListener('input', grow);
  input.addEventListener('keydown', event => {
    // Enter while an input method composes a character confirms the character, it does not send.
    if (event.key !== 'Enter' || event.shiftKey || event.isComposing) return;
    event.preventDefault();
    submit();
  });
  $('stop').addEventListener('click', () => post({ type: 'stop' }));
  document.addEventListener('click', event => {
    const link = event.target.closest('a[href]');
    if (!link) return;
    event.preventDefault();
    post({ type: 'open', href: link.getAttribute('href') });
  });

  window.vcx = { receive, restyle };
  post({ type: 'ready', contract: CONTRACT });
})();
