import AppKit

@MainActor
enum ArchiveResumeCheck {
    private static let turnTimeout: TimeInterval = 180
    private static let pollDelay: UInt64 = 100_000_000
    private static let marker = "vcx-archive-resume-ok"
    private static let adapterRevision = 1

    // One continuous fixture proves deletion and restoration refer to the exact native thread that produced the tool output.
    static func run(provider: String, pruneFixture: Bool) async -> Bool {
        guard ["claude", "codex", "agy"].contains(provider) else { return false }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vcx-archive-live-" + UUID().uuidString)
        let state = root.appendingPathComponent("state"), project = root.appendingPathComponent("project")
        let previousRouter = Session.router
        Session.router = { _, _ in nil }
        defer { Session.router = previousRouter }
        var stage = "start"
        let first = Session(cwd: project.path, stateDirectory: state)
        let second = Session(cwd: project.path, stateDirectory: state)
        defer { first.close(); second.close() }
        do {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let account = Settings.shared.candidates(provider).first ?? Account(id: provider, name: "Archive fixture", provider: provider)
            first.providerChoice = provider
            try await first.activate(account, resume: nil, keepRows: false)
            stage = "initial tool turn"
            try await turn(first, "Run printf '" + marker + "' with your terminal tool, then reply with just done.", provider: provider)
            guard first.rows.flatMap(\.items).contains(where: { ($0.data["aggregatedOutput"] as? String ?? "").contains(marker) }) else { throw VCXError(message: "Missing fixture tool result") }
            let id = first.currentConversationID, thread = first.threadID
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: first.snapshotURL)) as! JSON
            let sources = (record["nativeSources"] as? [JSON] ?? []).compactMap(NativeSource.init)
            guard sources.count == 1, sources[0].managed, let version = sources[0].clientVersion else { throw VCXError(message: "Fixture native provenance missing") }
            let nativePaths = try ConversationArchive.call("sourceFiles", state: state, values: ["sources": sources.map(\.json)])["paths"] as? [String] ?? []
            guard !nativePaths.isEmpty else { throw VCXError(message: "Fixture native artifacts missing") }
            if pruneFixture {
                _ = try ConversationArchive.call("certifyProvider", state: state, values: ["provider": provider, "adapterRevision": adapterRevision, "clientVersion": version])
            }
            stage = "archive"
            try await first.archiveForClose()
            try await first.refreshArchiveCatalog()
            first.close()
            guard !FileManager.default.fileExists(atPath: first.snapshotURL.path), first.nativeRecent().contains(where: { $0.id == id }) else { throw VCXError(message: "Archive catalog missing") }
            if pruneFixture, nativePaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) { throw VCXError(message: "Fixture native history was not pruned") }
            stage = "native resume"
            second.providerChoice = provider
            await Task.yield()
            await second.connect(resume: thread)
            guard second.ready, second.threadID == thread, second.currentConversationID == id else { throw VCXError(message: "Native resume failed") }
            stage = "recalled tool result"
            try await turn(second, "What exact string did the first terminal command in this conversation print? Reply with only that string.", provider: provider)
            guard second.rows.last(where: { $0.kind == "assistant" })?.items.contains(where: { ($0.data["text"] as? String ?? "").contains(marker) }) == true else { throw VCXError(message: "Native state not recalled") }
            stage = "second archive"
            try await second.archiveForClose()
            second.close()
            print("ok: " + provider + " close, archive, " + (pruneFixture ? "native deletion, " : "native retention, ") + "alias restore, native tool recall and second archive")
            try FileManager.default.removeItem(at: root)
            return true
        } catch {
            print("FAIL: " + provider + " archive resume at " + stage + "; test history retained")
            return false
        }
    }

    private static func turn(_ session: Session, _ prompt: String, provider: String) async throws {
        let account = session.account, thread = session.threadID, record = session.currentConversationID
        guard account.provider == provider else { throw VCXError(message: "Fixture provider changed before turn") }
        await session.send(text: prompt, images: [])
        let deadline = Date().addingTimeInterval(turnTimeout)
        repeat {
            guard session.account == account, session.threadID == thread, session.currentConversationID == record else { throw VCXError(message: "Fixture source changed during turn") }
            if session.busy { try await Task.sleep(nanoseconds: pollDelay) }
        } while session.busy && Date() < deadline
        guard !session.busy, session.ready, !session.needsAttention else { throw VCXError(message: "Fixture turn did not complete") }
    }
}
