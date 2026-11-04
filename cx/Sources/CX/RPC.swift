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
}

extension Connection {
    func request(_ method: String, _ params: JSON = [:]) async throws -> JSON { try await request(method, params, timeout: 120) }
}

@MainActor
final class RPC: Connection {
    var event: (JSON) -> Void = { _ in }
    var account: Account?
    var cwd: String?
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
        process.environment = agentEnvironment(account)
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardInput = incoming
        process.standardOutput = outgoing
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = incoming.fileHandleForWriting
        let reader = try ProviderJSONReader(handle: outgoing.fileHandleForReading, receive: { [weak self] message in
            guard let self, !closed else { return }; receive(message)
        }, invalid: { [weak self] message in
            guard let self, !closed else { return }
            event(["method": "cx/error", "params": ["message": message.replacingOccurrences(of: "Provider", with: "Codex")]])
        }, disconnected: { [weak self] in self?.disconnected() })
        self.reader = reader; reader.start()
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
        close()
        event(["method": "cx/disconnected", "params": ["message": "Codex disconnected. Reconnect to continue; your conversation is saved."]])
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

func endProcess(_ process: Process, signal: Int32 = SIGTERM) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    if getpgid(pid) == pid { kill(-pid, signal) }
    else { kill(pid, signal) }
}
