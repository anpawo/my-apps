import AppKit

@MainActor
enum ProviderCheck {
    static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vcx-provider-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = Settings.shared, previous = settings.value
        defer {
            settings.updateLimit(account: "claude-default", reset: previous.limits["claude-default"] ?? 0)
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
        var failures: [String] = []
        if session.modelLabel != "Not connected" { failures.append("a failed startup displays a model that never connected") }
        if session.activityLabel != "Not connected" { failures.append("a failed startup displays Ready") }

        let routing = Session(cwd: "/", stateDirectory: folder.appendingPathComponent("routing"))
        defer { routing.close() }
        let connection = FixtureConnection(previous.accounts.first { $0.id == "codex-default" }!)
        connection.routingFailures = 1
        routing.connectionFactory = { _, _ in connection }
        routing.providerChoice = "codex"
        routing.draft = NSAttributedString(string: "Keep the unsent draft")
        await routing.connect(resume: nil)
        if !routing.ready || connection.opened.count != 2 || !connection.sent.isEmpty || routing.draft.string != "Keep the unsent draft" {
            failures.append("a workspace routing timeout leaves startup disconnected")
        }
        if routing.activityLabel != "Ready" { failures.append("a successful startup never becomes Ready") }
        let unavailable = Session(cwd: "/", stateDirectory: folder.appendingPathComponent("routing-unavailable"))
        defer { unavailable.close() }
        let unavailableConnection = FixtureConnection(connection.account)
        unavailableConnection.routingFailures = 3
        unavailable.connectionFactory = { _, _ in unavailableConnection }
        unavailable.providerChoice = "codex"
        unavailable.draft = NSAttributedString(string: "Keep the failed draft")
        await unavailable.connect(resume: nil)
        if unavailable.ready || unavailableConnection.opened.count != 2 || unavailable.activityLabel != "Not connected" || unavailable.modelLabel != "Not connected" || unavailable.draft.string != "Keep the failed draft" {
            failures.append("a persistent routing failure must stop after one retry and preserve the draft")
        }
        if !failures.isEmpty { throw CXError(message: "FAIL: " + failures.joined(separator: "; ")) }
        print("Routing checks passed: transient discovery failure reconnects without sending or losing the draft")
    }
}
