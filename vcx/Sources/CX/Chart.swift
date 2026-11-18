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
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ChartWebView {
        let configuration = WKWebViewConfiguration()
        // Wrapped so they declare no global: a page's own `let s` would otherwise throw and never draw.
        let style = "(() => { const s = document.createElement('style'); s.textContent = 'html,body{margin:0;overflow:hidden;background:transparent}" + (inline ? " *{cursor:crosshair !important}" : "") + "'; document.documentElement.appendChild(s) })();"
        let report = "new ResizeObserver(() => webkit.messageHandlers.size.postMessage(\(Self.measure))).observe(document.body);"
        configuration.userContentController.addUserScript(WKUserScript(source: style, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
