import AppKit
import ScreenCaptureKit
import ScreenshotCore

/// A window as CoreGraphics lists it: front-to-back order, which ScreenCaptureKit does not give.
struct WindowInfo {
    let id: CGWindowID
    let frame: CGRect        // AppKit global points
    let app: String
    var radius: CGFloat = 16 // its corners', as the WindowServer cuts them
    var floating = false     // above the normal windows, like Jarvis's panel
}

/// ScreenCaptureKit, one frame at a time. Our own process is excluded from every display
/// filter, so overlays never have to hide before a shot.
enum Capture {
    private static let pid = ProcessInfo.processInfo.processIdentifier
    private static var cached: SCShareableContent?

    /// Fetched at launch and after each capture, so opening the bar does not wait ~100 ms on it.
    static func prefetch() {
        Task { cached = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
    }

    static func content() async throws -> SCShareableContent {
        if let cached { return cached }
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cached = c
        return c
    }

    static func displayFilter(_ screen: NSScreen) async throws -> (SCDisplay, SCContentFilter) {
        let content = try await content()
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw ShotError.noDisplay
        }
        let mine = content.applications.filter { $0.processID == pid }
        return (display, SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []))
    }

    /// The whole display, at its native pixel size.
    static func screen(_ screen: NSScreen) async throws -> CGImage {
        let (_, filter) = try await displayFilter(screen)
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        return try await shoot(filter, config)
    }

    /// `rect` in AppKit global points, inside `screen`.
    static func area(_ rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        let (_, filter) = try await displayFilter(screen)
        let config = SCStreamConfiguration()
        config.sourceRect = displayLocal(rect, in: screen.frame)
        config.width = Int(rect.width * screen.backingScaleFactor)
        config.height = Int(rect.height * screen.backingScaleFactor)
        return try await shoot(filter, config)
    }

    /// With its shadow on a transparent background, like ⌘⇧4-space; without, like ⌥-click there.
    static func window(_ w: WindowInfo, shadow: Bool) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: try await window(w.id))
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = !shadow
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        return try await shoot(filter, config)
    }

    /// The cache is as old as the last capture: a window opened since is missing from it.
    static func window(_ id: CGWindowID) async throws -> SCWindow {
        if let w = try await content().windows.first(where: { $0.windowID == id }) { return w }
        cached = nil
        guard let w = try await content().windows.first(where: { $0.windowID == id }) else { throw ShotError.noWindow }
        return w
    }

    private static func shoot(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws -> CGImage {
        config.showsCursor = Settings.cursor
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// The windows window mode offers (`pickable`), frontmost first, ours left out.
    @MainActor
    static func windows() -> [WindowInfo] {
        let mainHeight = NSScreen.screens[0].frame.height
        let screens = NSScreen.screens.map(\.frame)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let radii = cornerRadii(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        return list.compactMap { w in
            guard let layer = w[kCGWindowLayer as String] as? Int,
                  w[kCGWindowOwnerPID as String] as? Int32 != pid,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary),
                  bounds.width > 32, bounds.height > 32,
                  pickable(layer: layer, frame: appKit(bounds, mainHeight: mainHeight), screens: screens)
            else { return nil }
            return WindowInfo(id: id, frame: appKit(bounds, mainHeight: mainHeight),
                              app: w[kCGWindowOwnerName as String] as? String ?? "", radius: radii[id] ?? 16,
                              floating: layer != 0)
        }
    }

    /// No public API says how round a window is, and it varies: 16 pt for most macOS 26
    /// windows, 26 for one with a toolbar (Finder). SkyLight's window query does, by name.
    private static func cornerRadii(_ ids: [CGWindowID]) -> [CGWindowID: CGFloat] {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return [:] }
        func fn<T>(_ name: String, _: T.Type) -> T? { dlsym(sky, name).map { unsafeBitCast($0, to: T.self) } }
        guard let connection = fn("SLSMainConnectionID", (@convention(c) () -> Int32).self),
              let query = fn("SLSWindowQueryWindows", (@convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>).self),
              let results = fn("SLSWindowQueryResultCopyWindows", (@convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>).self),
              let advance = fn("SLSWindowIteratorAdvance", (@convention(c) (CFTypeRef) -> Bool).self),
              let windowID = fn("SLSWindowIteratorGetWindowID", (@convention(c) (CFTypeRef) -> CGWindowID).self),
              let radii = fn("SLSWindowIteratorGetResolvedCornerRadii", (@convention(c) (CFTypeRef) -> Unmanaged<CFArray>).self)
        else { return [:] }
        let it = results(query(connection(), ids as CFArray, Int32(ids.count)).takeRetainedValue()).takeRetainedValue()
        var out: [CGWindowID: CGFloat] = [:]
        while advance(it) {
            // Four corners, all the same so far.
            if let r = (radii(it).takeRetainedValue() as? [NSNumber])?.first { out[windowID(it)] = CGFloat(r.doubleValue) }
        }
        return out
    }
}

enum ShotError: LocalizedError {
    case noDisplay, noWindow
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "display not shareable — Screen Recording permission?"
        case .noWindow: return "window is gone"
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    }
    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(p) } ?? main ?? screens[0]
    }
    static func containing(_ r: CGRect) -> NSScreen {
        let c = CGPoint(x: r.midX, y: r.midY)
        return screens.first { $0.frame.contains(c) } ?? screens.max { $0.frame.intersection(r).area < $1.frame.intersection(r).area }!
    }
}

extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }
