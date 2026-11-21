import Foundation

typealias JSON = [String: Any]

func codexContextWindow(model: String, home: String, configured: Int? = nil) -> Int? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("models_cache.json")),
          let cache = try? JSONSerialization.jsonObject(with: data) as? JSON,
          let entry = (cache["models"] as? [JSON])?.first(where: { $0["slug"] as? String == model }),
          let window = configured ?? entry["context_window"] as? Int, window > 0 else { return nil }
    let percent = entry["effective_context_window_percent"] as? Int ?? 100
    guard percent > 0, percent <= 100 else { return nil }
    return window * percent / 100
}

struct CXError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
protocol Connection: AnyObject {
    var event: (JSON) -> Void { get set }
    func start(command: [String]?) async throws
    func request(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON
    func respond(_ id: Any, _ result: JSON) throws
    func reject(_ id: Any, method: String) throws
    func close()
    var fleetFile: String? { get set }
    var logFile: String? { get set }
}

extension Connection {
    func request(_ method: String, _ params: JSON = [:]) async throws -> JSON { try await request(method, params, timeout: 120) }
    var fleetFile: String? { get { nil } set {} }
    var logFile: String? { get { nil } set {} }
}

@MainActor
final class RPC: Connection {
    var event: (JSON) -> Void = { _ in }
    var account: Account?
    var cwd: String?
    var fleetFile: String?
    var logFile: String?
    private var log: (path: String, start: UInt64)?
    private var process: Process?
    private var input: FileHandle?
    private var reader: ProviderJSONReader?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var timeouts: [Int: DispatchWorkItem] = [:]
    private var closed = false

    func start(command: [String]? = nil) async throws {
        let process = Process(), incoming = Pipe(), outgoing = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command ?? ["codex", "app-server"]
        process.environment = agentEnvironment(account, fleet: fleetFile)
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardInput = incoming
        process.standardOutput = outgoing
        let errors = try agentLog(logFile)
        process.standardError = errors.writer
        try process.run(); try? errors.writer.close()
        log = (errors.path, errors.start)
        try attach(process, input: incoming.fileHandleForWriting, output: outgoing.fileHandleForReading)
        _ = try await request("initialize", [
            "clientInfo": ["name": "vcx", "title": "Vibe Code X", "version": "0.2.0"],
            "capabilities": ["experimentalApi": true]
        ])
        try send(["method": "initialized"])
        if command == nil {
            let status = try await request("account/read", ["refreshToken": false])
            guard (status["account"] as? JSON)?["type"] as? String == "chatgpt" else {
                close()
                throw CXError(message: "Sign in with a ChatGPT subscription in Settings. vcx does not use API-key billing.")
            }
            let roots = ClaudeCompatibility(cwd: cwd ?? FileManager.default.currentDirectoryPath).skillRoots
            if !roots.isEmpty { _ = try await request("skills/extraRoots/set", ["extraRoots": roots]) }
        }
    }

    private func attach(_ process: Process, input: FileHandle, output: FileHandle, leftover: Data = Data()) throws {
        self.process = process
        self.input = input
        let reader = try ProviderJSONReader(handle: output, leftover: leftover, receive: { [weak self] message in
            guard let self, !closed else { return }; receive(message)
        }, invalid: { [weak self] message in
            guard let self, !closed else { return }
            event(["method": "cx/error", "params": ["message": message.replacingOccurrences(of: "Provider", with: "Codex")]])
        }, disconnected: { [weak self] in self?.disconnected() })
        self.reader = reader; reader.start()
    }

    func request(_ method: String, _ params: JSON = [:], timeout: Double = 120) async throws -> JSON {
        guard !closed, process?.isRunning == true else { throw CXError(message: "Codex is disconnected.") }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let timer = DispatchWorkItem { [weak self] in
                guard let self, let waiting = pending.removeValue(forKey: id) else { return }
                timeouts.removeValue(forKey: id)
                waiting.resume(throwing: CXError(message: "Codex timed out while handling \(method)."))
            }
            timeouts[id] = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
            do { try send(["id": id, "method": method, "params": params]) }
            catch { finish(id, .failure(error)) }
        }
    }

    func respond(_ id: Any, _ result: JSON) throws { try send(["id": id, "result": result]) }
    func reject(_ id: Any, method: String) throws {
        try send(["id": id, "error": ["code": -32601, "message": "cx does not support \(method)"]])
    }

    private func send(_ message: JSON) throws {
        guard let input, !closed else { throw CXError(message: "Codex is disconnected.") }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ message: JSON) {
        if message["method"] != nil { event(message); return }
        guard let id = message["id"] as? Int else { return }
        if let error = message["error"] as? JSON {
            finish(id, .failure(CXError(message: error["message"] as? String ?? "Codex request failed.")))
        } else { finish(id, .success(message["result"] as? JSON ?? [:])) }
    }

    private func finish(_ id: Int, _ result: Result<JSON, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func disconnected() {
        guard !closed else { return }
        let process = process, log = log
        close()
        Task { [weak self] in
            var params: JSON = ["message": "Codex disconnected. Reconnect to continue; your conversation is saved."]
            if let process { params.merge(await Task.detached { process.waitUntilExit(); return agentCrash(process, log: log) }.value) { $1 } }
            self?.event(["method": "cx/disconnected", "params": params])
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        reader?.close(); reader = nil
        try? input?.close()
        input = nil
        if let process { endProcess(process) }
        for id in Array(pending.keys) { finish(id, .failure(CXError(message: "Codex is disconnected."))) }
        process = nil
    }
}

extension RPC: AdoptableConnection {
    func freezeForSwap() -> JSON? {
        guard pending.isEmpty else { return nil }
        var state: JSON = ["kind": "codex", "nextID": nextID, "closed": closed]
        state["cwd"] = cwd
        state["account"] = account.flatMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        guard !closed else { return state }
        guard let process, process.isRunning, let input, let reader, let leftover = reader.freeze() else { return nil }
        state["agent"] = ["pid": Int(process.processIdentifier), "input": Int(input.fileDescriptor), "output": Int(reader.descriptor), "leftover": leftover.base64EncodedString()]
        if let log { state["log"] = log.path; state["logStart"] = Int(log.start) }
        return state
    }

    func thawSwap() { reader?.thaw() }

    convenience init(adopting state: JSON) throws {
        self.init()
        log = (state["log"] as? String).map { ($0, UInt64(state["logStart"] as? Int ?? 0)) }
        cwd = state["cwd"] as? String
        account = (state["account"] as? JSON).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        nextID = state["nextID"] as? Int ?? 0
        closed = state["closed"] as? Bool ?? false
        if let agent = try adoptedAgent(state) { try attach(agent.process, input: agent.input, output: agent.output, leftover: agent.leftover) }
    }
}

// An agent's stderr goes to its session's log, cut to the last 1 MB at each launch. ponytail: one long run can still grow it past 1 MB.
func agentLog(_ path: String?) throws -> (writer: FileHandle, path: String, start: UInt64) {
    let url = URL(fileURLWithPath: path ?? FileManager.default.temporaryDirectory.appendingPathComponent("vcx-agent-" + UUID().uuidString + ".log").path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if let data = try? Data(contentsOf: url), data.count > 1 << 20 { try data.suffix(1 << 20).write(to: url) }
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    let writer = try FileHandle(forWritingTo: url)
    return (writer, url.path, try writer.seekToEnd())
}

// The last 4 KB this run wrote to its log.
func agentLogTail(_ log: (path: String, start: UInt64)?) -> String {
    guard let log, let handle = FileHandle(forReadingAtPath: log.path) else { return "" }
    defer { try? handle.close() }
    let end = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: max(log.start, end > 4096 ? end - 4096 : 0))
    return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
}

// Why an agent stopped, for the notice; empty for the TERM or HUP that stops it on purpose (Claude catches both and exits 143 or 129).
func agentCrash(_ process: Process, log: (path: String, start: UInt64)?) -> JSON {
    let status = process.terminationStatus, signaled = process.terminationReason == .uncaughtSignal
    guard !(signaled ? [SIGTERM, SIGHUP] : [128 + SIGTERM, 128 + SIGHUP]).contains(status) else { return [:] }
    var crash: JSON = ["reason": signaled ? "killed by signal \(status)" : "exited with code \(status)"]
    crash["line"] = lastErrorLine(agentLogTail(log)); crash["log"] = log?.path
    return crash
}

// Stack frames and Node's version banner name no cause; a line that says error or failed does.
func lastErrorLine(_ text: String) -> String? {
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("at ") && !$0.hasPrefix("Node.js v") && !$0.allSatisfy { "^~ ".contains($0) } }
    let line = lines.last { $0.range(of: "error|fatal|failed|exception|panic|abort", options: [.regularExpression, .caseInsensitive]) != nil } ?? lines.last
    return line.map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
}

func endProcess(_ process: Process, signal: Int32 = SIGTERM) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    if getpgid(pid) == pid { kill(-pid, signal) }
    else { kill(pid, signal) }
}
