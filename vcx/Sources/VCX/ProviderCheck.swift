import AppKit

@MainActor
enum ProviderCheck {
    static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vcx-provider-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = Settings.shared, previous = settings.value
        defer {
            settings.updateLimit(account: "claude-default", reset: previous.limits["claude-default"] ?? 0)
            settings.updateLimit(account: "codex-default", reset: previous.limits["codex-default"] ?? 0)
            settings.value = previous; settings.save()
        }
        settings.value.provider = "auto"
        settings.save()
        settings.updateLimit(account: "claude-default", reset: Date().timeIntervalSince1970 + 3600)
        var attempted: [String] = []
        let session = Session(cwd: folder.path, stateDirectory: folder)
        defer { session.close() }
        session.draft = NSAttributedString(string: "Keep my prompt")
        session.connectionFactory = { account, _ in
            attempted.append(account.provider)
            let connection = FixtureConnection(account)
            connection.failStart = true
            return connection
        }
        await session.connect(resume: nil)
        guard attempted == ["codex"], !session.ready,
              settings.value.limits["codex-default"] == nil, settings.value.limits["qwen"] == nil,
              session.rows.last?.items.first?.text == "Expected connection failure",
              session.draft.string == "Keep my prompt" else {
            throw CXError(message: "FAIL: a Codex connection failure tried another provider or recorded a false usage limit; attempted: " + attempted.joined(separator: ", "))
        }
        print("Provider failure checks passed: Codex errors stay on Codex without false limits or lost drafts")
        var routingErrors: [String] = []
        if session.modelLabel != "Not connected" { routingErrors.append("a failed startup displays a model that never connected") }
        if session.activityLabel != "Not connected" { routingErrors.append("a failed startup displays Ready") }
        session.model = "Codex"
        if session.modelLabel != "Not connected" { routingErrors.append("a disconnected worker from an older build displays its placeholder model") }

        let routing = Session(cwd: "/", stateDirectory: folder.appendingPathComponent("routing"))
        defer { routing.close() }
        let connection = FixtureConnection(previous.accounts.first { $0.id == "codex-default" }!)
        connection.routingFailures = 1
        routing.connectionFactory = { _, _ in connection }
        routing.providerChoice = "codex"
        routing.draft = NSAttributedString(string: "Keep the unsent draft")
        await routing.connect(resume: nil)
        if !routing.ready || connection.opened.count != 2 || !connection.sent.isEmpty || routing.draft.string != "Keep the unsent draft" {
            routingErrors.append("a workspace routing timeout leaves startup disconnected")
        }
        if routing.activityLabel != "Ready" { routingErrors.append("a successful startup never becomes Ready") }
        let unavailable = Session(cwd: "/", stateDirectory: folder.appendingPathComponent("routing-unavailable"))
        defer { unavailable.close() }
        let unavailableConnection = FixtureConnection(connection.account)
        unavailableConnection.routingFailures = 3
        unavailable.connectionFactory = { _, _ in unavailableConnection }
        unavailable.providerChoice = "codex"
        unavailable.draft = NSAttributedString(string: "Keep the failed draft")
        await unavailable.connect(resume: nil)
        if unavailable.ready || unavailableConnection.opened.count != 2 || unavailable.activityLabel != "Not connected" || unavailable.modelLabel != "Not connected" || unavailable.draft.string != "Keep the failed draft" {
            routingErrors.append("a persistent routing failure must stop after one retry and preserve the draft")
        }
        if !routingErrors.isEmpty { throw CXError(message: "FAIL: " + routingErrors.joined(separator: "; ")) }
        print("Routing checks passed: transient discovery failure reconnects without sending or losing the draft")

        let switching = Session(cwd: folder.path, stateDirectory: folder.appendingPathComponent("switching"))
        defer { switching.close() }
        var connections: [FixtureConnection] = []
        switching.connectionFactory = { account, _ in
            let connection = FixtureConnection(account)
            connection.failStart = account.provider == "qwen"
            connections.append(connection)
            return connection
        }
        switching.providerChoice = "claude"
        try await switching.activate(previous.accounts.first { $0.id == "claude-default" }!, resume: nil, keepRows: false)
        await switching.refreshCatalog()
        switching.draft = NSAttributedString(string: "Keep my draft while switching")
        let original = switching.rpc, thread = switching.threadID, models = switching.models
        let backend = SessionBackend(session: switching)
        _ = try await backend.perform(action: "command", params: ["text": "/model qwen"])
        var failures: [String] = []
        if !switching.ready || switching.rpc !== original || connections[0].closed || switching.providerChoice != "claude" || switching.threadID != thread || switching.models != models || switching.changing || switching.draft.string != "Keep my draft while switching" {
            failures.append("a failed provider switch must keep the current connection, selection, models and draft")
        }
        Settings.shared.updateLimit(account: "codex-default", reset: Date().timeIntervalSince1970 + 3600)
        _ = try await backend.perform(action: "command", params: ["text": "/model codex"])
        if !switching.ready || switching.account.provider != "codex" || switching.providerChoice != "codex" {
            failures.append("an explicit provider selection must retry enabled accounts despite cached usage limits")
        }
        await switching.send(text: "Use the explicitly selected provider", images: [])
        if switching.account.provider != "codex" || connections.last?.sent.count != 1 {
            failures.append("the next prompt must stay on the explicitly selected provider")
        }
        if !failures.isEmpty { throw CXError(message: "FAIL: " + failures.joined(separator: "; ")) }
        print("Provider switch checks passed: failed switches preserve the working session and explicit selections retry enabled accounts")

        let closing = Session(cwd: folder.path, stateDirectory: folder.appendingPathComponent("closing"))
        let pending = FixtureConnection(previous.accounts.first { $0.id == "codex-default" }!)
        pending.startDelay = 100_000_000
        closing.connectionFactory = { _, _ in pending }
        let start = Task { try await closing.activate(pending.account, resume: nil, keepRows: false) }
        for _ in 0..<100 where !closing.changing { try await Task.sleep(nanoseconds: 1_000_000) }
        closing.close()
        do {
            try await start.value
            throw CXError(message: "FAIL: a closed session finished connecting")
        } catch let error as CXError where !error.message.hasPrefix("FAIL:") {}
        guard pending.closed, !closing.ready, !closing.changing else { throw CXError(message: "FAIL: closing a session must close its pending connection") }
        print("Provider close checks passed: closing during startup cancels the pending connection")
    }
}
