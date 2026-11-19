import SwiftUI
import WebKit

// A ```chart block holds an HTML page the agent wrote; it is drawn live in the answer, and a click opens it larger at the same ratio.
struct ChartZoom: Equatable {
    let html: String
    let size: CGSize
}

private struct OpenChartKey: EnvironmentKey { static let defaultValue: ((ChartZoom) -> Void)? = nil }
extension EnvironmentValues { var openChart: ((ChartZoom) -> Void)? { get { self[OpenChartKey.self] } set { self[OpenChartKey.self] = newValue } } }

@MainActor private var chartHeights: [String: CGFloat] = [:]

// One chart per chat stays above the transcript, live; a block tagged `chart pin` pins itself the first time it is drawn.
@MainActor @Observable final class ChartPin {
    var html: String?
    @ObservationIgnored private var offered: Set<String> = []
    func toggle(_ chart: String) { html = html == chart ? nil : chart }
    func offer(_ chart: String) { if offered.insert(chart).inserted { html = chart } }
}

struct ChartBlock: View {
    let html: String
    var pin = false
    @Environment(\.openChart) private var openChart
    @Environment(ChartPin.self) private var pins: ChartPin?
    @State private var height: CGFloat
    @State private var size = CGSize.zero
    init(html: String, pin: Bool = false) { self.html = html; self.pin = pin; _height = State(initialValue: chartHeights[html] ?? 240) }
    var body: some View {
        ChartWeb(html: html, zoom: 1, inline: true, height: { h in chartHeights[html] = h; if abs(height - h) > 0.5 { height = h } }, click: { size in openChart?(ChartZoom(html: html, size: size)) })
            .frame(maxWidth: .infinity).frame(height: height)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1)))
            .overlay(alignment: .topTrailing) { ChartButtons(html: html, size: size, pins: pins) }
            .onAppear { if pin { pins?.offer(html) } }
    }
}

private struct ChartButtons: View {
    let html: String
    let size: CGSize
    let pins: ChartPin?
    @Environment(\.openChart) private var openChart
    var body: some View {
        HStack(spacing: 0) {
            if let pins {
                let pinned = pins.html == html
                button(pinned ? "pin.slash" : "pin", pinned ? "Unpin the chart" : "Pin the chart above the chat") { withAnimation(.spring(duration: 0.3)) { pins.toggle(html) } }
            }
            button("arrow.up.left.and.arrow.down.right", "Enlarge the chart") { openChart?(ChartZoom(html: html, size: size)) }
        }.padding(4)
    }
    private func button(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10)).opacity(0.5).frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.reactive(RoundedRectangle(cornerRadius: 6))).help(help).accessibilityLabel(help)
    }
}

struct PinnedChart: View {
    let html: String
    let pins: ChartPin
    @State private var height: CGFloat
    @State private var size = CGSize.zero
    init(html: String, pins: ChartPin) { self.html = html; self.pins = pins; _height = State(initialValue: chartHeights[html] ?? 240) }
    var body: some View {
        // Not inline: the wheel and pinch zoom it, as nothing scrolls under it.
        ChartWeb(html: html, zoom: 1, inline: false, height: { h in if abs(height - h) > 0.5 { height = h } })
            .frame(maxWidth: 760).frame(height: min(height, 280))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1)))
            .overlay(alignment: .topTrailing) { ChartButtons(html: html, size: size, pins: pins) }
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            .padding(.horizontal, 24).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChartPreview: View {
    let chart: ChartZoom
    let size: CGSize
    var dismiss: () -> Void
    var body: some View {
        let scale = max(1, min(size.width * 0.9 / (chart.size.width + 24), size.height * 0.85 / (chart.size.height + 24)))
        ChartWeb(html: chart.html, zoom: scale, inline: false)
            .frame(width: chart.size.width * scale, height: chart.size.height * scale)
            .padding(12 * scale)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .topTrailing) { RoundButton(icon: "xmark", label: "Close chart", action: dismiss).padding(10) }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.2), radius: 28, y: 12)
            .accessibilityAddTraits(.isModal)
    }
}

private final class ChartWebView: WKWebView {
    var inline = true
    var click: ((CGSize) -> Void)?
    var pageHeight: CGFloat = 0
    var offset: CGFloat = 0
    private var down: NSPoint?
    private var latch: Bool?
    // Inline, the transcript scrolls over the chart, unless the page is taller than its block: then a gesture that starts
    // where the page can still move scrolls the page, momentum included, and the next one at its edge goes to the transcript.
    override func scrollWheel(with event: NSEvent) {
        guard inline else { return super.scrollWheel(with: event) }
        if event.phase == .began || event.phase == .mayBegin || (event.phase.isEmpty && event.momentumPhase.isEmpty) { latch = nil }
        let dy = -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10) / pageZoom, end = max(0, pageHeight - bounds.height / pageZoom)
        if latch == nil, dy != 0 { latch = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) && (dy > 0 ? offset < end - 0.5 : offset > 0.5) }
        guard latch == true, dy != 0 else { nextResponder?.scrollWheel(with: event); return }
        offset = min(end, max(0, offset + dy))
        evaluateJavaScript("scrollTo(0, \(offset))")
    }
    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), y = isFlipped ? point.y : bounds.height - point.y
        evaluateJavaScript("vcx.zoom(\(1 + event.magnification), \(point.x / pageZoom), \(y / pageZoom))")
    }
    override func mouseDown(with event: NSEvent) { down = event.locationInWindow; super.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if let down, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) < 4 { click?(bounds.size) }
        down = nil
    }
}

private struct ChartWeb: NSViewRepresentable {
    let html: String
    let zoom: CGFloat
    let inline: Bool
    var height: (CGFloat) -> Void = { _ in }
    var click: (CGSize) -> Void = { _ in }

    // The page's own height is where its last element ends: the document's scrollHeight never drops below the view's.
    // Zoomed, the children's rects are scaled: 0 keeps the measured height.
    static let measure = "vcx.scale > 1 ? 0 : Math.ceil(Math.max(0, ...Array.from(document.body.children, e => e.getBoundingClientRect().bottom + window.scrollY)))"
    // `vcx.live` polls a URL from the Mac, where no CORS applies (a page loaded from a string has origin null), and hands the page its JSON.
    // Zoom magnifies the whole page around the pointer (pinch anywhere; the wheel where it reaches the page) and a drag pans it;
    // a page that takes the wheel itself (preventDefault, as lightweight-charts does on its x axis) keeps it.
    // A page taller than its view scrolls instead, for each wheel burst that starts where it can still move.
    static let script = #"""
    window.vcx = (() => {
      const subs = {}; let n = 0, s = 1, x = 0, y = 0, drag = null, mode = null, last = 0;
      const apply = () => {
        x = Math.min(0, Math.max(innerWidth * (1 - s), x)); y = Math.min(scrollY * (1 - s), Math.max((scrollY + innerHeight) * (1 - s), y));
        document.body.style.transformOrigin = '0 0'; document.body.style.transform = s > 1 ? `translate(${x}px,${y}px) scale(${s})` : '';
      };
      const vcx = {
        get scale() { return s },
        live(url, seconds, callback) { const id = ++n; subs[id] = callback; webkit.messageHandlers.live.postMessage({ id, url: String(url), seconds: Number(seconds) || 30 }) },
        _push(id, data) { subs[id] && subs[id](data) },
        // A page that draws with vcx.chart zooms its time axis instead (onzoom/onpan/onreset), so the price scale stays in view.
        zoom(factor, px, py) { if (vcx.onzoom?.(factor, px, py)) return; const k = Math.min(20, Math.max(1, s * factor)); x = px - (px - x) * k / s; y = py + scrollY - (py + scrollY - y) * k / s; s = k; apply() },
        pan(dx, dy) { if (vcx.onpan?.(dx, dy)) return; x += dx; y += dy; apply() },
        reset() { if (vcx.onreset?.()) return; s = 1; apply() },
      };
      addEventListener('wheel', e => setTimeout(() => {
        if (e.defaultPrevented) return;
        const vertical = Math.abs(e.deltaY) >= Math.abs(e.deltaX), room = document.documentElement.scrollHeight - innerHeight;
        if (e.timeStamp - last > 200) mode = null; last = e.timeStamp;
        mode ??= vertical && s === 1 && e.deltaY && (e.deltaY > 0 ? scrollY < room - 0.5 : scrollY > 0.5) ? 'scroll' : 'zoom';
        if (mode === 'scroll') { if (vertical) scrollBy(0, e.deltaY) }
        else if (vertical) vcx.zoom(Math.exp(-e.deltaY / 300), e.clientX, e.clientY); else vcx.pan(-e.deltaX, 0);
      }), { passive: true });
      addEventListener('mousedown', e => { if (s > 1 && e.button === 0) { drag = [e.clientX, e.clientY]; e.preventDefault() } }, true);
      addEventListener('mousemove', e => { if (drag) { vcx.pan(e.clientX - drag[0], e.clientY - drag[1]); drag = [e.clientX, e.clientY] } });
      addEventListener('mouseup', () => { drag = null });
      addEventListener('dblclick', () => vcx.reset());
      return vcx;
    })();
    """#
    // vcx.chart: a clean chart in one call (TradingView's lightweight-charts, Apache-2.0, from unpkg), zinc greys like shadcn's,
    // with a TradingView crosshair (price and time labels on the axes) and the hovered values in a legend.
    static let kit = #"""
    (() => {
      const lib = 'https://unpkg.com/lightweight-charts@5.3.0/dist/lightweight-charts.standalone.production.js';
      let loading, styled = false;
      const load = () => loading ??= new Promise((ok, fail) => {
        const script = document.createElement('script'); script.src = lib; script.onload = () => ok(window.LightweightCharts); script.onerror = fail; document.head.appendChild(script);
      });
      const css = `
    .vcx-card{font:13px/1.4 -apple-system,system-ui,Inter,sans-serif;color:#09090b}
    .vcx-head{display:flex;align-items:baseline;gap:2px 10px;flex-wrap:wrap;min-height:30px;margin:0 2px 8px}
    .vcx-title{font-weight:600;font-size:14px;flex-basis:100%}
    .vcx-value{font-weight:600;font-size:22px;font-variant-numeric:tabular-nums;letter-spacing:-.01em}
    .vcx-change{font-size:12px;font-weight:500;font-variant-numeric:tabular-nums}
    .vcx-up{color:#16a34a}.vcx-down{color:#dc2626}
    .vcx-note{color:#71717a;font-size:12px;margin-left:auto}
    .vcx-plot{position:relative}
    .vcx-plot .legend{position:absolute;left:2px;top:0;z-index:3;pointer-events:none;font-size:11px;white-space:nowrap;opacity:0;transition:opacity 120ms ease-out}
    .vcx-plot.hover .legend{opacity:1}
    .vcx-plot .legend .n{color:#71717a;margin-left:8px}.vcx-plot .legend .n:first-child{margin-left:0}
    .vcx-plot .legend b{font-weight:600;font-variant-numeric:tabular-nums}
    .vcx-days{position:relative;height:22px;overflow:hidden}
    .vcx-days .day{position:absolute;top:5px;border-top:1px solid #d4d4d8;padding-top:2px;text-align:center;font-size:11px;color:#71717a;white-space:nowrap;overflow:hidden}
    .vcx-days .day::before,.vcx-days .day::after{content:'';position:absolute;top:-5px;width:1px;height:5px;background:#d4d4d8}
    .vcx-days .day::before{left:0}.vcx-days .day::after{right:0}
    .vcx-card+.vcx-card{margin-top:16px}
    .vcx-card>.vcx-title{margin:0 2px 8px}
    .vcx-table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
    .vcx-table th{font-weight:500;font-size:12px;color:#71717a;text-align:left;padding:6px 10px;border-bottom:1px solid #e4e4e7;white-space:nowrap}
    .vcx-table td{padding:6px 10px;border-bottom:1px solid #f4f4f5}
    .vcx-table .num{text-align:right}
    .vcx-table tbody tr{transition:background-color 150ms ease-out}
    .vcx-table tbody tr:hover{background:#fafafa}
    .vcx-tiles{display:flex;flex-wrap:wrap;gap:8px;margin:0}
    .vcx-tile{min-width:96px;padding:8px 12px;border:1px solid #e4e4e7;border-radius:12px;background:#fff;transition:background-color 300ms ease-out,border-color 300ms ease-out}
    .vcx-tile dt{font-size:12px;line-height:16px;color:#71717a}
    .vcx-tile dd{margin:0;font-size:20px;line-height:28px;font-weight:600;font-variant-numeric:tabular-nums}
    .vcx-tile dd .v{display:inline-block}
    .vcx-tile.zero dd{color:#a1a1aa}
    .vcx-tile small{font-size:12px;font-weight:500;color:#71717a}
    .vcx-tile small.under{display:block;line-height:16px}
    .t-green{background:#f0fdf4!important;border-color:#bbf7d0}.t-red{background:#fef2f2!important;border-color:#fecaca}
    .t-orange{background:#fff7ed!important;border-color:#fed7aa}.t-blue{background:#eff6ff!important;border-color:#bfdbfe}`;
      const text = (v, f) => f ? f(v) : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 2 }) : v ?? '';
      // Tables and headline figures need no library. A row or a card may carry a tone (green, red, orange, blue); set(data) redraws
      // with new data, and a card's figure that changes rises into place (the template base's counter tiles, in VCX's light greys).
      const plain = (o, card) => {
        if (o.title) card.append(Object.assign(document.createElement('div'), { className: 'vcx-title', textContent: o.title }));
        const make = (tag, props) => Object.assign(document.createElement(tag), props);
        let set;
        if (o.kind === 'table') {
          const table = make('table', { className: 'vcx-table' }), head = table.createTHead(), body = table.createTBody();
          card.append(table);
          set = rows => {
            const keyed = rows.find(r => r && !Array.isArray(r));
            const cols = o.columns || (keyed ? Object.keys(keyed).filter(k => k !== 'tone') : []);
            const width = cols.length || Math.max(0, ...rows.map(r => r.length));
            const cell = (r, i) => Array.isArray(r) ? r[i] : r[cols[i]];
            const num = Array.from({ length: width }, (_, i) => rows.some(r => typeof cell(r, i) === 'number') && rows.every(r => cell(r, i) == null || cell(r, i) === '' || typeof cell(r, i) === 'number'));
            // A number column shows every figure with as many decimals as its most precise one, two at most.
            const places = num.map((n, i) => n ? Math.max(0, ...rows.map(r => Math.min(2, (String(cell(r, i) ?? '').split('.')[1] || '').length))) : 0);
            const fmt = i => (typeof o.format === 'function' ? o.format : o.format?.[cols[i]]) || (num[i] ? v => typeof v === 'number' ? v.toLocaleString('en-US', { minimumFractionDigits: places[i], maximumFractionDigits: places[i] }) : v ?? '' : null);
            const tr = (tag, values, tone) => {
              const row = make('tr', { className: tone ? 't-' + tone : '' });
              row.append(...values.map((v, i) => make(tag, { className: num[i] ? 'num' : '', textContent: tag === 'th' ? v : text(v, fmt(i)) })));
              return row;
            };
            head.replaceChildren(...(o.columns || keyed ? [tr('th', cols)] : []));
            body.replaceChildren(...rows.map(r => tr('td', Array.from({ length: width }, (_, i) => cell(r, i)), r.tone)));
          };
        } else {
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
          set = items => {
            items.forEach((c, i) => {
              let tile = box.children[i];
              if (!tile) { tile = make('div', { innerHTML: '<dt></dt><dd><span class="v"></span><small class="unit"></small><small class="under"></small></dd>' }); box.append(tile) }
              fill(tile, c);
            });
            while (box.children.length > items.length) box.lastChild.remove();
          };
        }
        set(o.data || []);
        return { el: card, set };
      };
      const charts = [];
      vcx.chart = async (o = {}) => {
        // A page that is only this script runs it in the head, before there is a body to draw into.
        if (!document.body) await new Promise(ready => addEventListener('DOMContentLoaded', ready, { once: true }));
        if (!styled) { styled = true; const style = document.createElement('style'); style.textContent = css; document.head.appendChild(style) }
        const card = document.createElement('div'); card.className = 'vcx-card';
        ((typeof o.el === 'string' ? document.querySelector(o.el) : o.el) || document.body).appendChild(card);
        if (o.kind === 'table' || o.kind === 'cards') return plain(o, card);
        card.innerHTML = '<div class="vcx-head"><span class="vcx-title"></span><span class="vcx-value"></span><span class="vcx-change"></span><span class="vcx-note"></span></div><div class="vcx-plot"><div class="legend"></div></div><div class="vcx-days"></div>';
        const $ = s => card.querySelector(s), plot = $('.vcx-plot'), legend = $('.legend');
        plot.style.height = (o.height || 260) + 'px';
        $('.vcx-title').textContent = o.title ?? o.symbol ?? '';
        const fmt = o.format || (v => (o.symbol ? '$' : '') + v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
        const L = await load(), up = '#16a34a', down = '#dc2626';
        const chart = L.createChart(plot, {
          autoSize: true,
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
          if (!o.symbol && data.length) { const first = data[0].value ?? data[0].close, last = data.at(-1).value ?? data.at(-1).close; show(last, last - first, (last - first) / first * 100) }
        };
        // Like TradingView: the crosshair's price and time sit on the axes, the hovered bar's values in a legend at the top left.
        chart.subscribeCrosshairMove(p => {
          const d = p.point && p.time !== undefined ? p.seriesData.get(series) : null;
          if (!d) { plot.classList.remove('hover'); return }
          const rows = d.open !== undefined ? [['O', d.open], ['H', d.high], ['L', d.low], ['C', d.close]] : [[o.name || o.symbol || '', d.value]];
          const move = d.open !== undefined ? d.close - d.open : NaN, tone = move >= 0 ? 'vcx-up' : 'vcx-down';
          legend.innerHTML = rows.map(([n, x]) => `<span class="n">${n}</span> <b>${fmt(x)}</b>`).join('')
            + (isFinite(move) ? ` <b class="${tone}">${move >= 0 ? '+' : '−'}${fmt(Math.abs(move))} (${(move / d.open * 100).toFixed(2)}%)</b>` : '');
          plot.classList.add('hover');
        });
        // Intraday data gets a date under each day's hours, on a bracket spanning them (days in UTC, as the axis shows them).
        function days() {
          const row = $('.vcx-days'), data = series.data(), ts = chart.timeScale(), w = ts.width();
          if (!data.length || typeof data[0].time !== 'number' || data.every(r => r.time % 86400 === 0)) { row.style.display = 'none'; return }
          row.style.display = '';
          const spans = [];
          data.forEach((r, i) => { const day = Math.floor(r.time / 86400); if (spans.at(-1)?.day === day) spans.at(-1).last = i; else spans.push({ day, first: i, last: i }) });
          row.innerHTML = spans.map(({ day, first, last }) => {
            const a = Math.max(0, ts.logicalToCoordinate(first) + 2), b = Math.min(w, ts.logicalToCoordinate(last) - 2);
            if (!(b - a > 4)) return '';
            const name = new Date(day * 86400000).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' });
            return `<div class="day" style="left:${a}px;width:${b - a}px">${b - a > 70 ? name : ''}</div>`;
          }).join('');
        }
        chart.timeScale().subscribeVisibleLogicalRangeChange(days);
        chart.timeScale().subscribeSizeChange(days);
        charts.push({ chart, plot });
        const hit = (px, py) => charts.find(c => { const r = c.plot.getBoundingClientRect(); return py >= r.top && py <= r.bottom + 30 }) || charts[0];
        vcx.onzoom = (factor, px, py) => {
          const c = hit(px, py), ts = c.chart.timeScale(), r = ts.getVisibleLogicalRange();
          if (!r || (r.to - r.from) / factor < 4) return true;
          const m = ts.coordinateToLogical(Math.min(Math.max(px - c.plot.getBoundingClientRect().left, 0), ts.width())) ?? (r.from + r.to) / 2;
          ts.setVisibleLogicalRange({ from: m - (m - r.from) / factor, to: m + (r.to - m) / factor });
          return true;
        };
        vcx.onpan = dx => {
          const ts = charts[0].chart.timeScale(), r = ts.getVisibleLogicalRange();
          if (r) { const k = dx * (r.to - r.from) / ts.width(); ts.setVisibleLogicalRange({ from: r.from - k, to: r.to - k }) }
          return true;
        };
        vcx.onreset = () => { charts.forEach(c => c.chart.timeScale().fitContent()); return true };
        if (o.data) set(o.data);
        if (o.symbol) {
          const base = `https://api.nasdaq.com/api/quote/${encodeURIComponent(o.symbol.toUpperCase())}/`, every = o.live ?? 15, n = t => parseFloat(String(t).replace(/[$,+%]/g, ''));
          vcx.live(base + 'chart?assetclass=stocks', every, d => { if (d?.data?.chart?.length) set(d.data.chart) });
          vcx.live(base + 'info?assetclass=stocks', every, d => {
            const q = d?.data?.primaryData; if (!q) return;
            show(n(q.lastSalePrice), n(q.netChange), n(q.percentageChange));
            $('.vcx-note').textContent = [d.data.marketStatus, q.lastTradeTimestamp?.replace(/^\w+ \d+, \d+ /, '')].filter(Boolean).join(' · ');
          });
        }
        return { chart, series, set };
      };
    })();
    """#
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ChartWebView {
        let configuration = WKWebViewConfiguration()
        // Wrapped so they declare no global: a page's own `let s` would otherwise throw and never draw.
        let style = "(() => { const s = document.createElement('style'); s.textContent = 'html,body{margin:0;overflow:hidden;background:transparent}" + (inline ? " *{cursor:crosshair !important}" : "") + "'; document.documentElement.appendChild(s) })();"
        let report = "new ResizeObserver(() => webkit.messageHandlers.size.postMessage(\(Self.measure))).observe(document.body);"
        configuration.userContentController.addUserScript(WKUserScript(source: style, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: Self.kit, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: report, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "size")
        configuration.userContentController.add(context.coordinator, name: "live")
        let view = ChartWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: ChartWebView, context: Context) {
        context.coordinator.height = height
        view.inline = inline
        view.click = inline ? click : nil
        view.pageZoom = zoom
        if context.coordinator.html != html { context.coordinator.html = html; context.coordinator.stop(); view.offset = 0; view.loadHTMLString(html.lowercased().contains("<!doctype") ? html : "<!doctype html>" + html, baseURL: nil) }
    }
    static func dismantleNSView(_ view: ChartWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "size")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "live")
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var html = ""
        var height: (CGFloat) -> Void = { _ in }
        // A window that is not on screen runs no ResizeObserver, so the height is also read once the page has loaded.
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            view.evaluateJavaScript(ChartWeb.measure) { [weak self, weak view] value, _ in self?.report(value, in: view) }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "live" { live(message.body, in: message.webView) } else { report(message.body, in: message.webView) }
        }
        // ponytail: each view polls on its own (inline, pinned and enlarged copies of one chart each fetch); share one feed per URL if that ever costs.
        private var feeds: [Task<Void, Never>] = []
        func stop() { feeds.forEach { $0.cancel() }; feeds = [] }
        private static let feed = URLSession(configuration: .ephemeral)
        private func live(_ body: Any, in view: WKWebView?) {
            guard let body = body as? [String: Any], let id = body["id"] as? Int, let link = body["url"] as? String, let url = URL(string: link),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let view else { return }
            let every = max((body["seconds"] as? Double) ?? 30, 5)
            var request = URLRequest(url: url)
            // Nasdaq's API answers a browser, not a bare client.
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            feeds.append(Task { @MainActor [weak view] in
                while !Task.isCancelled {
                    if let (data, _) = try? await Self.feed.data(for: request), !Task.isCancelled, let view {
                        let text = String(decoding: data, as: UTF8.self)
                        _ = try? await view.callAsyncJavaScript("let v; try { v = JSON.parse(body) } catch (e) { v = body } vcx._push(id, v)", arguments: ["id": id, "body": text], contentWorld: .page)
                    }
                    if view == nil { return }
                    try? await Task.sleep(for: .seconds(every))
                }
            })
        }
        private func report(_ body: Any?, in view: WKWebView?) {
            guard let value = (body as? NSNumber)?.doubleValue, value > 0 else { return }
            // The scroll end is the document's, which counts the body's own padding and margins, once it overflows the view.
            view?.evaluateJavaScript("document.documentElement.scrollHeight > innerHeight ? document.documentElement.scrollHeight : 0") { end, _ in
                (view as? ChartWebView)?.pageHeight = max(CGFloat(value), CGFloat((end as? NSNumber)?.doubleValue ?? 0))
            }
            let height = self.height
            Task { @MainActor in height(min(max(CGFloat(value), 40), 900)) }
        }
    }
}
