import AppKit
import SwiftUI

@MainActor
enum Check {
    static func live(settings: String) async -> Bool {
        var okay = true
        let claude = ClaudeConnection(account: Account(name: "Default Claude", provider: "claude"), cwd: NSTemporaryDirectory())
        do { try await claude.start(); print("Claude subscription: ready") }
        catch { print("Claude subscription: " + error.localizedDescription); okay = false }
        claude.close()
        let codex = RPC()
        do {
            try await codex.start()
            let models = try await codex.request("model/list", ["limit": 100])
            print("Codex subscription and model catalog: \((models["data"] as? [JSON] ?? []).isEmpty ? "empty" : "ready")")
        } catch { print("Codex subscription: " + error.localizedDescription); okay = false }
        codex.close()
        do {
            let preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: URL(fileURLWithPath: settings)))
            let network = qwenNetwork(preferences)
            defer { network.invalidateAndCancel() }
            guard var parts = URLComponents(string: preferences.qwenURL) else { throw CXError(message: "Invalid Qwen URL.") }
            parts.path = "/api/tags"
            var request = URLRequest(url: parts.url!); request.timeoutInterval = 10
            let (data, response) = try await network.data(for: request)
            let result = try JSONSerialization.jsonObject(with: data) as? JSON ?? [:]
            let names = (result["models"] as? [JSON] ?? []).compactMap { $0["name"] as? String }
            let ready = (response as? HTTPURLResponse)?.statusCode == 200 && names.contains { $0 == preferences.qwenModel || $0 == preferences.qwenModel + ":latest" }
            print("Jarvis Qwen route and text model: \(ready ? "ready" : "unavailable")")
            okay = okay && ready
        } catch { print("Qwen metadata check: " + error.localizedDescription); okay = false }
        return okay
    }

    static func run() async -> Bool {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { count += 1; if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) } }
        var follow = FollowState()
        check(follow.attached, "starts attached")
        follow.userScroll(distance: 120); check(!follow.attached, "scroll up detaches")
        follow.userScroll(distance: 0); check(follow.attached, "return to bottom attaches")
        check(usageLimit(["error": ["codexErrorInfo": "usageLimitExceeded"]]), "Codex usage limit")
        check(usageLimit(["error": "rate_limit"]), "Claude usage limit")
        check(!usageLimit(["error": "Network unavailable"]), "network failure is not a usage limit")
        check(Item(["id": "tool", "exitCode": 2]).failed, "failed tool counted")
        check(!Item(["id": "tool", "exitCode": 0, "error": NSNull()]).failed, "successful tool")
        let child = Process(), childOutput = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh"); child.arguments = ["-c", "sleep 10 & wait"]
        child.standardOutput = childOutput; child.standardError = FileHandle.nullDevice
        try! child.run()
        check(getpgid(child.processIdentifier) == child.processIdentifier, "tool process has an isolated process group")
        endProcess(child, signal: SIGKILL)
        let killed = await Task.detached { childOutput.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit(); return child.terminationStatus != 0 }.value
        check(killed, "stop terminates the command and its children")
        let blocks = markdownBlocks("Text\n```swift\nlet x = 1\n```\nDone")
        check(blocks.count == 3 && blocks[1].code && blocks[1].language == "swift", "code fences")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vcx-check-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/native_peer.py").path
        let imagePath = directory.appendingPathComponent("screen shot.png").path
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: imagePath))
        let escaped = imagePath.replacingOccurrences(of: " ", with: "\\ ")
        let pieces = pastedPieces("📷 Check this " + escaped)
        check(pieces.contains { if case .image(let path) = $0 { return path == imagePath }; return false }, "escaped paths after emoji become images")
        let draft = NSMutableAttributedString(string: "Look at ")
        draft.append(NSAttributedString(attachment: ImageChip(path: imagePath, number: 1)))
        check(draftContent(draft).count == 2 && draftContent(draft).last?["path"] as? String == imagePath, "draft attachments retain their place")
        draft.deleteCharacters(in: NSRange(location: draft.length - 1, length: 1))
        check(draftContent(draft).count == 1, "deleting a chip removes its attachment")
        check((try! agentImage(imagePath)).1 == "image/png", "image type is determined from its contents")
        check(tableCells("| Provider | Status |") == ["Provider", "Status"], "native table cells")
        let fixture = Bundle.main.url(forResource: "native_peer", withExtension: "py")?.path ?? sourceFixture
        let rpc = RPC()
        var notified = false
        rpc.event = { if $0["method"] as? String == "test/event" { notified = true } }
        do {
            try await rpc.start(command: ["python3", fixture, "codex"])
            let result = try await rpc.request("echo", ["hello": "world"])
            check(result["hello"] as? String == "world" && notified, "RPC replies and notifications")
            do { _ = try await rpc.request("fail"); check(false, "RPC error must throw") } catch { check(true, "RPC error") }
            do { _ = try await rpc.request("timeout", [:], timeout: 0.03); check(false, "timeout must throw") } catch { check(true, "RPC timeout") }
        } catch { check(false, "RPC integration: " + error.localizedDescription) }
        rpc.close()
        let account = Account(id: "test", name: "Test", provider: "claude")
        let claude = ClaudeConnection(account: account, cwd: directory.path)
        var claudeText = "", claudeDone = false, claudeCompletions = 0, claudeStarts = 0
        claude.event = { message in
            let p = message["params"] as? JSON ?? [:]
            if message["method"] as? String == "item/agentMessage/delta" { claudeText += p["delta"] as? String ?? "" }
            if message["method"] as? String == "turn/completed" { claudeDone = true; claudeCompletions += 1 }
            if message["method"] as? String == "turn/started" { claudeStarts += 1 }
        }
        do {
            try await claude.start(command: ["python3", fixture, "claude"])
            let started = try await claude.request("turn/start", ["input": [["type": "text", "text": "Hello"]]])
            let turn = (started["turn"] as? JSON)?["id"] as? String ?? ""
            let steered = try await claude.request("turn/steer", ["expectedTurnId": turn, "input": [["type": "text", "text": "Guidance"]]])
            check((steered["turn"] as? JSON)?["id"] as? String == turn, "Claude steering preserves turn ownership")
            for _ in 0..<100 where !claudeDone { try await Task.sleep(nanoseconds: 10_000_000) }
            check(claudeDone && claudeText == "Hello from ClaudeHello from Claude", "Claude streaming protocol")
            check(claudeStarts == 1 && claudeCompletions == 1, "Claude stays busy until queued guidance is answered")
        } catch { check(false, "Claude integration: " + error.localizedDescription) }
        claude.close()
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env"); server.arguments = ["python3", fixture, "http"]; server.standardOutput = output; server.standardError = FileHandle.nullDevice
        do {
            try server.run()
            let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            var preferences = Preferences(); preferences.qwenURL = "http://127.0.0.1:" + port + "/api/chat"
            let qwen = QwenConnection(preferences: preferences)
            var qwenText = "", qwenDone = false
            qwen.event = { message in
                let p = message["params"] as? JSON ?? [:]
                if message["method"] as? String == "item/agentMessage/delta" { qwenText += p["delta"] as? String ?? "" }
                if message["method"] as? String == "turn/completed" { qwenDone = true }
            }
            _ = try await qwen.request("turn/start", ["input": [["type": "text", "text": "Hello"]]])
            for _ in 0..<100 where !qwenDone { try await Task.sleep(nanoseconds: 10_000_000) }
            check(qwenDone && qwenText == "Hello from Qwen", "Qwen HTTP streaming")
            qwen.close()
            let tools = QwenConnection(preferences: preferences, cwd: directory.path)
            var approved = false, toolDone = false, toolOutput = ""
            tools.event = { message in
                let p = message["params"] as? JSON ?? [:]
                if let id = message["id"] { approved = true; try? tools.respond(id, ["decision": "accept"]) }
                if let item = p["item"] as? JSON, item["type"] as? String == "commandExecution" { toolOutput = item["aggregatedOutput"] as? String ?? "" }
                if message["method"] as? String == "turn/completed" { toolDone = true }
            }
            _ = try await tools.request("turn/start", ["input": [["type": "text", "text": "TOOLS"]]])
            for _ in 0..<200 where !toolDone { try await Task.sleep(nanoseconds: 10_000_000) }
            check(approved && toolDone && toolOutput == "native-tool-check", "Qwen commands require approval and return their output")
            tools.close()
        } catch { check(false, "Qwen integration: " + error.localizedDescription) }
        if server.isRunning { server.terminate() }
        Settings.shared.value = Preferences()
        var connections: [String: FixtureConnection] = [:]
        let session = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
        session.connectionFactory = { account, _ in
            let connection = FixtureConnection(account)
            connection.limit = account.provider == "claude"
            connections[account.id] = connection
            return connection
        }
        await session.connect(resume: nil)
        check(session.ready && session.account.provider == "claude", "Claude is the default")
        session.draft = NSAttributedString(string: "Build the feature")
        await session.send(text: "Build the feature", images: [])
        for _ in 0..<200 where session.busy || session.account.provider != "codex" { try? await Task.sleep(nanoseconds: 10_000_000) }
        check(session.account.provider == "codex", "explicit limit falls back to Codex")
        check(session.rows.filter { $0.kind == "user" }.count == 1, "fallback does not duplicate the user message")
        check(connections["codex-default"]?.sent.count == 1, "fallback retries once")
        check((connections["codex-default"]?.sent.first?["input"] as? [JSON])?.first?["text"] as? String != "Build the feature", "handoff includes recent context")
        check(connections["claude-default"]?.closed == true, "only one backend remains active")
        connections["codex-default"]?.failSend = true
        session.draft = NSAttributedString(string: "Keep this draft")
        await session.send(text: "Keep this draft", images: [directory.appendingPathComponent("image.png").path])
        check(session.draft.string == "Keep this draft", "failed sends restore the draft")
        check(!session.busy, "failed sends leave the session usable")
        connections["codex-default"]?.failSend = false
        connections["codex-default"]?.hold = true
        session.draft = NSAttributedString(string: "Wait")
        await session.send(text: "Wait", images: [])
        check(session.busy, "in-progress turn")
        await session.stop()
        check(!session.busy && session.status == "Stopped", "interrupt reaches the backend")
        session.draft = NSAttributedString(string: "Unsent draft")
        session.save()
        let files = try! FileManager.default.contentsOfDirectory(at: session.nativeDirectory, includingPropertiesForKeys: nil)
        check(files.count == 1, "one private conversation snapshot")
        let permissions = try! FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int
        check(permissions == 0o600, "conversation file is private")
        let record = try! JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as! JSON
        check(record["accountId"] as? String == "codex-default", "snapshot tracks the selected account")
        check((record["draft"] as? [JSON])?.first?["text"] as? String == "Unsent draft", "unsent draft is persisted")
        session.close()
        let restored = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
        restored.connectionFactory = { account, _ in FixtureConnection(account) }
        await restored.connect(resume: "last")
        check(restored.ready && restored.draft.string == "Unsent draft", "saved native conversation restores its draft")
        check(restored.rows.filter { $0.kind == "user" }.count == 2, "native history is restored without duplicates")
        let secondWindow = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
        secondWindow.connectionFactory = { account, _ in FixtureConnection(account) }
        await secondWindow.connect(resume: "last")
        check(!secondWindow.ready && secondWindow.rows.contains { $0.items.contains { $0.text.contains("already open") } }, "a second window cannot edit the same conversation snapshot")
        restored.draft = NSAttributedString(string: "Newer draft from first window"); restored.save()
        secondWindow.close()
        let latest = try! JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as! JSON
        check((latest["draft"] as? [JSON])?.first?["text"] as? String == "Newer draft from first window", "a rejected second window cannot overwrite the first window’s draft")
        restored.close()
        let reopened = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
        reopened.connectionFactory = { account, _ in FixtureConnection(account) }
        await reopened.connect(resume: "last")
        check(reopened.ready && reopened.draft.string == "Newer draft from first window", "closing a window releases conversation ownership")
        reopened.close()
        let envA = agentEnvironment(Account(name: "A", provider: "codex", home: "/tmp/account-a"))
        let envB = agentEnvironment(Account(name: "B", provider: "codex", home: "/tmp/account-b"))
        check(envA["CODEX_HOME"] == "/tmp/account-a" && envB["CODEX_HOME"] == "/tmp/account-b", "account homes stay isolated")
        check(envA["OPENAI_API_KEY"] == nil && envA["ANTHROPIC_API_KEY"] == nil, "subscription mode strips inherited API keys")
        check(Settings.shared.candidates.map(\.provider) == ["claude", "codex", "qwen"], "default provider priority")
        check(try! LaunchOptions(["--cwd", directory.path, "--resume"]).resume == "last", "CLI resume is compatible")
        let settingsA = Settings(), settingsB = Settings()
        settingsB.value.accounts.append(Account(id: "extra", name: "Another Claude", provider: "claude"))
        settingsB.value.provider = "codex"; settingsB.save()
        settingsA.updateLimit(account: "codex-default", reset: Date().timeIntervalSince1970 + 3600)
        let fresh = Settings()
        check(fresh.value.accounts.contains { $0.id == "extra" } && fresh.value.provider == "codex", "stale usage writes preserve account selection from another window")
        check(fresh.value.limits["codex-default"] != nil, "shared limit mutation is retained")
        settingsA.updateLimit(account: "claude-default", reset: 0)
        settingsB.updateLimit(account: "extra", reset: Date().timeIntervalSince1970 + 60)
        check(Settings().value.limits["codex-default"] != nil && Settings().value.limits["extra"] != nil, "independent limit mutations merge")
        Settings.shared.reload(); Settings.shared.value.provider = "auto"; Settings.shared.save()
        var failDestination = true
        let transactional = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("transaction"))
        transactional.connectionFactory = { account, _ in
            let connection = FixtureConnection(account)
            connection.failStart = account.provider == "codex" && failDestination
            return connection
        }
        await transactional.connect(resume: nil)
        let originalID = transactional.threadID
        let originalConversation = transactional.currentConversationID
        Settings.shared.value.provider = "codex"; Settings.shared.save()
        Settings.shared.updateLimit(account: "codex-default", reset: 0)
        transactional.draft = NSAttributedString(string: "Keep my work")
        await transactional.send(text: "Keep my work", images: [])
        check(!transactional.ready && transactional.account.provider == "claude" && transactional.threadID == originalID, "failed activation preserves account and thread ownership")
        transactional.save()
        let transactionFiles = try! FileManager.default.contentsOfDirectory(at: transactional.nativeDirectory, includingPropertiesForKeys: nil)
        let savedTransaction = try! JSONSerialization.jsonObject(with: Data(contentsOf: transactionFiles[0])) as! JSON
        check(savedTransaction["accountId"] as? String == "claude-default" && savedTransaction["threadId"] as? String == originalID, "failed activation cannot corrupt the saved conversation")
        failDestination = false
        await transactional.reconnect()
        check(transactional.ready && transactional.account.provider == "codex" && transactional.threadID == "codex:fixture", "reconnect retries the correct destination without reusing a foreign thread ID")
        check(transactional.currentConversationID == originalConversation && transactional.draft.string == "Keep my work", "recovery keeps the conversation and unsent draft")
        transactional.event(["id": "approval", "method": "item/commandExecution/requestApproval", "params": ["command": "echo example"]])
        transactional.event(["method": "turn/completed", "params": ["turn": ["id": "finished", "status": "interrupted"]]])
        check(transactional.permissions.isEmpty, "interrupted turns clear stale permission requests")
        transactional.close()
        let staleRestore = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
        var failRestore = true
        staleRestore.connectionFactory = { account, _ in
            let connection = FixtureConnection(account); connection.failStart = failRestore; return connection
        }
        await staleRestore.connect(resume: "last")
        check(!staleRestore.ready, "failed restore remains recoverable")
        failRestore = false
        await staleRestore.switchThread(nil)
        let newRecord = staleRestore.currentConversationID
        staleRestore.draft = NSAttributedString(string: "Draft in the new conversation")
        staleRestore.event(["method": "cx/disconnected", "params": ["message": "Fixture disconnect"]])
        await staleRestore.reconnect()
        check(staleRestore.ready && staleRestore.currentConversationID == newRecord && staleRestore.draft.string == "Draft in the new conversation", "new conversation clears a failed restore target before reconnect")
        staleRestore.close()

        print("\(count) native checks passed")
        return true
    }
}

@MainActor
enum Render {
    static func run(directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let session = Session(cwd: "/Users/example/projects/atlas", stateDirectory: URL(fileURLWithPath: directory + "/state"))
        session.ready = true; session.status = "Ready"; session.model = "Claude Sonnet"; session.providerLabel = "Claude"
        session.context = "24% context"; session.usage = "18% 5h / 32% weekly"
        session.recent = [Recent(id: "1", title: "Build a clearer workspace"), Recent(id: "2", title: "Review the authentication flow"), Recent(id: "3", title: "Improve image attachments")]
        let image = NSImage(size: NSSize(width: 600, height: 360), flipped: false) { rect in
            NSColor(calibratedRed: 0.22, green: 0.14, blue: 0.38, alpha: 1).setFill(); rect.fill()
            NSColor.systemPink.withAlphaComponent(0.6).setFill(); NSBezierPath(ovalIn: NSRect(x: 350, y: 60, width: 180, height: 180)).fill()
            NSAttributedString(string: "A clearer workspace", attributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.white]).draw(at: NSPoint(x: 35, y: 260))
            return true
        }
        let imagePath = directory + "/sample.png"
        if let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data) { try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: imagePath)) }
        session.show(["id": "user", "type": "userMessage", "content": [["type": "text", "text": "Make the workspace feel like this, with compact image attachments."], ["type": "localImage", "path": imagePath]]])
        session.show(["id": "tool", "type": "commandExecution", "command": "swift build -c release", "status": "completed", "exitCode": 0, "aggregatedOutput": "Build complete."])
        session.show(["id": "answer", "type": "agentMessage", "provider": "Claude", "text": "The workspace now uses native SwiftUI and AppKit, just like Jarvis.\n\n• Images stay in one compact card. Click to preview.\n• Actions stay folded so the conversation stays clear.\n• Scroll up to read; return to the bottom to follow.\n\n```swift\nlet workspace = Workspace(project: \"atlas\")\nworkspace.open()\n```\n\nYour existing conversations are still available in the sidebar."])
        let draft = NSMutableAttributedString(string: "Can you refine this? ", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white])
        draft.append(NSAttributedString(attachment: ImageChip(path: imagePath, number: 1)))
        session.draft = draft
        write(CXView(session: session), size: CGSize(width: 1120, height: 820), path: directory + "/conversation.png")
        write(SettingsView(session: session), size: CGSize(width: 620, height: 640), path: directory + "/settings.png")
        let empty = Session(cwd: "/Users/example/projects/atlas", stateDirectory: URL(fileURLWithPath: directory + "/empty"))
        empty.ready = true; empty.status = "Ready"; empty.model = "Claude"
        write(CXView(session: empty), size: CGSize(width: 860, height: 640), path: directory + "/empty.png")
        print("Rendered conversation, settings, and empty state offscreen")
    }
    static func write(_ view: some View, size: CGSize, path: String) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
final class FixtureConnection: Connection {
    var event: (JSON) -> Void = { _ in }
    let account: Account
    var sent: [JSON] = []
    var failStart = false
    var failSend = false
    var limit = false
    var hold = false
    var closed = false
    var pendingTurn = "fixture-turn"
    init(_ account: Account) { self.account = account }
    func start(command: [String]?) async throws { if failStart { throw CXError(message: "Expected connection failure") } }
    func request(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON {
        switch method {
        case "thread/start", "thread/resume": return ["thread": ["id": account.provider + ":fixture"], "model": "fixture-model"]
        case "thread/list", "thread/turns/list": return ["data": []]
        case "model/list": return ["data": [["id": "fixture-model"]]]
        case "turn/start", "turn/steer":
            sent.append(params)
            if failSend { throw CXError(message: "Expected send failure") }
            event(["method": "turn/started", "params": ["turn": ["id": pendingTurn]]])
            Task { @MainActor in
                await Task.yield()
                if self.limit { self.event(["method": "cx/limit", "params": ["limit": ["resetsAt": Date().timeIntervalSince1970 + 3600]]]) }
                else if !self.hold {
                    self.event(["method": "item/completed", "params": ["item": ["id": UUID().uuidString, "type": "agentMessage", "text": "Finished", "provider": self.account.provider]]])
                    self.event(["method": "turn/completed", "params": ["turn": ["id": self.pendingTurn, "status": "completed"]]])
                }
            }
            return ["turn": ["id": pendingTurn]]
        case "turn/interrupt": event(["method": "turn/completed", "params": ["turn": ["id": pendingTurn, "status": "interrupted"]]]); return [:]
        default: return [:]
        }
    }
    func respond(_ id: Any, _ result: JSON) throws {}
    func reject(_ id: Any, method: String) throws {}
    func close() { closed = true }
}

struct AppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous).fill(userGradient).frame(width: 824, height: 824)
            Text("vcx").font(.system(size: 270, weight: .bold, design: .rounded)).tracking(-16).foregroundStyle(.white).offset(x: -8)
        }
    }
}
