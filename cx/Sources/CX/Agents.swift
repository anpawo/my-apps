import Foundation
import AppKit
import ImageIO
import CFNetwork

func usageLimit(_ value: JSON) -> Bool {
    let code = (value["error"] as? JSON)?["codexErrorInfo"] ?? value["codexErrorInfo"] ?? value["error"] ?? value["subtype"] ?? ""
    let text = String(describing: code).lowercased()
    return ["usagelimitexceeded", "usage_limit", "rate_limit", "rate limit exceeded", "usage limit"].contains { text.contains($0) }
}

func limitReset(_ value: JSON) -> Double {
    for key in ["resetsAt", "resetAt", "resets_at"] {
        if let time = value[key] as? Double, time > Date().timeIntervalSince1970 { return time }
        if let text = value[key] as? String, let date = ISO8601DateFormatter().date(from: text) { return max(date.timeIntervalSince1970, Date().timeIntervalSince1970 + 1) }
    }
    return Date().timeIntervalSince1970 + 300
}

@MainActor
final class ClaudeConnection: Connection {
    var event: (JSON) -> Void = { _ in }
    let account: Account
    let cwd: String
    var thread = "claude:" + UUID().uuidString.lowercased()
    var model = "Claude"
    var history = ""
    private var process: Process?
    private var input: FileHandle?
    private var turn = ""
    private var closed = false
    private var tools: [String: JSON] = [:]
    private var controls: [String: JSON] = [:]
    private var blocks: [Int: (id: String, text: String)] = [:]
    private var messageID = ""
    private var lastAnswer = ""
    private var limit: JSON?
    private var stopped = false
    private var command: [String]?
    private var pendingUsers: [String] = []
    private var metadata: JSON?
    private var waiting: [String: CheckedContinuation<JSON, Error>] = [:]
    private var timers: [String: DispatchWorkItem] = [:]
    private var mode = Settings.shared.value.mode
    init(account: Account, cwd: String) { self.account = account; self.cwd = cwd }
    func start(command: [String]? = nil) async throws {
        self.command = command
        guard command == nil else { return }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "auth", "status", "--json"]
        process.environment = agentEnvironment(account)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { endProcess(process, signal: SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = await Task.detached {
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return data
        }.value
        timeout.cancel()
        guard let status = try? JSONSerialization.jsonObject(with: data) as? JSON,
              status["loggedIn"] as? Bool == true, status["authMethod"] as? String == "claude.ai" else {
            throw CXError(message: "Sign in with a Claude subscription in Settings. vcx does not use API-key billing.")
        }
    }
    private func launch(resume: Bool) throws {
        let process = Process(), incoming = Pipe(), outgoing = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command ?? (["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", mode == "bypass" ? "bypassPermissions" : "default"] +
            [resume ? "--resume" : "--session-id", String(thread.dropFirst(7))] + (model == "Claude" ? [] : ["--model", model]))
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = agentEnvironment(account)
        process.standardInput = incoming; process.standardOutput = outgoing; process.standardError = FileHandle.nullDevice
        try process.run(); self.process = process; input = incoming.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            while true {
                let data = outgoing.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                guard buffer.count <= 32 * 1024 * 1024 else { break }
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? JSON else { continue }
                    DispatchQueue.main.async { self?.receive(message) }
                }
            }
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.process = nil
                self.emit("cx/disconnected", ["message": "Claude disconnected. Reconnect to continue the saved conversation."])
            }
        }
    }
    private var resumed = false
    func request(_ method: String, _ params: JSON = [:], timeout: Double = 120) async throws -> JSON {
        switch method {
        case "thread/start": mode = params["approvalPolicy"] as? String == "never" ? "bypass" : "ask"; return ["thread": ["id": thread], "model": model]
        case "thread/resume":
            if let approval = params["approvalPolicy"] as? String { mode = approval == "never" ? "bypass" : "ask" }
            guard let id = params["threadId"] as? String else { throw CXError(message: "Missing Claude conversation ID.") }
            if let value = params["model"] as? String {
                if process != nil {
                    if let effort = params["effort"] {
                        _ = try await controlResult(["subtype": "apply_flag_settings", "settings": ["model": value, "effortLevel": effort]], timeout: 15)
                    } else { _ = try await controlResult(["subtype": "set_model", "model": value], timeout: 15) }
                }
                model = value
            }
            thread = id; resumed = true; return ["thread": ["id": thread], "model": model]
        case "thread/turns/list": return ["data": []]
        case "model/list":
            let catalog = try await catalog()
            return ["data": (catalog["models"] as? [JSON] ?? []).compactMap { ($0["value"] as? String).map { ["id": $0] } }]
        case "cx/catalog":
            var result = try await catalog()
            do {
                let status = try await controlResult(["subtype": "mcp_status"], timeout: 10)
                result["mcp_servers"] = status["mcpServers"] ?? status["mcp_servers"]
            } catch { result["mcp_servers"] = [["name": "MCP status", "status": error.localizedDescription]] }
            return result
        case "thread/list", "account/rateLimits/read": return [:]
        case "turn/start", "turn/steer":
            if process == nil { try launch(resume: resumed); resumed = true }
            let content = try claudeContent(params["input"] as? [JSON] ?? [])
            let steering = method == "turn/steer"
            if !steering, let effort = params["effort"] as? String {
                _ = try await controlResult(["subtype": "apply_flag_settings", "settings": ["effortLevel": effort]], timeout: 15)
            }
            if steering, params["expectedTurnId"] as? String != turn { throw CXError(message: "The Claude turn has changed. Your draft has been kept.") }
            if !steering {
                turn = UUID().uuidString; stopped = false; lastAnswer = ""; limit = nil
                tools.removeAll(); blocks.removeAll(); pendingUsers.removeAll()
            }
            let userID = params["clientUserMessageId"] as? String ?? UUID().uuidString
            try write(["type": "user", "uuid": userID, "message": ["role": "user", "content": content]])
            resumed = true; pendingUsers.append(userID)
            if !steering { emit("turn/started", ["turn": ["id": turn]]) }
            return ["turn": ["id": turn]]
        case "turn/interrupt": stopped = true; try control(["subtype": "interrupt"]); return [:]
        case "thread/compact/start": throw CXError(message: "Claude manages context compaction automatically.")
        case "review/start": throw CXError(message: "Ask Claude to review your changes in a message.")
        default: throw CXError(message: "Unsupported Claude action: \(method)")
        }
    }
    private func claudeContent(_ pieces: [JSON]) throws -> [JSON] {
        var content: [JSON] = []
        if !history.isEmpty { content.append(["type": "text", "text": history]); history = "" }
        for piece in pieces {
            if piece["type"] as? String == "text" { content.append(["type": "text", "text": piece["text"] as? String ?? ""]) }
            else if let path = piece["path"] as? String {
                let (data, media) = try agentImage(path)
                content.append(["type": "image", "source": ["type": "base64", "media_type": media, "data": data.base64EncodedString()]])
            }
        }
        return content
    }
    func emit(_ method: String, _ params: JSON) {
        var params = params; params["threadId"] = thread
        event(["method": method, "params": params])
    }
    func receive(_ message: JSON) {
        if message["parent_tool_use_id"] is String { return }
        switch message["type"] as? String {
        case "control_response":
            let response = message["response"] as? JSON ?? [:]
            if let id = response["request_id"] as? String {
                timers.removeValue(forKey: id)?.cancel()
                if response["subtype"] as? String == "error" { waiting.removeValue(forKey: id)?.resume(throwing: CXError(message: response["error"] as? String ?? "Claude rejected the control request.")) }
                else { waiting.removeValue(forKey: id)?.resume(returning: response["response"] as? JSON ?? [:]) }
            }
        case "system":
            if message["subtype"] as? String == "init", let model = message["model"] as? String { self.model = model; emit("cx/model", ["model": model]) }
        case "control_cancel_request":
            if let id = message["request_id"] as? String { controls.removeValue(forKey: id); emit("serverRequest/resolved", ["requestId": id]) }
        case "control_request":
            guard let id = message["request_id"] as? String, let request = message["request"] as? JSON else { return }
            guard request["subtype"] as? String == "can_use_tool" else {
                try? write(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Unsupported control request"]]); return
            }
            controls[id] = request
            let name = request["tool_name"] as? String ?? "Tool", input = request["input"] as? JSON ?? [:]
            var params: JSON = ["threadId": thread, "command": input["command"] as? String ?? name + "\n" + pretty(input), "reason": request["decision_reason"] as? String ?? "Claude requests permission for \(name)."]
            let method: String
            if name == "AskUserQuestion" {
                method = "item/tool/requestUserInput"
                params["questions"] = (input["questions"] as? [JSON] ?? []).enumerated().map { n, q in var q = q; q["id"] = q["question"] as? String ?? "\(n)"; return q }
            } else { method = "item/commandExecution/requestApproval" }
            event(["id": id, "method": method, "params": params])
        case "stream_event":
            let e = message["event"] as? JSON ?? [:], index = e["index"] as? Int ?? 0
            switch e["type"] as? String {
            case "message_start": messageID = ((e["message"] as? JSON)?["id"] as? String ?? UUID().uuidString)
            case "content_block_start":
                let block = e["content_block"] as? JSON ?? [:]
                if block["type"] as? String == "text" {
                    let id = messageID + "-\(index)"; blocks[index] = (id, block["text"] as? String ?? "")
                    emit("item/started", ["item": ["id": id, "type": "agentMessage", "text": block["text"] as? String ?? "", "provider": "Claude"]])
                }
            case "content_block_delta":
                let delta = e["delta"] as? JSON ?? [:]
                if let text = delta["text"] as? String, var block = blocks[index] {
                    block.text += text; blocks[index] = block
                    emit("item/agentMessage/delta", ["itemId": block.id, "delta": text])
                }
            default: break
            }
        case "assistant":
            if message["error"] as? String == "rate_limit" { limit = ["error": "rate_limit"]; return }
            let body = message["message"] as? JSON ?? [:], id = body["id"] as? String ?? UUID().uuidString
            if let usage = body["usage"] as? JSON {
                let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"].compactMap { usage[$0] as? Int }.reduce(0, +)
                emit("cx/context", ["used": used])
            }
            for (index, block) in (body["content"] as? [JSON] ?? []).enumerated() {
                if block["type"] as? String == "text", let text = block["text"] as? String {
                    lastAnswer = text
                    emit("item/completed", ["item": ["id": id + "-\(index)", "type": "agentMessage", "text": text, "provider": "Claude"]])
                } else if block["type"] as? String == "tool_use", let toolID = block["id"] as? String {
                    let input = block["input"] as? JSON ?? [:], name = block["name"] as? String ?? "Tool"
                    let tool: JSON = ["id": toolID, "type": "commandExecution", "command": input["command"] as? String ?? name + "\n" + pretty(input), "status": "inProgress"]
                    tools[toolID] = tool; emit("item/started", ["item": tool])
                }
            }
        case "user":
            for block in (message["message"] as? JSON)?["content"] as? [JSON] ?? [] {
                if let id = block["tool_use_id"] as? String, var tool = tools[id] {
                    tool["aggregatedOutput"] = String((block["content"] as? String ?? pretty(block["content"] ?? "")).suffix(16384))
                    tool["status"] = block["is_error"] as? Bool == true ? "failed" : "completed"
                    tools[id] = tool; emit("item/completed", ["item": tool])
                }
            }
        case "rate_limit_event":
            let info = message["rate_limit_info"] as? JSON ?? [:]
            emit("cx/claudeLimit", info)
            if info["status"] as? String == "rejected" { limit = info }
        case "result":
            if let models = message["modelUsage"] as? [String: JSON], let limit = models[model]?["contextWindow"] as? Int { emit("cx/context", ["limit": limit]) }
            if let usage = message["usage"] as? JSON {
                let input = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].compactMap { usage[$0] as? Int }.reduce(0, +)
                emit("cx/tokens", ["input": input, "output": usage["output_tokens"] as? Int ?? 0])
            }
            if let limit { emit("cx/limit", ["limit": limit]); return }
            if usageLimit(message) { emit("cx/limit", ["limit": message]); return }
            let ids = message["user_message_uuids"] as? [String] ?? (message["user_message_uuid"] as? String).map { [$0] } ?? []
            if ids.isEmpty { if !pendingUsers.isEmpty { pendingUsers.removeFirst() } }
            else { pendingUsers.removeAll { ids.contains($0) } }
            let queued = message["queued_turn_count"] as? Int
            if queued == 0 || stopped || message["is_error"] as? Bool == true { pendingUsers.removeAll() }
            if !pendingUsers.isEmpty || (queued ?? 0) > 0 { return }
            var result: JSON = ["id": turn, "status": stopped ? "interrupted" : "completed"]
            if message["is_error"] as? Bool == true { result["error"] = ["message": message["result"] as? String ?? "Claude did not finish the turn."] }
            emit("turn/completed", ["turn": result])
        default: break
        }
    }
    func respond(_ id: Any, _ result: JSON) throws {
        let key = String(describing: id)
        guard let request = controls[key] else { throw CXError(message: "This Claude request has expired.") }
        var updated = request["input"] as? JSON ?? [:]
        var response: JSON
        if let answers = result["answers"] as? [String: JSON], !answers.isEmpty {
            updated["answers"] = answers.mapValues { ($0["answers"] as? [String] ?? []).joined(separator: ", ") }
            response = ["behavior": "allow", "updatedInput": updated]
        } else if result["decision"] as? String == "accept" { response = ["behavior": "allow", "updatedInput": updated] }
        else { response = ["behavior": "deny", "message": "The user declined this action."] }
        try write(["type": "control_response", "response": ["subtype": "success", "request_id": key, "response": response]])
        controls.removeValue(forKey: key)
    }
    func reject(_ id: Any, method: String) throws { try respond(id, ["decision": "decline"]) }
    private func catalog() async throws -> JSON {
        if let metadata { return metadata }
        if process == nil { try launch(resume: resumed) }
        let result = try await controlResult(["subtype": "initialize"], timeout: 20)
        metadata = result
        if model == "Claude", let resolved = (result["models"] as? [JSON])?.first(where: { $0["value"] as? String == "default" })?["resolvedModel"] as? String { model = resolved; emit("cx/model", ["model": resolved]) }
        emit("cx/catalog", result); return result
    }
    private func controlResult(_ request: JSON, timeout: Double) async throws -> JSON {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                timers.removeValue(forKey: id)
                waiting.removeValue(forKey: id)?.resume(throwing: CXError(message: "Claude metadata request timed out."))
            }
            timers[id] = timer; DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
            do { try write(["type": "control_request", "request_id": id, "request": request]) }
            catch { timers.removeValue(forKey: id)?.cancel(); waiting.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }
    private func control(_ request: JSON) throws { try write(["type": "control_request", "request_id": UUID().uuidString, "request": request]) }
    private func write(_ message: JSON) throws {
        guard let input, process?.isRunning == true else { throw CXError(message: "Claude is disconnected.") }
        try input.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([10]))
    }
    func close() {
        for timer in timers.values { timer.cancel() }; timers.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: CXError(message: "Claude is disconnected.")) }; waiting.removeAll()
        closed = true; try? input?.close(); input = nil; if let process { endProcess(process) }; process = nil }
}

func pretty(_ value: Any) -> String {
    if let text = value as? String { return text }
    return (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

@MainActor
final class QwenConnection: Connection {
    var event: (JSON) -> Void = { _ in }
    var thread = "qwen:" + UUID().uuidString
    var messages: [JSON] = [["role": "system", "content": "You are Qwen in Vibe Code X, a coding assistant. Use run_command to inspect or change files when the user asks. Check the project instructions before changing code. Never claim to have performed an action unless its tool result confirms it. Stop when the task is complete."]]
    private var task: Task<Void, Never>?
    private var turn = ""
    let preferences: Preferences
    let cwd: String
    private var selectedModel: String?
    private var permissions: [String: CheckedContinuation<Bool, Never>] = [:]
    private var commandProcess: Process?
    private var network: URLSession?
    private func connection() throws -> URLSession {
        if let network { return network }
        let session = try qwenNetwork(preferences); network = session; return session
    }
    init(preferences: Preferences, cwd: String = FileManager.default.currentDirectoryPath) { self.preferences = preferences; self.cwd = cwd }
    func start(command: [String]? = nil) async throws {}
    func request(_ method: String, _ params: JSON = [:], timeout: Double = 120) async throws -> JSON {
        switch method {
        case "thread/start", "thread/resume":
            if let id = params["threadId"] as? String { thread = id }
            if let model = params["model"] as? String { selectedModel = model }
            return ["thread": ["id": thread], "model": selectedModel ?? preferences.qwenModel]
        case "thread/turns/list", "thread/list": return ["data": []]
        case "account/rateLimits/read": return [:]
        case "model/list": return ["data": [["id": preferences.qwenModel], ["id": preferences.qwenVisionModel]]]
        case "turn/start":
            guard let url = URL(string: preferences.qwenURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw CXError(message: "Set a valid Ollama URL in Settings.") }
            let pieces = params["input"] as? [JSON] ?? []
            let text = pieces.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let images = try pieces.compactMap { piece -> String? in
                guard let path = piece["path"] as? String else { return nil }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard data.count <= 20 * 1024 * 1024 else { throw CXError(message: "Image is larger than 20 MB.") }
                return data.base64EncodedString()
            }
            var message: JSON = ["role": "user", "content": text]
            if !images.isEmpty { message["images"] = images }
            messages.append(message)
            // Bound remote context without loading a local model or asking another model to summarize.
            if messages.count > 41 { messages.removeSubrange(1..<(messages.count - 40)) }
            turn = UUID().uuidString
            let current = turn, item = UUID().uuidString
            emit("turn/started", ["turn": ["id": current]])
            task = Task {
                do {
                    for _ in 0..<12 {
                        try Task.checkCancellation()
                        let (answer, calls) = try await completion(url: url, model: images.isEmpty ? selectedModel ?? preferences.qwenModel : preferences.qwenVisionModel, item: item)
                        if !calls.isEmpty {
                            messages.append(["role": "assistant", "content": answer, "tool_calls": calls])
                            for call in calls {
                                let function = call["function"] as? JSON ?? [:]
                                let arguments = function["arguments"] as? JSON ?? [:]
                                let name = function["name"] as? String ?? ""
                                let result: String
                                if name == "run_command", let command = arguments["command"] as? String, !command.isEmpty, command.utf8.count < 65536, !command.contains("\0") {
                                    result = try await commandResult(command)
                                } else { result = "Unsupported or invalid tool request. No command was executed." }
                                messages.append(["role": "tool", "tool_name": name, "content": result])
                            }
                            continue
                        }
                        messages.append(["role": "assistant", "content": answer])
                        emit("turn/completed", ["turn": ["id": current, "status": "completed"]])
                        task = nil
                        return
                    }
                    throw CXError(message: "Qwen reached 12 tool steps. Send a message to continue.")
                } catch {
                    let cancelled = Task.isCancelled
                    var result: JSON = ["id": current, "status": cancelled ? "interrupted" : "failed"]
                    if !cancelled { result["error"] = ["message": error.localizedDescription] }
                    emit("turn/completed", ["turn": result])
                }
                task = nil
            }
            return ["turn": ["id": current]]
        case "turn/steer": throw CXError(message: "Stop Qwen before sending another message. Your draft has been kept.")
        case "turn/interrupt":
            task?.cancel(); if let commandProcess { endProcess(commandProcess, signal: SIGKILL) }
            for continuation in permissions.values { continuation.resume(returning: false) }
            permissions.removeAll(); return [:]
        default: throw CXError(message: "Qwen does not support this action. Send your request as a message.")
        }
    }
    private func emit(_ method: String, _ params: JSON) { var p = params; p["threadId"] = thread; event(["method": method, "params": p]) }
    private func completion(url: URL, model: String, item: String) async throws -> (String, [JSON]) {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let tool: JSON = ["type": "function", "function": ["name": "run_command", "description": "Run a shell command in the project folder using the configured permission mode. Use for inspecting or changing code. Commands time out after two minutes.", "parameters": ["type": "object", "properties": ["command": ["type": "string"]], "required": ["command"]]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": messages, "stream": true, "keep_alive": "5m", "think": false, "tools": [tool]])
        let (bytes, response) = try await connection().bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CXError(message: "Qwen server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Check Settings and the remote machine.") }
        var answer = "", calls: [JSON] = []
        let id = item + "-" + UUID().uuidString
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON else { continue }
            if let error = event["error"] as? String { throw CXError(message: error) }
            let message = event["message"] as? JSON ?? [:]
            let delta = message["content"] as? String ?? ""
            answer += delta
            calls += message["tool_calls"] as? [JSON] ?? []
            if event["done"] as? Bool == true { emit("cx/tokens", ["input": event["prompt_eval_count"] as? Int ?? 0, "output": event["eval_count"] as? Int ?? 0]) }
            emit("item/agentMessage/delta", ["itemId": id, "delta": delta])
        }
        if !answer.isEmpty { emit("item/completed", ["item": ["id": id, "type": "agentMessage", "text": answer, "provider": "Qwen"]]) }
        return (answer, calls)
    }

    private func commandResult(_ command: String) async throws -> String {
        let id = UUID().uuidString
        emit("item/started", ["item": ["id": id, "type": "commandExecution", "command": command, "status": "inProgress"]])
        let allowed = preferences.mode == "bypass" ? true : await withCheckedContinuation { continuation in
            permissions[id] = continuation
            event(["id": id, "method": "item/commandExecution/requestApproval", "params": ["threadId": thread, "command": command, "reason": "Qwen wants to run this command in " + cwd]])
        }
        emit("serverRequest/resolved", ["requestId": id])
        guard allowed, !Task.isCancelled else {
            emit("item/completed", ["item": ["id": id, "type": "commandExecution", "command": command, "status": "declined"]])
            return "The user declined this command. Do not retry it."
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd); process.environment = agentEnvironment()
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
        try process.run(); commandProcess = process
        let timeout = DispatchWorkItem { if process.isRunning { endProcess(process, signal: SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        let result: (String, Int32) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var buffer = Data()
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    if buffer.count > 16384 { buffer = Data(buffer.suffix(16384)) }
                }
                process.waitUntilExit()
                continuation.resume(returning: (String(decoding: buffer, as: UTF8.self), process.terminationStatus))
            }
        }
        timeout.cancel(); commandProcess = nil
        emit("item/completed", ["item": ["id": id, "type": "commandExecution", "command": command, "aggregatedOutput": result.0, "exitCode": result.1, "status": result.1 == 0 ? "completed" : "failed"]])
        return "Exit: \(result.1)\n" + result.0
    }
    func respond(_ id: Any, _ result: JSON) throws { permissions.removeValue(forKey: String(describing: id))?.resume(returning: result["decision"] as? String == "accept") }
    func reject(_ id: Any, method: String) throws { permissions.removeValue(forKey: String(describing: id))?.resume(returning: false) }
    func close() {
        task?.cancel(); if let commandProcess { endProcess(commandProcess, signal: SIGKILL) }
        for continuation in permissions.values { continuation.resume(returning: false) }
        permissions.removeAll(); task = nil; network?.invalidateAndCancel()
    }
}

func validQwenProxy(_ text: String) -> Bool {
    guard let url = URL(string: text), ["socks5", "socks5h"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil else { return false }; return true
}

func qwenNetwork(_ preferences: Preferences) throws -> URLSession {
    guard preferences.qwenProxy.isEmpty || validQwenProxy(preferences.qwenProxy) else { throw CXError(message: "Invalid Qwen proxy. Set /qwen proxy socks5://host:port or /qwen proxy none. No request was sent.") }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    if !preferences.qwenProxy.isEmpty, let proxy = URL(string: preferences.qwenProxy), let host = proxy.host, let port = proxy.port {
        configuration.connectionProxyDictionary = [kCFNetworkProxiesSOCKSEnable as String: 1, kCFNetworkProxiesSOCKSProxy as String: host, kCFNetworkProxiesSOCKSPort as String: port]
    }
    return URLSession(configuration: configuration)
}
