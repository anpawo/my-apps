import AppKit
import SwiftUI
import WebKit

@MainActor
enum ChartInteractionCheck {
    private static let loadSeconds = 1.0
    private static let eventSeconds = 0.1
    private static let focusHoldSeconds = 0.5
    private static let pollSeconds = 0.01
    private static let timeoutSeconds = 5.0
    private static let page = #"<body style="padding:20px;font:16px system-ui"><label>Monthly pay <input id="pay" type="number" value="2000"></label><button id="preset" onclick="pay.value=3300">Full-time</button><div id="plot" style="height:180px;background:#f4f4f5;margin-top:20px">Forecast</div></body>"#
    private static var composerFocusRequests = 0
    private static var optionSelections = 0

    static func run(directory: String, pagePath: String? = nil) -> Bool {
        composerFocusRequests = 0; optionSelections = 0
        try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var opened: ChartZoom?
        let pins = ChartPin()
        let host = NSHostingView(rootView: ChartBlock(html: page).environment(pins).environment(\.openChart) { opened = $0 })
        let window = mount(host, size: CGSize(width: 640, height: 320))
        defer { window.close() }
        guard let view = web(host) else { return fail("inline chart exists") }

        click(view, selector: "#pay")
        guard keepsFocusAfterWindowClick(view) else { return fail("inline input keeps window focus after mouse release") }
        guard opened == nil else { return fail("editing an inline input must not enlarge the dashboard") }
        guard js(view, "document.activeElement.id") as? String == "pay" else { return fail("inline input receives focus") }
        increment(view)
        guard js(view, "pay.value") as? String == "2001" else { return fail("inline input accepts keyboard edits") }
        guard typesInField(view) else { return fail("inline typing stays out of the composer and numbered options") }
        click(view, selector: "#preset")
        guard opened == nil, js(view, "pay.value") as? String == "3300" else { return fail("inline buttons update without enlarging") }
        click(view, selector: "#plot")
        guard opened == nil else { return fail("a single chart click does not enlarge") }
        click(view, selector: "#plot", right: true)
        guard pins.html == page, opened == nil else { return fail("right-click pins without enlarging") }
        click(view, selector: "#plot", right: true)
        guard pins.html == nil else { return fail("right-click toggles the pin off") }
        click(view, selector: "#pay", count: 2)
        guard opened == nil else { return fail("double-clicking a field keeps editing") }
        click(view, selector: "#plot", count: 2)
        guard let chart = opened else { return fail("double-clicking chart background enlarges") }

        let preview = NSHostingView(rootView: ChartPreview(chart: chart, size: CGSize(width: 1000, height: 700)) {})
        let enlarged = mount(preview, size: CGSize(width: 1000, height: 700))
        defer { enlarged.close() }
        guard let zoomed = web(preview) else { return fail("enlarged chart exists") }
        click(zoomed, selector: "#pay")
        guard keepsFocusAfterWindowClick(zoomed) else { return fail("enlarged input keeps window focus after mouse release") }
        guard js(zoomed, "document.activeElement.id") as? String == "pay" else { return fail("enlarged input receives focus") }
        increment(zoomed)
        guard js(zoomed, "pay.value") as? String == "2001" else { return fail("enlarged input accepts keyboard edits") }
        guard typesInField(zoomed) else { return fail("enlarged typing stays out of the composer and numbered options") }
        click(zoomed, selector: "#preset")
        guard js(zoomed, "pay.value") as? String == "3300" else { return fail("enlarged preset updates pay") }
        _ = js(zoomed, "vcx.zoom(1.5, 0, 0); 0")
        let allowed = js(zoomed, "const event = new MouseEvent('mousedown', {bubbles:true,cancelable:true,button:0}); pay.dispatchEvent(event); !event.defaultPrevented") as? Bool
        guard allowed == true else { return fail("page zoom must not cancel input editing") }
        snapshot(zoomed, path: directory + "/chart-controls.png")
        windowClick(enlarged, at: NSPoint(x: 2, y: 2))
        guard composerFocusRequests == 1 else { return fail("clicking outside web content still focuses the composer") }
        let tall = "<body><input type='number' value='2000'><div style='height:2500px;background:linear-gradient(white,silver)'>Forecast</div></body>"
        guard enlargedWheelStaysInPage(html: tall, directory: directory) else { return false }
        guard pinnedChartEnlargesContent(directory: directory) else { return false }
        if let pagePath {
            guard let html = try? String(contentsOfFile: pagePath, encoding: .utf8),
                  enlargedWheelStaysInPage(html: html, directory: directory),
                  expandedPreviewFitsContent(html: html, directory: directory) else { return fail("supplied dashboard fits and scrolls inside its preview") }
        }
        print("PASS: inline and enlarged fields retain window focus and accept typing; numbered options stay untouched; outside clicks still focus the composer")
        return true
    }

    private static func mount(_ host: NSView, size: CGSize) -> NSWindow {
        host.frame = NSRect(origin: .zero, size: size)
        let window = ComposerWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let composer = NSTextView(frame: NSRect(x: 0, y: -40, width: 100, height: 24))
        host.addSubview(composer)
        window.focusComposer = { [weak window] in
            composerFocusRequests += 1
            DispatchQueue.main.async { window?.makeFirstResponder(composer) }
        }
        window.chooseOption = { _ in optionSelections += 1; return true }
        RunLoop.main.run(until: Date() + loadSeconds)
        return window
    }

    private static func enlargedWheelStaysInPage(html: String, directory: String) -> Bool {
        let session = Session(cwd: directory, stateDirectory: URL(fileURLWithPath: directory).appendingPathComponent(UUID().uuidString))
        session.ready = true; session.status = "Ready"; session.follow.attached = false
        session.show(["id": "scroll-question", "type": "userMessage", "content": [["type": "text", "text": "Show forecast"]]])
        session.show(["id": "scroll-answer", "type": "agentMessage", "text": String(repeating: "Forecast details\n\n", count: 100)])
        session.chart = ChartZoom(html: html, size: CGSize(width: 640, height: 400))
        let host = VCXView.host(session)
        let window = mount(host, size: CGSize(width: 1176 + taskBarWidth, height: 803))
        defer { window.close() }
        guard let view = web(host), let transcript = RuntimeUpdate.scrollView(in: host) else { return fail("preview and transcript exist") }
        transcript.contentView.scroll(to: NSPoint(x: 0, y: 200))
        transcript.reflectScrolledClipView(transcript.contentView)
        RunLoop.main.run(until: Date() + focusHoldSeconds)
        let origin = transcript.contentView.bounds.origin
        RunLoop.main.run(until: Date() + focusHoldSeconds)
        guard transcript.contentView.bounds.origin == origin else { return fail("background transcript is stationary before the wheel") }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard transcript.convert(transcript.bounds, to: nil).contains(point) else { return fail("preview covers the transcript") }
        let hit = host.hitTest(host.superview?.convert(point, from: nil) ?? point)
        guard hit === view || hit?.isDescendant(of: view) == true else { return fail("pointer hits the enlarged web page") }
        _ = js(view, "window.wheelCount=0; addEventListener('wheel',()=>wheelCount++); scrollTo(0,0); 0")
        for delta: Int32 in [-120, 60] {
            let before = js(view, "scrollY") as? Double ?? -1
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
            cg.location = point
            let event = NSEvent(cgEvent: cg)!
            let passed = TranscriptWheel.route(event, in: window, at: point)
            if let passed { view.scrollWheel(with: passed) }
            RunLoop.main.run(until: Date() + focusHoldSeconds)
            let after = js(view, "scrollY") as? Double ?? -1
            let chatMoved = transcript.contentView.bounds.origin != origin
            print("Preview wheel: delta=\(delta), passed=\(passed != nil), page=\(before)->\(after), chat=\(origin.y)->\(transcript.contentView.bounds.origin.y)")
            guard passed != nil, !chatMoved else { return fail("wheel over enlarged page never reaches the chat behind it") }
            guard delta < 0 ? after > before : after < before else { return fail("enlarged page scrolls in the wheel direction") }
        }
        guard js(view, "wheelCount") as? Int == 2 else { return fail("native wheel events reach the page") }
        return scrollsOverFormControls(view)
    }

    private static func scrollsOverFormControls(_ view: WKWebView) -> Bool {
        guard js(view, "!!document.querySelector('input')") as? Bool == true else { return true }
        let value = js(view, "window.wheelInput=document.querySelector('input'); wheelInput.scrollIntoView({block:'center'}); wheelInput.value") as? String
        for delta in [80, -40] {
            let before = js(view, "scrollY") as! Double
            _ = js(view, "wheelInput.dispatchEvent(new WheelEvent('wheel',{deltaY:\(delta),bubbles:true,cancelable:true})); 0")
            RunLoop.main.run(until: Date() + focusHoldSeconds)
            let after = js(view, "scrollY") as! Double
            print("Form wheel: delta=\(delta), page=\(before)->\(after)")
            guard delta > 0 ? after > before : after < before else { return fail("wheel over form fields scrolls the enlarged page") }
            guard js(view, "wheelInput.value") as? String == value else { return fail("scrolling over a field preserves its value") }
        }
        let before = js(view, "scrollY") as! Double
        _ = js(view, "wheelInput.addEventListener('wheel',e=>e.preventDefault(),{once:true,passive:false}); wheelInput.dispatchEvent(new WheelEvent('wheel',{deltaY:80,bubbles:true,cancelable:true})); 0")
        RunLoop.main.run(until: Date() + focusHoldSeconds)
        return js(view, "scrollY") as? Double == before || fail("a field that handles its own wheel keeps it")
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

    private static func click(_ view: WKWebView, selector: String, count: Int = 1, right: Bool = false) {
        let rect = js(view, "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2] })()") as? [Double] ?? []
        precondition(rect.count == 2, "Fixture target exists")
        let point = NSPoint(x: rect[0] * view.pageZoom, y: view.isFlipped ? rect[1] * view.pageZoom : view.bounds.height - rect[1] * view.pageZoom)
        let location = view.convert(point, to: nil)
        for type: NSEvent.EventType in right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            case .rightMouseDown: view.rightMouseDown(with: event)
            default: view.rightMouseUp(with: event)
            }
            RunLoop.main.run(until: Date() + eventSeconds)
        }
        RunLoop.main.run(until: Date() + focusHoldSeconds)
    }

    private static func pinnedChartEnlargesContent(directory: String) -> Bool {
        let html = "<body><div id='plot' style='height:200px;background:#eee'>Forecast</div><div style='height:1800px'>Monthly details</div></body>"
        let pins = ChartPin(); pins.toggle(html)
        var opened: ChartZoom?
        let host = NSHostingView(rootView: PinnedChart(html: html, pins: pins).environment(\.openChart) { opened = $0 })
        let window = mount(host, size: CGSize(width: 1000, height: 700))
        defer { window.close() }
        guard let view = web(host) else { return fail("pinned chart exists") }
        click(view, selector: "#plot", count: 2)
        guard let chart = opened, chart.size.height > view.bounds.height else { return fail("pinned double-click opens the full content height") }
        click(view, selector: "#plot", right: true)
        guard pins.html == nil else { return fail("right-click unpins a pinned chart") }
        return expandedPreviewFitsContent(html: html, directory: directory)
    }

    private static func expandedPreviewFitsContent(html: String, directory: String) -> Bool {
        let available = CGSize(width: 1000, height: 700)
        let chart = ChartZoom(html: html, size: CGSize(width: 640, height: 1800))
        let host = NSHostingView(rootView: ZStack { ChartPreview(chart: chart, size: available) {} }.frame(maxWidth: .infinity, maxHeight: .infinity))
        host.sizingOptions = []
        let window = mount(host, size: available)
        defer { window.close() }
        guard let view = web(host) else { return fail("expanded dashboard exists") }
        let frame = view.convert(view.bounds, to: nil)
        let minimumWidth = available.width * 0.8, maximumHeight = available.height * 0.85
        let centeringTolerance = 1.0
        print("Expanded content: \(Int(frame.width)) x \(Int(frame.height)) in \(Int(available.width)) x \(Int(available.height))")
        guard frame.width >= minimumWidth, frame.height <= maximumHeight,
              abs(frame.midX - available.width / 2) <= centeringTolerance else { return fail("expanded tall content uses the window width and stays centered inside it") }
        snapshot(view, path: directory + "/chart-expanded.png")
        return true
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
        view.window!.sendEvent(event)
        RunLoop.main.run(until: Date() + eventSeconds)
    }

    private static func retainsWindowFocus(_ view: WKWebView) -> Bool {
        let responder = view.window?.firstResponder as? NSView
        return composerFocusRequests == 0 && (responder === view || responder?.isDescendant(of: view) == true)
    }

    private static func keepsFocusAfterWindowClick(_ view: WKWebView) -> Bool {
        // Unshown windows do not acquire focus from the desktop; start with the web field focused, then replay the window policy.
        view.window!.makeFirstResponder(view)
        guard js(view, "document.activeElement.id") as? String == "pay" else { return false }
        let rect = js(view, "const r = pay.getBoundingClientRect(); [r.x+r.width/2,r.y+r.height/2]") as! [Double]
        let point = NSPoint(x: rect[0] * view.pageZoom, y: view.isFlipped ? rect[1] * view.pageZoom : view.bounds.height - rect[1] * view.pageZoom)
        windowClick(view.window!, at: view.convert(point, to: nil))
        return retainsWindowFocus(view)
    }

    private static func windowClick(_ window: NSWindow, at point: NSPoint) {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            RunLoop.main.run(until: Date() + focusHoldSeconds)
        }
    }

    private static func typesInField(_ view: WKWebView) -> Bool {
        _ = js(view, "pay.select(); 0")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber, context: nil, characters: "4", charactersIgnoringModifiers: "4", isARepeat: false, keyCode: 21)!
        view.window!.sendEvent(event)
        RunLoop.main.run(until: Date() + focusHoldSeconds)
        return retainsWindowFocus(view) && optionSelections == 0 && js(view, "pay.value") as? String == "4"
    }

    private static func fail(_ message: String) -> Bool {
        fputs("FAIL: \(message)\n", stderr)
        return false
    }
}
