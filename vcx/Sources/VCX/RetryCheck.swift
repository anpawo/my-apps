import AppKit

@MainActor
enum RetryCheck {
    static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vcx-retry-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Session(cwd: folder.path, stateDirectory: folder)
        defer { session.close() }
        let account = Settings.shared.value.accounts.first { $0.id == "codex-default" }!
        let connection = FixtureConnection(account)
        connection.hold = true
        session.providerChoice = "codex"
        session.connectionFactory = { _, _ in connection }
        try await session.activate(account, resume: nil, keepRows: false)
        await session.send(text: "Continue the task", images: [])
        session.draft = NSAttributedString(string: "Unsent draft")
        session.notice("Keep this warning")

        session.event(["method": "error", "params": ["willRetry": true, "error": ["message": "Reconnecting... 2/5"]]])
        let row = session.rows.last?.id
        session.event(["method": "error", "params": ["willRetry": true, "error": ["message": "Reconnecting... 3/5"]]])
        session.event(["method": "warning", "params": ["message": "Falling back from WebSockets to HTTPS transport: stream disconnected before completion: failed to lookup address information: nodename nor servname provided, or not known"]])
        session.event(["method": "error", "params": ["willRetry": true, "error": ["message": "Reconnecting... waiting for network"]]])

        guard session.rows.filter({ $0.kind == "notice" }).count == 2,
              session.rows.last?.id == row,
              session.rows.last?.items.first?.text == "Reconnecting... waiting for network",
              session.activityLabel == "Reconnecting…" else {
            throw CXError(message: "FAIL: retry notice count \(session.rows.filter { $0.kind == "notice" }.count), stable row \(session.rows.last?.id == row), latest text \(session.rows.last?.items.first?.text == "Reconnecting... waiting for network"), activity \(session.activityLabel), sent \(connection.sent.count)")
        }
        try preservesRetryStatusAcrossFrontendReconnect(session)
        session.event(["method": "item/agentMessage/delta", "params": ["itemId": "answer", "delta": "Recovered"]])
        guard session.rows.filter({ $0.kind == "notice" }).map({ $0.items.first?.text }) == ["Keep this warning"],
              session.activityLabel == "Thinking", connection.sent.count == 1,
              session.draft.string == "Unsent draft" else {
            throw CXError(message: "FAIL: recovery leaves retry notices, replays the prompt, or loses the draft")
        }
        session.event(["method": "error", "params": ["willRetry": true, "error": ["message": "Reconnecting... 1/5"]]])
        session.event(["method": "error", "params": ["willRetry": false, "error": ["message": "Connection failed"]]])
        guard session.rows.filter({ $0.kind == "notice" }).map({ $0.items.first?.text }) == ["Keep this warning", "Connection failed"] else {
            throw CXError(message: "FAIL: a terminal error is hidden by retry cleanup")
        }
        try await clearsRetryStatusWhenTurnEnds(session)
        print("Retry checks passed: one transient notice, cleared on recovery, with no replay or lost draft")
    }

    private static func preservesRetryStatusAcrossFrontendReconnect(_ session: Session) throws {
        let frontend = Session(cwd: session.cwd)
        defer { frontend.close() }
        frontend.applyRuntimeSnapshot(SessionBackend(session: session).snapshot())
        guard frontend.activityLabel == "Reconnecting…",
              frontend.rows.last?.items.first?.text == "Reconnecting... waiting for network" else {
            throw CXError(message: "FAIL: a frontend reconnect loses the current retry status")
        }
    }

    private static func clearsRetryStatusWhenTurnEnds(_ session: Session) async throws {
        session.event(["method": "error", "params": ["willRetry": true, "error": ["message": "Reconnecting... 1/5"]]])
        await session.stop(source: "Stop button")
        guard !session.busy, !session.rows.contains(where: { $0.items.first?.data["retry"] as? Bool == true }) else {
            throw CXError(message: "FAIL: stopping a retry leaves a reconnect status behind")
        }
        session.event(["method": "turn/started", "params": ["turn": ["id": "completed-turn"]]])
        session.event(["method": "error", "params": ["willRetry": true, "error": ["message": "Reconnecting... 1/5"]]])
        session.event(["method": "turn/completed", "params": ["turn": ["status": "completed"]]])
        guard session.activityLabel == "Ready", !session.rows.contains(where: { $0.items.first?.data["retry"] as? Bool == true }) else {
            throw CXError(message: "FAIL: completing a retry leaves a reconnect status behind")
        }
    }
}
