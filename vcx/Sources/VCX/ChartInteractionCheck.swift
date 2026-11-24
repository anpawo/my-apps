import AppKit
import SwiftUI
import WebKit

@MainActor
enum ChartInteractionCheck {
    private static let loadSeconds = 1.0
    private static let eventSeconds = 0.1
    private static let pollSeconds = 0.01
    private static let timeoutSeconds = 5.0
    private static let page = #"<body style="padding:20px;font:16px system-ui"><label>Monthly pay <input id="pay" type="number" value="2000"></label><button id="preset" onclick="pay.value=3300">Full-time</button><div id="plot" style="height:180px;background:#f4f4f5;margin-top:20px">Forecast</div></body>"#

    static func run(directory: String) -> Bool {
        try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var opened: ChartZoom?
        let host = NSHostingView(rootView: ChartBlock(html: page).environment(\.openChart) { opened = $0 })
        let window = mount(host, size: CGSize(width: 640, height: 320))
        defer { window.close() }
        guard let view = web(host) else { return fail("inline chart exists") }

        click(view, selector: "#pay")
        guard opened == nil else { return fail("editing an inline input must not enlarge the dashboard") }
        guard js(view, "document.activeElement.id") as? String == "pay" else { return fail("inline input receives focus") }
        increment(view)
        guard js(view, "pay.value") as? String == "2001" else { return fail("inline input accepts keyboard edits") }
        click(view, selector: "#preset")
        guard opened == nil, js(view, "pay.value") as? String == "3300" else { return fail("inline buttons update without enlarging") }
        click(view, selector: "#plot")
        guard let chart = opened else { return fail("clicking chart background still enlarges") }

        let preview = NSHostingView(rootView: ChartPreview(chart: chart, size: CGSize(width: 1000, height: 700)) {})
        let enlarged = mount(preview, size: CGSize(width: 1000, height: 700))
        defer { enlarged.close() }
        guard let zoomed = web(preview) else { return fail("enlarged chart exists") }
        click(zoomed, selector: "#pay")
        guard js(zoomed, "document.activeElement.id") as? String == "pay" else { return fail("enlarged input receives focus") }
        increment(zoomed)
        guard js(zoomed, "pay.value") as? String == "2001" else { return fail("enlarged input accepts keyboard edits") }
        click(zoomed, selector: "#preset")
        guard js(zoomed, "pay.value") as? String == "3300" else { return fail("enlarged preset updates pay") }
        _ = js(zoomed, "vcx.zoom(1.5, 0, 0); 0")
        let allowed = js(zoomed, "const event = new MouseEvent('mousedown', {bubbles:true,cancelable:true,button:0}); pay.dispatchEvent(event); !event.defaultPrevented") as? Bool
        guard allowed == true else { return fail("page zoom must not cancel input editing") }
        snapshot(zoomed, path: directory + "/chart-controls.png")
        print("PASS: inline controls edit without enlargement; background enlarges; enlarged controls remain interactive after zoom")
        return true
    }

    private static func mount(_ host: NSView, size: CGSize) -> NSWindow {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        RunLoop.main.run(until: Date() + loadSeconds)
        return window
    }

    private static func web(_ view: NSView) -> WKWebView? {
        (view as? WKWebView) ?? view.subviews.lazy.compactMap(web).first
    }

    private static func js(_ view: WKWebView, _ script: String) -> Any? {
        var result: Any?, done = false
        view.evaluateJavaScript(script) { value, _ in result = value; done = true }
        let deadline = Date() + timeoutSeconds
        while !done && Date() < deadline { RunLoop.main.run(until: Date() + pollSeconds) }
        return result
    }

    private static func click(_ view: WKWebView, selector: String) {
        let rect = js(view, "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2] })()") as? [Double] ?? []
        precondition(rect.count == 2, "Fixture target exists")
        let point = NSPoint(x: rect[0] * view.pageZoom, y: view.isFlipped ? rect[1] * view.pageZoom : view.bounds.height - rect[1] * view.pageZoom)
        let location = view.convert(point, to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            RunLoop.main.run(until: Date() + eventSeconds)
        }
    }

    private static func snapshot(_ view: WKWebView, path: String) {
        var done = false
        view.takeSnapshot(with: nil) { image, _ in
            if let data = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: data) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            done = true
        }
        let deadline = Date() + timeoutSeconds
        while !done && Date() < deadline { RunLoop.main.run(until: Date() + pollSeconds) }
    }

    private static func increment(_ view: WKWebView) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber, context: nil, characters: "\u{f700}", charactersIgnoringModifiers: "\u{f700}", isARepeat: false, keyCode: 126)!
        view.keyDown(with: event)
        RunLoop.main.run(until: Date() + eventSeconds)
    }

    private static func fail(_ message: String) -> Bool {
        fputs("FAIL: \(message)\n", stderr)
        return false
    }
}
