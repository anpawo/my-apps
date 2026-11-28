'use strict';
(() => {
  const CONTRACT = 1;
  // New content keeps the view pinned to the end only when the reader was already this close to it.
  const PINNED_DISTANCE_PX = 48;
  // A scroll this soon after the reader's wheel, scroll key or the page moving the view for him is his: only such a
  // scroll away from the end stops the following; one the page makes (a fold, a picture loading) never does.
  const READER_SCROLL_MS = 600;
  const SCROLL_KEYS = new Set(['PageUp', 'PageDown', 'ArrowUp', 'ArrowDown', 'Home', 'End', ' ']);
  // How long a code block's copy button shows its check mark, as in the Swift `CodeBlock`.
  const COPIED_MS = 5000;
  // Swift's tables: a column too wide for the room shares it with the other long ones, never narrower than this.
  const TABLE_COLUMN_FLOOR_PX = 320;
  // Swift's folds: the work block opens and shuts in 0.28 s, an action in 0.25 s; left while scrolled inside, the
  // transcript rises to the block's header in 0.3 s before it shuts.
  const WORK_GLIDE_MS = 280;
  const ACTION_GLIDE_MS = 250;
  const REVEAL_MS = 300;
  const GLIDE_EASING = 'cubic-bezier(0.4, 0, 0.2, 1)';
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

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
  // The Swift `/details`: every work block and action shown open until `/focus` folds them again.
  let detailsOn = false;
  // `sent`: a message just left the composer and its row is not drawn yet; `atEnd`: the reader is at the transcript's end.
  let sent = false;
  // Where the transcript ends, from the rows' own box: its scrollHeight also counts a bubble still gliding in from the
  // composer (composer.js), whose transform reaches below the rows, and scrolling there flung the bubble off the top.
  const endTop = () => {
    const box = $('rows').getBoundingClientRect(), view = transcript.getBoundingClientRect();
    return Math.max(0, box.bottom - view.top + transcript.scrollTop + parseFloat(getComputedStyle(transcript).paddingBottom) - transcript.clientHeight);
  };
  // Whether the transcript follows its end: true until the reader scrolls away from it, whatever the page measures in
  // a window that is hidden or covered and draws no frames, where nothing re-pins between two patches.
  let atEnd = true;
  let readerAt = -Infinity, held = false;
  const reader = () => held || performance.now() - readerAt < READER_SCROLL_MS;
  const DETAILED = /^(work|action)\b/;
  let meta = {};

  function make(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // A fold remembers that the reader opened it, so a redraw of its row does not close it. `opened` is where it is
  // going: a fold shutting stays open until its glide ends.
  function fold(key, className, ...title) {
    const details = make('details', className);
    details.open = unfolded.has(key) || (detailsOn && DETAILED.test(className));
    details.classList.toggle('opened', details.open);
    details.addEventListener('toggle', () => {
      if (!details.classList.contains('gliding')) details.classList.toggle('opened', details.open);
      if (details.classList.contains('opened')) unfolded.add(key);
      else unfolded.delete(key);
    });
    const summary = make('summary');
    summary.append(...title);
    details.append(summary);
    summary.addEventListener('click', event => {
      event.preventDefault();
      // Opened by the hover, a click keeps the work block open instead of shutting it.
      if (details.dataset.hovered === 'true') return void delete details.dataset.hovered;
      glide(details, !details.classList.contains('opened'));
    });
    return details;
  }

  // Opens or shuts a fold smoothly, its height and its content's opacity on one clock, as Swift's `.smooth`.
  function glide(details, open, done) {
    const ms = details.classList.contains('work') ? WORK_GLIDE_MS : details.classList.contains('recalled') ? QUESTION_GLIDE_MS : ACTION_GLIDE_MS;
    details.classList.toggle('opened', open);
    if (reducedMotion.matches || !details.isConnected) {
      details.open = open;
      if (done) done();
      return;
    }
    const from = details.getBoundingClientRect().height;
    details.getAnimations().forEach(motion => motion.cancel());
    details.classList.add('gliding');
    details.open = open;
    const to = details.getBoundingClientRect().height;
    details.open = true;
    const timing = { duration: ms, easing: GLIDE_EASING };
    for (const child of [...details.children].slice(1)) child.animate({ opacity: open ? [0, 1] : [1, 0] }, timing);
    details.animate({ height: [`${from}px`, `${to}px`] }, timing).onfinish = () => {
      details.classList.remove('gliding');
      details.open = open;
      if (done) done();
    };
  }

  // A question taller than this many lines shows only its first, behind its arrow, as the Swift bubble does.
  const FOLDED_QUESTION_LINES = 15.5;
  // Below this many characters on so few lines, a question cannot be that tall: it is not measured.
  const SHORT_QUESTION_CHARACTERS = 600;
  // The bubble opens in 0.3 s; it shuts 80 ms after the pointer leaves, once the pointer is surely gone.
  const QUESTION_GLIDE_MS = 300;
  const QUESTION_CLOSE_MS = 80;
  // Open and taller than this share of the transcript, the question scrolls inside its bubble.
  const QUESTION_CAP = 0.6;
  // Swift's thumbnail trims a screenshot's shadow: the picture is cut to its pixels at least this opaque.
  const OPAQUE_ALPHA = 230;
  const THUMBNAIL_PX = 360;
  const RECALL_NOTE_HEAD = "VCX note, not part of the request: past mistakes from Marius's ERRORS files that may apply to it.";
  const CHEVRON = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>';
  const SPARKLE = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2c.6 5.2 4.8 9.4 10 10-5.2.6-9.4 4.8-10 10-.6-5.2-4.8-9.4-10-10 5.2-.6 9.4-4.8 10-10z"/></svg>';
  const PHOTO = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="2.5"/><circle cx="9" cy="10" r="1.8"/><path d="m21 16-5-5-9 9"/></svg>';
  const EXPAND = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"/></svg>';
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
    const text = message.textContent;
    if (text.length > SHORT_QUESTION_CHARACTERS || text.split('\n').length > FOLDED_QUESTION_LINES) bubble.dataset.measure = 'true';
    const arrow = make('button', 'unfold');
    arrow.type = 'button';
    arrow.innerHTML = CHEVRON;
    arrow.setAttribute('aria-label', 'Show the whole message');
    bubble.append(arrow);
    if (item.recalled) {
      // No mark on the bubble: a click on it shows the note under the prompt, worded as the agent reads it.
      const recall = fold(`${item.id}:recalled`, 'recalled');
      recall.append(make('p', 'recall-note', recallNote(item.recalled)));
      bubble.classList.add('recall');
      bubble.append(recall);
    }
    const column = make('div', 'question');
    column.append(bubble);
    if (item.queued) column.append(queuedHint());
    return column;
  }

  // The worker's `recall::note`, which the prompt carries after a blank line.
  function recallNote(lines) {
    return [RECALL_NOTE_HEAD, ...lines.map(line => `- ${line}`)].join('\n');
  }

  function queuedHint() {
    const hint = make('p', 'unread', 'Not read yet');
    hint.append(make('kbd', 'apart', '↑'), 'edit', make('kbd', 'apart', '⇧'), make('kbd', '', '↩'), 'send now');
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
        image.addEventListener('error', () => image.replaceWith(missingPicture()), { once: true });
        image.addEventListener('load', () => trimShadow(image), { once: true });
        image.src = picture.src;
        button.append(image);
      } else {
        button.append(missingPicture());
      }
      const words = make('span', 'words');
      words.append(make('span', 'name', picture.title), make('span', 'hint', 'Click to preview'));
      const expand = make('span', 'expand');
      expand.innerHTML = EXPAND;
      button.append(words, expand);
      strip.append(button);
    }
    return strip;
  }

  function missingPicture() {
    const missing = make('span', 'missing');
    missing.innerHTML = PHOTO;
    return missing;
  }

  // A screenshot's transparent shadow margin is cut away, as Swift's `opaqueCrop`, so the card shows the window itself.
  function trimShadow(image) {
    const scale = Math.min(1, THUMBNAIL_PX / Math.max(image.naturalWidth, image.naturalHeight));
    const width = Math.max(1, Math.round(image.naturalWidth * scale)), height = Math.max(1, Math.round(image.naturalHeight * scale));
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext('2d', { willReadFrequently: true });
    context.drawImage(image, 0, 0, width, height);
    let pixels;
    try { pixels = context.getImageData(0, 0, width, height).data; } catch { return; }
    let left = width, right = -1, top = height, bottom = -1;
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        if (pixels[(y * width + x) * 4 + 3] < OPAQUE_ALPHA) continue;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
    if (right < 0 || (left === 0 && top === 0 && right === width - 1 && bottom === height - 1)) return;
    const crop = document.createElement('canvas');
    crop.width = right - left + 1;
    crop.height = bottom - top + 1;
    crop.getContext('2d').drawImage(canvas, left, top, crop.width, crop.height, 0, 0, crop.width, crop.height);
    image.src = crop.toDataURL();
  }

  // A streamed answer is redrawn in place: its unchanged blocks stay, so a chart frame in it is not loaded again.
  function answerItem(item) {
    const kept = drawing && [...drawing.children].find(child => child.classList.contains('answer-item') && child.dataset.item === item.id);
    const block = kept || make('div', 'answer-item');
    const label = item.provider || meta.providerLabel || 'Assistant';
    if (!kept) {
      block.dataset.item = item.id;
      const prose = make('div', 'prose');
      prose.dataset.find = item.id;
      const head = make('p', 'label');
      head.innerHTML = SPARKLE;
      head.append(make('span', 'provider', label));
      block.append(head, prose);
    } else if (block.firstChild.lastChild.textContent !== label) {
      block.firstChild.lastChild.textContent = label;
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
      const waiting = make('p', 'waiting');
      if (item.status === 'inProgress') waiting.append(make('span', 'spinner'));
      waiting.append(text);
      debate.append(turnBubble('claude', meta.modelLabel || 'Claude', true, waiting));
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

  // WebKit replays the pointer's last move after every scroll: a hover that comes with no move of its own is the
  // transcript sliding under a pointer at rest, as when it follows a streaming answer, not the reader pointing.
  let pointer = null;
  document.addEventListener('pointermove', event => { pointer = [event.clientX, event.clientY]; }, true);
  const resting = event => pointer !== null && pointer[0] === event.clientX && pointer[1] === event.clientY;

  function hoverOpens(block) {
    const summary = block.firstElementChild;
    summary.firstElementChild.addEventListener('pointerenter', event => {
      if (block.classList.contains('opened') || (atEnd && resting(event))) return;
      block.dataset.hovered = 'true';
      glide(block, true);
    });
    block.addEventListener('pointerleave', event => {
      if (block.dataset.hovered !== 'true') return;
      delete block.dataset.hovered;
      // Left by the answer streaming past the pointer: rising to its section would drop the end being followed.
      if (atEnd && resting(event)) return glide(block, false);
      // Scrolled inside it, the transcript rises to its section's top first, then it shuts: shut at once, the view
      // went blank under that offset until the scroll caught up.
      const section = block.closest('.turn') || block;
      const above = section.getBoundingClientRect().top - transcript.getBoundingClientRect().top - parseFloat(getComputedStyle(transcript).paddingTop);
      if (block.getBoundingClientRect().top >= transcript.getBoundingClientRect().top) return glide(block, false);
      readerAt = performance.now();
      if (reducedMotion.matches) {
        transcript.scrollTop += above;
        return glide(block, false);
      }
      transcript.scrollTo({ top: transcript.scrollTop + above, behavior: 'smooth' });
      setTimeout(() => { if (block.dataset.hovered !== 'true') glide(block, false); }, REVEAL_MS);
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
      // The answer being written is drawn as the answer: it turns into a thought only once later work makes it a note.
      node.classList.toggle('thought', !final && !ended(row));
      node.classList.toggle('settled', final && !working);
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
      // A question with no answer yet sits close above the next one, as Swift's.
      node.classList.toggle('unanswered', section.rows.length === 0 && index !== all.length - 1);
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
    // A draft saved as he types comes back as a patch with no rows: it must not pull a reader near the end down to it.
    const redraws = message.type === 'full' || Boolean(message.rows || message.order);
    const pinned = sent || (redraws && atEnd);
    const before = rows.size;
    apply(message);
    if (rows.size > before) sent = false;
    $('empty').hidden = rows.size > 0;
    if (window.vcxFind) vcxFind.refresh();
    if (window.vcxQuestions) vcxQuestions.receive(message, meta);
    for (const card of list.querySelectorAll('.prose .table:not([data-fitted])')) fitTable(card);
    measureQuestions();
    if (pinned) transcript.scrollTop = endTop();
    liftPinned();
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

  // Laid out at its natural width first: when that is wider than the room, its long columns keep at least the floor,
  // its short ones their whole width (else "Severity" wraps a letter a line), and the card scrolls sideways, as
  // Swift's `tableColumnWidths`.
  function fitTable(card) {
    card.dataset.fitted = 'true';
    const table = card.querySelector('table');
    const head = table && table.rows[0];
    if (!head) return;
    table.classList.add('measuring');
    const natural = [...head.cells].map(cell => cell.getBoundingClientRect().width);
    table.classList.remove('measuring');
    if (natural.reduce((sum, width) => sum + width, 0) <= card.clientWidth) return;
    [...head.cells].forEach((cell, index) => {
      cell.style.minWidth = `${Math.min(natural[index], TABLE_COLUMN_FLOOR_PX)}px`;
    });
  }

  // Read every height first, then fold: one layout for a whole thread.
  function measureQuestions() {
    const waiting = [...list.querySelectorAll('.bubble[data-measure]')];
    const line = parseFloat(getComputedStyle(transcript).lineHeight);
    const tall = waiting.map(bubble => bubble.querySelector('.message').scrollHeight > FOLDED_QUESTION_LINES * line);
    waiting.forEach((bubble, index) => {
      delete bubble.dataset.measure;
      bubble.classList.toggle('long', tall[index]);
    });
  }

  // Changes the question's height on one clock with its text, as Swift's `.smooth(duration: 0.3)`.
  function openQuestion(bubble, open) {
    clearTimeout(bubble.closing);
    if (bubble.classList.contains('open') === open) return;
    const message = bubble.querySelector('.message');
    const from = message.getBoundingClientRect().height;
    message.style.maxHeight = `${transcript.clientHeight * QUESTION_CAP}px`;
    bubble.classList.toggle('open', open);
    if (reducedMotion.matches) return;
    const to = message.getBoundingClientRect().height;
    message.animate({ height: [`${from}px`, `${to}px`] }, { duration: QUESTION_GLIDE_MS, easing: GLIDE_EASING });
  }

  // The stuck question (its section scrolled under it) casts a shadow that sets it above the transcript.
  let lifted = null;
  function liftPinned() {
    const view = transcript.getBoundingClientRect();
    const hit = document.elementFromPoint(list.getBoundingClientRect().left + 1, view.top + 1);
    const section = hit && hit.closest('.turn');
    const heading = section && section.querySelector(':scope > .row.heading');
    const stuck = heading && section.getBoundingClientRect().top < view.top - 1 ? heading : null;
    if (stuck === lifted) return;
    if (lifted) lifted.classList.remove('stuck');
    if (stuck) stuck.classList.add('stuck');
    lifted = stuck;
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
    // A close still running is dropped, or its end would hide the popup just opened.
    if (overlay.closing) overlay.getAnimations({ subtree: true }).forEach(motion => motion.cancel());
    overlay.closing = null;
    overlay.classList.remove('closing');
    overlay.hidden = false;
    zoomPop(overlay.querySelector('.glass'), overlay.querySelector('.veil'), true);
  }

  // The Swift `/preview`: the last picture of the conversation, false when there is none (the core says so).
  function previewLast() {
    const pictures = list.querySelectorAll('button.picture[data-src]');
    if (!pictures.length) return false;
    preview(pictures[pictures.length - 1].dataset.src);
    return true;
  }

  // Closing, it lets clicks through to the transcript, as Swift's: an image card clicked again during the fade opens it again.
  function closePreview() {
    const overlay = $('preview');
    if (overlay.closing) return;
    overlay.classList.add('closing');
    const closing = zoomPop(overlay.querySelector('.glass'), overlay.querySelector('.veil'), false).then(() => {
      if (overlay.closing !== closing) return;
      overlay.hidden = true;
      overlay.classList.remove('closing');
      overlay.closing = null;
    }, () => {});
    overlay.closing = closing;
  }

  document.addEventListener('click', event => {
    const link = event.target.closest('a[href]');
    // The whole header band copies, as Swift's: its other buttons (edit, run) keep their own clicks.
    const head = !event.target.closest('button:not(.copy)') && event.target.closest('figure.code > figcaption');
    const copy = head && head.querySelector('button.copy');
    const picture = event.target.closest('button.picture[data-src]');
    const shown = event.target.closest('.prose img[src^="vcx://image/"]');
    if (link) {
      event.preventDefault();
      post({ type: 'open', href: link.getAttribute('href') });
    } else if (copy) {
      copyCode(copy);
    } else if (picture) {
      preview(picture.dataset.src);
    } else if (shown) {
      preview(shown.getAttribute('src'));
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
    if (endTop() - transcript.scrollTop < PINNED_DISTANCE_PX) atEnd = true;
    else if (reader()) atEnd = false;
    $('latest').hidden = atEnd;
    liftPinned();
  }, { passive: true });
  transcript.addEventListener('wheel', () => { readerAt = performance.now(); }, { passive: true });
  transcript.addEventListener('pointerdown', () => { held = true; });
  document.addEventListener('pointerup', () => {
    if (held) readerAt = performance.now();
    held = false;
  }, true);
  document.addEventListener('keydown', event => {
    if (SCROLL_KEYS.has(event.key) && !event.target.closest?.('input, textarea, [contenteditable]')) readerAt = performance.now();
  }, true);
  // Find landing on a match, or a live update putting back where he had scrolled.
  document.addEventListener('vcx:reading', () => {
    atEnd = false;
    readerAt = performance.now();
  });
  // Only the arrow opens a long question: the pointer crossing it to read the answer leaves it shut. It shuts once the
  // pointer has left the bubble for good.
  list.addEventListener('pointerover', event => {
    const bubble = event.target.closest('.bubble.long');
    if (!bubble) return;
    clearTimeout(bubble.closing);
    if (event.target.closest('.unfold')) openQuestion(bubble, true);
  });
  list.addEventListener('click', event => {
    const bubble = event.target.closest('.bubble.recall');
    if (!bubble || event.target.closest('button, a') || getSelection().toString()) return;
    const recall = bubble.querySelector(':scope > .recalled');
    glide(recall, !recall.classList.contains('opened'));
  });
  list.addEventListener('pointerout', event => {
    const bubble = event.target.closest('.bubble.long.open');
    if (!bubble || bubble.contains(event.relatedTarget)) return;
    clearTimeout(bubble.closing);
    bubble.closing = setTimeout(() => openQuestion(bubble, false), QUESTION_CLOSE_MS);
  });
  // As the Swift window did: a sent message brings the transcript to its end and keeps it there until the message's row
  // is drawn, and while the reader is at the end it stays there as the transcript shrinks (the composer growing as he
  // types) or its rows grow after they are drawn (streamed text, pictures): no Back to latest for either.
  document.addEventListener('vcx:sent', () => {
    sent = true;
    atEnd = true;
    transcript.scrollTop = endTop();
  });
  const follow = new ResizeObserver(() => {
    if (atEnd) transcript.scrollTop = endTop();
  });
  follow.observe(transcript);
  follow.observe($('rows'));

  function toggleDetails() {
    detailsOn = !detailsOn;
    for (const fold of list.querySelectorAll('details.work, details.action')) {
      fold.getAnimations().forEach(motion => motion.cancel());
      fold.classList.remove('gliding');
      fold.open = detailsOn;
      fold.classList.toggle('opened', detailsOn);
    }
    return true;
  }

  window.vcx = { receive, restyle, post, previewLast, toggleDetails };
  // Read by the app before a live update, which turns details back on in the new page.
  Object.defineProperty(window.vcx, 'details', { get: () => detailsOn });
  post({ type: 'ready', contract: CONTRACT });
})();
