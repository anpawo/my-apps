import AppKit
import ApplicationServices
import DesksCore
import MachO

/// The real desktops, the Dock's own. What the window server lets anyone do is read them; going
/// to one, moving a window there and making one each take a side door, none needing SIP.
enum Spaces {

    struct Desktop { let id: UInt64; let type: Int; let current: Bool }

    /// The desktops of the screen holding the menu bar, left to right, fullscreen apps included:
    /// a swipe steps through those too, so they count as places.
    static func desktops() -> [Desktop] {
        let screens = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        let active = CGSCopyActiveMenuBarDisplayIdentifier(CGSMainConnectionID()) as String
        let screen = screens.first { $0["Display Identifier"] as? String == active } ?? screens.first
        guard let screen else { return [] }
        let current = ((screen["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
        return (screen["Spaces"] as? [[String: Any]] ?? []).compactMap { space in
            guard let id = (space["id64"] as? NSNumber)?.uint64Value else { return nil }
            return Desktop(id: id, type: space["type"] as? Int ?? 0, current: id == current)
        }
    }

    static func spaces(of window: CGWindowID) -> [UInt64] {
        (CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, [window] as CFArray)
            as? [NSNumber] ?? []).map(\.uint64Value)
    }

    // MARK: - Going to a desktop

    /// The window server reports the old desktop for a moment after a switch, so a quick second
    /// press counts from where the first one went, not from what it reads.
    private static var predicted: (index: Int, at: Date)?
    private static let predictionLifetime: TimeInterval = 1

    @discardableResult
    static func focus(_ target: Target) -> Bool {
        let row = desktops()
        guard let read = row.firstIndex(where: \.current) else { return false }
        let current = predicted.flatMap { Date().timeIntervalSince($0.at) < predictionLifetime ? $0.index : nil } ?? read
        guard let goal = target.index(from: current, count: row.count) else { return false }
        let steps = abs(goal - current)
        for _ in 0..<steps { swipe(right: goal > current, velocity: swipeVelocity * Double(steps)) }
        predicted = (goal, Date())
        return true
    }

    /// A three-finger swipe the Dock cannot tell from a trackpad's, flung so fast it skips the
    /// slide. The technique and the field numbers are InstantSpaceSwitcher's (jurplel, MIT),
    /// its pre-macOS-27 path. Posting events needs the Accessibility grant.
    private static func swipe(right: Bool, velocity: Double) {
        for phase in [Phase.began, .changed, .ended] {
            guard let event = CGEvent(source: nil) else { return }
            event.setIntegerValueField(Field.eventType, value: dockControlEvent)
            event.setIntegerValueField(Field.hidType, value: dockSwipeHIDType)
            event.setIntegerValueField(Field.phase, value: phase.rawValue)
            event.setDoubleValueField(Field.progress, value: right ? swipeProgress : -swipeProgress)
            event.setIntegerValueField(Field.motion, value: horizontalMotion)
            event.setDoubleValueField(Field.velocityX, value: right ? velocity : -velocity)
            event.setDoubleValueField(Field.velocityY, value: right ? velocity : -velocity)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }
    private enum Field {
        static let eventType = CGEventField(rawValue: 55)!
        static let hidType = CGEventField(rawValue: 110)!
        static let motion = CGEventField(rawValue: 123)!
        static let progress = CGEventField(rawValue: 124)!
        static let velocityX = CGEventField(rawValue: 129)!
        static let velocityY = CGEventField(rawValue: 130)!
        static let phase = CGEventField(rawValue: 132)!
    }
    private static let dockControlEvent: Int64 = 30
    private static let dockSwipeHIDType: Int64 = 23
    private static let horizontalMotion: Int64 = 1
    /// The smallest non-zero 16.16 value: nothing left to animate.
    private static let swipeProgress = 0.000016
    private static let swipeVelocity = 2000.0

    // MARK: - Sending a window to a desktop

    /// The window in front of you goes to `target`; past the last desktop one is made for it.
    @discardableResult
    static func sendFrontWindow(to target: Target, follow: Bool) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let window = windowsHere().first(where: {
                  $0[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier
              }),
              let id = window[kCGWindowNumber as String] as? CGWindowID else { return false }
        var row = desktops().filter { $0.type == 0 }.map(\.id)
        guard let space = spaces(of: id).first, let here = row.firstIndex(of: space) else { return false }
        let beyond: Bool
        switch target {
        case .next: beyond = here + 1 >= row.count
        case .number(let n): beyond = n > row.count
        case .previous: beyond = false
        }
        if beyond {
            guard addDesktop(), let grown = waitForDesktops(beyond: row.count) else { return false }
            row = grown
        }
        let goal: Int
        switch target {
        case .next: goal = min(here + 1, row.count - 1)
        case .previous: goal = max(here - 1, 0)
        case .number(let n): goal = min(n - 1, row.count - 1)
        }
        guard goal != here, move(id, to: row[goal]) else { return false }
        if follow, let index = desktops().firstIndex(where: { $0.id == row[goal] }) {
            focus(.number(index + 1))
            app.activate()
        }
        return true
    }

    private static func windowsHere() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                    kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { $0[kCGWindowLayer as String] as? Int == 0 }
    }

    private static func waitForDesktops(beyond count: Int) -> [UInt64]? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let row = desktops().filter { $0.type == 0 }.map(\.id)
            if row.count > count { return row }
            usleep(20_000)
        }
        return nil
    }

    /// macOS 14.5 shut `SLSMoveWindowsToManagedSpace` to all but the Dock; the bridged
    /// operation SkyLight hands the Dock still moves a window. From Fleet's Spaces.swift.
    private static func move(_ window: CGWindowID, to space: UInt64) -> Bool {
        guard let perform = performBridged,
              let type = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") as? NSObject.Type,
              let initialize = class_getMethodImplementation(type, initWithWindows) else { return false }
        let operation = unsafeBitCast(initialize, to: Initializer.self)(
            type.perform(NSSelectorFromString("alloc")).takeRetainedValue(), initWithWindows,
            [window] as CFArray, space)
        _ = perform(Unmanaged.passUnretained(operation).toOpaque())
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if spaces(of: window) == [space] { return true }
            usleep(20_000)
        }
        return false
    }

    private typealias Initializer = @convention(c) (AnyObject, Selector, CFArray, UInt64) -> AnyObject
    private typealias Perform = @convention(c) (UnsafeMutableRawPointer) -> Int64
    private static let initWithWindows = NSSelectorFromString("initWithWindows:spaceID:")
    private static let performBridged: Perform? = localSymbol(
        "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation",
        in: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    ).map { unsafeBitCast($0, to: Perform.self) }

    /// A symbol of a loaded image, local ones included: what `dlsym` cannot reach.
    private static func localSymbol(_ name: String, in image: String) -> UnsafeMutableRawPointer? {
        for i in 0..<_dyld_image_count()
        where _dyld_get_image_name(i).map({ String(cString: $0) }) == image {
            guard let header = _dyld_get_image_header(i) else { return nil }
            let slide = _dyld_get_image_vmaddr_slide(i)
            var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            var linkedit: segment_command_64?
            var symtab: symtab_command?
            for _ in 0..<header.pointee.ncmds {
                let kind = command.load(as: load_command.self)
                if kind.cmd == LC_SYMTAB { symtab = command.load(as: symtab_command.self) }
                if kind.cmd == LC_SEGMENT_64 {
                    let segment = command.load(as: segment_command_64.self)
                    let name = withUnsafeBytes(of: segment.segname) {
                        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                    }
                    if name == "__LINKEDIT" { linkedit = segment }
                }
                command = command.advanced(by: Int(kind.cmdsize))
            }
            guard let linkedit, let symtab else { return nil }
            let base = Int(linkedit.vmaddr) - Int(linkedit.fileoff) + slide
            guard let names = UnsafePointer<CChar>(bitPattern: base + Int(symtab.stroff)),
                  let entries = UnsafePointer<nlist_64>(bitPattern: base + Int(symtab.symoff)) else { return nil }
            for entry in UnsafeBufferPointer(start: entries, count: Int(symtab.nsyms))
            where strcmp(names + Int(entry.n_un.n_strx), name) == 0 {
                return UnsafeMutableRawPointer(bitPattern: Int(entry.n_value) + slide)
            }
        }
        return nil
    }

    // MARK: - Making a desktop

    /// No API makes a desktop the Dock knows (`SLSSpaceCreate` makes a ghost, see Fleet's
    /// Spaces.swift): Mission Control's own `+` is pressed through Accessibility, so it flashes
    /// on screen for about half a second.
    @discardableResult
    static func addDesktop() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let opened = missionControl() == nil
        if opened { CoreDockSendNotification("com.apple.expose.awake" as CFString, 0) }
        var button: AXUIElement?
        let deadline = Date().addingTimeInterval(2)
        while button == nil, Date() < deadline {
            button = spacesBar().flatMap { children($0).first { identifier($0) == "mc.spaces.add" } }
            if button == nil { usleep(20_000) }
        }
        let pressed = button.map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
        if opened {
            usleep(250_000)
            CoreDockSendNotification("com.apple.expose.awake" as CFString, 0)
        }
        return pressed
    }

    /// `Dock → mc → mc.display → mc.spaces`, by identifier: titles are localized.
    private static func spacesBar() -> AXUIElement? {
        guard let mc = missionControl(),
              let screen = children(mc).first(where: { identifier($0) == "mc.display" }) else { return nil }
        return children(screen).first { identifier($0) == "mc.spaces" }
    }

    private static func missionControl() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        return children(AXUIElementCreateApplication(dock.processIdentifier)).first { identifier($0) == "mc" }
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    private static func identifier(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &value)
        return value as? String
    }
}

@_silgen_name("CoreDockSendNotification")
private func CoreDockSendNotification(_ name: CFString, _ reserved: Int32)
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray
@_silgen_name("CGSCopyActiveMenuBarDisplayIdentifier")
private func CGSCopyActiveMenuBarDisplayIdentifier(_ connection: Int32) -> CFString
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray
