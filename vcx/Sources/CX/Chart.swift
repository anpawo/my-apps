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

struct ChartBlock: View {
    let html: String
    @Environment(\.openChart) private var openChart
    @State private var height: CGFloat
    @State private var size = CGSize.zero
    init(html: String) { self.html = html; _height = State(initialValue: chartHeights[html] ?? 240) }
    var body: some View {
        ChartWeb(html: html, zoom: 1, inline: true, height: { h in chartHeights[html] = h; if abs(height - h) > 0.5 { height = h } }, click: { size in openChart?(ChartZoom(html: html, size: size)) })
            .frame(maxWidth: 760).frame(height: height)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.1)))
            .overlay(alignment: .topTrailing) {
                Button { openChart?(ChartZoom(html: html, size: size)) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).opacity(0.5).frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.reactive(RoundedRectangle(cornerRadius: 6))).padding(4).help("Enlarge the chart").accessibilityLabel("Enlarge chart")
            }
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
    static let measure = "Math.ceil(Math.max(0, ...Array.from(document.body.children, e => e.getBoundingClientRect().bottom + window.scrollY)))"
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ChartWebView {
        let configuration = WKWebViewConfiguration()
        // Wrapped so they declare no global: a page's own `let s` would otherwise throw and never draw.
        let style = "(() => { const s = document.createElement('style'); s.textContent = 'html,body{margin:0;overflow:hidden;background:transparent}" + (inline ? " *{cursor:zoom-in !important}" : "") + "'; document.documentElement.appendChild(s) })();"
        let report = "new ResizeObserver(() => webkit.messageHandlers.size.postMessage(\(Self.measure))).observe(document.body);"
        configuration.userContentController.addUserScript(WKUserScript(source: style, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: report, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "size")
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
        if context.coordinator.html != html { context.coordinator.html = html; view.loadHTMLString(html.lowercased().contains("<!doctype") ? html : "<!doctype html>" + html, baseURL: nil) }
    }
    static func dismantleNSView(_ view: ChartWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "size")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var html = ""
        var height: (CGFloat) -> Void = { _ in }
        // A window that is not on screen runs no ResizeObserver, so the height is also read once the page has loaded.
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            view.evaluateJavaScript(ChartWeb.measure) { [weak self] value, _ in self?.report(value) }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { report(message.body) }
        private func report(_ body: Any?) {
            guard let value = (body as? NSNumber)?.doubleValue, value > 0 else { return }
            let height = self.height
            Task { @MainActor in height(min(max(CGFloat(value), 40), 900)) }
        }
    }
}
