import AppKit
import SwiftUI

struct LaunchOptions {
    var cwd = FileManager.default.currentDirectoryPath
    var resume: String?
    var prompt = ""
    var runtimeID: String?
    var socketPath: String?
    init(_ args: [String]) throws {
        var i = 0, words: [String] = []
        while i < args.count {
            switch args[i] {
            case "--cwd", "-C":
                i += 1; guard i < args.count else { throw CXError(message: "--cwd requires a folder.") }; cwd = (args[i] as NSString).expandingTildeInPath
            case "--resume", "-r":
                resume = "last"
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1; resume = args[i] }
            case "--": words += args.dropFirst(i + 1); i = args.count
            default:
                guard !args[i].hasPrefix("-") else { throw CXError(message: "Unknown option: " + args[i]) }
                words.append(args[i])
            }
            i += 1
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue else { throw CXError(message: "Working folder does not exist.") }
        prompt = words.joined(separator: " ")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    struct FrontendWindow {
        let window: NSWindow
        let session: Session
        let fleet: FleetPresence
    }
    var windows: [FrontendWindow] = []
    var window: NSWindow? { windows.first { $0.window.isKeyWindow }?.window ?? windows.first?.window }
    var session: Session? { windows.first { $0.window.isKeyWindow }?.session ?? windows.first?.session }
    var options: LaunchOptions?
    var restoreFile: String?
    var frontendLock: Int32?
    private var updating = false
    private var terminating = false
    private var closing = Set<ObjectIdentifier>()
    private var observers: [NSObjectProtocol] = []
    private var handoffFile: URL?
    private var replacement: NSRunningApplication?
    private var restorePending = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = RuntimeIdentity.build
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: RuntimeUpdate.openNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainOpenRequests() }
        })
        observers.append(center.addObserver(forName: RuntimeUpdate.updateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.replaceFrontend() }
        })
        observers.append(center.addObserver(forName: RuntimeUpdate.readyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.completeReplacement() }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.mr.vcx.focus"), object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let id = notification.userInfo?["sessionId"] as? String,
                      let entry = self?.windows.first(where: { $0.session.runtimeClient?.sessionID == id }) else { return }
                entry.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            }
        })
        let menu = NSMenu(), appMenu = NSMenu(), fileMenu = NSMenu(), editMenu = NSMenu()
        let app = NSMenuItem(); app.submenu = appMenu; menu.addItem(app)
        appMenu.addItem(withTitle: "About Vibe Code X", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Quit Vibe Code X", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); file.submenu = fileMenu; menu.addItem(file)
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "N")
        fileMenu.addItem(withTitle: "Open Project…", action: #selector(openProject), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); edit.submenu = editMenu; menu.addItem(edit)
        for (name, selector, key) in [("Undo", #selector(UndoManager.undo), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(withTitle: name, action: selector, keyEquivalent: key) }
        NSApp.mainMenu = menu

        if let restoreFile {
            do {
                let ticket = try RuntimeUpdate.readTicket(restoreFile, suffix: ".restore.json")
                guard let entries = ticket["windows"] as? [JSON], !entries.isEmpty else { throw CXError(message: "No windows to restore.") }
                restorePending = entries.count
                for entry in entries {
                    guard let cwd = entry["cwd"] as? String, let id = entry["sessionId"] as? String, UUID(uuidString: id) != nil,
                          let socket = entry["socket"] as? String else { throw CXError(message: "Invalid window restore entry.") }
                    var launch = try LaunchOptions(["--cwd", cwd])
                    launch.runtimeID = id; launch.socketPath = socket
                    createWindow(launch, state: entry["windowState"] as? JSON ?? [:])
                }
                Task {
                    for _ in 0..<100 {
                        if let lock = try? RuntimeUpdate.lockFrontend() { frontendLock = lock; break }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard frontendLock != nil else { exit(1) }
                    drainOpenRequests()
                }
            } catch { NSLog("VCX frontend restore: %@", error.localizedDescription); NSApp.terminate(nil) }
        } else if let options { createWindow(options) }
        drainOpenRequests()
        replaceFrontend()
    }

    func createWindow(_ options: LaunchOptions, state: JSON = [:]) {
        let session = Session(cwd: options.cwd)
        session.frontendReplacing = restoreFile != nil
        let client = RuntimeClient(session: session, cwd: options.cwd, resumeRuntimeID: options.runtimeID, socketPath: options.socketPath)
        session.runtimeClient = client
        let window = ComposerWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.focusComposer = { [weak session] in session?.focusComposer() }
        window.title = "\(session.folder) · Vibe Code X"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 780, height: 560)
        window.contentView = NSHostingView(rootView: CXView(session: session))
        window.backgroundColor = NSColor.white
        window.delegate = self; window.isReleasedWhenClosed = false
        if let frame = state["frame"] as? String { window.setFrame(NSRectFromString(frame), display: false) }
        else { window.setFrameAutosaveName("VCXWindow"); window.center() }
        windows.append(FrontendWindow(window: window, session: session, fleet: FleetPresence(session: session)))
        client.onLeaseLost = { [weak self, weak window] in
            guard let self, let window else { return }
            guard !self.updating else { return }
            self.closing.insert(ObjectIdentifier(window)); window.close()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            do { try await client.connect(resume: options.resume, prompt: options.prompt) }
            catch {
                if restoreFile != nil { fputs("Frontend replacement could not attach.\n", stderr); exit(1) }
                session.notice(error.localizedDescription); session.status = error.localizedDescription
            }
            window.title = "\(session.folder) · Vibe Code X"
            RuntimeUpdate.restore(state, window: window, session: session)
            if let restoreFile {
                restorePending -= 1
                if restorePending == 0 {
                    do { try RuntimeUpdate.acknowledge(restoreFile) }
                    catch { exit(1) }
                    for entry in windows { entry.session.frontendReplacing = false }
                }
            }
        }
    }

    func drainOpenRequests() {
        guard frontendLock != nil, !updating else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: RuntimeIdentity.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix(".open.json") {
            do {
                let value = try RuntimeUpdate.readTicket(file.path, suffix: ".open.json")
                guard let cwd = value["cwd"] as? String else { continue }
                var options = try LaunchOptions(["--cwd", cwd])
                options.resume = value["resume"] as? String; options.prompt = value["prompt"] as? String ?? ""
                try FileManager.default.removeItem(at: file)
                createWindow(options)
            } catch { NSLog("VCX open request: %@", error.localizedDescription) }
        }
    }

    func replaceFrontend() {
        let marker = RuntimeIdentity.directory.appendingPathComponent("installed-build")
        guard !updating, !windows.isEmpty, let installed = try? String(contentsOf: marker, encoding: .utf8),
              installed != RuntimeIdentity.build else { return }
        updating = true
        Task {
            do {
                let binary = RuntimeUpdate.installed.appendingPathComponent("Contents/MacOS/VCX")
                guard let client = windows.first?.session.runtimeClient else { throw CXError(message: "No attached frontend session.") }
                try await client.preflight(executable: binary)
                var entries: [JSON] = []
                for entry in windows {
                    entry.session.frontendReplacing = true
                    guard let runtime = entry.session.runtimeClient else { continue }
                    let state = RuntimeUpdate.state(window: entry.window, session: entry.session)
                    try await runtime.checkpointWindow(state)
                    entries.append(["cwd": entry.session.cwd, "sessionId": runtime.sessionID, "socket": runtime.socketPath, "windowState": state])
                }
                let file = try RuntimeUpdate.writeTicket(["windows": entries], suffix: ".restore.json")
                handoffFile = file
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                config.arguments = ["--restore-windows", file.path]
                replacement = try await NSWorkspace.shared.openApplication(at: RuntimeUpdate.installed, configuration: config)
                completeReplacement()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if !windows.isEmpty { throw CXError(message: "The replacement frontend did not finish attaching.") }
            } catch {
                if let replacement, !replacement.isTerminated {
                    replacement.forceTerminate()
                    for _ in 0..<30 where !replacement.isTerminated { try? await Task.sleep(nanoseconds: 100_000_000) }
                    guard replacement.isTerminated else { return }
                }
                for entry in windows where entry.session.runtimeClient?.isAttached == false {
                    try? await entry.session.runtimeClient?.reclaim()
                }
                for entry in windows { entry.session.frontendReplacing = false; entry.session.notice("Automatic frontend update paused: " + error.localizedDescription) }
                if let handoffFile {
                    try? FileManager.default.removeItem(at: handoffFile)
                    try? FileManager.default.removeItem(atPath: handoffFile.path + ".ready.json")
                }
                handoffFile = nil; replacement = nil
                updating = false
                drainOpenRequests()
            }
        }
    }

    func completeReplacement() {
        guard updating, let handoffFile, let replacement, !replacement.isTerminated,
              let ready = try? RuntimeUpdate.readTicket(handoffFile.path + ".ready.json", suffix: ".ready.json"),
              ready["pid"] as? Int == Int(replacement.processIdentifier) else { return }
        try? FileManager.default.removeItem(at: handoffFile)
        try? FileManager.default.removeItem(atPath: handoffFile.path + ".ready.json")
        for entry in Array(windows) { closing.insert(ObjectIdentifier(entry.window)); entry.window.close() }
    }

    @objc func openProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.begin { result in if result == .OK, let url = panel.url { self.openWindow(cwd: url.path) } }
    }
    @objc func newWindow() { openWindow(cwd: session?.cwd ?? NSHomeDirectory()) }
    func openWindow(cwd: String) {
        guard let options = try? LaunchOptions(["--cwd", cwd]) else { return }
        if updating { try? RuntimeUpdate.forward(options) }
        else { createWindow(options) }
    }
    func closeWindow(session: Session) { windows.first { $0.session === session }?.window.performClose(nil) }
    func updateTitle(session: Session) {
        windows.first { $0.session === session }?.window.title = session.folder + " · Vibe Code X"
    }
    func windowDidBecomeKey(_ notification: Notification) { FleetPresence.refreshFocus() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if terminating || closing.contains(ObjectIdentifier(sender)) { return true }
        guard let entry = windows.first(where: { $0.window === sender }) else { return true }
        guard !entry.session.frontendReplacing else { return false }
        entry.session.frontendReplacing = true
        Task {
            do {
                try await entry.session.runtimeClient?.checkpointWindow(RuntimeUpdate.state(window: sender, session: entry.session))
                _ = try await entry.session.runtimeClient?.perform("close")
                closing.insert(ObjectIdentifier(sender)); sender.close()
            } catch { entry.session.frontendReplacing = false; entry.session.notice("Cannot close before saving the draft: " + error.localizedDescription) }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let index = windows.firstIndex(where: { $0.window === window }) else { return }
        let entry = windows.remove(at: index)
        entry.session.close(); entry.fleet.close(); closing.remove(ObjectIdentifier(window))
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating || windows.isEmpty { return .terminateNow }
        Task {
            do {
                for entry in windows {
                    entry.session.frontendReplacing = true
                    try await entry.session.runtimeClient?.checkpointWindow(RuntimeUpdate.state(window: entry.window, session: entry.session))
                    _ = try await entry.session.runtimeClient?.perform("close")
                }
                terminating = true; sender.reply(toApplicationShouldTerminate: true)
            } catch {
                for entry in windows { entry.session.frontendReplacing = false; entry.session.notice("Cannot quit before saving drafts: " + error.localizedDescription) }
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        for entry in windows { entry.session.close(); entry.fleet.close() }
        if let frontendLock { flock(frontendLock, LOCK_UN); Darwin.close(frontendLock) }
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}

MainActor.assumeIsolated {
signal(SIGPIPE, SIG_IGN)
let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--runtime-protocol") { print("1"); exit(0) }
if args.contains("--publish-update") {
    do { try RuntimeUpdate.publish(); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if args.contains(where: { ["-p", "--print", "--headless", "--ensure-qwen"].contains($0) }) {
    let arguments = (["/usr/bin/python3", Bundle.main.resourceURL!.appendingPathComponent("background.py").path] + args).map { strdup($0) } + [nil]
    defer { arguments.forEach { free($0) } }
    arguments.withUnsafeBufferPointer { _ = execv("/usr/bin/python3", $0.baseAddress!) }
    perror("vcx"); exit(1)
}
if args.contains("--version") { print("vcx 0.2.0 (Vibe Code X)"); exit(0) }
if args.contains("--help") { print("vcx [--cwd FOLDER] [--resume [ID]] [PROMPT]\nvcx -p [--provider auto|claude|codex|qwen] [--output-format text|json|stream-json] [PROMPT]\nUse -p for background jobs with automatic fallback. Use cx --terminal for the previous terminal interface."); exit(0) }
if args.contains("--check") || args.contains("--runtime-check") || args.contains("--render") || args.contains("--icon") {
    setenv("VCX_CONFIG_HOME", (NSTemporaryDirectory() + "vcx-preview-" + UUID().uuidString), 1)
}
let app = NSApplication.shared
if let index = args.firstIndex(of: "--runtime-worker") {
    app.setActivationPolicy(.prohibited)
    _ = setsid()
    guard index + 1 < args.count else { fputs("Missing runtime socket.\n", stderr); exit(2) }
    var command: [String]?
    if let fixture = args.firstIndex(of: "--runtime-fixture-command") {
        guard args.contains("--runtime-test"), fixture + 1 < args.count,
              let data = try? Data(contentsOf: URL(fileURLWithPath: args[fixture + 1])),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String], !value.isEmpty else {
            fputs("Invalid runtime test command.\n", stderr); exit(2)
        }
        command = value
    }
    let server = RuntimeServer(socketPath: args[index + 1], build: RuntimeIdentity.build) { params in
        let state = args.contains("--runtime-test") ? RuntimeIdentity.directory.appendingPathComponent("test-state") : nil
        let backend = SessionBackend(cwd: params["cwd"] as? String ?? FileManager.default.currentDirectoryPath, stateDirectory: state)
        backend.startInBackground(params: params, command: command)
        return backend
    }
    server.onEmpty = { server.stop(); exit(0) }
    do { try server.start() }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    let signals = [SIGTERM, SIGINT].map { value -> DispatchSourceSignal in
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
        source.setEventHandler { server.stop(); exit(0) }
        source.resume(); return source
    }
    withExtendedLifetime((server, signals)) { RunLoop.main.run() }
    exit(0)
}
if let index = args.firstIndex(of: "--icon"), index + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    Render.write(AppIcon(), size: CGSize(width: 1024, height: 1024), path: args[index + 1]); exit(0)
}
if let index = args.firstIndex(of: "--render"), index + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    Render.run(directory: args[index + 1]); exit(0)
}
if args.contains("--runtime-check") {
    app.setActivationPolicy(.prohibited)
    Task {
        do { _ = try await RuntimeCheck.run(); exit(0) }
        catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else if let index = args.firstIndex(of: "--live-check"), index + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    Task { let ok = await Check.live(settings: args[index + 1]); exit(ok ? 0 : 1) }
    RunLoop.main.run()
} else if args.contains("--check") {
    app.setActivationPolicy(.prohibited)
    Task { let ok = await Check.run(); exit(ok ? 0 : 1) }
    RunLoop.main.run()
} else {
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    do {
        if let restore = args.firstIndex(of: "--restore-windows"), restore + 1 < args.count {
            _ = try RuntimeUpdate.readTicket(args[restore + 1], suffix: ".restore.json")
            delegate.restoreFile = args[restore + 1]
        } else {
            let options = try LaunchOptions(args)
            guard let lock = try RuntimeUpdate.lockFrontend() else { try RuntimeUpdate.forward(options); exit(0) }
            delegate.frontendLock = lock; delegate.options = options
        }
    }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(2) }
    app.delegate = delegate
    app.run()
}

}
