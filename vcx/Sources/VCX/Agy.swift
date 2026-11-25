import Foundation

// Google's Antigravity CLI (`agy`) spoken to over the Agent Client Protocol (`agy acp`, JSON-RPC 2.0 on stdio),
// translated into the Codex app-server events a Session already handles. Its rules, skills, MCP servers and hooks
// are agy's own user configuration (~/.gemini), set up to match Claude Code's.
@MainActor
final class AgyConnection: Connection {
    var archiveProcess: Process? { process }
    private(set) var archiveClientVersion: String?
    var event: (JSON) -> Void = { _ in }
    var fleetFile: String?
    var logFile: String?
    private(set) var cwd: String
    private var thread = ""
    private var session = ""
    private var bypass = true
    private var models: [String] = []
    private var model = ""
    private var process: Process?
    private var input: FileHandle?
    private var reader: ProviderJSONReader?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var permissions: [String: (rpcID: Any, allow: String, deny: String)] = [:]
    private var closed = false
    private var turn: String?
    private var message: (id: String, text: String)?
    private var thought: (id: String, text: String, start: Date)?
    private var tools: [String: JSON] = [:]
    // A first answer can take a while on a big context; a stuck request still ends.
    nonisolated static let requestTimeout: Double = 120

    init(cwd: String) { self.cwd = cwd }

    func start(command: [String]? = nil) async throws {
        if command == nil { archiveClientVersion = await nativeClientVersion("agy", environment: agentEnvironment(fleet: fleetFile)) }
        let process = Process(), incoming = Pipe(), outgoing = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command ?? ["agy", "acp"]
        process.environment = agentEnvironment(fleet: fleetFile)
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = incoming; process.standardOutput = outgoing
        let errors = try agentLog(logFile)
        process.standardError = errors.writer
        do { try process.run() } catch { throw CXError(message: "Antigravity is not installed: brew install --cask antigravity-cli") }
        try? errors.writer.close()
        self.process = process; input = incoming.fileHandleForWriting
        let reader = try ProviderJSONReader(handle: outgoing.fileHandleForReading, leftover: Data(), receive: { [weak self] message in
            guard let self, !closed else { return }; receive(message)
        }, invalid: { [weak self] text in
            guard let self, !closed else { return }
            event(["method": "cx/error", "params": ["message": text.replacingOccurrences(of: "Provider", with: "Antigravity")]])
        }, disconnected: { [weak self] in
            guard let self, !closed else { return }
            closed = true
            event(["method": "cx/disconnected", "params": ["message": "Antigravity stopped."]])
        })
        self.reader = reader; reader.start()
        _ = try await call("initialize", ["protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                                          "clientInfo": ["name": "vcx", "title": "Vibe Code X", "version": "0.2.0"]], timeout: 30)
    }

    func request(_ method: String, _ params: JSON = [:], timeout: Double = 120) async throws -> JSON {
        switch method {
        case "thread/start", "thread/resume":
            if let policy = params["approvalPolicy"] as? String { bypass = policy == "never" }
            if let path = params["cwd"] as? String { cwd = path }
            let wanted = (params["threadId"] as? String).map { String($0.dropFirst($0.hasPrefix("agy:") ? 4 : 0)) }
            if let wanted, wanted == session {
                if let next = params["model"] as? String, next != model { _ = try await call("session/set_model", ["sessionId": session, "modelId": next]); model = next }
                return ["thread": ["id": thread], "model": model]
            }
            var open: JSON = ["cwd": cwd, "mcpServers": [JSON]()]
            if let instructions = params["developerInstructions"] as? String, !instructions.isEmpty { open["_meta"] = ["antigravity": ["systemPrompt": ["append": instructions]]] }
            let result: JSON
            if let wanted { open["sessionId"] = wanted; result = try await call("session/resume", open, timeout: 60) }
            else { result = try await call("session/new", open, timeout: 60) }
            session = result["sessionId"] as? String ?? wanted ?? ""
            guard !session.isEmpty else { throw CXError(message: "Antigravity did not return a conversation.") }
            thread = "agy:" + session
            let list = result["models"] as? JSON
            models = (list?["availableModels"] as? [JSON] ?? []).compactMap { $0["modelId"] as? String }
            model = list?["currentModelId"] as? String ?? model
            if let next = params["model"] as? String, next != model, models.contains(next) { _ = try await call("session/set_model", ["sessionId": session, "modelId": next]); model = next }
            try await applyMode()
            return ["thread": ["id": thread], "model": model]
        case "thread/turns/list", "thread/list": return ["data": []]
        case "account/rateLimits/read", "config/read": return [:]
        case "model/list": return ["data": models.map { ["id": $0] }]
        case "cx/mode":
            bypass = params["mode"] as? String == "bypass"
            try await applyMode(); return [:]
        case "turn/start":
            guard turn == nil else { throw CXError(message: "Stop Antigravity before sending another message. Your draft has been kept.") }
            if let path = params["cwd"] as? String { cwd = path }
            let prompt = try (params["input"] as? [JSON] ?? []).compactMap { piece -> JSON? in
                if let text = piece["text"] as? String { return ["type": "text", "text": text] }
                guard let path = piece["path"] as? String else { return nil }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let type = ["png": "image/png", "gif": "image/gif", "webp": "image/webp"][URL(fileURLWithPath: path).pathExtension.lowercased()] ?? "image/jpeg"
                return ["type": "image", "mimeType": type, "data": data.base64EncodedString()]
            }
            let current = UUID().uuidString
            turn = current
            emit("turn/started", ["turn": ["id": current]])
            Task { await run(current, prompt) }
            return ["turn": ["id": current]]
        case "turn/steer": throw CXError(message: "Stop Antigravity before sending another message. Your draft has been kept.")
        case "turn/interrupt":
            if !session.isEmpty { try? send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": session]]) }
            return [:]
        default: throw CXError(message: "Antigravity does not support this action. Send your request as a message.")
        }
    }

    private func run(_ current: String, _ prompt: [JSON]) async {
        var status = "completed", failure: String?
        do {
            // A turn runs as long as the agent works: no timeout here, Stop cancels it.
            let result = try await call("session/prompt", ["sessionId": session, "prompt": prompt], timeout: .infinity)
            if result["stopReason"] as? String == "cancelled" { status = "interrupted" }
            if let usage = result["usage"] as? JSON, let input = usage["inputTokens"] as? Int, let output = usage["outputTokens"] as? Int { emit("cx/tokens", ["input": input, "output": output]) }
        } catch { status = "failed"; failure = error.localizedDescription }
        endMessage(); endThought()
        for (id, var item) in tools { item["status"] = status == "completed" ? "completed" : "failed"; tools[id] = nil; emit("item/completed", ["item": item]) }
        var result: JSON = ["id": current, "status": status]
        if let failure { result["error"] = ["message": failure] }
        turn = nil
        emit("turn/completed", ["turn": result])
    }

    private func applyMode() async throws {
        // VCX's bypass answers every permission itself; "auto" only keeps agy from asking for the safe ones.
        guard !session.isEmpty else { return }
        _ = try await call("session/set_mode", ["sessionId": session, "modeId": bypass ? "auto" : "default"])
    }

    private func update(_ value: JSON) {
        switch value["sessionUpdate"] as? String ?? "" {
        case "agent_message_chunk":
            endThought()
            let text = (value["content"] as? JSON)?["text"] as? String ?? ""
            if message == nil { message = (UUID().uuidString, "") }
            message!.text += text
            emit("item/agentMessage/delta", ["itemId": message!.id, "delta": text])
        case "agent_thought_chunk":
            let text = (value["content"] as? JSON)?["text"] as? String ?? ""
            if thought == nil {
                thought = (UUID().uuidString, "", Date())
                emit("item/started", ["item": ["id": thought!.id, "type": "reasoning", "description": "Thinking", "stepStartedAt": thought!.start.timeIntervalSince1970]])
            }
            thought!.text += text
        case "tool_call", "tool_call_update":
            endMessage(); endThought()
            guard let id = value["toolCallId"] as? String else { return }
            var item = tools[id] ?? toolItem(value)
            let status = value["status"] as? String ?? ""
            if tools[id] == nil, !["completed", "failed"].contains(status) { tools[id] = item; emit("item/started", ["item": item]); return }
            guard ["completed", "failed"].contains(status) else { return }
            tools[id] = nil
            let raw = value["rawOutput"] as? JSON
            let text = raw?["output"] as? String ?? (value["content"] as? [JSON] ?? []).compactMap { ($0["content"] as? JSON)?["text"] as? String }.joined(separator: "\n")
            if item["type"] as? String == "commandExecution" {
                item["aggregatedOutput"] = text
                item["exitCode"] = raw?["exit_code"] as? Int ?? (status == "failed" ? 1 : 0)
            }
            item["status"] = status
            emit("item/completed", ["item": item])
        case "usage_update":
            emit("cx/context", ["used": value["used"] as? Int ?? 0, "limit": value["size"] as? Int ?? 0, "model": model])
        case "current_model_update":
            if let next = value["currentModelId"] as? String ?? value["modelId"] as? String { model = next; emit("cx/model", ["model": next]) }
        default: break
        }
    }

    // A shell call is shown as its command line; an edit as the files it changes; any other tool as its name over its input.
    private func toolItem(_ value: JSON) -> JSON {
        let id = value["toolCallId"] as? String ?? UUID().uuidString
        let input = value["rawInput"] as? JSON ?? [:], kind = value["kind"] as? String ?? ""
        let diffs = (value["content"] as? [JSON] ?? []).filter { $0["type"] as? String == "diff" }
        if kind == "edit", !diffs.isEmpty {
            let changes = diffs.map { diff -> JSON in
                let old = (diff["oldText"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }
                let new = (diff["newText"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
                return ["path": diff["path"] as? String ?? "", "kind": "update", "diff": (old + new).joined(separator: "\n")]
            }
            return ["id": id, "type": "fileChange", "changes": changes, "status": "inProgress"]
        }
        let command: String
        if kind == "execute", let line = input["CommandLine"] as? String ?? input["command"] as? String { command = line }
        else {
            let name = value["name"] as? String ?? value["title"] as? String ?? "tool"
            let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            command = name + "\n" + json
        }
        return ["id": id, "type": "commandExecution", "command": command, "cwd": input["Cwd"] as? String ?? cwd, "status": "inProgress",
                "description": kind == "execute" ? "" : value["title"] as? String ?? "", "stepStartedAt": Date().timeIntervalSince1970]
    }

    private func endMessage() {
        guard let message else { return }
        self.message = nil
        if !message.text.isEmpty { emit("item/completed", ["item": ["id": message.id, "type": "agentMessage", "text": message.text, "provider": "Antigravity"]]) }
    }

    private func endThought() {
        guard let thought else { return }
        self.thought = nil
        emit("item/completed", ["item": ["id": thought.id, "type": "reasoning", "description": "Thinking", "summary": [thought.text], "status": "completed",
                                         "seconds": Int(Date().timeIntervalSince(thought.start).rounded())]])
    }

    private func permission(_ rpcID: Any, _ params: JSON) {
        let options = params["options"] as? [JSON] ?? []
        let allow = options.first { ($0["kind"] as? String ?? "").hasPrefix("allow") }?["optionId"] as? String ?? "allow"
        let deny = options.first { ($0["kind"] as? String ?? "").hasPrefix("reject") }?["optionId"] as? String ?? "deny"
        if bypass { try? answer(rpcID, allow); return }
        let call = params["toolCall"] as? JSON ?? [:]
        let id = UUID().uuidString
        permissions[id] = (rpcID, allow, deny)
        let input = call["rawInput"] as? JSON ?? [:]
        let command = input["CommandLine"] as? String ?? call["title"] as? String ?? call["name"] as? String ?? "an action"
        event(["id": id, "method": "item/commandExecution/requestApproval", "params": ["threadId": thread, "command": command, "reason": "Antigravity wants to run this in " + cwd]])
    }

    private func answer(_ rpcID: Any, _ option: String) throws {
        try send(["jsonrpc": "2.0", "id": rpcID, "result": ["outcome": ["outcome": "selected", "optionId": option]]])
    }

    func respond(_ id: Any, _ result: JSON) throws {
        guard let waiting = permissions.removeValue(forKey: String(describing: id)) else { return }
        emit("serverRequest/resolved", ["requestId": String(describing: id)])
        try answer(waiting.rpcID, result["decision"] as? String == "accept" ? waiting.allow : waiting.deny)
    }

    func reject(_ id: Any, method: String) throws {
        guard let waiting = permissions.removeValue(forKey: String(describing: id)) else { return }
        try answer(waiting.rpcID, waiting.deny)
    }

    private func receive(_ message: JSON) {
        let method = message["method"] as? String
        if method == "session/update" { update((message["params"] as? JSON)?["update"] as? JSON ?? [:]); return }
        if method == "session/request_permission", let id = message["id"] { permission(id, message["params"] as? JSON ?? [:]); return }
        if let method, let id = message["id"] {
            // No file system or terminal capability was offered, so agy has nothing else to ask.
            try? send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "vcx does not support \(method)"]]); return
        }
        guard let id = message["id"] as? Int, let waiting = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? JSON { waiting.resume(throwing: CXError(message: "Antigravity: " + (error["message"] as? String ?? "request failed"))) }
        else { waiting.resume(returning: message["result"] as? JSON ?? [:]) }
    }

    private func call(_ method: String, _ params: JSON, timeout: Double = AgyConnection.requestTimeout) async throws -> JSON {
        guard !closed, process?.isRunning == true else { throw CXError(message: "Antigravity is disconnected.") }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if timeout.isFinite {
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.pending.removeValue(forKey: id)?.resume(throwing: CXError(message: "Antigravity timed out while handling \(method)."))
                }
            }
            do { try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    private func send(_ message: JSON) throws {
        guard let input, !closed else { throw CXError(message: "Antigravity is disconnected.") }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func emit(_ method: String, _ params: JSON) { var p = params; p["threadId"] = thread; event(["method": method, "params": p]) }

    func close() {
        guard !closed else { return }
        closed = true
        for waiting in pending.values { waiting.resume(throwing: CXError(message: "Antigravity is disconnected.")) }
        pending.removeAll(); permissions.removeAll()
        try? input?.close()
        if let process, process.isRunning { endProcess(process) }
    }
}
