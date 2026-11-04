import AppKit
import Darwin

@MainActor
enum FrontendCheck {
    static func run() async throws -> Int {
        let directory = URL(fileURLWithPath: "/tmp/vcx-front-check-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let previousHome = ProcessInfo.processInfo.environment["VCX_RUNTIME_HOME"]
        setenv("VCX_RUNTIME_HOME", directory.path, 1)
        defer {
            if let previousHome { setenv("VCX_RUNTIME_HOME", previousHome, 1) } else { unsetenv("VCX_RUNTIME_HOME") }
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/runtime_peer.py")
        let peer = Bundle.main.url(forResource: "runtime_peer", withExtension: "py") ?? source
        let image = directory.appendingPathComponent("attachment.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        var workers: [Process] = [], candidates: [Process] = [], sockets: [String] = [], ids: [String] = [], frontends: [AppDelegate] = []
        var count = 0
        let previousDelegate = NSApp.delegate
        defer {
            NSApp.delegate = previousDelegate
            for frontend in frontends {
                frontend.stopObservingFrontendEvents()
                for entry in frontend.windows {
                    entry.window.delegate = nil; entry.window.close(); entry.session.close(); entry.fleet.close()
                }
            }
            for process in candidates + workers where process.isRunning { process.terminate() }
        }
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CXError(message: "Frontend handoff failed: " + message) }
            count += 1
        }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<500 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CXError(message: "Frontend handoff fixture timed out.")
        }
        for index in 0..<2 {
            let folder = directory.appendingPathComponent("session-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard mkfifo(folder.appendingPathComponent("release-tool").path, 0o600) == 0 else { throw CXError(message: "Cannot create handoff fixture gate.") }
            let command = folder.appendingPathComponent("command.json")
            try JSONSerialization.data(withJSONObject: ["/usr/bin/python3", peer.path, folder.path]).write(to: command)
            let socket = folder.appendingPathComponent("worker.sock").path
            let worker = Process()
            worker.executableURL = RuntimeIdentity.executable
            worker.arguments = ["--runtime-worker", socket, "--runtime-test", "--runtime-fixture-command", command.path]
            worker.environment = ProcessInfo.processInfo.environment.merging(["VCX_RUNTIME_HOME": folder.path, "VCX_CONFIG_HOME": folder.appendingPathComponent("config").path]) { _, new in new }
            worker.standardInput = FileHandle.nullDevice; worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
            try worker.run(); workers.append(worker); sockets.append(socket)
            try await wait { FileManager.default.fileExists(atPath: socket) }
            let session = Session(cwd: folder.path, stateDirectory: folder.appendingPathComponent("frontend-state"))
            let seed = RuntimeClient(session: session, cwd: folder.path, socketPath: socket)
            session.runtimeClient = seed
            try await seed.connect(resume: nil)
            try await wait { session.ready }
            ids.append(seed.sessionID)
            seed.close(); session.close()
        }
        try Data("fixture-new-build".utf8).write(to: directory.appendingPathComponent("installed-build"))

        for mode in ["launch-failure", "preflight-failure", "partial", "stubborn", "success", "close"] {
            let frontend = AppDelegate()
            frontends.append(frontend)
            frontend.headless = true
            frontend.replacementBinary = mode == "preflight-failure" ? URL(fileURLWithPath: "/usr/bin/false") : RuntimeIdentity.executable
            frontend.replacementTimeout = ["partial", "stubborn"].contains(mode) ? 1.5 : 8
            NSApp.delegate = frontend
            frontend.observeFrontendEvents()
            for index in 0..<2 {
                var options = try LaunchOptions(["--cwd", directory.appendingPathComponent("session-\(index)").path])
                options.runtimeID = ids[index]; options.socketPath = sockets[index]
                frontend.createWindow(options)
            }
            try await wait { frontend.windows.count == 2 && frontend.windows.allSatisfy { $0.session.ready } }
            let old = frontend.windows
            try check(await frontend.refreshVisibleSessions() == 0, "hidden windows polled their runtimes")
            if mode == "launch-failure" {
                for entry in old { await entry.session.send(text: "handoff fixture work", images: []) }
                try await wait { FileManager.default.fileExists(atPath: directory.appendingPathComponent("session-0/tool-started.json").path) && FileManager.default.fileExists(atPath: directory.appendingPathComponent("session-1/tool-started.json").path) }
                let gate = Darwin.open(directory.appendingPathComponent("session-1/release-tool").path, O_WRONLY | O_NONBLOCK)
                guard gate >= 0 else { throw CXError(message: "Cannot release handoff fixture tool.") }
                var byte: UInt8 = 1
                _ = Darwin.write(gate, &byte, 1); Darwin.close(gate)
                try await wait { !old[1].session.permissions.isEmpty }
            }
            for (index, entry) in old.enumerated() {
                entry.window.setFrame(NSRect(x: 100 + index * 30, y: 100, width: 1000, height: 700), display: false)
                entry.session.editDraft(runtimeDraft([["text": "handoff draft \(index)"], ["path": image.path]]))
                entry.session.follow.attached = false; entry.session.details = true
                try await entry.session.runtimeClient?.checkpointWindow(RuntimeUpdate.state(window: entry.window, session: entry.session))
                try check(!entry.window.isVisible, "verification displayed a window")
            }
            if mode == "close" {
                let menu = NSMenu(), appMenu = NSMenu()
                frontend.configureMenu(menu, appMenu: appMenu, fileMenu: NSMenu(), editMenu: NSMenu())
                guard let quit = appMenu.items.first(where: { $0.keyEquivalent == "q" }) else {
                    throw CXError(message: "Cmd+Q menu item is missing.")
                }
                try check(quit.action == #selector(NSWindow.performClose(_:)), "Cmd+Q terminates every session instead of closing the focused window")
                try check(quit.target == nil && quit.keyEquivalentModifierMask == .command, "Cmd+Q bypasses the focused responder")
                try check(NSApp.sendAction(quit.action!, to: old[1].window, from: quit), "Cmd+Q action was not handled by the second window")
                try await wait { frontend.windows.count == 1 }
                try check(frontend.windows[0].window === old[0].window, "Cmd+Q closed the unfocused window")
                try check(old[0].session.runtimeClient?.isAttached == true && old[0].session.busy, "Cmd+Q stopped the unfocused session")
                _ = try await old[0].session.runtimeClient?.perform("refreshRepository")
                try check(draftContent(old[0].session.draft).first?["text"] as? String == "handoff draft 0", "Cmd+Q changed the other session's draft")
                try check(old.allSatisfy { !$0.window.isVisible }, "quit verification displayed a window")
                try check(NSApp.sendAction(quit.action!, to: old[0].window, from: quit), "last session did not handle Cmd+Q")
                try await wait { frontend.windows.isEmpty }
                frontend.headless = false
                try check(frontend.applicationShouldTerminateAfterLastWindowClosed(NSApp), "closing the last session did not quit the app")
                try check(frontend.applicationShouldTerminate(NSApp) == .terminateNow, "empty app did not allow termination")
                frontend.headless = true
                frontend.stopObservingFrontendEvents()
                continue
            }
            if mode == "launch-failure" {
                frontend.replacementLaunch = { _ in throw CXError(message: "Expected fixture launch failure.") }
            } else {
                frontend.replacementLaunch = { ticket in
                    let candidate = Process()
                    candidate.executableURL = RuntimeIdentity.executable
                    candidate.arguments = ["--frontend-handoff-fixture", ticket.path, mode]
                    if mode == "stubborn" {
                        candidate.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                        candidate.arguments = ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"]
                    }
                    candidate.environment = ProcessInfo.processInfo.environment
                    candidate.standardInput = FileHandle.nullDevice; candidate.standardOutput = FileHandle.nullDevice; candidate.standardError = FileHandle.nullDevice
                    try candidate.run(); candidates.append(candidate)
                    return FrontendReplacementProcess(candidate)
                }
            }
            frontend.replaceFrontend()
            guard let task = frontend.replacementTask else { throw CXError(message: "Frontend replacement did not start.") }
            await task.value
            if mode == "success" {
                try check(frontend.windows.isEmpty, "acknowledged old windows were not retired")
                try check(candidates.last?.isRunning == true, "replacement exited after attachment")
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                guard let file = files.first(where: { $0.lastPathComponent.hasSuffix(".verification.json") }),
                      let report = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? JSON,
                      let restored = report["windows"] as? [JSON] else { throw CXError(message: "Replacement state report is missing.") }
                try check(report["restoreFinished"] as? Bool == true, "completed restoration still freezes new windows")
                try check(restored.count == 2, "replacement lost a window")
                for index in 0..<2 {
                    guard let record = restored.first(where: { $0["sessionId"] as? String == ids[index] }) else { throw CXError(message: "Replacement session identity changed.") }
                    let state = record["state"] as? JSON ?? [:]
                    let draft = record["draft"] as? [JSON] ?? []
                    try check(draft.first?["text"] as? String == "handoff draft \(index)", "replacement lost draft text")
                    try check(draft.last?["path"] as? String == image.path, "replacement lost draft attachment")
                    try check(record["threadId"] as? String == "runtime-fixture-thread", "replacement lost conversation identity")
                    try check(state["frame"] as? String == NSStringFromRect(old[index].window.frame), "replacement changed frame")
                    try check(state["follow"] as? Bool == false && state["details"] as? Bool == true, "replacement changed viewport preferences")
                    try check(record["visible"] as? Bool == false, "replacement displayed a verification window")
                    try check(record["permissions"] as? [String] == old[index].session.permissions.map { $0.id.uuidString }, "replacement changed approval identity")
                    try check(record["busy"] as? Bool == true, "replacement stopped running work")
                }
            } else {
                try check(frontend.windows.count == 2, "failed replacement retired an old window")
                for (index, entry) in frontend.windows.enumerated() {
                    try check(entry.session.runtimeClient?.isAttached == true, "rollback did not reclaim writer lease")
                    try check(!entry.session.frontendReplacing, "rollback left input frozen")
                    try check(draftContent(entry.session.draft).first?["text"] as? String == "handoff draft \(index)", "rollback lost draft")
                }
                for entry in Array(frontend.windows) {
                    entry.window.delegate = nil; entry.window.close(); entry.session.close(); entry.fleet.close()
                }
                frontend.windows.removeAll()
            }
            frontend.stopObservingFrontendEvents()
            if let candidate = candidates.last, candidate.isRunning {
                candidate.terminate()
                await Task.detached { candidate.waitUntilExit() }.value
            }
        }
        for worker in workers where worker.isRunning {
            worker.terminate(); await Task.detached { worker.waitUntilExit() }.value
        }
        print("\(count) frontend handoff checks passed (AppKit windows never displayed)")
        return count
    }
}
