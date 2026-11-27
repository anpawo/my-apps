'use strict';
// The page API of a chart frame: vcx.chart, vcx.live, zoom and pan. The frame is sandboxed under its own CSP: it
// talks to the transcript page by postMessage only, and the core fetches vcx.live's URLs for it.
window.vcx = (() => {
  const view = new URLSearchParams(location.search).get('view') || 'inline';
  document.documentElement.dataset.view = view;
  const MAX_ZOOM = 20;
  const WHEEL_ZOOM_SPEED = 300;
  // Wheel events this close together are one gesture: it keeps scrolling or zooming, whichever it started as.
  const GESTURE_GAP_MS = 200;
  const DEFAULT_LIVE_SECONDS = 30;
  const subs = {};
  let n = 0, s = 1, x = 0, y = 0, drag = null, mode = null, last = 0, pinch = 1;
  const tell = message => parent.postMessage({ vcx: message.type, ...message }, '*');
  const interactive = target => target instanceof Element && (target.isContentEditable || !!target.closest('input,textarea,select,button,a,label,summary,[role="button"],[role="slider"],[role="spinbutton"],[role="textbox"]'));
  const apply = () => {
    x = Math.min(0, Math.max(innerWidth * (1 - s), x)); y = Math.min(scrollY * (1 - s), Math.max((scrollY + innerHeight) * (1 - s), y));
    document.body.style.transformOrigin = '0 0'; document.body.style.transform = s > 1 ? `translate(${x}px,${y}px) scale(${s})` : '';
  };
  // The page's own height is where its last element ends: the document's scrollHeight never drops below the frame's.
  const height = () => s > 1 || !document.body ? 0 : Math.ceil(Math.max(0, ...Array.from(document.body.children, e => e.getBoundingClientRect().bottom + scrollY)));
  let told = 0;
  const measure = () => { const h = height(); if (h > 0 && h !== told) { told = h; tell({ type: 'size', height: h }) } };
  const box = e => { const r = e.getBoundingClientRect(); return [r.x, r.y, r.width, r.height].map(Math.round) };
  const vcx = {
    view,
    get scale() { return s },
    measure,
    isInteractive(px, py) { return interactive(document.elementFromPoint(px, py)) },
    live(url, seconds, callback) { const id = ++n; subs[id] = callback; tell({ type: 'live', id, url: String(url), seconds: Number(seconds) || DEFAULT_LIVE_SECONDS }) },
    // A page that draws with vcx.chart zooms its time axis instead (onzoom/onpan/onreset), so the price scale stays in view.
    zoom(factor, px, py) { if (vcx.onzoom?.(factor, px, py)) return; const k = Math.min(MAX_ZOOM, Math.max(1, s * factor)); x = px - (px - x) * k / s; y = py + scrollY - (py + scrollY - y) * k / s; s = k; apply() },
    pan(dx, dy) { if (vcx.onpan?.(dx, dy)) return; x += dx; y += dy; apply() },
    reset() { if (vcx.onreset?.()) return; s = 1; apply() },
  };
  addEventListener('message', e => {
    if (e.source !== parent || typeof e.data !== 'object' || !e.data) return;
    const m = e.data;
    if (m.vcx === 'push' && subs[m.id]) { let v; try { v = JSON.parse(m.body) } catch { v = m.body } subs[m.id](v) }
    // The transcript page reads what the frame drew: its text and boxes, for its checks.
    if (m.vcx === 'read') {
      const items = Array.from(document.querySelectorAll(m.selector), e => ({ text: e.textContent, box: box(e), className: typeof e.className === 'string' ? e.className : '' }));
      tell({ type: 'read', id: m.id, items, data: { ...document.body?.dataset } });
    }
  });
  // Inline, the transcript scrolls over the chart and only a pinch zooms it; pinned or enlarged, the wheel zooms too.
  // A page taller than its frame scrolls instead, for each wheel gesture that starts where it can still move.
  addEventListener('wheel', e => setTimeout(() => {
    if (e.defaultPrevented) return;
    if (e.ctrlKey) { if (!interactive(e.target)) vcx.zoom(Math.exp(-e.deltaY / 100), e.clientX, e.clientY); return }
    if (view === 'inline') return;
    const vertical = Math.abs(e.deltaY) >= Math.abs(e.deltaX), room = document.documentElement.scrollHeight - innerHeight;
    if (e.timeStamp - last > GESTURE_GAP_MS) mode = null; last = e.timeStamp;
    mode ??= vertical && s === 1 && e.deltaY && (e.deltaY > 0 ? scrollY < room - 0.5 : scrollY > 0.5) ? 'scroll' : 'zoom';
    if (mode === 'scroll') { if (vertical) scrollBy(0, e.deltaY) }
    else if (!interactive(e.target)) { if (vertical) vcx.zoom(Math.exp(-e.deltaY / WHEEL_ZOOM_SPEED), e.clientX, e.clientY); else vcx.pan(-e.deltaX, 0) }
  }), { passive: true });
  // WebKit hands a trackpad pinch to the page as gesture events, with the scale since the pinch began.
  addEventListener('gesturestart', e => { e.preventDefault(); pinch = 1 });
  addEventListener('gesturechange', e => { e.preventDefault(); if (!interactive(e.target)) vcx.zoom(e.scale / pinch, e.clientX, e.clientY); pinch = e.scale });
  addEventListener('mousedown', e => { if (s > 1 && e.button === 0 && !interactive(e.target)) { drag = [e.clientX, e.clientY]; e.preventDefault() } }, true);
  addEventListener('mousemove', e => { if (drag) { vcx.pan(e.clientX - drag[0], e.clientY - drag[1]); drag = [e.clientX, e.clientY] } });
  addEventListener('mouseup', () => { drag = null });
  // A double click on the chart (not on a field or a button) resets its zoom and enlarges it; a right click pins it.
  addEventListener('dblclick', e => { if (interactive(e.target)) return; vcx.reset(); if (view !== 'enlarged') tell({ type: 'enlarge' }) });
  addEventListener('contextmenu', e => { if (interactive(e.target)) return; e.preventDefault(); tell({ type: 'pin' }) });
  addEventListener('keydown', e => { if (e.key === 'Escape') tell({ type: 'escape' }) });
  // A frame in a window that is not on screen runs no ResizeObserver: the height is also told once loaded and after each chart.
  addEventListener('load', () => { measure(); if (window.ResizeObserver) new ResizeObserver(measure).observe(document.body) });
  addEventListener('DOMContentLoaded', measure);
  tell({ type: 'hello' });
  return vcx;
})();

// vcx.chart: a clean chart in one call (TradingView's lightweight-charts, Apache-2.0, vendored beside this file), zinc
// greys like shadcn's, with a TradingView crosshair (price and time labels on the axes) and the hovered values in a legend.
(() => {
  const LIBRARY = 'vcx://template/chart/lightweight-charts.js';
  const DEFAULT_HEIGHT = 260;
  const NASDAQ_SECONDS = 15;
  // A zoom never shows fewer bars than this.
  const MIN_BARS = 4;
  const DAY_SECONDS = 86400;
  let loading;
  const load = () => loading ??= new Promise((ok, fail) => {
    const script = document.createElement('script'); script.src = LIBRARY; script.onload = () => ok(window.LightweightCharts); script.onerror = fail; document.head.appendChild(script);
  });
  const text = (v, f) => f ? f(v) : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 2 }) : v ?? '';
  const make = (tag, props) => Object.assign(document.createElement(tag), props);
  // Tables and headline figures need no library. A row or a card may carry a tone (green, red, orange, blue); set(data)
  // redraws with new data, and a card's figure that changes rises into place.
  const table = (o, card) => {
    const el = make('table', { className: 'vcx-table' }), head = el.createTHead(), body = el.createTBody();
    card.append(el);
    return rows => {
      const keyed = rows.find(r => r && !Array.isArray(r));
      const cols = o.columns || (keyed ? Object.keys(keyed).filter(k => k !== 'tone') : []);
      const width = cols.length || Math.max(0, ...rows.map(r => r.length));
      const cell = (r, i) => Array.isArray(r) ? r[i] : r[cols[i]];
      const num = Array.from({ length: width }, (_, i) => rows.some(r => typeof cell(r, i) === 'number') && rows.every(r => cell(r, i) == null || cell(r, i) === '' || typeof cell(r, i) === 'number'));
      // A number column shows every figure with as many decimals as its most precise one, two at most.
      const places = num.map((isNum, i) => isNum ? Math.max(0, ...rows.map(r => Math.min(2, (String(cell(r, i) ?? '').split('.')[1] || '').length))) : 0);
      const fmt = i => (typeof o.format === 'function' ? o.format : o.format?.[cols[i]]) || (num[i] ? v => typeof v === 'number' ? v.toLocaleString('en-US', { minimumFractionDigits: places[i], maximumFractionDigits: places[i] }) : v ?? '' : null);
      const tr = (tag, values, tone) => {
        const row = make('tr', { className: tone ? 't-' + tone : '' });
        row.append(...values.map((v, i) => make(tag, { className: num[i] ? 'num' : '', textContent: tag === 'th' ? v : text(v, fmt(i)) })));
        return row;
      };
      head.replaceChildren(...(o.columns || keyed ? [tr('th', cols)] : []));
      body.replaceChildren(...rows.map(r => tr('td', Array.from({ length: width }, (_, i) => cell(r, i)), r.tone)));
    };
  };
  const cards = (o, card) => {
    const box = make('dl', { className: 'vcx-tiles' });
    card.append(box);
    const fill = (tile, c) => {
      tile.className = 'vcx-tile' + (c.tone ? ' t-' + c.tone : '') + (c.value === 0 || c.value === '0' ? ' zero' : '');
      tile.querySelector('dt').textContent = c.label ?? '';
      tile.querySelector('.unit').textContent = c.unit ? ' ' + c.unit : '';
      tile.querySelector('.under').textContent = c.note ?? '';
      const v = tile.querySelector('.v'), figure = String(text(c.value, o.format));
      if (v.textContent === figure) return;
      // The figure is written at once: an animation's end never comes in a page that is not drawn.
      const old = v.textContent; v.textContent = figure;
      if (old && !matchMedia('(prefers-reduced-motion: reduce)').matches) v.animate({ transform: ['translateY(40%)', 'none'], opacity: [0, 1] }, { duration: 220, easing: 'ease-out' });
    };
    return items => {
      items.forEach((c, i) => {
        let tile = box.children[i];
        if (!tile) { tile = make('div', { innerHTML: '<dt></dt><dd><span class="v"></span><small class="unit"></small><small class="under"></small></dd>' }); box.append(tile) }
        fill(tile, c);
      });
      while (box.children.length > items.length) box.lastChild.remove();
    };
  };
  const plain = (o, card) => {
    if (o.title) card.append(make('div', { className: 'vcx-title', textContent: o.title }));
    const draw = o.kind === 'table' ? table(o, card) : cards(o, card);
    const set = rows => { draw(rows); vcx.measure() };
    set(o.data || []);
    return { el: card, set };
  };
  const charts = [];
  const hit = py => charts.find(c => { const r = c.plot.getBoundingClientRect(); return py >= r.top && py <= r.bottom + 30 }) || charts[0];
  vcx.onzoom = (factor, px, py) => {
    if (!charts.length) return false;
    const c = hit(py), ts = c.chart.timeScale(), r = ts.getVisibleLogicalRange();
    if (!r || (r.to - r.from) / factor < MIN_BARS) return true;
    const m = ts.coordinateToLogical(Math.min(Math.max(px - c.plot.getBoundingClientRect().left, 0), ts.width())) ?? (r.from + r.to) / 2;
    ts.setVisibleLogicalRange({ from: m - (m - r.from) / factor, to: m + (r.to - m) / factor });
    return true;
  };
  vcx.onpan = dx => {
    if (!charts.length) return false;
    const ts = charts[0].chart.timeScale(), r = ts.getVisibleLogicalRange();
    if (r) { const k = dx * (r.to - r.from) / ts.width(); ts.setVisibleLogicalRange({ from: r.from - k, to: r.to - k }) }
    return true;
  };
  vcx.onreset = () => { if (!charts.length) return false; charts.forEach(c => c.chart.timeScale().fitContent()); return true };
  // A chart sized by the library's autoSize waits for a ResizeObserver, which a window off screen never runs: it is
  // sized from its box at once, then again whenever the frame changes width.
  addEventListener('resize', () => charts.forEach(c => c.chart.resize(c.plot.clientWidth, c.plot.clientHeight)));
  vcx.chart = async (o = {}) => {
    // A page that is only this script runs it in the head, before there is a body to draw into.
    if (!document.body) await new Promise(ready => addEventListener('DOMContentLoaded', ready, { once: true }));
    const card = make('div', { className: 'vcx-card' });
    ((typeof o.el === 'string' ? document.querySelector(o.el) : o.el) || document.body).appendChild(card);
    if (o.kind === 'table' || o.kind === 'cards') return plain(o, card);
    card.innerHTML = '<div class="vcx-head"><span class="vcx-title"></span><span class="vcx-value"></span><span class="vcx-change"></span><span class="vcx-note"></span></div><div class="vcx-plot"><div class="legend"></div></div><div class="vcx-days"></div>';
    const $ = q => card.querySelector(q), plot = $('.vcx-plot'), legend = $('.legend');
    plot.style.height = (o.height || DEFAULT_HEIGHT) + 'px';
    $('.vcx-title').textContent = o.title ?? o.symbol ?? '';
    const fmt = o.format || (v => (o.symbol ? '$' : '') + v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
    const L = await load(), up = '#16a34a', down = '#dc2626';
    const chart = L.createChart(plot, {
      width: plot.clientWidth,
      height: plot.clientHeight,
      layout: { background: { color: 'transparent' }, textColor: '#71717a', fontSize: 11, fontFamily: '-apple-system, system-ui, Inter, sans-serif', attributionLogo: false },
      grid: { vertLines: { visible: false }, horzLines: { color: '#f4f4f5' } },
      rightPriceScale: { borderVisible: false, scaleMargins: { top: 0.12, bottom: 0.08 } },
      timeScale: { borderVisible: false, timeVisible: true, secondsVisible: false, fixLeftEdge: true, fixRightEdge: true },
      crosshair: { mode: L.CrosshairMode.Normal, vertLine: { color: '#a1a1aa', labelBackgroundColor: '#18181b' }, horzLine: { color: '#a1a1aa', labelBackgroundColor: '#18181b' } },
      localization: { priceFormatter: fmt },
    });
    // OHLC rows draw their close as a line; candles only when asked.
    const candles = !!o.candles && o.data?.[0]?.open !== undefined;
    const series = candles
      ? chart.addSeries(L.CandlestickSeries, { upColor: up, downColor: down, wickUpColor: up, wickDownColor: down, borderVisible: false, priceLineVisible: false, lastValueVisible: false })
      : chart.addSeries(L.AreaSeries, { lineWidth: 2, priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false });
    // A page that feeds OHLC rows to series.setData itself (written when they drew candles) still draws their close.
    if (!candles) { const own = series.setData.bind(series); series.setData = rows => own(rows.map(r => r.value === undefined && r.close !== undefined ? { time: r.time, value: +r.close } : r)) }
    const tint = c => { plot.style.setProperty('--line', c); if (!candles) series.applyOptions({ lineColor: c, topColor: c + '29', bottomColor: c + '00' }) };
    tint(o.color || '#18181b');
    const show = (value, change, percent) => {
      if (!isFinite(value)) return;
      const sign = change >= 0 ? '+' : '−', el = $('.vcx-change');
      $('.vcx-value').textContent = fmt(value);
      el.textContent = isFinite(change) ? `${sign}${fmt(Math.abs(change))} (${sign}${Math.abs(percent).toFixed(2)}%)` : '';
      el.className = 'vcx-change ' + (change >= 0 ? 'vcx-up' : 'vcx-down');
      if (!o.color && isFinite(change)) tint(change >= 0 ? up : down);
    };
    // Nasdaq's x is Eastern wall-clock time written as UTC: shown as UTC, the axis reads ET.
    const time = t => t instanceof Date ? Math.round(t / 1000) : typeof t === 'number' && t > 1e11 ? Math.round(t / 1000) : t;
    let fitted = false;
    const set = rows => {
      const data = rows.map(r => candles ? { ...r, time: time(r.time) } : { time: time(r.time ?? r.x), value: +(r.value ?? r.close ?? r.y) })
        .sort((a, b) => (a.time > b.time ? 1 : -1)).filter((r, i, all) => !i || r.time !== all[i - 1].time);
      series.setData(data);
      if (!fitted && data.length) { chart.timeScale().fitContent(); fitted = true }
      days();
      if (!o.symbol && data.length) { const first = data[0].value ?? data[0].close, end = data.at(-1).value ?? data.at(-1).close; show(end, end - first, (end - first) / first * 100) }
      vcx.measure();
    };
    // Like TradingView: the crosshair's price and time sit on the axes, the hovered bar's values in a legend at the top left.
    chart.subscribeCrosshairMove(p => {
      const d = p.point && p.time !== undefined ? p.seriesData.get(series) : null;
      if (!d) { plot.classList.remove('hover'); return }
      const rows = d.open !== undefined ? [['O', d.open], ['H', d.high], ['L', d.low], ['C', d.close]] : [[o.name || o.symbol || '', d.value]];
      const move = d.open !== undefined ? d.close - d.open : NaN, tone = move >= 0 ? 'vcx-up' : 'vcx-down';
      legend.replaceChildren(...rows.flatMap(([name, v]) => [make('span', { className: 'n', textContent: name }), ' ', make('b', { textContent: fmt(v) })]));
      if (isFinite(move)) legend.append(' ', make('b', { className: tone, textContent: `${move >= 0 ? '+' : '−'}${fmt(Math.abs(move))} (${(move / d.open * 100).toFixed(2)}%)` }));
      plot.classList.add('hover');
    });
    // Intraday data gets a date under each day's hours, on a bracket spanning them (days in UTC, as the axis shows them).
    function days() {
      const row = $('.vcx-days'), data = series.data(), ts = chart.timeScale(), w = ts.width();
      if (!data.length || typeof data[0].time !== 'number' || data.every(r => r.time % DAY_SECONDS === 0)) { row.style.display = 'none'; return }
      row.style.display = '';
      const spans = [];
      data.forEach((r, i) => { const day = Math.floor(r.time / DAY_SECONDS); if (spans.at(-1)?.day === day) spans.at(-1).last = i; else spans.push({ day, first: i, last: i }) });
      row.replaceChildren(...spans.flatMap(({ day, first, last }) => {
        const a = Math.max(0, ts.logicalToCoordinate(first) + 2), b = Math.min(w, ts.logicalToCoordinate(last) - 2);
        if (!(b - a > 4)) return [];
        const name = new Date(day * DAY_SECONDS * 1000).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' });
        const el = make('div', { className: 'day', textContent: b - a > 70 ? name : '' });
        el.style.left = a + 'px'; el.style.width = (b - a) + 'px';
        return [el];
      }));
    }
    chart.timeScale().subscribeVisibleLogicalRangeChange(days);
    chart.timeScale().subscribeSizeChange(days);
    charts.push({ chart, plot });
    if (o.data) set(o.data);
    if (o.symbol) {
      const base = `https://api.nasdaq.com/api/quote/${encodeURIComponent(o.symbol.toUpperCase())}/`, every = o.live ?? NASDAQ_SECONDS, num = t => parseFloat(String(t).replace(/[$,+%]/g, ''));
      vcx.live(base + 'chart?assetclass=stocks', every, d => { if (d?.data?.chart?.length) set(d.data.chart) });
      vcx.live(base + 'info?assetclass=stocks', every, d => {
        const q = d?.data?.primaryData; if (!q) return;
        show(num(q.lastSalePrice), num(q.netChange), num(q.percentageChange));
        $('.vcx-note').textContent = [d.data.marketStatus, q.lastTradeTimestamp?.replace(/^\w+ \d+, \d+ /, '')].filter(Boolean).join(' · ');
      });
    }
    vcx.measure();
    return { chart, series, set };
  };
})();
