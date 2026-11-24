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
        try refusesUnsafeClosures(session)
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
        session.busy = true
        _ = try await backend.perform(action: "command", params: ["text": "/model codex fixture-model"])
        guard session.model == "other-model", session.pendingModelCommand == "/model codex fixture-model" else {
            throw CXError(message: "FAIL: vcx --set-model on a busy window must wait for the turn to end")
        }
        session.busy = false; session.pendingModelCommand = nil
        _ = try await backend.perform(action: "command", params: ["text": "/model codex fixture-model"])
        guard session.model == "fixture-model" else { throw CXError(message: "FAIL: vcx --set-model did not switch an idle window") }
        _ = try await backend.perform(action: "setModel", params: ["model": "other-model", "effort": "low"])
        await session.send(text: "Use the selected model", images: [], retry: true)
        let settings = (connection.sent.last?["collaborationMode"] as? JSON)?["settings"] as? JSON
        guard settings?["model"] as? String == "other-model", settings?["reasoning_effort"] as? String == "low" else {
            throw CXError(message: "FAIL: the next turn must use the selected model and effort")
        }
        print("Model control checks passed: model and effort change without a prompt or draft change")
    }

    static func refusesUnsafeClosures(_ session: Session) throws {
        let window = NSWindow(contentRect: .zero, styleMask: [.closable], backing: .buffered, defer: false)
        guard CloseControl.reason(session, window: window) == nil else { throw CXError(message: "FAIL: an idle empty session must be closable") }
        session.busy = true
        guard CloseControl.reason(session, window: window) != nil else { throw CXError(message: "FAIL: close control must preserve active work") }
        session.busy = false; session.backgroundTasks = 1
        guard CloseControl.reason(session, window: window) != nil else { throw CXError(message: "FAIL: close control must preserve background work") }
        session.backgroundTasks = 0; session.draft = NSAttributedString(string: "unsent draft")
        guard CloseControl.reason(session, window: window) != nil else { throw CXError(message: "FAIL: close control must preserve an unsent draft") }
        session.draft = NSAttributedString()
        print("Close control checks passed: active work, background work and drafts are preserved")
    }
}
