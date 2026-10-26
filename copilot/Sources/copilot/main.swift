import AppKit
import Carbon.HIToolbox
import SwiftUI

private nonisolated(unsafe) var onChord: () -> Void = {}

/// Carbon's `RegisterEventHotKey`, as opener does: no Accessibility permission, and the chord never reaches the app
/// in front.
@MainActor
func registerChord(keyCode: Int, modifiers: Int, label: String, _ action: @escaping () -> Void) {
    onChord = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
        DispatchQueue.main.async { onChord() }
        return noErr
    }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x434F_504C), id: 1),
                                     GetEventDispatcherTarget(), 0, &ref)
    if status != noErr { NSLog("copilot: could not register \(label) (\(status)), another app likely owns it") }
}

let args = CommandLine.arguments

if args.contains("--selftest") { MainActor.assumeIsolated { exit(SelfCheck.run() == 0 ? 0 : 1) } }

// `--ask <image> [question] [follow-up…]`: a conversation on a picture, the way ↵ sends the screen, the answers printed as
// they come. Never a window: this is how the path to Claude is checked.
if let i = args.firstIndex(of: "--ask"), i + 1 < args.count {
    guard let image = NSImage(contentsOfFile: args[i + 1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("cannot read \(args[i + 1])")
        exit(1)
    }
    var questions = Array(args[(i + 2)...]), start = Date(), first: TimeInterval?
    var conversation: Conversation!
    func ask(_ typed: String, _ image: Data?) {
        print("> \(typed.isEmpty ? "(nothing typed)" : typed)\n")
        conversation.send(Conversation.question(typed, app: image == nil ? nil : "Terminal"), image: image)
    }
    func seconds(_ t: TimeInterval?) -> String { t.map { String(format: "%.1f s", $0) } ?? "none" }
    conversation = Conversation { event in
        switch event {
        case .text(let t):
            if first == nil { first = Date().timeIntervalSince(start) }
            print(t, terminator: "")
            fflush(stdout)
        case .done:
            print("\n")
            FileHandle.standardError.write(Data("\n\nfirst word \(seconds(first)), whole \(seconds(Date().timeIntervalSince(start)))\n".utf8))
            guard !questions.isEmpty else { exit(0) }
            (start, first) = (Date(), nil)
            ask(questions.removeFirst(), nil)
        case .failed(let why):
            FileHandle.standardError.write(Data("failed: \(why)\n".utf8))
            exit(1)
        }
    }
    ask(questions.isEmpty ? "" : questions.removeFirst(), Screen.jpeg(image))
    dispatchMain()
}

// `--render <png> [--dark]`: the panel offscreen, on the demo's conversation. Never a window.
if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Demo.still(to: URL(fileURLWithPath: args[i + 1]), dark: args.contains("--dark"))
        exit(0)
    }
}

// `--render-demo <dir>`: the README's GIF as frames. Never a window.
if let i = args.firstIndex(of: "--render-demo"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Demo.render(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }
}

@MainActor
final class App: NSObject, NSApplicationDelegate {
    let copilot = Copilot()

    func applicationDidFinishLaunching(_ note: Notification) {
        // An agent with no window is a candidate for automatic termination; that is how it would "crash" unseen.
        ProcessInfo.processInfo.disableAutomaticTermination("hotkey listener")
        ProcessInfo.processInfo.disableSuddenTermination()
        // A second copy could not take the chord anyway: the newer one leaves.
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me && ($0.launchDate ?? .distantPast) <= (me.launchDate ?? .now) }) {
            NSLog("copilot: already running")
            exit(0)
        }
        let copilot = self.copilot
        // Free: Handy holds ⌥⇧Space and ⌘S, opener ⌘Space (27/10/2026).
        registerChord(keyCode: kVK_Space, modifiers: optionKey, label: "⌥Space") { MainActor.assumeIsolated { copilot.summon() } }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { App() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
