import AppKit
import Carbon.HIToolbox
import Foundation

/// `watcher --selftest`: the panel's rules against files as the checker writes them, and its entrance read frame by
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
        let folder = FileManager.default.temporaryDirectory.appending(path: "watcher-inbox-\(getpid())")
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
        let state = FileManager.default.temporaryDirectory.appending(path: "watcher-checks-\(getpid())")
        try? FileManager.default.createDirectory(at: state.appending(path: "fired"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try? Data(#"{"id":"w","name":"W","chat":"Maman","since":5}"#.utf8).write(to: state.appending(path: "w.json"))
        try? Data(#"{"id":"a","name":"A","cmd":"x","since":1,"fired":{"at":9}}"#.utf8).write(to: state.appending(path: "fired/a.json"))
        try? Data(#"{"id":"d","name":"D","chat":"Maman","since":1,"dropped":3}"#.utf8).write(to: state.appending(path: "fired/d.json"))
        let checks = CheckEntry.load(state: state)
        expect(checks.entries.map { "\($0.id)\($0.state.rawValue)" } == ["wwaiting", "ddropped", "aarrived"], true,
               "checks: waiting, then dropped, then arrived, a dropped one marked")
        expect(checks.entries.map(\.channel) == [.whatsapp, .whatsapp, .command], true, "checks: a chat is WhatsApp, a cmd a command")
        func parts(_ name: String, _ who: String?) -> [String]? {
            CheckEntry(id: "p", name: name, who: who, watching: "", channel: .gmail, state: .waiting, at: 0).parts.map { [$0.before, $0.who, $0.after] }
        }
        expect(checks.entries.map(\.who) == ["Maman", "Maman", nil] && parts("Claude invoice for Caroline", "caroline") == ["Claude invoice for ", "Caroline", ""]
               && parts("who redoes the poster", "EIP") == ["", "EIP", " who redoes the poster"] && parts("Windows session rename", nil) == nil, true,
               "checks: the one awaited from, a chat's title by default, pilled where the name says it, else in front")
        func logo(_ channel: CheckEntry.Channel, _ how: String) -> String {
            CheckEntry(id: "l", name: "", who: nil, watching: how, channel: channel, state: .waiting, at: 0).logo
        }
        expect(logo(.whatsapp, "") == "whatsapp" && logo(.gmail, "") == "gmail" && logo(.command, "mo@ inbox: a BofA reply") == "outlook"
               && logo(.command, "ssh to mo-recon") == "server.rack" && logo(.command, "a quiet Mac") == "terminal", true,
               "checks: each shows the logo of what it reads, a command's by a word of its how")
        let missing = (["whatsapp", "gmail", "terminal"] + CheckEntry.logos.map(\.1)).filter {
            Bundle.main.url(forResource: $0, withExtension: "png", subdirectory: "logos") == nil && NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil
        }
        expect(missing.isEmpty, true, "checks: every logo is in the app or among the SF Symbols \(missing)")
        let watcher = Inbox(folder: state.appending(path: "inbox"))
        expect(watcher.key(UInt16(kVK_ANSI_S)) && watcher.settings && watcher.checks.count == 3, true, "inbox: S shows the checks")
        expect(watcher.key(UInt16(kVK_DownArrow)), false, "inbox: in the checks, other keys go on")
        expect(watcher.key(UInt16(kVK_Escape)) && !watcher.settings, true, "inbox: Esc in the checks closes Watcher")
        _ = watcher.key(UInt16(kVK_ANSI_S))
        expect(watcher.key(UInt16(kVK_ANSI_K), flags: [.command, .option]) && !watcher.settings, true,
               "inbox: ⌘⌥K come in as a plain key closes Watcher, as the hot key does")
        // Add back runs the real checker, on this folder: the fixture has no todo, so nothing leaves the Mac.
        setenv("AWAIT_STATE", state.path, 1)
        _ = watcher.key(UInt16(kVK_ANSI_S))
        watcher.addBack(checks.entries[2]) // it left no line: watched again
        expect(watcher.checks.first.map { "\($0.id)\($0.state.rawValue)" } == "awaiting", true, "checks: Add back shows it waiting at once")
        let given = Date().addingTimeInterval(10)
        while Date() < given, !FileManager.default.fileExists(atPath: state.appending(path: "a.json").path) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        unsetenv("AWAIT_STATE")
        let disk = CheckEntry.load(state: state).entries
        expect(disk.first { $0.id == "a" }?.state == .waiting && watcher.checks == disk, true,
               "checks: Add back has the checker watch it again, and the list is read back from disk")
        expect(disk.filter { $0.id == "a" }.map(\.state) == [.waiting, .arrived], true, "checks: Add back keeps it under done too")
        // A check whose follow-up left a line he set aside: Add back brings the line back, shown, and watches nothing.
        try? FileManager.default.createDirectory(at: state.appending(path: "inbox/done"), withIntermediateDirectories: true)
        try? Data(#"{"id":"b","name":"B","cmd":"x","since":1,"fired":{"at":8}}"#.utf8).write(to: state.appending(path: "fired/b.json"))
        try? Data(#"{"id":"r","at":8,"kind":"needs","subject":"B","line":"L","dir":"/","options":["--resume","s"],"entries":["b"]}"#.utf8)
            .write(to: state.appending(path: "inbox/done/r.json"))
        expect(watcher.settings, true, "checks: still on the watch list before Add back")
        watcher.addBack(CheckEntry.load(state: state).entries.first { $0.id == "b" }!)
        expect(watcher.current?.id == "r" && !watcher.settings && !FileManager.default.fileExists(atPath: state.appending(path: "b.json").path), true,
               "checks: Add back brings back the line its follow-up left, shown, and watches nothing again")
        press(kVK_DownArrow)
        press(kVK_Return)
        expect(inbox.items.isEmpty && kept("a"), true, "inbox: the last line set aside leaves none")
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
