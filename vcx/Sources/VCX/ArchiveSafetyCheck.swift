import AppKit

@MainActor
enum ArchiveSafetyCheck {
    private static let fixtureDelay = "1"
    private static let pollDelay: UInt64 = 10_000_000

    // The same fixture must survive failed save, timed-out shutdown and retry to prove no stale generation is substituted.
    static func run() async -> Bool {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("vcx-archive-check-" + UUID().uuidString)
        var stage = "native lease exclusivity"
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try leases(root)
            stage = "native hint symlink evidence"
            try await hintSymlinksAreRejected(root)
            stage = "fresh save failure"
            let (session, connection, sourcePath) = try fixture(root)
            defer { session.close() }
            try FileManager.default.removeItem(at: session.snapshotURL)
            try FileManager.default.createDirectory(at: session.snapshotURL, withIntermediateDirectories: true)
            var rejected = false
            do { try await session.archiveForClose() } catch { rejected = true }
            guard rejected, FileManager.default.fileExists(atPath: sourcePath.path), !connection.didClose else { throw CXError(message: "Archive accepted a failed save") }
            try FileManager.default.removeItem(at: session.snapshotURL)
            guard session.save() else { throw CXError(message: "Fixture save failed") }

            stage = "source and unsent context persistence"
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: session.snapshotURL)) as! JSON
            guard (record["nativeSources"] as? [JSON])?.count == 2, record["injectedContext"] as? String == "Unsent fixture context" else { throw CXError(message: "Source or context lost") }
            let origins = (record["rows"] as? [JSON] ?? []).flatMap { $0["items"] as? [JSON] ?? [] }.compactMap { $0["archiveOrigin"] as? JSON }
            guard origins.compactMap({ $0["client"] as? String }) == ["claude", "codex"], origins.compactMap({ $0["model"] as? String }) == ["claude-fixture", "codex-fixture"] else { throw CXError(message: "Stream update relabeled message origin") }

            stage = "saves frozen while archiving"
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = [fixtureDelay]
            try child.run(); connection.child = child
            connection.archiveStopAttempts = 1
            let archive = Task { try await session.archiveForClose() }
            while !connection.didClose { try await Task.sleep(nanoseconds: pollDelay) }
            let freshSnapshot = try Data(contentsOf: session.snapshotURL)
            session.draft = NSAttributedString(string: "Arrived during close")
            guard !session.save(), try Data(contentsOf: session.snapshotURL) == freshSnapshot else { throw CXError(message: "Archive snapshot was overwritten") }
            var timedOut = false
            do { try await archive.value } catch { timedOut = true }
            guard timedOut, child.isRunning, FileManager.default.fileExists(atPath: sourcePath.path) else { throw CXError(message: "Timed-out close lost its live child or native source") }
            connection.archiveStopAttempts = 100
            try await session.archiveForClose()

            stage = "verified deletion and repeated close"
            guard !FileManager.default.fileExists(atPath: sourcePath.path), !FileManager.default.fileExists(atPath: session.snapshotURL.path), !FileManager.default.fileExists(atPath: session.agentLogFile) else { throw CXError(message: "Native fixture or stopped child log was retained") }
            try await session.archiveForClose()
            session.close(); session.close()
            guard !FileManager.default.fileExists(atPath: session.snapshotURL.path) else { throw CXError(message: "Close recreated archived snapshot") }
            await Task.yield()
            stage = "runtime lifecycle and exact-source recovery"
            try await ArchiveLifecycleCheck.run(root.appendingPathComponent("lifecycle"), fixtureRoot: root)
            try FileManager.default.removeItem(at: root)
            print("ok: native leases, failed saves, timeout retry, frozen snapshots, ordered close, cold recovery and exact-source aliases")
            return true
        } catch {
            print("FAIL: archive safety at " + stage + "; synthetic fixture retained")
            print("reason: " + ArchiveLifecycleCheck.failureDescription(error))
            return false
        }
    }

    private static func leases(_ root: URL) throws {
        let id = UUID().uuidString
        let source = NativeSource(provider: "codex", home: root.path, threadID: "codex:" + id)
        let first = try NativeThreadLease(source)
        defer { withExtendedLifetime(first) {} }
        var blocked = false
        do { _ = try NativeThreadLease(NativeSource(provider: "codex", home: root.path, threadID: id.lowercased())) }
        catch { blocked = true }
        guard blocked else { throw CXError(message: "Raw native ID bypassed its lease") }
        let profile = try NativeThreadLease(NativeSource(provider: "codex", home: root.appendingPathComponent("other").path, threadID: id))
        let provider = try NativeThreadLease(NativeSource(provider: "claude", home: root.path, threadID: id))
        withExtendedLifetime([profile, provider]) {}
        let name = "vcx-archive-check-alias-" + UUID().uuidString
        let alias = NativeSource(provider: "codex", home: "/tmp/" + name, threadID: id)
        let canonical = NativeSource(provider: "codex", home: "/private/tmp/" + name, threadID: id)
        guard alias.home == canonical.home, alias.key == canonical.key else { throw CXError(message: "Filesystem alias changed native lease identity") }
        let aliasLease = try NativeThreadLease(alias)
        defer { withExtendedLifetime(aliasLease) {} }
        blocked = false
        do { _ = try NativeThreadLease(canonical) } catch { blocked = true }
        guard blocked else { throw CXError(message: "Filesystem alias bypassed native lease") }
    }

    private static func fixture(_ root: URL) throws -> (Session, ArchiveFixtureConnection, URL) {
        let home = root.appendingPathComponent("codex"), state = root.appendingPathComponent("state")
        let thread = UUID().uuidString.lowercased(), record = UUID().uuidString
        let native = home.appendingPathComponent("sessions/fixture/" + thread + ".jsonl")
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": thread]]).write(to: native)
        let sources = [NativeSource(provider: "codex", home: home.path, threadID: thread, path: native.path, managed: true), NativeSource(provider: "claude", home: root.appendingPathComponent("claude").path, threadID: UUID().uuidString, pendingCreation: true, managed: true)]
        let connection = ArchiveFixtureConnection(), session = Session(cwd: root.path, stateDirectory: state)
        let snapshot: JSON = ["cwd": root.path, "recordID": record, "threadID": thread, "nativeSources": sources.map(\.json), "nativeHistoryPath": native.path, "ready": true, "model": "codex-fixture", "archiveService": "openai",
                              "account": ["id": "archive-fixture", "name": "Archive fixture", "provider": "codex", "home": home.path, "enabled": true],
                              "rows": [["id": UUID().uuidString, "kind": "assistant", "items": [["id": "fixture-answer", "type": "agentMessage", "text": "Fixture answer", "archiveOrigin": ["client": "claude", "provider": "anthropic", "model": "claude-fixture"]]]]]]
        try session.adoptSwap(["testing": false, "injectedContext": "Unsent fixture context"], snapshot: snapshot, connection: connection)
        session.show(["id": "codex-answer", "type": "agentMessage", "text": "Second fixture answer"])
        session.model = "codex-updated"
        session.show(["id": "codex-answer", "type": "agentMessage", "text": "Completed fixture answer"])
        guard session.save() else { throw CXError(message: "Fixture origin save failed") }
        let log = URL(fileURLWithPath: session.agentLogFile)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Synthetic archive stderr\n".utf8).write(to: log)
        session.archiveFixtureRoot = root.path
        return (session, connection, native)
    }

    private static func hintSymlinksAreRejected(_ root: URL) async throws {
        let home = root.appendingPathComponent("hint-home"), target = home.appendingPathComponent("rollouts/actual.jsonl")
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id]]).write(to: target)
        let leaf = home.appendingPathComponent("hint.jsonl"), ancestor = home.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: target.deletingLastPathComponent())
        for hint in [leaf, ancestor.appendingPathComponent(target.lastPathComponent)] {
            let source = NativeSource(provider: "codex", home: home.path, threadID: id, path: hint.path)
            guard source.path == hint.path else { throw CXError(message: "Native hint erased symlink evidence") }
            var rejected = false
            do { _ = try await ConversationArchive.sourceFiles([source], state: root.appendingPathComponent("hint-state")) }
            catch { rejected = true }
            guard rejected else { throw CXError(message: "Native hint followed an untrusted symlink") }
        }
    }
}

@MainActor
private final class ArchiveFixtureConnection: Connection {
    var event: (JSON) -> Void = { _ in }
    var child: Process?
    var archiveStopAttempts = 100
    var archiveProcess: Process? { child }
    private(set) var didClose = false
    func start(command: [String]?) async throws {}
    func request(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON { [:] }
    func respond(_ id: Any, _ result: JSON) throws {}
    func reject(_ id: Any, method: String) throws {}
    func close() { didClose = true; child = nil }
}
