import AppKit

@MainActor
enum ArchiveLifecycleCheck {
    private static let pollDelay: UInt64 = 10_000_000
    private static let observationDelay: UInt64 = 40_000_000
    private static let deadline: TimeInterval = 5

    static func run(_ root: URL, fixtureRoot: URL) async throws {
        print("check: runtime close waits for switch")
        try await serverOrdersCloseAfterSwitch()
        print("check: startup cannot outlive close")
        try await startupCannotOutliveClose(root.appendingPathComponent("startup"))
        print("check: archived earlier-source alias and cold recovery")
        try await restoresExactEarlierSource(root.appendingPathComponent("aliases"), fixtureRoot: fixtureRoot)
        print("check: restored synthetic account stays preferred")
        try await restoredSyntheticAccountStaysPreferred(root.appendingPathComponent("synthetic-account"))
    }

    static func failureDescription(_ error: Error) -> String {
        let labels = ["Conversation diagnostics could not be saved; close was stopped to keep the pending events.": "diagnostic persistence blocked close",
                      "A diagnostic event could not be encoded; retry close to acknowledge this diagnostic failure.": "diagnostic encoding blocked close",
                      "Wait for the current connection change before closing this conversation.": "connection transition blocked close",
                      "Archive lifecycle fixture timed out": "fixture gate timeout",
                      "Earlier alias resumed the latest source or another profile": "earlier-source alias mismatch",
                      "Committed archive disappeared from cold recovery": "committed archive missing in recovery",
                      "Ambiguous native alias started a source": "ambiguous alias was accepted",
                      "Unavailable account silently started a new thread": "unavailable profile was replaced",
                      "Restored synthetic account selected a fallback": "built-in profile replaced on restore",
                      "Close bypassed an ordered conversation switch": "close bypassed switch",
                      "Close interrupted an unfinished startup": "close bypassed startup",
                      "Startup did not settle before close": "startup did not settle",
                      "Cancelled startup mutated a closed session": "cancelled startup reopened session"]
        if let label = labels[error.localizedDescription] { return label }
        if let response = error as? RuntimeResponseError {
            let codes = ["actionFailed", "invalidAction", "closed", "sequenceGap", "sequenceConflict", "unknownSession", "superseded", "busy"]
            return "runtime " + (response.code.flatMap { codes.contains($0) ? $0 : nil } ?? "other") + ", message length " + String(response.message.count)
        }
        return "unclassified fixture error, message length " + String(error.localizedDescription.count)
    }

    private static func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(deadline)
        while !condition() {
            guard Date() < end else { throw CXError(message: "Archive lifecycle fixture timed out") }
            try await Task.sleep(nanoseconds: pollDelay)
        }
    }

    private static func serverOrdersCloseAfterSwitch() async throws {
        let root = URL(fileURLWithPath: "/tmp/vcx-archive-check-race-" + UUID().uuidString.prefix(8)).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backend = RaceBackend(root), socket = root.appendingPathComponent("worker.sock").path
        let server = RuntimeServer(socketPath: socket, build: "archive-race-fixture") { _ in backend }
        try server.start()
        let proxy = Session(cwd: root.path, stateDirectory: root.appendingPathComponent("frontend"))
        let client = RuntimeClient(session: proxy, cwd: root.path, socketPath: socket)
        defer { backend.gate.release(); client.close(); proxy.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await client.connect(resume: nil)
        let switching = Task { try await client.perform("switchThread") }
        try await wait { backend.gate.started }
        let closing = Task { try await client.perform("close") }
        try await Task.sleep(nanoseconds: observationDelay)
        guard !backend.closeStarted else { throw CXError(message: "Close bypassed an ordered conversation switch") }
        backend.gate.release()
        _ = try await switching.value; _ = try await closing.value
        guard backend.switchFinished, backend.closeStarted else { throw CXError(message: "Ordered close did not finish") }
    }

    private static func startupCannotOutliveClose(_ root: URL) async throws {
        let first = Session(cwd: root.path, stateDirectory: root.appendingPathComponent("first"))
        let connection = LifecycleConnection(gated: true), backend = SessionBackend(session: first)
        first.connectionFactory = { _, _ in connection }; first.providerChoice = "codex"
        backend.startInBackground(params: [:])
        try await wait { connection.gate.started }
        let closing = Task { try await backend.perform(action: "close", params: [:]) }
        try await Task.sleep(nanoseconds: observationDelay)
        guard !connection.didClose else { throw CXError(message: "Close interrupted an unfinished startup") }
        connection.gate.release()
        _ = try await closing.value
        guard connection.didClose, first.threadID != nil else { throw CXError(message: "Startup did not settle before close") }

        let second = Session(cwd: root.path, stateDirectory: root.appendingPathComponent("second"))
        let abandoned = LifecycleConnection(gated: true), cancelled = SessionBackend(session: second)
        second.connectionFactory = { _, _ in abandoned }; second.providerChoice = "codex"
        cancelled.startInBackground(params: [:])
        try await wait { abandoned.gate.started }
        cancelled.close(); abandoned.gate.release()
        try await wait { abandoned.startReturned }
        await Task.yield()
        guard second.threadID == nil, abandoned.nativeOpens.isEmpty else { throw CXError(message: "Cancelled startup mutated a closed session") }
    }

    private static func restoresExactEarlierSource(_ root: URL, fixtureRoot: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldAccounts = Settings.shared.value.accounts
        defer { Settings.shared.value.accounts = oldAccounts }
        let nativeID = UUID().uuidString.lowercased(), recordID = UUID().uuidString
        let profiles = [Account(id: "archive-old", name: "Earlier fixture", provider: "claude", home: root.appendingPathComponent("claude").path), Account(id: "archive-new", name: "Latest fixture", provider: "codex", home: root.appendingPathComponent("codex").path)]
        Settings.shared.value.accounts = profiles
        let sources = try profiles.map { profile -> NativeSource in
            let home = URL(fileURLWithPath: profile.home!)
            let path = home.appendingPathComponent(profile.provider == "claude" ? "projects/fixture/" + nativeID + ".jsonl" : "sessions/fixture/" + nativeID + ".jsonl")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": nativeID]]).write(to: path)
            var source = NativeSource(provider: profile.provider, home: home.path, threadID: nativeID, path: profile.provider == "codex" ? path.path : nil, managed: true)
            source.accountID = profile.id
            return source
        }
        let state = root.appendingPathComponent("state"), first = Session(cwd: root.path, stateDirectory: state)
        let snapshot: JSON = ["cwd": root.path, "recordID": recordID, "threadID": nativeID, "nativeSources": sources.map(\.json), "account": try JSONSerialization.jsonObject(with: JSONEncoder().encode(profiles[1])), "rows": [["id": UUID().uuidString, "kind": "assistant", "items": [["id": "answer", "text": "Fixture"]]]]]
        try first.adoptSwap([:], snapshot: snapshot, connection: LifecycleConnection())
        first.archiveFixtureRoot = fixtureRoot.path
        try await first.archiveForClose(); first.close(); await Task.yield()
        let recovery = RuntimeRecovery.Entry(sessionID: UUID().uuidString, cwd: root.path, socketPath: root.appendingPathComponent("worker.sock").path, windowState: [:], state: ["recordID": recordID, "stateDirectory": state.path], instanceID: nil, resume: "native:" + recordID)
        guard await RuntimeRecovery.hasSavedRecord(recovery) else { throw CXError(message: "Committed archive disappeared from cold recovery") }
        try await checkAliasResume(root, state: state, nativeID: nativeID, recordID: recordID)
    }

    private static func checkAliasResume(_ root: URL, state: URL, nativeID: String, recordID: String) async throws {
        let connection = LifecycleConnection(), resumed = Session(cwd: root.path, stateDirectory: state)
        resumed.connectionFactory = { _, _ in connection }
        await resumed.connect(resume: "claude:" + nativeID)
        guard resumed.ready, resumed.threadID == "claude:" + nativeID, resumed.currentConversationID == "native:" + recordID, connection.nativeOpens == ["claude:" + nativeID], resumed.account.id == "archive-old" else { throw CXError(message: "Earlier alias resumed the latest source or another profile") }
        resumed.close(); await Task.yield()
        let ambiguous = Session(cwd: root.path, stateDirectory: state), unknown = LifecycleConnection()
        ambiguous.connectionFactory = { _, _ in unknown }
        await ambiguous.connect(resume: nativeID)
        guard !ambiguous.ready, unknown.nativeOpens.isEmpty else { throw CXError(message: "Ambiguous native alias started a source") }
        ambiguous.close()
        Settings.shared.value.accounts[0].enabled = false
        let disabled = Session(cwd: root.path, stateDirectory: state), fallback = LifecycleConnection()
        disabled.connectionFactory = { _, _ in fallback }
        await disabled.connect(resume: "claude:" + nativeID)
        guard !disabled.ready, fallback.nativeOpens.isEmpty else { throw CXError(message: "Unavailable account silently started a new thread") }
        disabled.close()
    }

    private static func restoredSyntheticAccountStaysPreferred(_ root: URL) async throws {
        let settings = Settings.shared, saved = Settings.shared.value
        defer { settings.value = saved }
        settings.value.accounts = [Account(id: "archive-fallback", name: "Fallback fixture", provider: "claude")]
        settings.value.limits = [:]
        for provider in ["agy", "qwen"] {
            let state = root.appendingPathComponent(provider), first = Session(cwd: root.path, stateDirectory: state)
            first.connectionFactory = { _, _ in LifecycleConnection() }
            first.providerChoice = provider
            guard let account = settings.candidates(provider).first else { throw CXError(message: "Synthetic fixture account missing") }
            try await first.activate(account, resume: nil, keepRows: false)
            let id = first.currentConversationID
            guard first.save() else { throw CXError(message: "Synthetic account fixture save failed") }
            first.close()
            let resumed = Session(cwd: root.path, stateDirectory: state)
            resumed.connectionFactory = { _, _ in LifecycleConnection() }
            await resumed.connect(resume: id)
            defer { resumed.close() }
            guard resumed.ready, resumed.account.id == account.id, resumed.accountChoice == account.id,
                  resumed.available.first?.id == account.id else { throw CXError(message: "Restored synthetic account selected a fallback") }
        }
        let disabled = Account(id: "archive-explicit", name: "Explicit fixture", provider: "claude", enabled: false)
        settings.value.accounts = [disabled]
        let selected = Session(cwd: root.path, stateDirectory: root.appendingPathComponent("explicit"))
        defer { selected.close() }
        selected.providerChoice = disabled.provider; selected.accountChoice = disabled.id
        guard selected.available.first == disabled else { throw CXError(message: "Explicit persisted account preference changed") }
        settings.value.limits[disabled.id] = Date().addingTimeInterval(deadline).timeIntervalSince1970
        guard !selected.available.contains(where: { $0.id == disabled.id }) else { throw CXError(message: "Selected account bypassed its usage limit") }
    }
}

@MainActor
private final class LifecycleGate {
    private(set) var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class LifecycleConnection: Connection {
    let gate = LifecycleGate()
    private let gated: Bool
    private(set) var startReturned = false
    private(set) var didClose = false
    private(set) var nativeOpens: [String] = []
    var event: (JSON) -> Void = { _ in }
    init(gated: Bool = false) { self.gated = gated }
    func start(command: [String]?) async throws { if gated { await gate.wait() }; startReturned = true }
    func request(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON {
        if ["thread/start", "thread/resume"].contains(method) {
            let id = params["threadId"] as? String ?? UUID().uuidString
            nativeOpens.append(id)
            return ["thread": ["id": id], "model": "fixture-model"]
        }
        if method == "thread/turns/list" { return ["data": [JSON]()] }
        return [:]
    }
    func respond(_ id: Any, _ result: JSON) throws {}
    func reject(_ id: Any, method: String) throws {}
    func close() { didClose = true }
}

@MainActor
private final class RaceBackend: RuntimeBackend {
    let gate = LifecycleGate()
    private let root: URL
    private(set) var switchFinished = false
    private(set) var closeStarted = false
    var onChange: ((JSON) -> Void)?
    init(_ root: URL) { self.root = root }
    func snapshot() -> JSON { ["cwd": root.path, "rows": [JSON](), "ready": true] }
    func perform(action: String, params: JSON) async throws -> JSON {
        if action == "switchThread" { await gate.wait(); switchFinished = true }
        if action == "close" { closeStarted = true }
        return [:]
    }
    func close() {}
}
