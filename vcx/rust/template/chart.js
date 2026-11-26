'use strict';
// The transcript page's side of chart frames. Each ```chart block is a sandboxed frame served from vcx://chart/<id>
// under its own CSP; this file hears the frames by postMessage, sizes them, relays vcx.live to the core (which fetches
// for them), and keeps one chart pinned above the chat and one enlarged over it.
(() => {
  const INLINE_MIN_PX = 40;
  const INLINE_MAX_PX = 900;
  const PINNED_MAX_PX = 280;
  const ENLARGED_SHARE = 0.85;
  const READ_WAIT_MS = 2000;
  // An unshown window runs no animation frame and may never finish an animation: the zoom goes on without them.
  const FRAME_WAIT_MS = 50;
  const SETTLE_MARGIN_MS = 100;
  const QUICK_MS = 100;

  const settled = (promise, ms) => Promise.race([promise, new Promise(done => setTimeout(done, ms))]);

  // ---- Effect: zoom and blur popup (WT-118), its two waits bounded for an unshown window ----
  async function zoomPop(pop, veil, open, { dur = 400, out = 250, from = 108, blur = 8 } = {}) {
    const shut = { opacity: 0, scale: from / 100, filter: `blur(${blur}px)` }, shown = { opacity: 1, scale: 1, filter: 'blur(0)' };
    const way = { duration: open ? dur : out, easing: open ? 'cubic-bezier(.4,0,.2,1)' : 'cubic-bezier(.4,0,1,1)', fill: 'both' };
    pop.classList.add('open');
    veil.classList.add('open');
    const moves = [veil.animate({ opacity: open ? [0, 1] : [1, 0] }, way), pop.animate(open ? [shut, shown] : [shown, shut], way)];
    // Held for the popup's first paint (its backdrop blur and content), else that paint eats the start of the zoom.
    if (open) { moves.forEach(m => m.pause()); await settled(new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))), FRAME_WAIT_MS); moves.forEach(m => m.play()); }
    await settled(Promise.all(moves.map(m => m.finished)), way.duration + SETTLE_MARGIN_MS);
    if (!open) { pop.classList.remove('open'); veil.classList.remove('open'); }
    moves.forEach(m => m.cancel());
  }
  // ---- End of effect ----

  const timing = () => matchMedia('(prefers-reduced-motion: reduce)').matches ? { dur: QUICK_MS, out: QUICK_MS } : {};
  const ICONS = {
    pin: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6 2h4l-.5 4 2.5 2.5V10H8.6L8 14l-.6-4H4V8.5L6.5 6z"/></svg>',
    enlarge: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M9.5 2H14v4.5M14 2l-5 5M6.5 14H2V9.5M2 14l5-5"/></svg>',
    close: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 3.5l9 9M12.5 3.5l-9 9"/></svg>',
  };
  const post = message => window.ipc.postMessage(JSON.stringify(message));
  const offered = new Set();
  const reads = new Map();
  let frames = 0, reading = 0, pinned = null;

  const make = (tag, className) => Object.assign(document.createElement(tag), { className });
  const frameOf = source => [...document.querySelectorAll('.chart iframe')].find(frame => frame.contentWindow === source);
  const key = frame => Number(frame.dataset.frame ||= String(++frames));
  const blockOf = frame => frame.closest('.chart');
  const view = frame => (blockOf(frame)?.classList.contains('pinned') ? 'pinned' : blockOf(frame)?.closest('.chart-zoom') ? 'enlarged' : 'inline');

  function frame(id, mode) {
    const element = document.createElement('iframe');
    element.setAttribute('sandbox', 'allow-scripts');
    element.title = 'Chart';
    element.src = `vcx://chart/${id}?view=${mode}`;
    return element;
  }

  function button(icon, label, action) {
    const element = make('button', `chart-button ${icon}`);
    element.type = 'button';
    element.title = label;
    element.setAttribute('aria-label', label);
    element.innerHTML = ICONS[icon];
    element.addEventListener('click', event => { event.stopPropagation(); action() });
    return element;
  }

  function decorate(block) {
    if (block.querySelector(':scope > .chart-buttons')) return;
    const id = block.dataset.chart;
    const bar = make('div', 'chart-buttons');
    const pin = button('pin', '', () => toggle(id));
    bar.append(pin, ...(block.closest('.chart-zoom') ? [] : [button('enlarge', 'Enlarge the chart', () => enlarge(id, block))]));
    block.append(bar);
    label(block);
  }

  function label(block) {
    const pin = block.querySelector(':scope > .chart-buttons .pin');
    if (!pin) return;
    const on = pinned === block.dataset.chart;
    pin.classList.toggle('on', on);
    pin.title = on ? 'Unpin the chart' : 'Pin the chart above the chat';
    pin.setAttribute('aria-label', pin.title);
  }

  function strip() {
    let element = document.getElementById('chart-pin');
    if (!element) {
      element = make('div', '');
      element.id = 'chart-pin';
      element.hidden = true;
      const transcript = document.getElementById('transcript');
      // First in the scrolling transcript and sticky, so it holds the top of the chat whatever lays out the window.
      transcript ? transcript.prepend(element) : document.body.prepend(element);
    }
    return element;
  }

  // One chart per chat stays above the transcript, live; the same chart pinned again comes off (the pin() of the
  // WT-119 template, the block a frame).
  function toggle(id) {
    pinned = pinned === id ? null : id;
    const area = strip();
    area.replaceChildren();
    area.hidden = !pinned;
    if (pinned) {
      const block = make('div', 'chart pinned');
      block.dataset.chart = pinned;
      block.append(frame(pinned, 'pinned'));
      area.append(block);
      decorate(block);
    }
    document.querySelectorAll('.chart').forEach(label);
  }

  function enlarge(id, from) {
    close();
    const overlay = make('div', '');
    overlay.id = 'chart-zoom';
    overlay.className = 'chart-zoom';
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.setAttribute('aria-label', 'Enlarged chart');
    const veil = make('div', 'veil');
    veil.addEventListener('click', close);
    const block = make('div', 'chart enlarged glass');
    block.dataset.chart = id;
    const element = frame(id, 'enlarged');
    const known = from?.querySelector('iframe')?.dataset.height;
    if (known) element.style.height = `${Math.min(Number(known), innerHeight * ENLARGED_SHARE)}px`;
    block.append(element, button('close', 'Close the chart', close));
    overlay.append(veil, block);
    document.body.append(overlay);
    decorate(block);
    zoomPop(block, veil, true, timing());
  }

  // The overlay gives up its id at once, so a chart enlarged while it zooms out opens a new one.
  function close() {
    const overlay = document.getElementById('chart-zoom');
    if (!overlay) return;
    overlay.id = '';
    overlay.classList.add('closing');
    zoomPop(overlay.querySelector('.chart'), overlay.querySelector('.veil'), false, timing()).then(() => overlay.remove());
  }

  function size(element, height) {
    element.dataset.height = String(height);
    const mode = view(element);
    const shown = mode === 'pinned' ? Math.min(height, PINNED_MAX_PX) : mode === 'enlarged' ? Math.min(height, innerHeight * ENLARGED_SHARE) : Math.min(Math.max(height, INLINE_MIN_PX), INLINE_MAX_PX);
    element.style.height = `${shown}px`;
    if (mode === 'pinned') document.documentElement.style.setProperty('--chart-pin-height', `${strip().offsetHeight}px`);
  }

  function heard(event) {
    const element = frameOf(event.source);
    const message = event.data;
    if (!element || typeof message !== 'object' || !message || typeof message.vcx !== 'string') return;
    const id = blockOf(element)?.dataset.chart;
    switch (message.vcx) {
      // A frame that loads again starts its feeds again: the ones of its earlier page stop.
      case 'hello': post({ type: 'chartStop', frame: key(element) }); element.dataset.heard = 'yes'; break;
      case 'size': if (Number.isFinite(message.height)) size(element, message.height); break;
      case 'live': post({ type: 'chartLive', frame: key(element), id: Number(message.id), url: String(message.url), seconds: Number(message.seconds) }); break;
      case 'pin': if (id) toggle(id); break;
      case 'enlarge': if (id) enlarge(id, blockOf(element)); break;
      case 'escape': close(); break;
      case 'read': {
        const done = reads.get(message.id);
        if (!done) break;
        reads.delete(message.id);
        const at = element.getBoundingClientRect();
        done({ items: (message.items || []).map(item => ({ ...item, box: [item.box[0] + at.x, item.box[1] + at.y, item.box[2], item.box[3]].map(Math.round) })), data: message.data || {} });
        break;
      }
    }
  }

  // The core's answer to vcx.live: handed to the frame that asked, or the feed stops when that frame is gone.
  function push(number, id, body) {
    const element = document.querySelector(`.chart iframe[data-frame="${number}"]`);
    if (!element?.isConnected) return post({ type: 'chartStop', frame: number });
    element.contentWindow.postMessage({ vcx: 'push', id, body }, '*');
  }

  // What a frame drew, its text and boxes in page coordinates, for checks: the frame answers its parent only.
  function read(element, selector) {
    const id = ++reading;
    return new Promise((done, fail) => {
      reads.set(id, done);
      element.contentWindow.postMessage({ vcx: 'read', id, selector }, '*');
      setTimeout(() => reads.delete(id) && fail(new Error('the frame did not answer')), READ_WAIT_MS);
    });
  }

  function scan(root) {
    if (!(root instanceof Element)) return;
    const blocks = root.matches('.chart') ? [root] : root.querySelectorAll('.chart');
    for (const block of blocks) {
      decorate(block);
      const id = block.dataset.chart;
      // A block tagged `chart pin` pins itself the first time it is drawn.
      if (block.dataset.pin === 'true' && !offered.has(id)) {
        offered.add(id);
        if (pinned !== id) toggle(id);
      }
    }
  }

  addEventListener('message', heard);
  addEventListener('keydown', event => { if (event.key === 'Escape') close() });
  new MutationObserver(changes => changes.forEach(change => change.addedNodes.forEach(scan))).observe(document.body, { childList: true, subtree: true });
  window.vcxCharts = { push, read, toggle, enlarge, close, get pinned() { return pinned } };
})();
