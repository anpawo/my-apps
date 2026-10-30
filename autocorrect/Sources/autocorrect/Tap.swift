import AppKit

/// firefax stamps every key it posts with this value; autocorrect lets those pass untouched so a
/// form it fills is not rewritten. Keep equal to firefaxEventStamp in firefax/Sources/firefax/Keys.swift.
let firefaxEventStamp: Int64 = 0x6669_7265_6661_78  // "firefax"

/// Every key and click of the session goes through here; the corrections are typed back as
/// key events of their own, right behind this tap, so they never come through it again.
final class Tap {
    private var typist: Typist
    private var port: CFMachPort?
    /// Apps where words are not prose: terminals, code editors, password managers. Not Ghostty:
    /// it is where he writes to Claude Code.
    private let skipped: Set<String>
    private var app: String?

    static let defaultSkipped: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4", "com.apple.dt.Xcode",
        "com.jetbrains.intellij", "com.jetbrains.CLion", "com.jetbrains.pycharm", "com.google.android.studio",
        "com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords",
    ]

    init(_ words: Words) {
        typist = Typist(words)
        skipped = Self.defaultSkipped.union(UserDefaults.standard.stringArray(forKey: "skip") ?? [])
    }

    /// False until macOS grants Accessibility: without it a tap that can change keys is refused.
    func start() -> Bool {
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { proxy, type, event, me in
            Unmanaged<Tap>.fromOpaque(me!).takeUnretainedValue().handle(proxy, type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            _ = typist.handle(.reset)
            return pass
        }
        guard type == .keyDown else { _ = typist.handle(.focus); return pass }
        if event.getIntegerValueField(.eventSourceUserData) == firefaxEventStamp { return pass }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let front, skipped.contains(front) {
            _ = typist.handle(.reset)
            return pass
        }
        if front != app { app = front; _ = typist.handle(.focus) }
        guard let key = Self.key(event) else { return pass }
        switch typist.handle(key) {
        case .pass:
            return pass
        case let .edit(delete, text, thenKey):
            let source = CGEventSource(stateID: .privateState)
            for _ in 0..<delete { Self.post(proxy, source, code: 51) }
            for c in text { Self.post(proxy, source, text: String(c)) }
            if thenKey, let copy = event.copy() { copy.tapPostEvent(proxy) }
            return nil
        }
    }

    /// nil for a dead key: it types nothing yet, the next key brings the accented letter.
    private static func key(_ event: CGEvent) -> Typist.Key? {
        if !event.flags.isDisjoint(with: [.maskCommand, .maskControl]) { return .focus }
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 51: return .backspace
        case 36, 76: return .char("\r")
        default: break
        }
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
        let text = String(utf16CodeUnits: units, count: length)
        guard let c = text.first else { return nil }
        // Tab, Escape, arrows, function keys: the caret may go anywhere.
        if text.count > 1 || c.unicodeScalars.contains(where: { $0.value < 32 || (0xF700...0xF8FF).contains($0.value) }) {
            return .reset
        }
        return .char(c)
    }

    private static func post(_ proxy: CGEventTapProxy, _ source: CGEventSource?, code: CGKeyCode = 0, text: String? = nil) {
        let units = text.map { Array($0.utf16) } ?? []
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = []
            if text != nil { e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
            e.tapPostEvent(proxy)
        }
    }
}
