'use strict';
// The transcript page's side of chart frames. Each ```chart block is a sandboxed frame served from vcx://chart/<id>
// under its own CSP; this file hears the frames by postMessage, sizes them, relays vcx.live to the core (which fetches
// for them), and keeps one chart pinned above the chat and one enlarged over it.
(() => {
  const INLINE_MIN_PX = 40;
  const INLINE_MAX_PX = 900;
  const PINNED_MAX_PX = 280;
  const ENLARGED_SHARE = 0.85;
  const INLINE_HEIGHT_PX = 240;
  const READ_WAIT_MS = 2000;
  // An unshown window runs no animation frame and may never finish an animation: the code goes on without them.
  const SETTLE_MARGIN_MS = 100;
  const QUICK_MS = 100;
  // Swift ChartPreview: the card takes 90 % of the window's width and at most 85 % of its height, its page magnified
  // so that the inline width plus its 12 pt margins fills it.
  const ENLARGED_WIDTH = 0.9;
  const CARD_PAD_PX = 12;
  const POP_MS = 240;
  const POP_FROM = 0.9;
  const POP_EASE = 'cubic-bezier(.42, 0, .58, 1)';
  // SwiftUI's .spring(duration: 0.3), no bounce: a critically damped spring sampled for linear().
  const PIN_MS = 300;
  const SPRING_STEPS = 24;
  const SPRING = `linear(${Array.from({ length: SPRING_STEPS + 1 }, (_, i) => i === SPRING_STEPS ? 1 : +(1 - (1 + 2 * Math.PI * i / SPRING_STEPS) * Math.exp(-2 * Math.PI * i / SPRING_STEPS)).toFixed(4)).join(', ')})`;

  const settled = (promise, ms) => Promise.race([promise, new Promise(done => setTimeout(done, ms))]);
  const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
  const ended = moves => settled(Promise.all(moves.map(move => move.finished)), Math.max(...moves.map(move => move.effect.getTiming().duration)) + SETTLE_MARGIN_MS);

  // Swift: the veil fades and the card scales from 90 % with a fade, ease-in-out both ways; reduced motion fades only.
  async function pop(card, veil, open) {
    const quick = reduced();
    const way = { duration: quick ? QUICK_MS : POP_MS, easing: POP_EASE, fill: 'both' };
    const fade = { opacity: open ? [0, 1] : [1, 0] };
    const grow = quick ? fade : { ...fade, scale: open ? [POP_FROM, 1] : [1, POP_FROM] };
    const moves = [veil.animate(fade, way), card.animate(grow, way)];
    await ended(moves);
    if (open) moves.forEach(move => move.cancel());
  }

  // Swift: the pinned chart moves in from the top with a fade, the chat below following it, on a 0.3 s spring;
  // reduced motion fades it in 0.1 s.
  function slide(area, block, shown) {
    area.getAnimations().forEach(move => move.cancel());
    if (reduced()) { const fade = block.animate({ opacity: shown ? [0, 1] : [1, 0] }, { duration: QUICK_MS, easing: 'ease-out', fill: 'both' }); return ended([fade]).then(() => shown && fade.cancel()) }
    const way = { duration: PIN_MS, easing: SPRING, fill: 'both' };
    const style = getComputedStyle(area);
    const open = { height: `${area.getBoundingClientRect().height}px`, paddingTop: style.paddingTop, paddingBottom: style.paddingBottom, marginBottom: style.marginBottom };
    const shut = { height: '0px', paddingTop: '0px', paddingBottom: '0px', marginBottom: '0px' };
    const moves = [
      area.animate([{ ...(shown ? shut : open), overflow: 'hidden', boxSizing: 'border-box' }, { ...(shown ? open : shut), overflow: 'hidden', boxSizing: 'border-box' }], way),
      block.animate({ translate: shown ? ['0 -100%', '0 0'] : ['0 0', '0 -100%'], opacity: shown ? [0, 1] : [1, 0] }, way),
    ];
    return ended(moves).then(() => { if (shown) { moves.forEach(move => move.cancel()); pinHeight() } });
  }

  const ICONS = {
    pin: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6 2h4l-.5 4 2.5 2.5V10H8.6L8 14l-.6-4H4V8.5L6.5 6z"/></svg>',
    unpin: '<svg viewBox="0 0 16 16" aria-hidden="true"><mask id="chart-unpin"><rect width="16" height="16" fill="#fff"/><path d="M2 1l13 13" stroke="#000" stroke-width="3.2"/></mask><path mask="url(#chart-unpin)" d="M6 2h4l-.5 4 2.5 2.5V10H8.6L8 14l-.6-4H4V8.5L6.5 6z"/><path d="M2.2 1.6l12.2 12.2" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>',
    enlarge: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M9.5 2H14v4.5M14 2l-5 5M6.5 14H2V9.5M2 14l5-5"/></svg>',
    close: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/></svg>',
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

  // The enlarged view has only its close button: pinning there is by right-click.
  function decorate(block) {
    if (block.closest('.chart-zoom') || block.querySelector(':scope > .chart-buttons')) return;
    const id = block.dataset.chart;
    const bar = make('div', 'chart-buttons');
    bar.append(button('pin', '', () => toggle(id)), button('enlarge', 'Enlarge the chart', () => enlarge(id, block)));
    block.append(bar);
    label(block);
  }

  function label(block) {
    const pin = block.querySelector(':scope > .chart-buttons .pin');
    if (!pin) return;
    const on = pinned === block.dataset.chart;
    const changed = pin.classList.contains('on') !== on;
    if (changed || !pin.firstChild) pin.innerHTML = ICONS[on ? 'unpin' : 'pin'];
    if (changed && !reduced()) pin.firstChild.animate({ opacity: [0, 0.5] }, { duration: PIN_MS, easing: SPRING });
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
    const old = area.querySelector(':scope > .chart');
    document.querySelectorAll('.chart').forEach(label);
    if (!pinned) {
      if (old) slide(area, old, false).then(() => { if (!pinned) { area.getAnimations().forEach(move => move.cancel()); area.replaceChildren(); area.hidden = true } });
      return;
    }
    const block = make('div', 'chart pinned');
    block.dataset.chart = pinned;
    block.append(frame(pinned, 'pinned'));
    area.replaceChildren(block);
    area.hidden = false;
    decorate(block);
    if (!old || area.getAnimations().length) slide(area, block, true);
  }

  // Swift ChartPreview: the page keeps its inline width and is magnified to fill the card.
  function fit(block) {
    const element = block.querySelector('iframe');
    const scale = Math.max(1, innerWidth * ENLARGED_WIDTH / (Number(element.dataset.width) + 2 * CARD_PAD_PX));
    const width = innerWidth * ENLARGED_WIDTH - 2 * CARD_PAD_PX * scale;
    const height = Math.min(Number(element.dataset.height || INLINE_HEIGHT_PX) * scale, innerHeight * ENLARGED_SHARE - 2 * CARD_PAD_PX * scale);
    element.dataset.scale = String(scale);
    Object.assign(element.style, { width: `${width / scale}px`, height: `${height / scale}px`, transform: `scale(${scale})` });
    Object.assign(block.style, { width: `${width}px`, height: `${height}px`, padding: `${CARD_PAD_PX * scale}px` });
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
    const block = make('div', 'chart enlarged');
    block.dataset.chart = id;
    const element = frame(id, 'enlarged');
    const inline = from?.querySelector('iframe');
    element.dataset.width = String(inline?.clientWidth || innerWidth * ENLARGED_WIDTH - 2 * CARD_PAD_PX);
    element.dataset.height = String(inline?.clientHeight || INLINE_HEIGHT_PX);
    block.append(element, button('close', 'Close the chart', close));
    overlay.append(veil, block);
    document.body.append(overlay);
    fit(block);
    pop(block, veil, true);
  }

  // The overlay gives up its id at once, so a chart enlarged while it zooms out opens a new one.
  function close() {
    const overlay = document.getElementById('chart-zoom');
    if (!overlay) return;
    overlay.id = '';
    overlay.classList.add('closing');
    pop(overlay.querySelector('.chart'), overlay.querySelector('.veil'), false).then(() => overlay.remove());
  }

  // Enlarged, the frame keeps the inline height it opened with, as Swift's preview does.
  function size(element, height) {
    const mode = view(element);
    if (mode === 'enlarged') return;
    element.dataset.height = String(height);
    const shown = mode === 'pinned' ? Math.min(height, PINNED_MAX_PX) : Math.min(Math.max(height, INLINE_MIN_PX), INLINE_MAX_PX);
    element.style.height = `${shown}px`;
    if (mode === 'pinned') pinHeight();
  }

  // Measured once the strip has slid in: a turn's sticky heading stops under it.
  const pinHeight = () => document.documentElement.style.setProperty('--chart-pin-height', `${strip().offsetHeight}px`);

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
        const at = element.getBoundingClientRect(), k = Number(element.dataset.scale || 1);
        done({ items: (message.items || []).map(item => ({ ...item, box: [item.box[0] * k + at.x, item.box[1] * k + at.y, item.box[2] * k, item.box[3] * k].map(Math.round) })), data: message.data || {} });
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
  addEventListener('resize', () => { const block = document.querySelector('#chart-zoom .chart'); if (block) fit(block) });
  new MutationObserver(changes => changes.forEach(change => change.addedNodes.forEach(scan))).observe(document.body, { childList: true, subtree: true });
  window.vcxCharts = { push, read, toggle, enlarge, close, get pinned() { return pinned } };
})();
