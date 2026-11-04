import AppKit
import CryptoKit
import Darwin

enum RuntimeIdentity {
    static let executable = Bundle.main.executableURL!
    static let build = (try? Data(contentsOf: executable)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unavailable"
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["VCX_RUNTIME_HOME"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/cx/runtime", isDirectory: true)
    }
    static func socket(cwd: String) -> String {
        let group = SHA256.hash(data: Data(URL(fileURLWithPath: cwd).standardized.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return directory.appendingPathComponent(String(group) + ".sock").path
    }
    static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw CXError(message: "Runtime folder must be private and owned by your account.")
        }
    }
}

@MainActor
final class RuntimeClient {
    weak var session: Session?
    let sessionID: String
    let socketPath: String
    var onLeaseLost: () -> Void = {}
    var isAttached: Bool { attached && !closed && !superseded }
    private var channel: RuntimeChannel?
    private var lease = ""
    private var sequence = 0
    private var revision = 0
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
    private var timeouts: [String: DispatchWorkItem] = [:]
    private var closed = false
    private var superseded = false
    private var attached = false
    private var attaching = false
    private var bufferedUpdates: [JSON] = []
    private var reconnectTask: Task<Void, Never>?
    private var connectTask: Task<Void, Error>?
    private var checkpointTask: Task<Void, Error>?
    private var acknowledgedGeneration = -1
    private let initialCwd: String
    private let resumingRuntime: Bool

    init(session: Session, cwd: String, resumeRuntimeID: String? = nil, socketPath: String? = nil) {
        self.session = session
        initialCwd = cwd
        resumingRuntime = resumeRuntimeID != nil
        sessionID = resumeRuntimeID.flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
        self.socketPath = socketPath ?? RuntimeIdentity.socket(cwd: cwd)
    }

    func connect(resume: String?, prompt: String = "") async throws {
        if let connectTask { return try await connectTask.value }
        let task = Task { try await attach(resume: resume, prompt: prompt, launch: !resumingRuntime) }
        connectTask = task
        defer { connectTask = nil }
        try await task.value
    }

    func reclaim() async throws {
        guard !closed else { throw CXError(message: "This frontend is closed.") }
        superseded = false
        channel?.close(); channel = nil
        try await attach(resume: nil, prompt: "", launch: false)
    }

    private func attach(resume: String?, prompt: String, launch: Bool) async throws {
        guard !closed, !superseded else { throw CXError(message: "This window no longer owns the session.") }
        let connection = try await openChannel(launch: launch)
        channel = connection
        connection.onMessage = { [weak self] in self?.receive($0) }
        connection.onClose = { [weak self, weak connection] in
            guard let self, self.channel === connection else { return }
            self.disconnected()
        }
        connection.start()
        attaching = true
        bufferedUpdates.removeAll()
        do {
            let hello = try await request("hello", ["protocol": 1], timeout: 10)
            guard hello["protocol"] as? Int == 1 else { throw CXError(message: "The frontend and runtime use incompatible protocols.") }
            var params: JSON = ["sessionId": sessionID, "cwd": initialCwd, "prompt": prompt]
            params["resume"] = resume
            let result = try await request("attach", params)
            guard let nextLease = result["lease"] as? String, let state = result["state"] as? JSON, let nextRevision = result["revision"] as? Int else {
                throw CXError(message: "The runtime returned an invalid session snapshot.")
            }
            lease = nextLease
            sequence = result["lastSequence"] as? Int ?? 0
            revision = nextRevision
            attached = true
            session?.applyRuntimeSnapshot(state)
            acknowledgedGeneration = state["draftGeneration"] as? Int ?? -1
            attaching = false
            let updates = bufferedUpdates
            bufferedUpdates.removeAll()
            for update in updates { receive(update) }
        } catch {
            attaching = false
            bufferedUpdates.removeAll()
            attached = false
            channel = nil
            connection.close()
            failPending(error)
            throw error
        }
    }

    private func openChannel(launch: Bool) async throws -> RuntimeChannel {
        if let channel = try? RuntimeChannel.connect(path: socketPath) { return channel }
        guard launch else { throw CXError(message: "The session runtime stopped. Saved history remains available; running work was interrupted.") }
        try RuntimeIdentity.prepareDirectory()
        let lock = Darwin.open(socketPath + ".launch.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CXError(message: "Cannot lock runtime startup.") }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
            throw CXError(message: "Runtime startup lock is not private.")
        }
        var process: Process?
        for attempt in 0..<100 {
            if let channel = try? RuntimeChannel.connect(path: socketPath) { return channel }
            if process == nil, flock(lock, LOCK_EX | LOCK_NB) == 0 {
                if let channel = try? RuntimeChannel.connect(path: socketPath) { return channel }
                let worker = Process()
                worker.executableURL = RuntimeIdentity.executable
                worker.arguments = ["--runtime-worker", socketPath]
                var environment = ProcessInfo.processInfo.environment
                environment.removeValue(forKey: "BUILD_STACK_FD")
                worker.environment = environment
                worker.currentDirectoryURL = URL(fileURLWithPath: initialCwd, isDirectory: true)
                worker.standardInput = FileHandle.nullDevice
                worker.standardOutput = FileHandle.nullDevice
                worker.standardError = FileHandle.nullDevice
                try worker.run()
                process = worker
            }
            if let process, !process.isRunning { throw CXError(message: "The runtime could not start.") }
            try await Task.sleep(nanoseconds: attempt < 10 ? 50_000_000 : 100_000_000)
        }
        throw CXError(message: "Timed out waiting for the runtime to start.")
    }

    func perform(_ action: String, _ params: JSON = [:]) async throws -> JSON {
        guard attached, !closed, !superseded else { throw CXError(message: "The session runtime is disconnected.") }
        sequence += 1
        do { return try await request("perform", ["sessionId": sessionID, "lease": lease, "sequence": sequence, "action": action, "params": params]) }
        catch { channel?.close(); throw error }
    }

    func checkpoint(draft: [JSON], generation: Int) async throws {
        if let checkpointTask { try await checkpointTask.value }
        guard generation > acknowledgedGeneration else { return }
        let task = Task {
            _ = try await perform("checkpoint", ["draft": draft, "generation": generation])
            acknowledgedGeneration = max(acknowledgedGeneration, generation)
        }
        checkpointTask = task
        defer { checkpointTask = nil }
        try await task.value
    }

    func checkpointWindow(_ state: JSON) async throws {
        if let checkpointTask { try await checkpointTask.value }
        guard let session else { return }
        _ = try await perform("checkpoint", ["draft": draftContent(session.savedCommandDraft ?? session.draft), "generation": session.draftGeneration, "windowState": state])
        acknowledgedGeneration = max(acknowledgedGeneration, session.draftGeneration)
    }

    func preflight(executable: URL) async throws {
        let check = Process()
        check.executableURL = executable
        check.arguments = ["--runtime-protocol"]
        let output = Pipe()
        check.standardOutput = output
        check.standardError = FileHandle.nullDevice
        try check.run()
        let timeout = DispatchWorkItem { if check.isRunning { check.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        let result = await Task.detached {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            check.waitUntilExit()
            return (check.terminationStatus, data)
        }.value
        guard result.0 == 0, String(data: result.1, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
            throw CXError(message: "The new frontend cannot attach to the running runtime.")
        }
    }

    private func request(_ method: String, _ params: JSON, timeout: Double = 120) async throws -> JSON {
        guard let channel, !closed else { throw CXError(message: "The session runtime is disconnected.") }
        guard pending.count < 256 else { throw CXError(message: "The runtime request queue is full.") }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let timer = DispatchWorkItem { [weak self] in self?.finish(id, result: .failure(CXError(message: "The runtime request timed out; it may still have been accepted. Reconnect before retrying."))) }
            timeouts[id] = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
            do { try channel.send(["id": id, "method": method, "params": params]) }
            catch { finish(id, result: .failure(error)) }
        }
    }

    private func receive(_ message: JSON) {
        if let id = message["id"] as? String {
            if let error = message["error"] as? JSON { finish(id, result: .failure(CXError(message: error["message"] as? String ?? "Runtime request failed."))) }
            else { finish(id, result: .success(message["result"] as? JSON ?? [:])) }
            return
        }
        guard let method = message["method"] as? String, let params = message["params"] as? JSON, params["sessionId"] as? String == sessionID else { return }
        if method == "session/leaseLost" {
            superseded = true
            attached = false
            reconnectTask?.cancel()
            session?.ready = false
            session?.status = "Session moved to another window."
            failPending(CXError(message: "This window no longer owns the session."))
            onLeaseLost()
        } else if method == "session/update", attaching {
            guard bufferedUpdates.count < 256 else { channel?.close(); return }
            bufferedUpdates.append(message)
        } else if method == "session/update", attached, let next = params["revision"] as? Int, let patch = params["patch"] as? JSON {
            guard next == revision + 1 else {
                if next > revision { channel?.close() }
                return
            }
            revision = next
            session?.applyRuntimePatch(patch)
        }
    }

    private func finish(_ id: String, result: Result<JSON, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func failPending(_ error: Error) { for id in Array(pending.keys) { finish(id, result: .failure(error)) } }

    private func disconnected() {
        channel = nil
        attached = false
        failPending(CXError(message: "Connection lost. Accepted actions continue in the runtime and will not be replayed."))
        guard !closed, !superseded, reconnectTask == nil else { return }
        session?.ready = false
        session?.status = "Reconnecting to the running session…"
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { reconnectTask = nil }
            for attempt in 0..<5 {
                if Task.isCancelled || closed || superseded { return }
                do { try await attach(resume: nil, prompt: "", launch: false); return }
                catch { if attempt == 4 { session?.status = error.localizedDescription; return } }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 200_000_000)
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        reconnectTask?.cancel()
        if attached { try? channel?.send(["id": UUID().uuidString, "method": "detach", "params": ["sessionId": sessionID, "lease": lease]]) }
        channel?.close()
        channel = nil
        attached = false
        failPending(CXError(message: "Frontend detached; agent work remains in the runtime."))
    }
}
