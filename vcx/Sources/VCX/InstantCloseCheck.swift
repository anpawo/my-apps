import AppKit

@MainActor
enum InstantCloseCheck {
    private static let timeout: TimeInterval = 5
    private static let pollDelay: UInt64 = 1_000_000
    private final class Backend: RuntimeBackend {
        var onChange: ((JSON) -> Void)?
        var closing = false
        var closed = false
        var failClose = false
        var draft: [JSON] = []
        var release: CheckedContinuation<Void, Never>?
        func snapshot() -> JSON { ["ready": true, "status": "Ready", "rows": []] }
        func perform(action: String, params: JSON) async throws -> JSON {
            if action == "checkpoint" { draft = params["draft"] as? [JSON] ?? [] }
            if action == "close" {
                closing = true
                await withCheckedContinuation { release = $0 }
                if failClose { throw VCXError(message: "Expected close fixture failure.") }
            }
            return [:]
        }
        func finish() { release?.resume(); release = nil }
        func close() { closed = true; finish() }
    }

    static func run() async throws -> Int {
        let count = try await runCase(failClose: false) + runCase(failClose: true)
        print("\(count) instant close checks passed (AppKit windows never displayed)")
        return count
    }

    // The shared live fixture keeps draft preservation, sibling ownership and app termination in one lifecycle.
    private static func runCase(failClose: Bool) async throws -> Int {
        let root = URL(fileURLWithPath: "/tmp/vcx-close-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let previousHome = ProcessInfo.processInfo.environment["VCX_RUNTIME_HOME"]
        setenv("VCX_RUNTIME_HOME", root.path, 1)
        let frontend = AppDelegate(), previousDelegate = NSApp.delegate
        frontend.headless = true; NSApp.delegate = frontend
        var backends: [Backend] = [], count = 0
        let socket = root.appendingPathComponent("worker.sock").path
        let server = RuntimeServer(socketPath: socket, build: "close-fixture") { _ in
            let backend = Backend(); backends.append(backend); return backend
        }
        try server.start()
        defer {
            backends.forEach { $0.finish() }; server.stop()
            for entry in Array(frontend.windows) { entry.window.delegate = nil; entry.window.close(); entry.session.close(); entry.fleet.close() }
            NSApp.delegate = previousDelegate
            if let previousHome { setenv("VCX_RUNTIME_HOME", previousHome, 1) } else { unsetenv("VCX_RUNTIME_HOME") }
            try? FileManager.default.removeItem(at: root)
        }
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw VCXError(message: "Instant close: " + message) }; count += 1
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else { throw VCXError(message: "Instant close fixture timed out.") }
                try await Task.sleep(nanoseconds: pollDelay)
            }
        }
        for index in 0..<2 {
            let session = Session(cwd: root.path, stateDirectory: root.appendingPathComponent("state-\(index)"))
            let client = RuntimeClient(session: session, cwd: root.path, socketPath: socket)
            session.runtimeClient = client
            try await client.connect(resume: nil)
            let window = ComposerWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false; window.delegate = frontend
            frontend.windows.append(AppDelegate.FrontendWindow(window: window, session: session, fleet: FleetPresence(session: session)))
        }
        let target = frontend.windows[0], sibling = frontend.windows[1]
        target.session.draft = NSAttributedString(string: "Preserved close draft")
        let menu = NSMenu(), appMenu = NSMenu()
        frontend.configureMenu(menu, appMenu: appMenu, fileMenu: NSMenu(), editMenu: NSMenu())
        guard let shortcut = appMenu.items.first(where: { $0.keyEquivalent == "k" }) else { throw VCXError(message: "Cmd+K close shortcut is missing.") }
        try check(shortcut.action == #selector(ComposerWindow.closeImmediately(_:)) && shortcut.keyEquivalentModifierMask == .command && shortcut.allowsKeyEquivalentWhenHidden, "Cmd+K did not route to the focused window")
        target.session.busy = true
        frontend.headless = false
        let started = DispatchTime.now().uptimeNanoseconds
        let handled = NSApp.sendAction(shortcut.action!, to: target.window, from: shortcut)
        frontend.headless = true
        try check(handled && target.window.attachedSheet == nil, "Cmd+K was not handled immediately while busy")
        try check(frontend.windows.count == 1 && frontend.windows[0].window === sibling.window, "window remained open until cleanup completed")
        print(String(format: "Window dismissed before cleanup: %.2f ms", Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
        try await wait { backends[0].closing }
        try check(!backends[0].closed && target.session.runtimeClient?.isAttached == true, "closing the window interrupted its archive")
        try check(backends[0].draft.first?["text"] as? String == "Preserved close draft", "background close lost the draft")
        try check(sibling.session.runtimeClient?.isAttached == true && !backends[1].closing, "closing one window affected its sibling")
        backends[0].finish()
        try await wait { backends[0].closed && !frontend.hasPendingCloses }
        try check(!target.window.isVisible && !sibling.window.isVisible, "close verification displayed a window")
        sibling.session.draft = NSAttributedString(string: "Draft after failed cleanup")
        backends[1].failClose = failClose
        sibling.window.performClose(nil)
        try check(frontend.windows.isEmpty, "last window waited for cleanup")
        var replied: Bool?
        frontend.terminationReply = { replied = $0 }
        try check(frontend.applicationShouldTerminate(NSApp) == .terminateLater, "last window terminated its pending archive")
        try await wait { backends[1].closing }
        backends[1].finish()
        try await wait { replied != nil && !frontend.hasPendingCloses }
        if failClose {
            try check(replied == false && frontend.windows.count == 1 && sibling.session.draft.string == "Draft after failed cleanup", "failed cleanup lost the recoverable window or draft")
        } else {
            try check(replied == true && frontend.windows.isEmpty && backends[1].closed, "last window did not finish archiving before app termination")
        }
        return count
    }
}
