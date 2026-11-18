import AppKit
import WebKit

struct Broker { let name, account, home: String }

let brokers = [
    Broker(name: "Bourse Direct", account: "PEA", home: "https://www.boursedirect.fr/fr/login"),
    Broker(name: "Trade Republic", account: "CTO", home: "https://app.traderepublic.com/"),
]
let finance = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("self/trading/finance")
// Sessions expire on idle; 4 min stays under the shortest idle timeout seen on French broker sites (10 min).
let keepAliveSeconds: TimeInterval = 240
// A mouse move resets the page's own idle timer; a same-origin GET with its cookies resets the server's.
let keepAliveJS = """
document.dispatchEvent(new MouseEvent('mousemove', {bubbles: true}));
fetch(location.href, {credentials: 'include', cache: 'no-store'}).catch(() => {});
"""

func runPlan() -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = finance.appendingPathComponent("insiders/.venv/bin/python")
    p.arguments = ["-I", finance.appendingPathComponent("allocation/plan.py").path]
    p.currentDirectoryURL = finance.appendingPathComponent("allocation")
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "Could not run plan.py: \(error.localizedDescription)" }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return p.terminationStatus == 0 ? out : "plan.py exited \(p.terminationStatus):\n" + out
}

func esc(_ s: Substring) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
}

/// plan.py prints text lines then markdown tables: lines become paragraphs, tables become HTML tables.
func planHTML(_ text: String) -> String {
    var body = "", rows: [[Substring]] = []
    func flush() {
        guard let head = rows.first else { return }
        body += "<table><tr>" + head.map { "<th>\(esc($0))</th>" }.joined() + "</tr>"
        body += rows.dropFirst().map { "<tr>" + $0.map { "<td>\(esc($0))</td>" }.joined() + "</tr>" }.joined() + "</table>"
        rows = []
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("|") {
            if !line.allSatisfy({ "|-: ".contains($0) }) {
                rows.append(line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                    .map { $0.trimmingCharacters(in: .whitespaces)[...] })
            }
        } else {
            flush()
            if !line.isEmpty { body += "<p>\(esc(line))</p>" }
        }
    }
    flush()
    return """
    <meta charset="utf-8"><style>
    :root { color-scheme: light dark } body { font: 13px -apple-system; margin: 14px }
    h3 { font-size: 13px; margin: 0 0 10px } p { margin: 0 0 8px; line-height: 1.4 }
    table { border-collapse: collapse; margin: 6px 0 14px; width: 100% }
    th, td { text-align: left; padding: 4px 6px; border-bottom: 1px solid #8884; font-variant-numeric: tabular-nums }
    th { font-weight: 600; color: #888 }
    </style><h3>Allocation check</h3>\(body)
    """
}

final class Desk: NSObject, WKUIDelegate, WKNavigationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 920),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let tabs = NSSegmentedControl()
    let status = NSTextField(labelWithString: "")
    let plan = WKWebView()
    var views: [WKWebView] = []
    var pending = 0
    var onSettled: (() -> Void)?

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Some broker pages refuse a browser they cannot name: say Safari, which WKWebView is.
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        tabs.segmentCount = brokers.count
        tabs.trackingMode = .selectOne
        tabs.target = self; tabs.action = #selector(tabClicked)
        let box = NSView()
        for (i, b) in brokers.enumerated() {
            let v = WKWebView(frame: .zero, configuration: config)
            v.uiDelegate = self; v.navigationDelegate = self
            v.allowsBackForwardNavigationGestures = true
            v.isHidden = i != 0
            v.autoresizingMask = [.width, .height]
            box.addSubview(v)
            views.append(v)
            tabs.setLabel("\(b.name) · \(b.account)  ⌘\(i + 1)", forSegment: i)
            let saved = UserDefaults.standard.string(forKey: b.name).flatMap(URL.init(string:))
            pending += 1
            v.load(URLRequest(url: saved ?? URL(string: b.home)!))
        }
        tabs.selectedSegment = 0
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [tabs, NSView(), status])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(box)
        split.addArrangedSubview(plan)
        let root = NSView()
        for v in [bar, split] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor), split.topAnchor.constraint(equalTo: bar.bottomAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window.contentView = root
        window.title = "Trade"
        window.center()
        window.setFrameAutosaveName("Trade")
        split.setHoldingPriority(.init(251), forSubviewAt: 1)
        let width = plan.widthAnchor.constraint(equalToConstant: 380)
        width.priority = .init(260)  // above the split's holding priority (251), below a divider drag (490)
        NSLayoutConstraint.activate([width, box.widthAnchor.constraint(greaterThanOrEqualToConstant: 500)])
        for v in box.subviews { v.frame = box.bounds }
        refreshPlan()
        Timer.scheduledTimer(withTimeInterval: keepAliveSeconds, repeats: true) { [weak self] _ in self?.keepAlive() }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.refreshPlan() }
    }

    func show(_ i: Int) {
        for (j, v) in views.enumerated() { v.isHidden = j != i }
        tabs.selectedSegment = i
        window.makeFirstResponder(views[i])
    }

    @objc func tabClicked() { show(tabs.selectedSegment) }
    @objc func showMenu(_ item: NSMenuItem) { show(item.tag) }
    @objc func reloadPage() { views[tabs.selectedSegment].reload() }
    @objc func goHome() { views[tabs.selectedSegment].load(URLRequest(url: URL(string: brokers[tabs.selectedSegment].home)!)) }

    @objc func refreshPlan() {
        pending += 1
        DispatchQueue.global().async {
            let html = planHTML(runPlan())
            DispatchQueue.main.async { self.plan.loadHTMLString(html, baseURL: nil); self.settle() }
        }
    }

    func keepAlive() {
        for v in views { v.evaluateJavaScript(keepAliveJS) }
        status.stringValue = "Sessions kept alive at " + Date().formatted(date: .omitted, time: .shortened)
    }

    func settle() {
        pending -= 1
        if pending == 0 { onSettled?() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let i = views.firstIndex(of: webView), let url = webView.url?.absoluteString {
            UserDefaults.standard.set(url, forKey: brokers[i].name)
        }
        if views.contains(webView) { settleOnce(webView) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { settleOnce(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        settleOnce(webView)
    }

    var settled = Set<ObjectIdentifier>()
    func settleOnce(_ v: WKWebView) {
        if settled.insert(ObjectIdentifier(v)).inserted { settle() }
    }

    // target=_blank links and window.open (an order ticket, a statement) open in the same tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(action.request)
        return nil
    }

    // Without these, window.alert shows nothing and window.confirm answers "cancel", so an order a site
    // confirms through confirm() could never go through.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message
        a.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    /// Renders both broker tabs and the allocation panel to PNGs without putting a window on screen.
    func snapshot(to dir: URL) {
        onSettled = { [self] in
            // Late scripts (Trade Republic's app) draw after didFinish.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [self] in
                let shots = [("plan", plan)] + zip(["bourse-direct", "trade-republic"], views).map { ($0, $1) }
                var left = shots.count
                for (name, v) in shots {
                    v.isHidden = false
                    let config = WKSnapshotConfiguration()
                    config.afterScreenUpdates = false
                    v.takeSnapshot(with: config) { image, error in
                        let url = dir.appendingPathComponent("\(name).png")
                        if let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?
                            .representation(using: .png, properties: [:]) {
                            try? png.write(to: url)
                            print("\(name): \(Int(image.size.width))x\(Int(image.size.height)) \(v.url?.host ?? "") \(url.path)")
                        } else {
                            print("\(name): no snapshot \(v.frame) \(error?.localizedDescription ?? "")")
                        }
                        left -= 1
                        if left == 0 { exit(0) }
                    }
                }
            }
        }
        if pending == 0 { onSettled?() }
    }
}

func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    top.submenu = NSMenu(title: title)
    items.forEach(top.submenu!.addItem)
    return top
}

func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
          target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
    i.keyEquivalentModifierMask = mods; i.target = target; i.tag = tag
    return i
}

func selftest() {
    let html = planHTML("Portfolio empty: <nothing>.\n\n| Part | Value |\n|---|---|\n| World ETF (PEA) | €0 |\n\nTo place €200.\n")
    precondition(html.contains("<p>Portfolio empty: &lt;nothing>.</p>"), html)
    precondition(html.contains("<tr><th>Part</th><th>Value</th></tr><tr><td>World ETF (PEA)</td><td>€0</td></tr></table>"), html)
    precondition(html.contains("<p>To place €200.</p>") && !html.contains("---"), html)
    print("selftest ok")
}

let args = CommandLine.arguments
if args.contains("--selftest") { selftest(); exit(0) }
let app = NSApplication.shared
app.setActivationPolicy(args.contains("--snapshot") ? .prohibited : .regular)
// Without it App Nap would stretch the keep-alive timer while the window sits behind others.
let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "broker keep-alive")
let desk = Desk()
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    desk.window.setFrame(NSRect(x: 0, y: 0, width: 1500, height: 920), display: false)
    desk.snapshot(to: URL(fileURLWithPath: args[i + 1]))
} else {
    let main = NSMenu()
    main.addItem(menu("Trade", [item("Hide Trade", #selector(NSApplication.hide(_:)), "h"),
                                item("Quit Trade", #selector(NSApplication.terminate(_:)), "q")]))
    main.addItem(menu("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                               .separator(),
                               item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                               item("Paste", #selector(NSText.paste(_:)), "v"),
                               item("Select All", #selector(NSText.selectAll(_:)), "a")]))
    main.addItem(menu("View", brokers.enumerated().map {
        item("\($1.name) (\($1.account))", #selector(Desk.showMenu(_:)), "\($0 + 1)", target: desk, tag: $0)
    } + [.separator(),
         item("Reload Page", #selector(Desk.reloadPage), "r", target: desk),
         item("Broker Home", #selector(Desk.goHome), "h", [.command, .shift], target: desk),
         item("Back", #selector(WKWebView.goBack(_:)), "["), item("Forward", #selector(WKWebView.goForward(_:)), "]"),
         item("Refresh Allocation", #selector(Desk.refreshPlan), "r", [.command, .shift], target: desk)]))
    app.mainMenu = main
    desk.window.makeKeyAndOrderFront(nil)
    app.activate()
}
app.run()
