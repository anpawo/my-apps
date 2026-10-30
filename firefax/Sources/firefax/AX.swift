import AppKit
import ApplicationServices

// The accessibility surface the engine runs on, behind a protocol so --selftest drives an in-memory
// FakeAX and never touches the real tree, a real window, real time or his keychain. LiveAX is the
// thin shim lifted from ovhax/axprobe; it is never run against his Firefox here.

protocol Clock {
    func now() -> Double
    func sleep(_ seconds: Double)
}

protocol AXNode: AnyObject {
    func str(_ attr: String) -> String?
    func num(_ attr: String) -> Int?
    func bool(_ attr: String) -> Bool?
    func kids() -> [AXNode]
    func parent() -> AXNode?
    @discardableResult func setValue(_ s: String) -> Bool
    @discardableResult func focus() -> Bool
    @discardableResult func press() -> Bool
    func same(as other: AXNode) -> Bool
}

extension AXNode {
    var role: String { str("AXRole") ?? "" }
    var axValue: String { str("AXValue") ?? "" }
    var enabled: Bool { bool("AXEnabled") ?? true }
    var secure: Bool { str("AXSubrole") == "AXSecureTextField" }
}

enum LeaseResult { case typed, focusLost, notIdle }

enum Challenge {
    case challenge(String)  // a captcha / rate-limit wall: lock the host, exit 5
    case expired            // "session expirée": exit 3, no lock
}

// What fill needs of the live context: the page it started on, and the guarded ways to act on it.
protocol Page {
    var host: String { get }
    var path: String { get }
    func webArea() -> AXNode?
    func sameWindow() -> Bool
    func typeUnderLease(_ chars: String, into target: AXNode, human: Bool) -> LeaseResult
    func restore()
}

struct RealClock: Clock {
    func now() -> Double { Date().timeIntervalSinceReferenceDate }
    func sleep(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}

// ---- Live AX (compiled, never exercised here) ----

final class LiveNode: AXNode {
    let el: AXUIElement
    init(_ el: AXUIElement) { self.el = el }
    private func raw(_ a: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success ? v : nil
    }
    func str(_ a: String) -> String? { raw(a) as? String }
    func num(_ a: String) -> Int? { (raw(a) as? NSNumber)?.intValue }
    func bool(_ a: String) -> Bool? { (raw(a) as? NSNumber)?.boolValue }
    func kids() -> [AXNode] { (raw("AXChildren") as? [AXUIElement] ?? []).map(LiveNode.init) }
    func parent() -> AXNode? { raw("AXParent").map { LiveNode($0 as! AXUIElement) } }
    func setValue(_ s: String) -> Bool {
        AXUIElementSetAttributeValue(el, "AXFocused" as CFString, kCFBooleanTrue)
        return AXUIElementSetAttributeValue(el, "AXValue" as CFString, s as CFString) == .success
    }
    func focus() -> Bool { AXUIElementSetAttributeValue(el, "AXFocused" as CFString, kCFBooleanTrue) == .success }
    func press() -> Bool { AXUIElementPerformAction(el, kAXPressAction as CFString) == .success }
    func same(as other: AXNode) -> Bool { (other as? LiveNode).map { CFEqual(el, $0.el) } ?? false }
}

final class LivePage: Page {
    let pid: pid_t
    let app: AXUIElement
    let window: AXUIElement
    let startArea: AXUIElement
    let host: String
    let path: String
    private let previousApp: NSRunningApplication?

    init?(wantHost: String, wantPath: String, clock: Clock) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "org.mozilla.firefox").first,
              running.processIdentifier > 0 else { return nil }
        pid = running.processIdentifier
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 5.0)
        LivePage.wake(app)
        var found: (AXUIElement, AXUIElement)?
        let start = clock.now()
        while clock.now() - start < 5.0 {
            if let hit = LivePage.findArea(app, wantHost: wantHost, wantPath: wantPath) { found = hit; break }
            clock.sleep(0.1)
        }
        guard let (win, area) = found else { return nil }
        window = win
        startArea = area
        host = wantHost
        path = wantPath
        previousApp = NSWorkspace.shared.frontmostApplication
    }

    // For `scan` with no page given: the web area of the frontmost Firefox window, whatever its host.
    convenience init?(clock: Clock) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "org.mozilla.firefox").first,
              running.processIdentifier > 0 else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 5.0)
        LivePage.wake(app)
        var wantHost = "", wantPath = ""
        let start = clock.now()
        while clock.now() - start < 5.0 {
            if let wins = LivePage.attr(app, "AXWindows") as? [AXUIElement] {
                for win in wins {
                    if let area = LivePage.search(win, 0), let url = LivePage.attr(area, "AXURL") as? URL,
                       let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let h = comps.host {
                        wantHost = h; wantPath = comps.path; break
                    }
                }
            }
            if !wantHost.isEmpty { break }
            clock.sleep(0.1)
        }
        guard !wantHost.isEmpty else { return nil }
        self.init(wantHost: wantHost, wantPath: wantPath, clock: clock)
    }

    static func wake(_ app: AXUIElement) {
        // Firefox turns its tree on when this is set; the error code is expected (firefox.md 2026-10-22).
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    static func findArea(_ app: AXUIElement, wantHost: String, wantPath: String) -> (AXUIElement, AXUIElement)? {
        for win in attr(app, "AXWindows") as? [AXUIElement] ?? [] {
            if let area = search(win, 0), let url = attr(area, "AXURL") as? URL,
               let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               comps.host == wantHost, comps.path.hasPrefix(wantPath) {
                return (win, area)
            }
        }
        return nil
    }

    private static func search(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
        if (attr(e, "AXRole") as? String) == "AXWebArea" { return e }
        if depth > 12 { return nil }
        for c in attr(e, "AXChildren") as? [AXUIElement] ?? [] {
            if let w = search(c, depth + 1) { return w }
        }
        return nil
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    func webArea() -> AXNode? {
        LivePage.search(window, 0).map(LiveNode.init)
    }

    func sameWindow() -> Bool {
        guard let wins = LivePage.attr(app, "AXWindows") as? [AXUIElement] else { return false }
        return wins.contains { CFEqual($0, window) }
    }

    func typeUnderLease(_ chars: String, into target: AXNode, human: Bool) -> LeaseResult {
        guard idleSeconds() >= 2 else { return .notIdle }
        NSRunningApplication(processIdentifier: pid)?.activate()
        AXUIElementPerformAction(window, "AXRaise" as CFString)
        Thread.sleep(forTimeInterval: 0.2)
        let gaps = Cadence.gaps(max(chars.count, 1), seed: 0xF1FAC5)
        for (i, c) in chars.enumerated() {
            guard frontIsFirefox(), let focused = focusedElement(), focused.same(as: target) else {
                restore(); return .focusLost
            }
            post(c)
            let ms = human ? gaps[i] : 30
            Thread.sleep(forTimeInterval: ms / 1000)
        }
        restore()
        return .typed
    }

    func restore() { previousApp?.activate() }

    private func idleSeconds() -> Double {
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    private func frontIsFirefox() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

    private func focusedElement() -> AXNode? {
        LivePage.attr(app, "AXFocusedUIElement").map { LiveNode($0 as! AXUIElement) }
    }

    private func post(_ c: Character) {
        let src = CGEventSource(stateID: .privateState)
        let mapped = USKeys.code(c)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: mapped?.code ?? 0, keyDown: down) else { continue }
            e.flags = (mapped?.shift == true) ? .maskShift : []
            if mapped == nil { e.keyboardSetUnicodeString(stringLength: String(c).utf16.count, unicodeString: Array(String(c).utf16)) }
            e.setIntegerValueField(.eventSourceUserData, value: firefaxEventStamp)
            e.post(tap: .cghidEventTap)
        }
    }
}
