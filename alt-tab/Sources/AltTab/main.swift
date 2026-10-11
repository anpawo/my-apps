import AppKit
import SwitchCore

/// The system's own ⌘Tab, and how to give it back.
///
/// alt-tab binds ⌘Tab by default, and the Dock answers that chord before any application sees
/// it, so the system's own is switched off for as long as alt-tab holds it. That setting
/// outlives the process that set it: an app that takes ⌘Tab and then crashes leaves the
/// machine with no switcher at all, across reboots, with no UI anywhere to explain it. The
/// *recovery* half is what this ships for.
///
/// Deliberately not called at launch. A chord alt-tab did not take may be held off by another
/// switcher, and restoring every one on every launch would break a working switcher instead
/// of repairing a broken one: a launch gives back only what the last run wrote down.
/// `--restore-hotkeys` is the escape hatch, and it works without a GUI.
enum SymbolicHotKeys {
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32

    /// 1 ⌘Tab · 2 ⌘⇧Tab · 6 ⌘` — collected, not picked: the pick used to come from iterating a
    /// dictionary, whose order is not stable across launches, so which chord got restored
    /// varied per run.
    static let all: [Int32] = [1, 2, 6]

    private static let setEnabled: SetEnabled? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(symbol, to: SetEnabled.self)
    }()

    @discardableResult
    static func set(_ ids: [Int32], enabled: Bool) -> Bool {
        guard let setEnabled else {
            FileHandle.standardError.write(Data("alt-tab: CGSSetSymbolicHotKeyEnabled is gone on this macOS\n".utf8))
            return false
        }
        for id in ids { _ = setEnabled(id, enabled) }
        return true
    }

    static func restoreSystemSwitcher() { set(all, enabled: true) }
}

let arguments = Set(CommandLine.arguments.dropFirst())

/// The LaunchAgent passes `--agent`, and nothing else ever does. Told apart by who started us
/// rather than by inspecting the session, because the two launches are otherwise identical and
/// the difference decides whether a window appears in front of someone who only logged in.
let startedByHand = !arguments.contains("--agent")

/// Refuses to be the second copy.
///
/// Two of these running is not a cosmetic problem. Carbon gives a hotkey to the first process
/// that claims it, so a forgotten copy keeps ⌘Tab while the one you are looking at silently
/// does nothing — and if that copy is a bare binary rather than the signed bundle, it has no
/// Screen Recording grant of its own and every picture comes back black. Both symptoms, one
/// cause, and nothing about either points at the real reason.
///
/// A file lock rather than a check of the running applications: an executable launched outside
/// a bundle has no identifier to be counted by, and that is exactly the copy that causes this.
func claimSoleInstance() -> Bool {
    let path = NSHomeDirectory() + "/Library/Application Support/com.mr.alttab.lock"
    let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { return true }   // cannot lock, carry on rather than refuse to run
    // Held for the life of the process, and released by the kernel however it ends — including
    // a kill, which a lock file with a pid in it would not survive.
    return flock(descriptor, LOCK_EX | LOCK_NB) == 0
}

if arguments.contains("--restore-hotkeys") {
    SymbolicHotKeys.restoreSystemSwitcher()
    exit(0)
}

/// A window list for pictures: apps everyone has, titles that belong to no one.
@MainActor
func demoWindows() -> [WindowInfo] {
    let script: [(bundle: String, title: String, width: CGFloat)] = [
        ("com.apple.finder", "Downloads", 1100),
        ("org.mozilla.firefox", "Swift.org", 1440),
        ("com.apple.Safari", "Apple Developer", 1440),
        ("com.mitchellh.ghostty", "~/code", 960),
        ("com.apple.Terminal", "~/notes", 960),
        ("com.apple.Preview", "poster.pdf", 800),
        ("com.apple.Notes", "Groceries", 700),
        ("com.apple.mail", "Inbox", 1300),
        ("com.apple.iCal", "Week 39", 1400),
        ("com.apple.Music", "Now Playing", 1000),
        ("com.apple.TextEdit", "Untitled", 800),
        ("com.apple.systempreferences", "Displays", 720),
    ]
    return script.enumerated().compactMap { i, entry in
        // Installed is enough; the icon comes off the bundle, the pid is invented.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundle) else { return nil }
        let id = CGWindowID(900_000 + i), pid = pid_t(900_000 + i)
        Panel.seedIcon(pid, NSWorkspace.shared.icon(forFile: url.path))
        Thumbnails.seed(id, demoPicture(width: entry.width, height: 860, seed: i))
        return WindowInfo(id: id, pid: pid, appName: url.deletingPathExtension().lastPathComponent,
                          title: entry.title, element: nil, size: CGSize(width: entry.width, height: 860))
    }
}

/// The main screen at its own pixel size, a plain gradient for a wallpaper (never the user's
/// own, which may be a photo of someone), and the panel centred on it.
@MainActor
func demoScreen(panel: Data) -> Data? {
    guard let screen = NSScreen.main, let panelImage = NSImage(data: panel),
          let panelCG = panelImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let scale = screen.backingScaleFactor
    let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let colors = [CGColor(red: 0.16, green: 0.24, blue: 0.48, alpha: 1), CGColor(red: 0.55, green: 0.30, blue: 0.52, alpha: 1)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    }
    let pw = CGFloat(panelCG.width), ph = CGFloat(panelCG.height)
    ctx.draw(panelCG, in: CGRect(x: (CGFloat(w) - pw) / 2, y: (CGFloat(h) - ph) / 2, width: pw, height: ph))
    guard let out = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
}

/// A window that never existed: a title bar, a sidebar or not, a few grey lines of content.
func demoPicture(width: CGFloat, height: CGFloat, seed: Int) -> NSImage {
    let image = NSImage(size: CGSize(width: width, height: height))
    image.lockFocus()
    NSColor(white: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor(white: 0.90, alpha: 1).setFill()
    NSRect(x: 0, y: height - 52, width: width, height: 52).fill()
    if seed % 2 == 0 {
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width * 0.22, height: height - 52).fill()
    }
    NSColor(white: 0.82, alpha: 1).setFill()
    let left = seed % 2 == 0 ? width * 0.22 + 40 : 40
    for row in 0..<12 {
        let lineWidth = (width - left - 60) * [0.9, 0.6, 0.75, 0.45][(row + seed) % 4]
        NSRect(x: left, y: height - 110 - CGFloat(row) * 56, width: lineWidth, height: 16).fill()
    }
    image.unlockFocus()
    return image
}

if arguments.contains("--render") {
    MainActor.assumeIsolated {
        WindowList.prewarm()
        // `--demo` swaps the real windows for made-up ones: icons of apps everyone has,
        // invented titles, hand-drawn pictures. For a screenshot that shows nobody's work.
        let snapshot = arguments.contains("--demo") ? demoWindows() : WindowList.snapshot()
        for (i, window) in snapshot.enumerated() {
            let handle = window.element == nil ? "no element" : "ok"
            print("\(i)  \(window.appName) — \(window.title)  [wid \(window.id), \(handle)]")
        }
        // The grid, laid out but never ordered in: `show` only arms a timer, and this exits
        // before any runloop turns it, so nothing appears on the screen being worked on.
        let many = arguments.first(where: { $0.hasPrefix("--windows=") })
            .flatMap { Int($0.dropFirst("--windows=".count)) }
        let list = many.map { n in (0..<n).map { snapshot[$0 % max(snapshot.count, 1)] } } ?? snapshot
        guard !list.isEmpty else { exit(0) }
        // `--shot=<path>` writes the panel as a PNG instead of printing it. Same layout, same
        // pictures, and still nothing on the screen.
        if let shot = arguments.first(where: { $0.hasPrefix("--shot=") }).map({ String($0.dropFirst("--shot=".count)) }) {
            NSApplication.shared.setActivationPolicy(.accessory)
            guard var data = Panel.png(list, selected: 1, settle: 2.5) else {
                print("could not draw the panel")
                exit(1)
            }
            // The demo picture is the whole screen, the panel floating on it, as it looks in use.
            if arguments.contains("--demo"), let full = demoScreen(panel: data) { data = full }
            try? data.write(to: URL(fileURLWithPath: shot))
            print("wrote \(shot)  (\(list.count) windows)")
            exit(0)
        }
        Panel.show(list, selected: 0)
        for (i, frame) in Panel.tileFrames.enumerated() {
            print("tile \(i)  x \(Int(frame.minX))  y \(Int(frame.minY))  \(Int(frame.width))×\(Int(frame.height))")
        }
    }
    exit(0)
}

/// What a second copy says to the first before it goes: "you were opened, show yourself".
///
/// The reopen event above covers the ordinary case — the same bundle, opened twice. This covers
/// the other one: a copy launched from a different path, or the bare binary, which
/// LaunchServices does not recognise as the running application and starts for real. It cannot
/// run, because of the lock, so it delivers the intent and leaves.
let openedNotification = Notification.Name("com.mr.alttab.opened")

guard claimSoleInstance() else {
    DistributedNotificationCenter.default().postNotificationName(
        openedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

/// Opening an application that is already running does not start a second copy: LaunchServices
/// activates the one that is there and sends it a reopen event. That event is the only signal
/// alt-tab gets, and without a delegate to catch it, double-clicking the bundle does nothing at
/// all — which for an app whose settings window is its only face means no way in.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        PreferencesWindow.shared.show()
        return true
    }
}

let application = NSApplication.shared
// Held for the process lifetime: `NSApplication.delegate` is a weak reference.
var delegate: AppDelegate?
// No Dock icon and no menu bar. Also what keeps alt-tab out of the window ordering it switches.
application.setActivationPolicy(.accessory)

var state = SwitcherState()
var windows: [WindowInfo] = []
/// The only place both worlds meet. Everything above is AppKit, everything below is a value
/// type that cannot import it, and nothing calls back up.
@MainActor
func dispatch(_ command: SwitchCommand) {
    if !state.isOpen, command == .next {
        // Enumerate on open, once, and hand the same array to every step of the session.
        // Re-reading it per keystroke would let the list move under the selection.
        windows = WindowList.snapshot()
        if !AXIsProcessTrusted() {
            Panel.note("No Accessibility grant — window names and switching are unavailable.")
        } else if !Thumbnails.isPermitted {
            // Said here rather than by putting a system prompt over a switcher the user is in
            // the middle of using. The menu bar item is where it can be granted.
            Panel.note("Showing icons — window pictures need Screen Recording, in the ⇥ menu.")
        } else {
            Panel.note(nil)
        }
    }

    guard let effect = state.handle(command, windows: windows) else { return }
    apply(effect)
}

@MainActor
func apply(_ effect: Effect) {
    switch effect {
    case let .show(list, index):
        Panel.show(list, selected: index)
        Trigger.watchForRelease()
    case let .move(index):
        Panel.move(to: index)
    case .hide:
        Trigger.stopWatchingForRelease()
        Panel.hide()
    case let .raise(window):
        Trigger.stopWatchingForRelease()
        Panel.dismiss()
        if !WindowAction.perform(window) {
            // Hangs off the failed *action*, not off the permission check: the check can
            // report trusted after a revocation, and the failure to design against is the
            // panel that opens, looks perfect, and then does nothing when ⌘ comes up.
            Panel.note("Could not switch to \(window.appName) — check alt-tab in "
                       + "System Settings → Privacy & Security → Accessibility.")
        }
        // Photographed after the raise, and by id rather than by asking who has focus — asked
        // before, the answer is about the window we are leaving.
        Thumbnails.captureSoon(window.id)
    }
}

// Everything expensive, once, before the first keystroke: the window, its view tree, the icon
// cache, and one Accessibility connection per running app. Left lazy, the first ⌘Tab pays all
// of it at once and that is what "slow the first time" is.
// `assumeIsolated` rather than an await: this is main.swift, it is already on the main thread,
// and the alternative is an async entry point that defers setup past the first keystroke.
MainActor.assumeIsolated {
    delegate = AppDelegate()
    application.delegate = delegate

    Panel.warm()
    WindowList.prewarm()
    // Nothing in the menu bar unless it has been asked for. Launched at login this is the whole
    // of alt-tab's visible presence: none.
    MenuBar.setVisible(Settings.showsMenuBarIcon)

    DistributedNotificationCenter.default().addObserver(
        forName: openedNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated { PreferencesWindow.shared.show() }
    }

    guard Trigger.install({ command in dispatch(command) }) else {
        let chord = Shortcuts.current()[.next]?.label ?? "its chord"
        FileHandle.standardError.write(Data("alt-tab: could not register \(chord) — another app owns it\n".utf8))
        exit(1)
    }

    // The cross on a tile. Closing is asked for here and confirmed by re-reading the list a
    // moment later: a window with unsaved changes puts up a sheet and does not go anywhere, and
    // a list that had already dropped it would be showing something untrue.
    Panel.onCloseRequested = { window in
        guard WindowAction.close(window) else {
            Panel.note("Could not close \(window.appName).")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                windows = WindowList.snapshot()
                if let effect = state.refresh(windows) { apply(effect) }
            }
        }
    }

    // A tile clicked anywhere but on its cross. The click stands in for the whole gesture —
    // there is no ⌘ to release after it — so it names its window and the state machine raises it.
    Panel.onPicked = { window in dispatch(.pick(window.id)) }

    // A window is photographed while it is the one in use. Cross-application switches are what
    // NSWorkspace reports; a switch between two windows of the same application is not, and is
    // covered instead by the capture that follows our own raise below.
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { note in
        MainActor.assumeIsolated {
            guard !state.isOpen,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            Thumbnails.captureFocused(of: app.processIdentifier)
        }
    }

    // One pass a few seconds after login, so the very first ⌘Tab of the day has pictures too
    // rather than being the one open that pays for all of them.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        MainActor.assumeIsolated { Thumbnails.captureQuietly(WindowList.snapshot().map(\.id)) }
    }

    if arguments.contains("--fake") {
        dispatch(.next)
    }
    // There is no Dock icon to click, so the menu bar is normally the only way in. This is the
    // other one, for when the menu bar is full.
    // Double-clicking the bundle lands here, with no arguments and no window. The switcher
    // launched by launchd passes none either, so the two are told apart by who started us:
    // launchd hands its jobs a session that no Dock click ever produces.
    if arguments.contains("--settings") || startedByHand {
        PreferencesWindow.shared.show()
    }
}

application.run()
