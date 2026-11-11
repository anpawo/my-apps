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
    }
}
