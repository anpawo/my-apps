import AppKit
import SwiftUI

struct LaunchOptions {
    var cwd = FileManager.default.currentDirectoryPath
    var resume: String?
    var prompt = ""
    var focus = false
    var runtimeID: String?
    var socketPath: String?
    var recoveryEntry: RuntimeRecovery.Entry?
    init(_ args: [String]) throws {
        var i = 0, words: [String] = []
        while i < args.count {
            switch args[i] {
            case "--cwd", "-C":
                i += 1; guard i < args.count else { throw CXError(message: "--cwd requires a folder.") }; cwd = (args[i] as NSString).expandingTildeInPath
            case "--resume", "-r":
                resume = "last"
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1; resume = args[i] }
            case "--focus": focus = true
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
    var headless = false
    var verificationMode: String?
    var replacementBinary = RuntimeUpdate.installed.appendingPathComponent("Contents/MacOS/VCX")
    var replacementLaunch: ((URL) async throws -> FrontendReplacementProcess)?
    var replacementTimeout: Double = 15
    private(set) var replacementTask: Task<Void, Never>?
    private var updating = false
    private var terminating = false
    private var closing = Set<ObjectIdentifier>()
    private var observers: [NSObjectProtocol] = []
    private var handoffFile: URL?
    private var replacement: FrontendReplacementProcess?
    private var replacementWaiter: CheckedContinuation<Void, Error>?
    private var replacementDeadline: DispatchWorkItem?
    private var replacementAcknowledged = false
    private var restorePending = 0
    private var refreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = RuntimeIdentity.build
        observeFrontendEvents()
        let menu = NSMenu(), appMenu = NSMenu(), fileMenu = NSMenu(), editMenu = NSMenu()
        configureMenu(menu, appMenu: appMenu, fileMenu: fileMenu, editMenu: editMenu)
        restoreWindows()
        Task {
            do { _ = try await RuntimeRecovery.finishRequestedCloses() }
            catch { NSLog("VCX pending session close: %@", error.localizedDescription) }
        }
        drainOpenRequests()
        if !headless { replaceFrontend(); FreezeTrace.start() }
    }

    func observeFrontendEvents() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: RuntimeUpdate.openNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainOpenRequests() }
        })
        observers.append(center.addObserver(forName: RuntimeUpdate.updateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.headless == false { self?.replaceFrontend() } }
        })
        observers.append(center.addObserver(forName: RuntimeUpdate.readyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.completeReplacement() }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.mr.vcx.focus"), object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let id = notification.userInfo?["sessionId"] as? String,
                      let entry = self?.windows.first(where: { $0.session.runtimeClient?.sessionID == id }) else { return }
                guard self?.headless == false else { return }
                entry.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            }
        })
    }

    func stopObservingFrontendEvents() {
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers.removeAll()
    }

    func configureMenu(_ menu: NSMenu, appMenu: NSMenu, fileMenu: NSMenu, editMenu: NSMenu) {
        let app = NSMenuItem(); app.submenu = appMenu; menu.addItem(app)
        appMenu.addItem(withTitle: "About Vibe Code X", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Close Session", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); file.submenu = fileMenu; menu.addItem(file)
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "N")
        fileMenu.addItem(withTitle: "Open Project…", action: #selector(openProject), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); edit.submenu = editMenu; menu.addItem(edit)
        for (name, selector, key) in [("Undo", #selector(UndoManager.undo), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(withTitle: name, action: selector, keyEquivalent: key) }
        NSApp.mainMenu = menu
    }

    private func restoreWindows() {
        if let restoreFile {
            do {
                let ticket = try RuntimeUpdate.readTicket(restoreFile, suffix: ".restore.json")
                guard let entries = ticket["windows"] as? [JSON], !entries.isEmpty else { throw CXError(message: "No windows to restore.") }
                restorePending = entries.count
                for entry in verificationMode == "partial" ? Array(entries.prefix(1)) : entries {
                    guard let cwd = entry["cwd"] as? String, let id = entry["sessionId"] as? String, UUID(uuidString: id) != nil,
                          let socket = entry["socket"] as? String else { throw CXError(message: "Invalid window restore entry.") }
                    var launch = try LaunchOptions(["--cwd", cwd])
                    launch.runtimeID = id; launch.socketPath = socket
                    createWindow(launch, state: entry["windowState"] as? JSON ?? [:])
                }
                if !headless { for entry in windows.reversed() { entry.window.makeKeyAndOrderFront(nil) } }
                Task {
                    for _ in 0..<100 {
                        if let lock = try? RuntimeUpdate.lockFrontend() { frontendLock = lock; break }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard frontendLock != nil else { exit(1) }
                    drainOpenRequests()
                }
            } catch { NSLog("VCX frontend restore: %@", error.localizedDescription); NSApp.terminate(nil) }
        } else {
            do {
                for entry in try RuntimeRecovery.pending() {
                    guard var launch = try? LaunchOptions(["--cwd", entry.cwd]) else { continue }
                    launch.runtimeID = entry.sessionID; launch.socketPath = entry.socketPath; launch.recoveryEntry = entry
                    createWindow(launch, state: entry.windowState)
                }
            } catch { NSLog("VCX recovery registry: %@", error.localizedDescription) }
            if let options { createWindow(options) }
        }
    }

    func createWindow(_ options: LaunchOptions, state: JSON = [:]) {
        let session = Session(cwd: options.cwd, stateDirectory: headless ? RuntimeIdentity.directory.appendingPathComponent("frontend-state") : nil)
        let restoring = restoreFile
        session.frontendReplacing = restoring != nil
        RuntimeUpdate.adopt(state, session: session)
        let client = RuntimeClient(session: session, cwd: options.cwd, resumeRuntimeID: options.runtimeID, socketPath: options.socketPath, recovery: options.recoveryEntry)
        session.runtimeClient = client
        let window = ComposerWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.focusComposer = { [weak session] in session?.focusComposer() }
        window.chooseOption = { [weak session] in session?.chooseOption($0) ?? false }
        window.title = "\(session.folder) · Vibe Code X"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 780, height: 560)
        window.contentView = CXView.host(session)
        window.backgroundColor = NSColor.white
        window.delegate = self; window.isReleasedWhenClosed = false
        if let frame = state["frame"] as? String { window.setFrame(NSRectFromString(frame), display: false) }
        else if !headless, let screen = NSScreen.main?.visibleFrame {
            // New windows always open at 4/5 of the screen's width, centered, whatever size the last one was left at.
            window.setFrame(screen.insetBy(dx: screen.width / 10, dy: screen.height / 20).integral, display: false)
        }
        windows.append(FrontendWindow(window: window, session: session, fleet: FleetPresence(session: session)))
        startRefresh()
        client.onLeaseLost = { [weak self, weak window] in
            guard let self, let window else { return }
            guard !self.updating else { return }
            self.closing.insert(ObjectIdentifier(window)); window.close()
        }
        if !headless {
            // Only a window he asked for takes focus; one opened from outside (spawn, Watcher, an update) lands behind his current window.
            if !options.focus, let key = NSApp.keyWindow { window.order(.below, relativeTo: key.windowNumber) }
            else { window.makeKeyAndOrderFront(nil) }
            if options.focus { NSApp.activate(ignoringOtherApps: true) }
        }
        Task {
            do { try await client.connect(resume: options.resume, prompt: options.prompt) }
            catch {
                if restoring != nil { fputs("Frontend replacement could not attach.\n", stderr); exit(1) }
                session.notice(error.localizedDescription); session.status = error.localizedDescription
            }
            window.title = "\(session.folder) · Vibe Code X"
            RuntimeUpdate.restore(state, window: window, session: session)
            if let restoreFile = restoring {
                if verificationMode == "partial" { exit(1) }
                restorePending -= 1
                if restorePending == 0 {
                    self.restoreFile = nil
                    if headless {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        let report: JSON = ["restoreFinished": self.restoreFile == nil, "windows": windows.map { ["sessionId": $0.session.runtimeClient?.sessionID ?? "", "threadId": $0.session.threadID ?? "", "draft": draftContent($0.session.draft), "permissions": $0.session.permissions.map { $0.id.uuidString }, "busy": $0.session.busy, "state": RuntimeUpdate.state(window: $0.window, session: $0.session), "visible": $0.window.isVisible] }]
                        try? JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: restoreFile + ".verification.json"), options: .atomic)
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: restoreFile + ".verification.json")
                    }
                    do { try RuntimeUpdate.acknowledge(restoreFile) }
                    catch { exit(1) }
                    for entry in windows { entry.session.frontendReplacing = false }
                }
            }
        }
    }

    private func startRefresh() {
        guard !headless, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self else { return }
                await refreshVisibleSessions()
            }
        }
    }

    @discardableResult
    func refreshVisibleSessions() async -> Int {
        var refreshed = 0
        for entry in windows where entry.window.isVisible && entry.window.occlusionState.contains(.visible) {
            await entry.session.refreshUsage(force: false)
            await entry.session.refreshRepository()
            refreshed += 1
        }
        return refreshed
    }

    func drainOpenRequests() {
        guard frontendLock != nil, !updating else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: RuntimeIdentity.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix(".open.json") {
            do {
                let value = try RuntimeUpdate.readTicket(file.path, suffix: ".open.json")
                guard let cwd = value["cwd"] as? String else { continue }
                var options = try LaunchOptions(["--cwd", cwd])
                options.resume = value["resume"] as? String; options.prompt = value["prompt"] as? String ?? ""; options.focus = value["focus"] as? Bool ?? false
                try FileManager.default.removeItem(at: file)
                createWindow(options)
            } catch { NSLog("VCX open request: %@", error.localizedDescription) }
        }
        AgentMessages.drain(windows)
    }

    func replaceFrontend() {
        guard !updating, !windows.isEmpty, RuntimeUpdate.pendingBuild() != nil else { return }
        updating = true; replacementAcknowledged = false
        replacementTask = Task {
            do {
                guard windows.first?.session.runtimeClient != nil else { throw CXError(message: "No attached frontend session.") }
                try await RuntimeClient.preflight(executable: replacementBinary)
                var entries: [JSON] = []
                // Front to back, so the replacement can put the window he was on back in front.
                let order = NSApp.orderedWindows
                for entry in windows.sorted(by: { (order.firstIndex(of: $0.window) ?? .max) < (order.firstIndex(of: $1.window) ?? .max) }) {
                    entry.session.frontendReplacing = true
                    guard let runtime = entry.session.runtimeClient else { continue }
                    let state = RuntimeUpdate.state(window: entry.window, session: entry.session)
                    try await runtime.checkpointWindow(state)
                    entries.append(["cwd": entry.session.cwd, "sessionId": runtime.sessionID, "socket": runtime.socketPath, "windowState": state])
                }
                let file = try RuntimeUpdate.writeTicket(["windows": entries], suffix: ".restore.json")
                handoffFile = file
                if let replacementLaunch { replacement = try await replacementLaunch(file) }
                else {
                    let config = NSWorkspace.OpenConfiguration()
                    config.createsNewApplicationInstance = true
                    config.activates = NSApp.isActive
                    config.arguments = ["--restore-windows", file.path]
                    replacement = FrontendReplacementProcess(try await NSWorkspace.shared.openApplication(at: RuntimeUpdate.installed, configuration: config))
                }
                try await waitForReplacement()
            } catch {
                if let replacement, !replacement.isTerminated() {
                    replacement.terminate()
                    for _ in 0..<30 where !replacement.isTerminated() { try? await Task.sleep(nanoseconds: 100_000_000) }
                    if !replacement.isTerminated() { kill(replacement.pid, SIGKILL) }
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

    private func waitForReplacement() async throws {
        if replacementAcknowledged { return }
        try await withCheckedThrowingContinuation { continuation in
            replacementWaiter = continuation
            let timeout = DispatchWorkItem { [weak self] in
                self?.replacementWaiter?.resume(throwing: CXError(message: "The replacement frontend did not finish attaching."))
                self?.replacementWaiter = nil
            }
            replacementDeadline = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + replacementTimeout, execute: timeout)
            completeReplacement()
        }
    }

    func completeReplacement() {
        guard updating, !replacementAcknowledged, let handoffFile, let replacement, !replacement.isTerminated(),
              let ready = try? RuntimeUpdate.readTicket(handoffFile.path + ".ready.json", suffix: ".ready.json"),
              ready["pid"] as? Int == Int(replacement.pid) else { return }
        replacementAcknowledged = true
        replacementDeadline?.cancel(); replacementDeadline = nil
        replacementWaiter?.resume(); replacementWaiter = nil
        try? FileManager.default.removeItem(at: handoffFile)
        try? FileManager.default.removeItem(atPath: handoffFile.path + ".ready.json")
        // Still active here: hand focus to the replacement before closing, or macOS gives it to whatever app is next.
        if NSApp.isActive { NSRunningApplication(processIdentifier: replacement.pid)?.activate(options: []) }
        for entry in Array(windows) { closing.insert(ObjectIdentifier(entry.window)); entry.window.close() }
    }

    @objc func openProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.begin { result in if result == .OK, let url = panel.url { self.openWindow(cwd: url.path) } }
    }
    @objc func newWindow() { openWindow(cwd: session?.cwd ?? NSHomeDirectory()) }
    func openWindow(cwd: String) {
        guard let options = try? LaunchOptions(["--cwd", cwd, "--focus"]) else { return }
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
        guard !entry.session.frontendReplacing, sender.attachedSheet == nil else { return false }
        let close = { [self] in
            entry.session.frontendReplacing = true
            Task {
                do {
                    try await entry.session.runtimeClient?.checkpointWindow(RuntimeUpdate.state(window: sender, session: entry.session))
                    _ = try await entry.session.runtimeClient?.perform("close")
                    closing.insert(ObjectIdentifier(sender)); sender.close()
                } catch { entry.session.frontendReplacing = false; entry.session.notice("Cannot close before saving the draft: " + error.localizedDescription) }
            }
        }
        if !headless, let work = runningWork(entry.session) {
            closeAlert("Close \(entry.session.folder)?", work).beginSheetModal(for: sender) { if $0 == .alertFirstButtonReturn { close() } }
        } else { close() }
        return false
    }
    func runningWork(_ session: Session) -> String? {
        if session.backgroundTasks > 0 { return session.backgroundTasks == 1 ? "A background task is still running." : "\(session.backgroundTasks) background tasks are still running." }
        return session.busy ? "The agent is still working." : nil
    }
    private func closeAlert(_ title: String, _ detail: String, button: String = "Close") -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        return alert
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let index = windows.firstIndex(where: { $0.window === window }) else { return }
        let entry = windows.remove(at: index)
        entry.session.close(); entry.fleet.close(); closing.remove(ObjectIdentifier(window))
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !headless }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating || windows.isEmpty { return .terminateNow }
        let busy = windows.compactMap { entry in runningWork(entry.session).map { "\(entry.session.folder): \($0)" } }
        if !headless, !busy.isEmpty, closeAlert("Quit Vibe Code X?", busy.joined(separator: "\n"), button: "Quit").runModal() != .alertFirstButtonReturn { return .terminateCancel }
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
        refreshTask?.cancel()
        for entry in windows { entry.session.close(); entry.fleet.close() }
        if let frontendLock { flock(frontendLock, LOCK_UN); Darwin.close(frontendLock) }
        stopObservingFrontendEvents()
    }
}

MainActor.assumeIsolated {
signal(SIGPIPE, SIG_IGN)
let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--runtime-protocol") { print("1"); exit(0) }
if let index = args.firstIndex(of: "--adopt-check"), index + 1 < args.count {
    do { _ = try RuntimeSwap.manifest(args[index + 1]); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if args.contains("--publish-update") {
    do { try RuntimeUpdate.publish(manual: args.contains("--manual")); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if args.contains("--update-now") {
    do { try RuntimeUpdate.requestUpdate(); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if args.contains(where: { ["-p", "--print", "--headless", "--ensure-qwen"].contains($0) }) {
    let arguments = (["/usr/bin/python3", Bundle.main.resourceURL!.appendingPathComponent("background.py").path] + args).map { strdup($0) } + [nil]
    defer { arguments.forEach { free($0) } }
    arguments.withUnsafeBufferPointer { _ = execv("/usr/bin/python3", $0.baseAddress!) }
    perror("vcx"); exit(1)
}
if args.first == "--sessions" { exit(AgentMessages.list()) }
if args.first == "--send" { exit(AgentMessages.send(Array(args.dropFirst()))) }
if args.contains("--version") { print("vcx 0.2.0 (Vibe Code X)"); exit(0) }
if args.first == "--route-project" {
    let prompt = args.dropFirst().joined(separator: " ")
    Task { print(await routeProject(prompt, account: Settings.shared.value.accounts.first { $0.provider == "claude" && $0.enabled }) ?? "none"); exit(0) }
    dispatchMain()
}
if args.contains("--help") { print("vcx [--cwd FOLDER] [--resume [ID]] [PROMPT]\nvcx -p [--provider auto|claude|codex|qwen] [--output-format text|json|stream-json] [PROMPT]\nUse -p for background jobs with automatic fallback. Use cx --terminal for the previous terminal interface.\nvcx --update-now moves every running session and window to the installed build once its sessions are idle, a build installed with --manual included."); exit(0) }
if args.contains(where: { ["--check", "--bug-check", "--runtime-check", "--frontend-check", "--runtime-bounds-check", "--runtime-recovery-check", "--runtime-load-check", "--runtime-swap-check", "--verify-runtime", "--render", "--render-demo", "--icon"].contains($0) }) {
    let isolated = NSTemporaryDirectory() + "vcx-preview-" + UUID().uuidString
    setenv("VCX_CONFIG_HOME", isolated + "/config", 1)
    setenv("VCX_RUNTIME_HOME", isolated + "/runtime", 1)
}
let app = NSApplication.shared
if let index = args.firstIndex(of: "--recovery-frontend"), index + 3 < args.count {
    app.setActivationPolicy(.prohibited)
    Task {
        do { try await RecoveryCheck.frontend(directory: URL(fileURLWithPath: args[index + 1]), socketPath: args[index + 2], stage: args[index + 3]); exit(0) }
        catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
    RunLoop.main.run(); exit(0)
}
if let index = args.firstIndex(of: "--frontend-handoff-fixture"), index + 2 < args.count {
    app.setActivationPolicy(.prohibited)
    let delegate = AppDelegate()
    delegate.headless = true; delegate.verificationMode = args[index + 2]; delegate.restoreFile = args[index + 1]
    app.delegate = delegate
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    withExtendedLifetime(delegate) { RunLoop.main.run() }
    exit(0)
}
if let index = args.firstIndex(of: "--runtime-load-worker"), index + 2 < args.count {
    app.setActivationPolicy(.prohibited)
    do {
        let server = try RuntimeLoadCheck.worker(socketPath: args[index + 1], directory: URL(fileURLWithPath: args[index + 2]))
        try server.start()
        withExtendedLifetime(server) { RunLoop.main.run() }
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    exit(0)
}
if let index = args.firstIndex(of: "--runtime-worker") {
    app.setActivationPolicy(.prohibited)
    _ = setsid()
    guard index + 1 < args.count else { fputs("Missing runtime socket.\n", stderr); exit(2) }
    DispatchQueue.global().async { _ = loginEnvironment }
    var command: [String]?
    if let fixture = args.firstIndex(of: "--runtime-fixture-command") {
        guard args.contains("--runtime-test"), fixture + 1 < args.count,
              let data = try? Data(contentsOf: URL(fileURLWithPath: args[fixture + 1])),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String], !value.isEmpty else {
            fputs("Invalid runtime test command.\n", stderr); exit(2)
        }
        command = value
    }
    // A session adopted by a live update has no factory of its own: one that restarts a crashed agent starts the fake again.
    if args.contains("--runtime-swap-test"), let command {
        Session.testConnectionFactory = { account, cwd in RuntimeSwapCheck.connection(command: command, account: account, cwd: cwd) }
        Connectivity.online = { true }
    }
    var manifest: JSON?
    if let adopt = args.firstIndex(of: "--adopt"), adopt + 1 < args.count {
        do { manifest = try RuntimeSwap.manifest(args[adopt + 1]) }
        catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        try? FileManager.default.removeItem(atPath: args[adopt + 1])
    }
    let server = RuntimeServer(socketPath: args[index + 1], build: RuntimeIdentity.build, instanceID: manifest?["instanceID"] as? String ?? UUID().uuidString) { params in
        let state = args.contains("--runtime-test") ? RuntimeIdentity.directory.appendingPathComponent("test-state") : nil
        let recovery = params["recovery"] as? JSON
        let backend = SessionBackend(cwd: recovery?["conversationDirectory"] as? String ?? params["cwd"] as? String ?? FileManager.default.currentDirectoryPath, stateDirectory: state)
        if args.contains("--runtime-recovery-test"), let command {
            backend.session.connectionFactory = { account, cwd in RecoveryCheck.connection(command: command, account: account, cwd: cwd) }
        }
        if args.contains("--runtime-swap-test"), let command { RuntimeSwapCheck.start(backend, params: params, command: command); return backend }
        backend.startInBackground(params: params, command: args.contains("--runtime-recovery-test") ? nil : command)
        return backend
    }
    // Each session has its own socket, so its lock files would otherwise pile up.
    server.onEmpty = { server.stop(); for suffix in [".lock", ".launch.lock"] { unlink(args[index + 1] + suffix) }; exit(0) }
    do { if let manifest { try RuntimeSwap.adopt(manifest, into: server) } else { try server.start() } }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    let swap = RuntimeSwap(server: server, testing: args.contains("--runtime-test"))
    swap?.start()
    let signals = [SIGTERM, SIGINT].map { value -> DispatchSourceSignal in
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
        source.setEventHandler { server.stop(); exit(0) }
        source.resume(); return source
    }
    withExtendedLifetime((server, signals, swap)) { RunLoop.main.run() }
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
if let index = args.firstIndex(of: "--render-demo"), index + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    Demo.run(directory: args[index + 1]); exit(0)
}
if let index = args.firstIndex(of: "--verify-runtime"), index + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    Task {
        var report: JSON = ["status": "running", "limits": ["No desktop windows were displayed; Space switching and visible compositor performance were not measured.", "Synthetic model connections isolate VCX overhead; real provider CLI and model inference costs are excluded.", "Transcript paging and a global provider-tool concurrency budget remain separate implementation work."]]
        func saveReport() throws {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
        }
        do {
            try saveReport()
            guard await Check.run() else { exit(1) }
            report["nativeAndContinuity"] = "passed"; try saveReport()
            let bounds = try await RuntimeBoundsCheck.run()
            report["boundsChecks"] = bounds; try saveReport()
            let frontend = try await FrontendCheck.run()
            report["frontendChecks"] = frontend; try saveReport()
            let recovery = try await RecoveryCheck.run()
            report["recoveryChecks"] = recovery; try saveReport()
            let loadPath = args[index + 1] + ".load.json"
            let load = try await RuntimeLoadCheck.run(reportPath: loadPath)
            report["loadChecks"] = load
            report["load"] = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: loadPath)))
            report["status"] = "checks_passed_with_limits"; try saveReport()
            print("Runtime verification checks passed; report and limits: " + args[index + 1]); exit(0)
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription; try? saveReport()
            fputs(error.localizedDescription + "\n", stderr); exit(1)
        }
    }
    RunLoop.main.run()
} else if args.contains("--frontend-check") || args.contains("--runtime-bounds-check") || args.contains("--runtime-recovery-check") || args.contains("--runtime-load-check") || args.contains("--runtime-swap-check") {
    app.setActivationPolicy(.prohibited)
    Task {
        do {
            if args.contains("--frontend-check") { _ = try await FrontendCheck.run() }
            else if args.contains("--runtime-bounds-check") { _ = try await RuntimeBoundsCheck.run() }
            else if args.contains("--runtime-recovery-check") { _ = try await RecoveryCheck.run() }
            else if args.contains("--runtime-swap-check") { print(try await RuntimeSwapCheck.run()) }
            else if let index = args.firstIndex(of: "--runtime-load-check"), index + 1 < args.count { _ = try await RuntimeLoadCheck.run(reportPath: args[index + 1]) }
            else { throw CXError(message: "A load report path is required.") }
            exit(0)
        } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else if args.contains("--runtime-check") {
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
} else if args.contains("--bug-check") {
    app.setActivationPolicy(.prohibited)
    Task {
        do { try await BugCheck.run(); exit(0) }
        catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
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
