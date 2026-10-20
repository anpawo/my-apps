import AppKit
import Carbon.HIToolbox
import Foundation

/// `echo --selftest`: the panel's rules against files as the checker writes them, and its entrance read frame by
/// frame on a panel put off every screen. `swift test` runs nothing without Xcode, so it is a flag.
@MainActor
enum SelfCheck {

    static func run() -> Int {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            if got == want { print("  ok    \(what)") } else {
                print("  FAIL  \(what)\n        want \(want)\n        got  \(got)")
                failures += 1
            }
        }
        inbox(expect)
        glass(expect)
        print(failures == 0 ? "\nall ok" : "\n\(failures) FAILED")
        return failures
    }

    /// The checks' glass, in a window never shown: its backdrop takes the site's filters and the material's tints
    /// are hidden. A macOS that renames these private layers fails here, not on his screen.
    private static func glass(_ expect: (Bool, Bool, String) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = Glass(blur: 40, tone: Glass.matrix, radius: 14)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        window.contentView = view
        window.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.display()
        let layers = view.layer?.sublayers?.flatMap { $0.sublayers ?? [] } ?? []
        let backdrop = layers.first { $0.name == "backdrop" }
        let names = (backdrop?.filters ?? []).compactMap { ($0 as? NSObject)?.value(forKey: "name") as? String }
        expect(Array(names.suffix(2)) == ["cssBlur", "colorMatrix"], true, "glass: the backdrop blurs, then saturates and brightens as the site does (\(names))")
        var m = [Float](repeating: 0, count: 20)
        ((backdrop?.filters?.last as? NSObject)?.value(forKey: "inputColorMatrix") as? NSValue)?.getValue(&m, size: 80)
        expect(m == Glass.pack(Glass.matrix), true, "glass: the backdrop holds the CSS matrix as given (\(m.prefix(3)))")
        expect(layers.filter { $0 !== backdrop }.allSatisfy(\.isHidden) && layers.count > 1, true, "glass: the material's own tints are hidden")
    }

    /// The watcher's lines: in time order, ←→ wrap and take nothing away, ↵ opens and sets the line aside in `done/`
    /// once its terminal has started; ↓ only asks, however often, and only ↵ says yes (to `done/`).
    private static func inbox(_ expect: (Bool, Bool, String) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "echo-inbox-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (id, at) in [("b", 2), ("a", 1), ("d", 4), ("c", 3)] {
            try? Data(#"{"id":"\#(id)","at":\#(at),"kind":"done","subject":"s","line":"l","dir":"/","options":["--resume","x"]}"#.utf8)
                .write(to: folder.appending(path: "\(id).json"))
        }
        try? Data("{".utf8).write(to: folder.appending(path: ".e"))
        let inbox = Inbox(folder: folder)
        var opened: [String] = [], starts = false
        inbox.launch = { opened.append($0.id); return starts }
        let kept = { (id: String) in FileManager.default.fileExists(atPath: folder.appending(path: "done/\(id).json").path) }
        func press(_ code: Int) { _ = inbox.key(UInt16(code)) }
        inbox.refresh()
        expect(inbox.items.map(\.id) == ["a", "b", "c", "d"], true, "inbox: read in time order, a file not yet renamed in left out")
        press(kVK_LeftArrow)
        expect(inbox.current?.id == "d" && inbox.items.count == 4, true, "inbox: ← from the first wraps to the last, nothing taken")
        press(kVK_Return)
        expect(opened == ["d"] && inbox.items.count == 4, true, "inbox: an open whose terminal did not start keeps its line")
        starts = true
        press(kVK_Return)
        expect(inbox.items.map(\.id) == ["a", "b", "c"] && kept("d"), true, "inbox: an open that started sets its line aside as done")
        press(kVK_DownArrow)
        expect(inbox.items.count == 3 && inbox.asking == Inbox.Ask(id: "c"), true, "inbox: ↓ only asks")
        press(kVK_Return)
        expect(inbox.items.map(\.id) == ["a", "b"] && kept("c") && opened.count == 2, true, "inbox: ↵ after ↓ sets it aside as done, opening nothing")
        starts = false
        press(kVK_DownArrow)
        press(kVK_Escape)
        press(kVK_Return)
        expect(inbox.items.map(\.id) == ["a", "b"] && opened.count == 3, true, "inbox: Esc after ↓ keeps it, and ↵ then opens")
        press(kVK_DownArrow)
        press(kVK_DownArrow)
        expect(inbox.items.count == 2 && inbox.asking == Inbox.Ask(id: "b") && !kept("b"), true, "inbox: ↓ again at once (a double click, a held key) still asks")
        expect(inbox.key(UInt16(kVK_UpArrow)), false, "inbox: ↑ is left to go on")
        press(kVK_DownArrow)
        press(kVK_Return)
        expect(inbox.items.map(\.id) == ["a"] && kept("b"), true, "inbox: only ↵ says yes")
        expect(inbox.key(UInt16(kVK_ANSI_A)), false, "inbox: a letter is left to go on")
        let state = FileManager.default.temporaryDirectory.appending(path: "echo-checks-\(getpid())")
        try? FileManager.default.createDirectory(at: state.appending(path: "fired"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try? Data(#"{"id":"w","name":"W","chat":"Maman","since":5}"#.utf8).write(to: state.appending(path: "w.json"))
        try? Data(#"{"id":"a","name":"A","cmd":"x","since":1,"fired":{"at":9}}"#.utf8).write(to: state.appending(path: "fired/a.json"))
        try? Data(#"{"id":"d","name":"D","chat":"Maman","since":1,"dropped":3}"#.utf8).write(to: state.appending(path: "fired/d.json"))
        let checks = CheckEntry.load(state: state)
        expect(checks.entries.map { "\($0.id)\($0.state.rawValue)" } == ["wwaiting", "ddropped", "aarrived"], true,
               "checks: waiting, then dropped, then arrived, a dropped one marked")
        expect(checks.entries.map(\.channel) == [.whatsapp, .whatsapp, .command], true, "checks: a chat is WhatsApp, a cmd a command")
        let echo = Inbox(folder: state.appending(path: "inbox"))
        expect(echo.key(UInt16(kVK_ANSI_S)) && echo.settings && echo.checks.count == 3, true, "inbox: S shows the checks")
        expect(echo.key(UInt16(kVK_DownArrow)), false, "inbox: in the checks, other keys go on")
        expect(echo.key(UInt16(kVK_Escape)) && !echo.settings, true, "inbox: Esc in the checks closes Echo")
        press(kVK_DownArrow)
        press(kVK_Return)
        expect(inbox.past && inbox.items.map(\.id) == ["d", "c", "b", "a"], true, "inbox: at 0, the lines set aside, newest first")
        press(kVK_DownArrow)
        expect(inbox.asking == nil, true, "inbox: ↓ asks nothing of a past line")
        starts = true
        let shown = inbox.current?.id ?? ""
        press(kVK_Return)
        expect(opened.last == shown && inbox.items.count == 4 && kept(shown), true, "inbox: ↵ on a past line opens its session and keeps the line")
        func row(_ type: String, _ minute: String, _ content: Any, meta: Bool = false) -> String {
            var entry: [String: Any] = ["type": type, "timestamp": "2026-10-15T10:\(minute):00.000Z", "message": ["content": content]]
            if meta { entry["isMeta"] = true }
            return String(decoding: (try? JSONSerialization.data(withJSONObject: entry)) ?? Data(), as: UTF8.self)
        }
        let transcript = folder.appending(path: "t.jsonl")
        let at = ((try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-10-15T10:01:00.000Z"))?
            .timeIntervalSince1970 ?? 0) * 1000
        let ended = row("assistant", "00", [["type": "text", "text": "DONE: sent"]])
        let after = [row("user", "05", "meta", meta: true), row("user", "06", [["type": "tool_result", "content": "r"]]),
                     row("assistant", "07", [["type": "text", "text": "Sent."]])]
        try? ([ended] + after).joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        expect(Inbox.said(after: at, in: transcript) == nil, true, "inbox: a session he asked nothing of since the line is not summed up")
        try? ([ended, row("user", "04", "send it")] + after).joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        expect(Inbox.said(after: at, in: transcript) == "He: send it\n\nClaude: Sent.", true,
               "inbox: what was said since the line, his prompts and Claude's text, nothing from before")
        var noon = DateComponents(calendar: .current, year: 2026, month: 10, day: 14, hour: 12)
        let now = noon.date!
        noon.hour = 9; noon.minute = 5
        let morning = noon.date!.timeIntervalSince1970 * 1000
        expect(Store.when(morning, now: now) == "09h05" && Store.when(morning - 86_400_000, now: now) == "13/10 09h05", true,
               "inbox: today's line by its hour, written 09h05; an older one with its day")

        // The entrance, read at every frame on a panel put off every screen, where nothing of it can be seen.
        NSApplication.shared.setActivationPolicy(.accessory)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let place = NSRect(x: -30000, y: -30000, width: 400, height: 100)
        Inbox.present(panel, at: place)
        var alphas: [CGFloat] = [], ys: [CGFloat] = []
        let end = Date().addingTimeInterval(Inbox.entrance + 0.15)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            alphas.append(panel.alphaValue)
            ys.append(panel.frame.minY)
        }
        panel.orderOut(nil)
        let oneWay = zip(alphas, alphas.dropFirst()).allSatisfy { $0 <= $1 } && zip(ys, ys.dropFirst()).allSatisfy { $0 <= $1 }
        print("        entrance: \(Set(alphas).count) alphas, \(Set(ys).count) heights over \(alphas.count) frames")
        expect(oneWay && alphas.last == 1 && ys.last == place.minY && Set(ys).count > 3 && Set(alphas).count > 3, true,
               "inbox: fades in while it rises into its place, in steps, each going one way only")
    }
}
