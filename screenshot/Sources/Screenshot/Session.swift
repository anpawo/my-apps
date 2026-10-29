import AppKit
import AVFoundation
import Carbon.HIToolbox
import ScreenCaptureKit
import ScreenshotCore

/// The bar and its overlays, from ⌘⇧5 to the file on disk.
@MainActor
final class Session {
    static let shared = Session()

    var state = Settings.bar
    /// AppKit global points; only for area.
    var selection: CGRect? = Settings.lastRect
    var hoverWindow: WindowInfo?
    var hoverScreen: NSScreen?
    var windows: [WindowInfo] = []   // set by Docs too
    private var overlays: [Overlay] = []
    private var bar: Bar?
    private let recorder = Recorder()
    private var opening = false

    var isOpen: Bool { !overlays.isEmpty }

    /// ⌘⇧5: open; open again: photo ↔ video; while recording: stop.
    func toggle() {
        if recorder.isRecording { stopRecording(); return }
        // Without the grant ScreenCaptureKit fails silently; this opens the right Settings pane.
        NSLog("screenshot: ⌘⇧5")
        guard CGPreflightScreenCaptureAccess() else {
            NSLog("screenshot: no Screen Recording permission")
            // Prompts once; afterwards it is a no-op, so open the pane ourselves.
            if !CGRequestScreenCaptureAccess() {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }
        if isOpen { state.toggleKind(); refresh(); return }
        open()
    }

    func open() {
        guard !isOpen, !opening else { return }
        opening = true
        state = Settings.bar
        hoverScreen = NSScreen.underMouse
        windows = Capture.windows()
        // A capture can never answer (replayd: "no client found", 28-10): `opening` then stays set
        // and ⌘⇧5 is dead until a restart. Quitting lets the LaunchAgent start a fresh copy.
        let watchdog = DispatchWorkItem { NSLog("screenshot: capture hung, restarting"); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: watchdog)
        Task {
            defer { watchdog.cancel() }
            var frozen: [CGDirectDisplayID: CGImage] = [:]
            do {
                // Every display at once: the screen is frozen as of a single instant.
                try await withThrowingTaskGroup(of: (CGDirectDisplayID, CGImage).self) { group in
                    for screen in NSScreen.screens {
                        group.addTask { (screen.displayID, try await Capture.screen(screen)) }
                    }
                    for try await (id, image) in group { frozen[id] = image }
                }
            } catch {
                NSLog("screenshot: \(error.localizedDescription)")
                opening = false
                return
            }
            opening = false
            guard !isOpen else { return }
            if let r = selection, !NSScreen.screens.contains(where: { $0.frame.contains(r) }) { selection = nil }
            overlays = NSScreen.screens.map { Overlay(screen: $0, frozen: frozen[$0.displayID]!, session: self) }
            overlays.forEach { $0.orderFrontRegardless() }
            let under = NSScreen.underMouse
            (overlays.first { $0.display == under } ?? overlays[0]).makeKey()
            bar = Bar(session: self, on: under)
            bar?.orderFrontRegardless()
            refresh()
            registerChords()
        }
    }

    /// Escape and Return as system-wide chords while the overlay is up: a non-activating panel
    /// does not always get key events, and these two must never depend on it. Suspended while
    /// the Options menu is open, so Escape closes the menu instead of the session.
    func registerChords() {
        HotKey.register(key: kVK_Escape, modifiers: 0, id: 2) { Task { @MainActor in Session.shared.close() } }
        HotKey.register(key: kVK_Return, modifiers: 0, id: 3) { Task { @MainActor in Session.shared.commit() } }
    }

    func unregisterChords() {
        HotKey.unregister(id: 2)
        HotKey.unregister(id: 3)
    }

    func close() {
        unregisterChords()
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        bar?.orderOut(nil)
        bar = nil
        hoverWindow = nil
        hoverScreen = nil
        Settings.bar = state
        Settings.lastRect = selection
    }

    func step(_ delta: Int) { state.step(delta); refresh() }
    func set(_ target: Target) { state.target = target; refresh() }
    func toggleKind() { state.toggleKind(); refresh() }

    /// The arrows glide the drawn box to `selection`, which stays the truth for hits and the shot.
    /// Each press restarts the glide from where the box is drawn, so a held key moves it smoothly.
    private var glide: (from: CGRect, start: CFTimeInterval)?
    private var glideTimer: Timer?
    private static let glideDuration: CFTimeInterval = 0.12

    var drawnSelection: CGRect? {
        guard let to = selection, let g = glide else { return selection }
        return ScreenshotCore.glide(g.from, to, (CACurrentMediaTime() - g.start) / Self.glideDuration)
    }

    func nudge(dx: CGFloat, dy: CGFloat, resize: Bool) {
        guard let r = selection else { return }
        let from = drawnSelection ?? r
        selection = ScreenshotCore.nudge(r, dx: dx, dy: dy, resize: resize, bounds: NSScreen.containing(r).frame)
        glide = (from, CACurrentMediaTime())
        if glideTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                MainActor.assumeIsolated { Session.shared.glideTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            glideTimer = timer
        }
        refresh()
    }

    private func glideTick() {
        if let g = glide, CACurrentMediaTime() - g.start >= Self.glideDuration {
            glide = nil
            glideTimer?.invalidate()
            glideTimer = nil
        }
        redraw()
    }

    /// After a state change: the bar and every overlay. Panels at screen-saver level do not
    /// always flush a `needsDisplay` without a mouse event, so this draws now.
    func refresh() {
        // The hover is otherwise only set by a mouse move: opening in window mode, or ⌘→ into
        // it, would show nothing until the pointer moves. On the bar it stays as it was.
        let p = NSEvent.mouseLocation
        if bar?.frame.contains(p) != true {
            hoverWindow = state.target == .window ? windows.first { $0.frame.contains(p) } : nil
        }
        bar?.refresh()
        redraw()
    }

    /// After a hover change: overlays only. Touching the bar on every mouse move made it flash.
    func redraw() {
        overlays.forEach { $0.refreshLayers() }
    }

    func makeKey(_ overlay: Overlay) {
        if !overlay.isKeyWindow { overlay.makeKey() }
    }

    // MARK: Commit

    /// Enter, the Capture button, or a click on a screen or window.
    func commit(screen: NSScreen? = nil, window: WindowInfo? = nil) {
        let state = state
        let selection = selection
        let window = window ?? hoverWindow
        let shadow = !NSEvent.modifierFlags.contains(.option)
        if state.needsSelection && selection == nil { return }
        if state.target == .window && window == nil { return }
        let frozen = Dictionary(uniqueKeysWithValues: overlays.map { ($0.display.displayID, $0.frozen) })
        close()
        if state.kind == .video { startRecording(state.target, screen: screen, window: window, rect: selection); return }

        Task {
            do {
                let live = Settings.timer > 0
                if live { try await Task.sleep(for: .seconds(Settings.timer)) }
                switch state.target {
                case .screen:
                    var last: (URL, CGImage, CGRect)?
                    for s in screen.map({ [$0] }) ?? NSScreen.screens {
                        let image = live ? try await Capture.screen(s) : frozen[s.displayID]!
                        last = (try Output.save(image, scale: s.backingScaleFactor), image, s.frame)
                    }
                    if let (url, image, rect) = last { Thumbnail.show(.image(image, url, rect)) }
                case .window:
                    let w = window!
                    let image = try await Capture.window(w, shadow: shadow)
                    let url = try Output.save(image, scale: NSScreen.containing(w.frame).backingScaleFactor, app: w.app)
                    Thumbnail.show(.image(image, url, w.frame))
                case .area:
                    let r = selection!.integral
                    let s = NSScreen.containing(r)
                    let image = live ? try await Capture.area(r, on: s)
                        : frozen[s.displayID]!.cropping(to: pixelCrop(r, in: s.frame, scale: s.backingScaleFactor))!
                    Thumbnail.show(.image(image, try Output.save(image, scale: s.backingScaleFactor), r))
                }
            } catch {
                NSLog("screenshot: \(error.localizedDescription)")
            }
            Capture.prefetch()
        }
    }

    // MARK: Video

    private func startRecording(_ target: Target, screen: NSScreen?, window: WindowInfo?, rect: CGRect?) {
        Task {
            do {
                switch target {
                case .screen:
                    let s = screen ?? NSScreen.underMouse
                    let (_, filter) = try await Capture.displayFilter(s)
                    try await recorder.start(filter: filter, size: s.frame.size, scale: s.backingScaleFactor)
                case .window:
                    guard let w = window else { return }
                    let filter = SCContentFilter(desktopIndependentWindow: try await Capture.window(w.id))
                    try await recorder.start(filter: filter, size: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
                case .area:
                    let r = rect!.integral
                    let s = NSScreen.containing(r)
                    let (_, filter) = try await Capture.displayFilter(s)
                    try await recorder.start(filter: filter, size: r.size, scale: s.backingScaleFactor,
                                             sourceRect: displayLocal(r, in: s.frame))
                }
            } catch {
                NSLog("screenshot: \(error.localizedDescription)")
                return
            }
        }
    }

    func stopRecording() {
        Task {
            guard let url = await recorder.stop() else { return }
            for f in Settings.folders.dropFirst() {
                try? FileManager.default.copyItem(at: url, to: f.appendingPathComponent(url.lastPathComponent))
            }
            Output.remember(url)
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            let frame = try? await gen.image(at: .zero).image
            Thumbnail.show(.movie(frame, url))
            Capture.prefetch()
        }
    }
}
