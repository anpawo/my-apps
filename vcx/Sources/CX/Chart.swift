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
            .frame(maxWidth: 760).frame(height: height)
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
    private var down: NSPoint?
    // Inline, the transcript scrolls over the chart instead of the page swallowing the wheel.
    override func scrollWheel(with event: NSEvent) { if inline { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) } }
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
    static let script = #"""
    window.vcx = (() => {
      const subs = {}; let n = 0, s = 1, x = 0, y = 0, drag = null;
      const apply = () => {
        x = Math.min(0, Math.max(innerWidth * (1 - s), x)); y = Math.min(0, Math.max(innerHeight * (1 - s), y));
        document.body.style.transformOrigin = '0 0'; document.body.style.transform = s > 1 ? `translate(${x}px,${y}px) scale(${s})` : '';
      };
      const vcx = {
        get scale() { return s },
        live(url, seconds, callback) { const id = ++n; subs[id] = callback; webkit.messageHandlers.live.postMessage({ id, url: String(url), seconds: Number(seconds) || 30 }) },
        _push(id, data) { subs[id] && subs[id](data) },
        zoom(factor, px, py) { const k = Math.min(20, Math.max(1, s * factor)); x = px - (px - x) * k / s; y = py - (py - y) * k / s; s = k; apply() },
        pan(dx, dy) { x += dx; y += dy; apply() },
        reset() { s = 1; apply() },
      };
      addEventListener('wheel', e => setTimeout(() => {
        if (e.defaultPrevented) return;
        if (Math.abs(e.deltaY) >= Math.abs(e.deltaX)) vcx.zoom(Math.exp(-e.deltaY / 300), e.clientX, e.clientY); else vcx.pan(-e.deltaX, 0);
      }), { passive: true });
      addEventListener('mousedown', e => { if (s > 1 && e.button === 0) { drag = [e.clientX, e.clientY]; e.preventDefault() } }, true);
      addEventListener('mousemove', e => { if (drag) { vcx.pan(e.clientX - drag[0], e.clientY - drag[1]); drag = [e.clientX, e.clientY] } });
      addEventListener('mouseup', () => { drag = null });
      addEventListener('dblclick', () => vcx.reset());
      return vcx;
    })();
    """#
    // vcx.chart: a clean chart in one call (TradingView's lightweight-charts, Apache-2.0, from unpkg), zinc greys like shadcn's,
    // with the tooltip of web template `tooltip` (a dot, a guide and a card that glide to the hovered point).
    static let kit = #"""
    (() => {
      const lib = 'https://unpkg.com/lightweight-charts@5.3.0/dist/lightweight-charts.standalone.production.js';
      let loading, styled = false;
      const load = () => loading ??= new Promise((ok, fail) => {
        const script = document.createElement('script'); script.src = lib; script.onload = () => ok(window.LightweightCharts); script.onerror = fail; document.head.appendChild(script);
      });
      const css = `
    .vcx-card{font:13px/1.4 -apple-system,system-ui,Inter,sans-serif;color:#09090b}
    .vcx-head{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;min-height:30px;margin:0 2px 8px}
    .vcx-title{font-weight:600;font-size:14px}
    .vcx-value{font-weight:600;font-size:22px;font-variant-numeric:tabular-nums;letter-spacing:-.01em}
    .vcx-change{font-size:12px;font-weight:500;font-variant-numeric:tabular-nums}
    .vcx-up{color:#16a34a}.vcx-down{color:#dc2626}
    .vcx-note{color:#71717a;font-size:12px;margin-left:auto}
    .vcx-plot{position:relative}
    .vcx-plot :is(.guide,.dot,.tip){position:absolute;left:0;top:0;opacity:0;pointer-events:none;z-index:3;transition:translate 150ms ease-out,opacity 120ms ease-out}
    .vcx-plot.hover :is(.guide,.dot,.tip){opacity:1}
    .vcx-plot.still :is(.guide,.dot,.tip){transition:opacity 120ms ease-out}
    .vcx-plot .guide{width:1px;height:calc(100% - 26px);background:rgb(0 0 0/.18)}
    .vcx-plot .dot{width:9px;height:9px;margin:-4.5px;border-radius:50%;background:var(--line);box-shadow:0 0 0 2px #fff}
    .vcx-plot .tip{padding:7px 10px;border-radius:8px;background:#fff;border:1px solid #e4e4e7;box-shadow:0 4px 16px rgb(0 0 0/.10);font-size:11px;white-space:nowrap}
    .vcx-plot .tip .t{color:#71717a;margin-bottom:2px}.vcx-plot .tip .n{color:#71717a}
    .vcx-plot .tip b{font-weight:600;font-variant-numeric:tabular-nums}`;
      vcx.chart = async (o = {}) => {
        // A page that is only this script runs it in the head, before there is a body to draw into.
        if (!document.body) await new Promise(ready => addEventListener('DOMContentLoaded', ready, { once: true }));
        if (!styled) { styled = true; const style = document.createElement('style'); style.textContent = css; document.head.appendChild(style) }
        const card = document.createElement('div'); card.className = 'vcx-card';
        card.innerHTML = '<div class="vcx-head"><span class="vcx-title"></span><span class="vcx-value"></span><span class="vcx-change"></span><span class="vcx-note"></span></div><div class="vcx-plot"><div class="guide"></div><div class="dot"></div><div class="tip"></div></div>';
        ((typeof o.el === 'string' ? document.querySelector(o.el) : o.el) || document.body).appendChild(card);
        const $ = s => card.querySelector(s), plot = $('.vcx-plot'), [guide, dot, tip] = ['.guide', '.dot', '.tip'].map($);
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
          crosshair: { vertLine: { visible: false }, horzLine: { visible: false, labelVisible: false } },
          localization: { priceFormatter: fmt },
        });
        const candles = o.data?.[0]?.open !== undefined;
        const series = candles
          ? chart.addSeries(L.CandlestickSeries, { upColor: up, downColor: down, wickUpColor: up, wickDownColor: down, borderVisible: false, priceLineVisible: false, lastValueVisible: false })
          : chart.addSeries(L.AreaSeries, { lineWidth: 2, priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false });
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
          const data = rows.map(r => candles ? { ...r, time: time(r.time) } : { time: time(r.time ?? r.x), value: +(r.value ?? r.y) })
            .sort((a, b) => (a.time > b.time ? 1 : -1)).filter((r, i, all) => !i || r.time !== all[i - 1].time);
          series.setData(data);
          if (!fitted && data.length) { chart.timeScale().fitContent(); fitted = true }
          if (!o.symbol && data.length) { const first = data[0].value ?? data[0].close, last = data.at(-1).value ?? data.at(-1).close; show(last, last - first, (last - first) / first * 100) }
        };
        const label = t => {
          const intraday = typeof t === 'number' && t % 86400 !== 0;
          const date = typeof t === 'number' ? new Date(t * 1000) : typeof t === 'string' ? new Date(t + 'T00:00:00Z') : new Date(Date.UTC(t.year, t.month - 1, t.day));
          return date.toLocaleString('en-US', { ...(intraday ? { hour: 'numeric', minute: '2-digit' } : { month: 'short', day: 'numeric', year: 'numeric' }), timeZone: 'UTC' }) + (intraday && o.symbol ? ' ET' : '');
        };
        let shown = null;
        chart.subscribeCrosshairMove(p => {
          const d = p.point && p.time !== undefined ? p.seriesData.get(series) : null;
          if (!d) { plot.classList.remove('hover'); shown = null; return }
          const v = d.value ?? d.close, x = chart.timeScale().timeToCoordinate(p.time), y = series.priceToCoordinate(v);
          if (x === null || y === null) return;
          plot.classList.toggle('still', shown === null); shown = p.time;
          const rows = d.open !== undefined ? [['Open', d.open], ['High', d.high], ['Low', d.low], ['Close', d.close]] : [[o.name || o.symbol || o.title || 'Value', v]];
          tip.innerHTML = `<div class="t">${label(p.time)}</div>` + rows.map(([n, x]) => `<div><span class="n">${n}</span> <b>${fmt(x)}</b></div>`).join('');
          const w = tip.offsetWidth, h = tip.offsetHeight, left = Math.min(Math.max(0, x - w / 2), plot.clientWidth - w), top = y - h - 12 < 0 ? y + 12 : y - h - 12;
          guide.style.translate = `${x}px 0`; dot.style.translate = `${x}px ${y}px`; tip.style.translate = `${left}px ${top}px`;
          plot.classList.add('hover');
        });
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
        if context.coordinator.html != html { context.coordinator.html = html; context.coordinator.stop(); view.loadHTMLString(html.lowercased().contains("<!doctype") ? html : "<!doctype html>" + html, baseURL: nil) }
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
            view.evaluateJavaScript(ChartWeb.measure) { [weak self] value, _ in self?.report(value) }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "live" { live(message.body, in: message.webView) } else { report(message.body) }
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
        private func report(_ body: Any?) {
            guard let value = (body as? NSNumber)?.doubleValue, value > 0 else { return }
            let height = self.height
            Task { @MainActor in height(min(max(CGFloat(value), 40), 900)) }
        }
    }
}
