import AppKit
import Carbon.HIToolbox
import SwiftUI

/// ⌥Space and not ⌘Space: Raycast holds ⌘Space while it runs, and Carbon gives a chord to one app only.
let chord = (keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "⌥Space")

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
    let status = RegisterEventHotKey(chord.keyCode, chord.modifiers, EventHotKeyID(signature: OSType(0x4F50_4E52), id: 1),
                                     GetEventDispatcherTarget(), 0, &ref)
    if status != noErr { NSLog("opener: could not register \(chord.label) (\(status)), another app likely owns it") }
}

let args = CommandLine.arguments

if args.contains("--selftest") { MainActor.assumeIsolated { exit(SelfCheck.run() == 0 ? 0 : 1) } }

// `--render <png> [query] [--dark]`: the panel offscreen, on the apps of this Mac. Never a window.
if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let opener = Opener()
        opener.apps = Catalog.apps()
        opener.type(i + 2 < args.count && !args[i + 2].hasPrefix("--") ? args[i + 2] : "")
        let backdrop = LinearGradient(colors: [Color(red: 0.55, green: 0.70, blue: 0.85), Color(red: 0.85, green: 0.82, blue: 0.70)],
                                      startPoint: .top, endPoint: .bottom)
        let renderer = ImageRenderer(content: OpenerView(opener: opener)
            .frame(width: Opener.size.width, height: Opener.size.height)
            .background(backdrop)
            .environment(\.colorScheme, args.contains("--dark") ? .dark : .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        print("wrote \(args[i + 1]) \(image.size)")
        exit(0)
    }
}

@MainActor
final class App: NSObject, NSApplicationDelegate {
    let opener = Opener()

    func applicationDidFinishLaunching(_ note: Notification) {
        // An agent with no window is a candidate for automatic termination; that is how it would "crash" unseen.
        ProcessInfo.processInfo.disableAutomaticTermination("hotkey listener")
        ProcessInfo.processInfo.disableSuddenTermination()
        // A second copy could not take the chord anyway: the newer one leaves.
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me && ($0.launchDate ?? .distantPast) <= (me.launchDate ?? .now) }) {
            NSLog("opener: already running")
            exit(0)
        }
        toggle = { [opener] in MainActor.assumeIsolated { opener.toggle() } }
        registerChord()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { App() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
