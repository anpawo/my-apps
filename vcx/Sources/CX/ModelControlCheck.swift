import AppKit

@MainActor
enum ModelControlCheck {
    static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vcx-model-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Session(cwd: "/", stateDirectory: folder)
        let connection = FixtureConnection(Account(id: "codex-default", name: "Codex", provider: "codex"))
        session.connectionFactory = { _, _ in connection }
        try await session.activate(connection.account, resume: nil, keepRows: false)
        defer { session.close() }
        session.models = ["fixture-model", "other-model"]
        session.modelEfforts["other-model"] = ["low", "high"]
        session.effort = "high"
        connection.resumeModel = session.model
        session.draft = NSAttributedString(string: "/model unfinished draft")
        session.show(["id": "existing", "type": "agentMessage", "text": "Existing answer"])
        let thread = session.threadID, record = session.runtimeMetadata()["recordID"] as? String, rows = session.rows.map(\.id), draft = session.draft, generation = session.draftGeneration
        let backend = SessionBackend(session: session)
        session.busy = true
        do {
            _ = try await backend.perform(action: "setModel", params: ["model": "other-model"])
            throw CXError(message: "FAIL: model control interrupted an active turn")
        } catch let error as CXError where !error.message.hasPrefix("FAIL:") {}
        session.busy = false
        _ = try await backend.perform(action: "setModel", params: ["model": "other-model"])
        guard session.model == "other-model", session.effort == "high", session.threadID == thread, session.runtimeMetadata()["recordID"] as? String == record,
              session.rows.map(\.id) == rows, session.draft.isEqual(to: draft), session.draftGeneration == generation, connection.sent.isEmpty else {
            throw CXError(message: "FAIL: model control must preserve effort, conversation and draft without sending a prompt")
        }
        do {
            _ = try await backend.perform(action: "setModel", params: ["model": "missing-model"])
            throw CXError(message: "FAIL: model control accepted an unknown model")
        } catch let error as CXError where !error.message.hasPrefix("FAIL:") {}
        _ = try await backend.perform(action: "setModel", params: ["model": "other-model", "effort": "low"])
        guard session.effort == "low" else { throw CXError(message: "FAIL: model control ignored explicit effort") }
        await session.send(text: "Use the selected model", images: [], retry: true)
        let settings = (connection.sent.last?["collaborationMode"] as? JSON)?["settings"] as? JSON
        guard settings?["model"] as? String == "other-model", settings?["reasoning_effort"] as? String == "low" else {
            throw CXError(message: "FAIL: the next turn must use the selected model and effort")
        }
        print("Model control checks passed: model and effort change without a prompt or draft change")
    }
}
