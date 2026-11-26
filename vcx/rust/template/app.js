'use strict';
(() => {
  const CONTRACT = 1;
  // New content keeps the view pinned to the end only when the reader was already this close to it.
  const PINNED_DISTANCE_PX = 48;
  // How long a code block's copy button shows its check mark, as in the Swift `CodeBlock`.
  const COPIED_MS = 5000;

  const $ = id => document.getElementById(id);
  // Every message also goes out as a DOM event, which a windowless test listens to: window.ipc cannot be wrapped.
  const post = message => {
    document.dispatchEvent(new CustomEvent('vcx:post', { detail: message }));
    window.ipc.postMessage(JSON.stringify(message));
  };
  const transcript = $('transcript');
  const list = $('rows');
  const rows = new Map();
  const unfolded = new Set();
  let meta = {};

  function make(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // A fold remembers that the reader opened it, so a redraw of its row does not close it.
  function fold(key, className, ...title) {
    const details = make('details', className);
    details.open = unfolded.has(key);
    details.addEventListener('toggle', () => (details.open ? unfolded.add(key) : unfolded.delete(key)));
    const summary = make('summary');
    summary.append(...title);
    details.append(summary);
    return details;
  }

  // A question longer than this many lines shows folded behind its arrow, as the Swift bubble does.
  const FOLDED_QUESTION_LINES = 15;
  const CLOCK_MS = 1000;
  const SECONDS_PER_MINUTE = 60;
  // The Swift `debateColor`: each model keeps its colour in every round.
  const SPEAKER_COLORS = { claude: '199, 97, 56', codex: '10, 122, 102', qwen: '51, 97, 209', agy: '133, 77, 199', gemini: '209, 64, 128' };
  const data = new Map();
  const clocks = new Set();
  const sectionNodes = new Map();
  // The HTML each answer and each of its blocks was drawn from: chart.js may restyle a block, its source stays.
  const sources = new WeakMap();
  let drawing = null;
  let ids = [];
  let clockTimer = 0;

  function userItem(item) {
    const bubble = make('div', item.from ? 'bubble from-agent' : 'bubble');
    if (item.queued) bubble.classList.add('queued');
    if (item.from) bubble.append(make('span', 'from', `from ${item.from}`));
    const message = make('div', 'message');
    message.dataset.find = item.id;
    for (const part of item.content || [{ type: 'text', text: item.text || '' }]) {
      message.append(part.type === 'pictures' ? pictures(part.pictures) : part.text);
    }
    bubble.append(message);
    if ((item.text || '').split('\n').length > FOLDED_QUESTION_LINES) {
      bubble.classList.add('long');
      bubble.dataset.fold = item.id;
      bubble.classList.toggle('open', unfolded.has(item.id));
      const arrow = make('button', 'unfold');
      arrow.type = 'button';
      arrow.setAttribute('aria-label', 'Show the whole message');
      bubble.append(arrow);
    }
    if (item.recalled) {
      const recall = fold(`${item.id}:recalled`, 'recalled', String(item.recalled.length));
      recall.title = 'ERRORS lines VCX added to this prompt';
      recall.append(make('p', 'recall-head', 'ERRORS lines VCX added'), ...item.recalled.map(line => make('p', 'recall-line', line)));
      bubble.append(recall);
    }
    const column = make('div', 'question');
    column.append(bubble);
    if (item.queued) column.append(queuedHint());
    return column;
  }

  function queuedHint() {
    const hint = make('p', 'unread', 'Not read yet');
    hint.append(make('kbd', '', '↑'), ' edit', make('kbd', '', '⇧'), make('kbd', '', '↩'), ' send now');
    return hint;
  }

  function pictures(list) {
    const strip = make('span', 'pictures');
    for (const picture of list) {
      const button = make('button', 'picture');
      button.type = 'button';
      if (picture.src) {
        button.dataset.src = picture.src;
        const image = make('img');
        image.alt = picture.title;
        // A file gone since it was pasted shows the placeholder, as in the Swift `PictureView`.
        image.addEventListener('error', () => image.replaceWith(make('span', 'missing', '?')), { once: true });
        image.src = picture.src;
        button.append(image);
      } else {
        button.append(make('span', 'missing', '?'));
      }
      const words = make('span', 'words');
      words.append(make('span', 'name', picture.title), make('span', 'hint', 'Click to preview'));
      button.append(words);
      strip.append(button);
    }
    return strip;
  }

  // A streamed answer is redrawn in place: its unchanged blocks stay, so a chart frame in it is not loaded again.
  function answerItem(item) {
    const kept = drawing && [...drawing.children].find(child => child.classList.contains('answer-item') && child.dataset.item === item.id);
    const block = kept || make('div', 'answer-item');
    const label = `✦ ${item.provider || meta.providerLabel || 'Assistant'}`;
    if (!kept) {
      block.dataset.item = item.id;
      const prose = make('div', 'prose');
      prose.dataset.find = item.id;
      block.append(make('p', 'label', label), prose);
    } else if (block.firstChild.textContent !== label) {
      block.firstChild.textContent = label;
    }
    morph(block.lastChild, item.html);
    return block;
  }

  // Moving a frame reloads it: the blocks that did not change are left where they are, the others come and go around them.
  function morph(prose, html) {
    if (sources.get(prose) === html) return;
    sources.set(prose, html);
    const fresh = document.createElement('template');
    fresh.innerHTML = html;
    const old = [...prose.childNodes];
    const next = [...fresh.content.childNodes].map((node, index) => {
      const was = old[index];
      const same = was && was.nodeType === node.nodeType && (node.nodeType === Node.ELEMENT_NODE ? sources.get(was) === node.outerHTML : was.data === node.data);
      if (!same && node.nodeType === Node.ELEMENT_NODE) sources.set(node, node.outerHTML);
      return same ? was : node;
    });
    const keep = new Set(next);
    for (const node of old) if (!keep.has(node)) node.remove();
    let cursor = prose.firstChild;
    for (const node of next) {
      if (node === cursor) cursor = cursor.nextSibling;
      else prose.insertBefore(node, cursor);
    }
  }

  function minutes(seconds) {
    const whole = Math.max(0, Math.floor(seconds));
    return `${Math.floor(whole / SECONDS_PER_MINUTE)}:${String(whole % SECONDS_PER_MINUTE).padStart(2, '0')}`;
  }

  function tick() {
    const now = Date.now() / CLOCK_MS;
    for (const clock of clocks) {
      if (clock.isConnected) clock.textContent = minutes(now - Number(clock.dataset.since));
      else clocks.delete(clock);
    }
    if (!clocks.size) {
      clearInterval(clockTimer);
      clockTimer = 0;
    }
  }

  function actionItem(item) {
    const action = fold(item.id, item.failed ? 'action failed' : 'action', make('span', 'icon'), make('span', 'title', item.title || item.type));
    if (item.startedAt) {
      const clock = make('span', 'clock', minutes(Date.now() / CLOCK_MS - item.startedAt));
      clock.dataset.since = item.startedAt;
      clocks.add(clock);
      action.firstChild.append(clock);
      if (!clockTimer) clockTimer = setInterval(tick, CLOCK_MS);
    } else if (typeof item.seconds === 'number') {
      action.firstChild.append(make('span', 'clock', minutes(item.seconds)));
    }
    if (item.command) action.append(make('pre', 'command', item.command));
    if (item.output) action.append(make('pre', 'output', item.output));
    return action;
  }

  function speakerName(turn) {
    if (turn.speaker === 'claude') return meta.modelLabel || 'Claude';
    return turn.speaker.charAt(0).toUpperCase() + turn.speaker.slice(1) + (turn.model ? ` ${turn.model}` : '');
  }

  function turnBubble(speaker, name, right, body) {
    const turn = make('div', right ? 'turn-bubble right' : 'turn-bubble');
    turn.dataset.speaker = speaker;
    if (SPEAKER_COLORS[speaker]) turn.style.setProperty('--speaker', SPEAKER_COLORS[speaker]);
    turn.append(make('span', 'speaker', name), body);
    return turn;
  }

  function debateItem(item) {
    const debate = make('div', 'debate');
    const turns = item.turns || [];
    turns.forEach((turn, index) => {
      const prose = make('div', 'prose');
      prose.innerHTML = turn.html;
      debate.append(turnBubble(turn.speaker, speakerName(turn), index === 0, prose));
    });
    if (!turns.length) {
      const asked = (item.command || item.title || '').includes('ask-qwen') ? 'Qwen' : 'Codex';
      const text = item.status === 'inProgress' ? `Asking ${asked}…` : item.failed ? `The round failed: ${item.title}` : item.title;
      debate.append(turnBubble('claude', meta.modelLabel || 'Claude', true, make('p', 'waiting', text)));
    }
    return debate;
  }

  function noticeItem(item) {
    const notice = make('div', 'notice-line');
    notice.append(make('p', 'notice-text', item.text));
    if (item.link) {
      const link = make('a', 'notice-link', item.link.label);
      link.href = item.link.path;
      notice.append(link);
    }
    return notice;
  }

  function peerItem(item) {
    const first = (item.text || '').split('\n')[0];
    const peer = make('p', item.failed ? 'peer-line failed' : 'peer-line', item.title + (first ? ` · ${first}` : ''));
    peer.dataset.direction = item.direction || 'received';
    peer.title = item.text || '';
    return peer;
  }

  function content(row) {
    const items = row.items;
    switch (row.kind) {
      case 'user': return items.map(userItem);
      case 'assistant': return items.filter(item => item.type === 'agentMessage').map(answerItem);
      case 'debate': return items.slice(0, 1).map(debateItem);
      case 'notice': return items.map(noticeItem);
      case 'peer': return items.map(peerItem);
      default: return items.map(item => (item.type === 'agentMessage' ? answerItem(item) : actionItem(item)));
    }
  }

  function draw(row) {
    let node = rows.get(row.id);
    if (!node) {
      node = make('div', 'row enter');
      node.dataset.row = row.id;
      rows.set(row.id, node);
    }
    data.set(row.id, row);
    node.dataset.kind = row.kind;
    drawing = node;
    place(node, content(row));
    drawing = null;
    return node;
  }

  function heads(row) {
    return row.kind === 'user' || (row.kind === 'peer' && row.items[0] && row.items[0].direction === 'received');
  }

  // The Swift `conversationSections`: a question, or a message from another session, opens a section.
  function sections() {
    const found = [];
    let current = null;
    for (const id of ids) {
      const row = data.get(id);
      if (!row) continue;
      if (!current || heads(row)) {
        current = { id, question: heads(row) ? row : null, rows: [] };
        found.push(current);
        if (current.question) continue;
      }
      current.rows.push(row);
    }
    return found;
  }

  // The Swift `sectionParts`: the last assistant message answers, earlier ones are notes, tool activity folds into one block.
  function parts(sectionRows) {
    let last = -1;
    sectionRows.forEach((row, index) => { if (row.kind === 'assistant') last = index; });
    const part = { trail: [], debates: [], notes: [], last: last >= 0 ? sectionRows[last] : null, sent: [], notices: [] };
    sectionRows.forEach((row, index) => {
      if (index === last) return;
      if (row.kind === 'assistant') part.notes.push(row);
      else if (row.kind === 'debate') part.debates.push(row);
      else if (row.kind === 'peer') part.sent.push(row);
      else if (row.kind === 'notice') part.notices.push(row);
      else part.trail.push(row);
    });
    return part;
  }

  function ended(row) {
    return row.items.some(item => item.endedTurn);
  }

  function sectionNode(id) {
    let node = sectionNodes.get(id);
    if (!node) {
      node = make('section', 'turn');
      node.dataset.section = id;
      sectionNodes.set(id, node);
    }
    return node;
  }

  function counted(count, one, many) {
    return count ? `${count} ${count === 1 ? one : many}` : '';
  }

  // The Swift `WorkBlock`: one fold for a section's actions, opened by hovering its arrow and kept open by a click.
  function workBlock(key, blockRows, className) {
    const actions = blockRows.filter(row => row.kind !== 'peer').reduce((sum, row) => sum + row.items.length, 0);
    const sent = blockRows.filter(row => row.kind === 'peer').length;
    let block = sectionNodes.get(key);
    if (!block) {
      block = fold(key, `work ${className}`, make('span', 'chevron'), make('span', 'count'));
      block.dataset.work = key;
      hoverOpens(block);
      sectionNodes.set(key, block);
    }
    const count = block.querySelector('.count');
    const words = [counted(actions, 'action', 'actions'), counted(sent, 'message sent', 'messages sent')].filter(Boolean).join(' · ');
    // Rewriting an unchanged count would lay out every section again on each streamed patch.
    if (count.textContent !== words) count.textContent = words;
    place(block, [block.firstElementChild, ...blockRows.map(row => rows.get(row.id))]);
    return block;
  }

  function hoverOpens(block) {
    const summary = block.firstElementChild;
    summary.firstElementChild.addEventListener('pointerenter', () => {
      if (block.open) return;
      block.dataset.hovered = 'true';
      block.open = true;
    });
    block.addEventListener('pointerleave', () => {
      if (block.dataset.hovered !== 'true') return;
      delete block.dataset.hovered;
      block.open = false;
    });
    // Opened by the hover, a click keeps it open instead of shutting it.
    summary.addEventListener('click', event => {
      if (block.dataset.hovered !== 'true') return;
      event.preventDefault();
      delete block.dataset.hovered;
    });
  }

  // Moves only the nodes out of place: a patch that adds one row moves one node, not the thread.
  function place(parent, children) {
    let cursor = parent.firstElementChild;
    for (const child of children) {
      if (child === cursor) cursor = cursor.nextElementSibling;
      else parent.insertBefore(child, cursor);
    }
    while (cursor) {
      const next = cursor.nextElementSibling;
      cursor.remove();
      cursor = next;
    }
  }

  function sectionChildren(section, working, kept) {
    const part = parts(section.rows);
    const children = [];
    if (section.question) {
      const question = rows.get(section.question.id);
      question.classList.toggle('heading', true);
      children.push(question);
    }
    if (part.trail.length) {
      kept.add(`work:${section.id}`);
      children.push(workBlock(`work:${section.id}`, part.trail, 'trail'));
    }
    children.push(...part.debates.map(row => rows.get(row.id)));
    const spoken = part.last ? [...part.notes, part.last] : part.notes;
    spoken.forEach((row, at) => {
      const node = rows.get(row.id);
      const final = row === part.last;
      node.classList.toggle('lead', at === 0);
      node.classList.toggle('final', final);
      node.classList.toggle('thought', final ? working && !ended(row) : !ended(row));
      children.push(node);
    });
    if (part.sent.length) {
      kept.add(`sent:${section.id}`);
      children.push(workBlock(`sent:${section.id}`, part.sent, 'sent'));
    }
    children.push(...part.notices.map(row => rows.get(row.id)));
    return children;
  }

  function arrange() {
    const all = sections();
    const kept = new Set();
    const nodes = all.map((section, index) => {
      const node = sectionNode(section.id);
      kept.add(section.id);
      place(node, sectionChildren(section, Boolean(meta.busy) && index === all.length - 1, kept));
      return node;
    });
    for (const key of [...sectionNodes.keys()]) if (!kept.has(key)) sectionNodes.delete(key);
    place(list, nodes);
  }

  function order(next) {
    ids = next;
    const known = new Set(next);
    for (const id of [...rows.keys()]) {
      if (known.has(id)) continue;
      rows.delete(id);
      data.delete(id);
    }
  }

  // The status line, the title, the chips and the notice are chrome.js's: the rows only need the metadata.
  function describe(next) {
    meta = next;
  }

  function apply(message) {
    if (window.composer) composer.receive(message);
    if (message.type === 'full') {
      rows.clear();
      data.clear();
      sectionNodes.clear();
      describe(message.meta);
      for (const row of message.rows) draw(row);
      order(message.rows.map(row => row.id));
      arrange();
    } else if (message.type === 'patch') {
      const fresh = (message.rows || []).filter(row => !rows.has(row.id)).map(row => row.id);
      const label = meta.modelLabel;
      for (const row of message.rows || []) draw(row);
      order(message.order || ids.concat(fresh));
      if (message.meta) describe(message.meta);
      // A debate names this session's own turns after its model.
      if (meta.modelLabel !== label) for (const row of data.values()) if (row.kind === 'debate') draw(row);
      arrange();
    }
  }

  // Applied at once, with no requestAnimationFrame: a window that is hidden or covered gets no frames.
  function receive(message) {
    const pinned = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < PINNED_DISTANCE_PX;
    apply(message);
    $('empty').hidden = rows.size > 0;
    if (window.vcxFind) vcxFind.refresh();
    if (window.vcxQuestions) vcxQuestions.receive(message, meta);
    if (pinned) transcript.scrollTop = transcript.scrollHeight;
    post({ type: 'rendered', serial: message.serial });
  }

  // One edit, one `restyled`: the core counts edits, so the page answers once every sheet has loaded again.
  function restyle(version) {
    const loads = [...document.querySelectorAll('link[rel="stylesheet"]')].map(link => new Promise(done => {
      link.addEventListener('load', done, { once: true });
      link.addEventListener('error', done, { once: true });
      link.href = `${link.href.split('?')[0]}?v=${version}`;
    }));
    Promise.all(loads).then(() => post({ type: 'restyled', version }));
  }

  function copyCode(button) {
    const figure = button.closest('figure.code');
    const code = figure.querySelector('pre.source code') || figure.querySelector('pre code');
    post({ type: 'copy', text: code.textContent });
    button.classList.add('copied');
    clearTimeout(button.copiedTimer);
    button.copiedTimer = setTimeout(() => button.classList.remove('copied'), COPIED_MS);
  }

  // ---- Effect: zoom and blur popup. Copy from here ----
  // Opens or closes the popup and its veil on one clock and one curve. Opening, the popup settles from `from` % of its
  // size to 100 %, unblurring `blur` px and fading in from 0, in `dur` ms on a slow-start curve (an ease-out jumped to
  // 20-45 % opacity in two frames). Closing, it grows back, blurs and fades in `out` ms, speeding up as it goes.
  async function zoomPop(pop, veil, open, { dur = 400, out = 250, from = 108, blur = 8 } = {}) {
    const shut = { opacity: 0, scale: from / 100, filter: `blur(${blur}px)` }, shown = { opacity: 1, scale: 1, filter: 'blur(0)' };
    const way = { duration: open ? dur : out, easing: open ? 'cubic-bezier(.4,0,.2,1)' : 'cubic-bezier(.4,0,1,1)', fill: 'both' };
    pop.classList.add('open');
    veil.classList.add('open');
    const moves = [veil.animate({ opacity: open ? [0, 1] : [1, 0] }, way), pop.animate(open ? [shut, shown] : [shown, shut], way)];
    // Held for the popup's first paint (its backdrop blur and content), else that paint eats the start of the zoom.
    if (open) { moves.forEach(m => m.pause()); await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); moves.forEach(m => m.play()); }
    await Promise.all(moves.map(m => m.finished));
    if (!open) { pop.classList.remove('open'); veil.classList.remove('open'); }
    moves.forEach(m => m.cancel());
  }
  // ---- End of effect ----

  function preview(source) {
    const overlay = $('preview');
    overlay.querySelector('img').src = source;
    overlay.hidden = false;
    zoomPop(overlay.querySelector('.glass'), overlay.querySelector('.veil'), true);
  }

  // Hidden once the popup has shrunk away, so a click during the close does not reach the transcript under it.
  function closePreview() {
    const overlay = $('preview');
    if (overlay.closing) return;
    overlay.closing = zoomPop(overlay.querySelector('.glass'), overlay.querySelector('.veil'), false).then(() => {
      overlay.hidden = true;
      overlay.closing = null;
    });
  }

  document.addEventListener('click', event => {
    const link = event.target.closest('a[href]');
    const copy = event.target.closest('figure.code button.copy');
    const picture = event.target.closest('button.picture[data-src]');
    const unfold = event.target.closest('.bubble.long .unfold');
    if (link) {
      event.preventDefault();
      post({ type: 'open', href: link.getAttribute('href') });
    } else if (copy) {
      copyCode(copy);
    } else if (picture) {
      preview(picture.dataset.src);
    } else if (unfold) {
      const bubble = unfold.closest('.bubble');
      bubble.classList.toggle('open');
      if (bubble.classList.contains('open')) unfolded.add(bubble.dataset.fold);
      else unfolded.delete(bubble.dataset.fold);
    } else if (event.target.closest('#preview')) {
      closePreview();
    } else if (event.target.closest('#latest')) {
      transcript.scrollTop = transcript.scrollHeight;
    }
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !$('preview').hidden) {
      event.preventDefault();
      closePreview();
    }
  }, true);
  // Back to latest shows once the reader has scrolled away from the end.
  transcript.addEventListener('scroll', () => {
    $('latest').hidden = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < PINNED_DISTANCE_PX;
  }, { passive: true });

  window.vcx = { receive, restyle, post };
  post({ type: 'ready', contract: CONTRACT });
})();
