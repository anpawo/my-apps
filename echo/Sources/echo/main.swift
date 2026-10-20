import AppKit
import Carbon.HIToolbox

private nonisolated(unsafe) var toggle: (() -> Void)?

/// Carbon's `RegisterEventHotKey` rather than a global key monitor: the monitor needs Accessibility permission, this
/// needs nothing, and it consumes the chord so the app in front never sees it.
@MainActor
func registerChord() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
        DispatchQueue.main.async { toggle?() }
        return noErr
    }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(Inbox.chord.keyCode), Inbox.chord.modifiers,
                                     EventHotKeyID(signature: OSType(0x4543_484F), id: 1),
                                     GetEventDispatcherTarget(), 0, &ref)
    if status != noErr { NSLog("echo: could not register \(Inbox.chord.label) (\(status)) — another app likely owns it") }
}

let args = CommandLine.arguments

if args.dropFirst().first == "mcp" { Mcp.serve() }

if args.contains("--selftest") { MainActor.assumeIsolated { exit(SelfCheck.run() == 0 ? 0 : 1) } }

// `--render <png>`: the panel offscreen, on lines that test it, and on his real checks. Never a window.
if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let path = args[i + 1]
        func beside(_ name: String) -> String { path.replacingOccurrences(of: ".png", with: "-\(name).png") }
        func item(_ kind: String, _ subject: String, _ line: String) -> InboxItem {
            InboxItem(id: subject, at: Date().timeIntervalSince1970 * 1000 - Double(subject.count) * 3_600_000, kind: kind,
                      subject: subject, line: line, dir: "/", options: ["--resume", "x"], prompt: nil)
        }
        let items = [
            item("needs", "photo of her ID", "Mum sent her ID; the licence request now needs your FranceConnect login."),
            item("done", "CROUS deposit refund", "CROUS confirmed the 412 € refund, so the todo is ticked and its reply is filed with the ARPEJ papers."),
        ]
        Inbox.render(items, to: path)
        Inbox.render(items, asking: true, to: beside("asking"))
        Inbox.render([], to: beside("empty"))
        let real = CheckEntry.load()
        Inbox.render([], checks: real.entries, lastCheck: real.last, to: beside("checks"))
        Inbox.render([], checks: real.entries, lastCheck: real.last, on: "white", to: beside("checks-white"))
        Inbox.render(items, past: true, outcomes: ["photo of her ID": "Licence request filed on ANTS, receipt saved"], to: beside("past"))
        exit(0)
    }
}

@MainActor
final class App: NSObject, NSApplicationDelegate {
    let inbox = Inbox()

    func applicationDidFinishLaunching(_ note: Notification) {
        // An agent with no window is a candidate for automatic termination; that is how it would "crash" unseen.
        ProcessInfo.processInfo.disableAutomaticTermination("hotkey listener")
        ProcessInfo.processInfo.disableSuddenTermination()
        // A second copy would take the chord and stack a second menu bar item: the newer one leaves.
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me && ($0.launchDate ?? .distantPast) <= (me.launchDate ?? .now) }) {
            NSLog("echo: already running")
            exit(0)
        }
        inbox.start()
        toggle = { [inbox] in MainActor.assumeIsolated { inbox.toggle() } }
        registerChord()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { App() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
