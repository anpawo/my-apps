import AppKit
import Carbon.HIToolbox
import SwiftUI

private nonisolated(unsafe) var actions: [UInt32: () -> Void] = [:]

/// Carbon's `RegisterEventHotKey` rather than a global key monitor: the monitor needs Accessibility permission, this
/// needs nothing, and it consumes the chord so the app in front never sees it.
@MainActor
func registerChords(_ chords: [(keyCode: Int, modifiers: Int, label: String, action: () -> Void)]) {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
        var key = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &key)
        let id = key.id
        DispatchQueue.main.async { actions[id]?() }
        return noErr
    }, 1, &spec, nil, nil)
    for (i, chord) in chords.enumerated() {
        let id = UInt32(i + 1)
        actions[id] = chord.action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(chord.keyCode), UInt32(chord.modifiers), EventHotKeyID(signature: OSType(0x4F50_4E52), id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        if status != noErr { NSLog("opener: could not register \(chord.label) (\(status)), another app likely owns it") }
    }
}

/// Firefox started while ⌥ is still down asks whether to open in Troubleshoot Mode, so it waits (2 s at most) for the
/// chord to be let go.
func openOnceOptionIsUp(_ path: String, tries: Int = 40) {
    if tries > 0, CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
        return DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { openOnceOptionIsUp(path, tries: tries - 1) }
    }
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
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
        let opener = self.opener
        registerChords([
            // Free only while Spotlight's own shortcut stays off (Keyboard Shortcuts → Spotlight): the system would
            // take it first. Raycast held it until 2026-10-24.
            (kVK_Space, cmdKey, "⌘Space", { MainActor.assumeIsolated { opener.toggle() } }),
            // A Windows habit (Win+E). It was the system's "Show Finder search window", which the Spotlight agent
            // carries out and which went with it on 2026-10-24. The home folder rather than Finder's default
            // window: that is Recents, a Spotlight search, empty without the index.
            (kVK_ANSI_E, cmdKey, "⌘E", { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory())) }),
            // Raycast app hotkeys until it was uninstalled on 2026-10-24.
            (kVK_ANSI_F, cmdKey | optionKey, "⌥⌘F", { openOnceOptionIsUp("/Applications/Firefox.app") }),
            // Ghostty already in front: bringing it up shows nothing, so a new window, the way spawn opens one
            // (`open -na Ghostty`).
            (kVK_ANSI_T, cmdKey | optionKey, "⌥⌘T", {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.mitchellh.ghostty"
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Ghostty.app"), configuration: config)
            }),
        ])
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { App() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
