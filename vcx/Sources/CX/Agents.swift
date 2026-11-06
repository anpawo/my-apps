import Foundation
import AppKit
import ImageIO
import CFNetwork
import CryptoKit

func readClaudeUsage(_ account: Account) async throws -> JSON {
    let directory = account.home ?? NSHomeDirectory() + "/.claude"
    let suffix = account.home.map { "-" + SHA256.hash(data: Data($0.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8) } ?? ""
    let stored = await Task.detached { () -> Data in
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials" + suffix, "-w"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        let timeout = DispatchWorkItem { if process.isRunning { endProcess(process, signal: SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        return process.terminationStatus == 0 ? data : Data()
    }.value
    let data = stored.isEmpty ? (try? Data(contentsOf: URL(fileURLWithPath: directory + "/.credentials.json"))) ?? Data() : stored
    guard let credentials = try? JSONSerialization.jsonObject(with: data) as? JSON,
          let token = (credentials["claudeAiOauth"] as? JSON)?["accessToken"] as? String, !token.isEmpty else {
        throw CXError(message: "Usage unavailable: sign in to this Claude profile.")
    }
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    request.timeoutInterval = 15
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("VibeCodeX/0.2.0", forHTTPHeaderField: "User-Agent")
    let (body, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
        throw CXError(message: "Usage unavailable: Claude returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
    }
    guard let result = try JSONSerialization.jsonObject(with: body) as? JSON else { throw CXError(message: "Usage unavailable: invalid Claude response.") }
    return result
}

func claudeRateLimits(_ usage: JSON) throws -> JSON {
    var limits: JSON = [:]
    for (source, target, minutes) in [("five_hour", "primary", 300), ("seven_day", "secondary", 10080)] {
        guard let value = usage[source] else { continue }
        let window = value as? JSON
        guard value is NSNull || window?["utilization"] is Double else { throw CXError(message: "Usage unavailable: invalid Claude window.") }
        var rate: JSON = ["usedPercent": window?["utilization"] as? Double ?? 0, "windowDurationMins": minutes]
        if let reset = window?["resets_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            rate["resetsAt"] = formatter.date(from: reset)?.timeIntervalSince1970 ?? ISO8601DateFormatter().date(from: reset)?.timeIntervalSince1970
        }
        limits[target] = rate
    }
    guard !limits.isEmpty else { throw CXError(message: "Usage unavailable: Claude returned no usage windows.") }
    return limits
}

func usageLimit(_ value: JSON) -> Bool {
    // A failed turn's error object holds the provider's own words ("not your usage limit"); only its codes are read.
    let code = (value["error"] as? JSON)?["codexErrorInfo"] ?? value["codexErrorInfo"] ?? (value["error"] is JSON ? nil : value["error"]) ?? value["subtype"] ?? ""
    let text = String(describing: code).lowercased()
    return ["usagelimitexceeded", "usage_limit", "usage limit"].contains { text.contains($0) }
}

func limitReset(_ value: JSON) -> Double {
    for key in ["resetsAt", "resetAt", "resets_at"] {
        if let time = value[key] as? Double, time > Date().timeIntervalSince1970 { return time }
        if let text = value[key] as? String, let date = ISO8601DateFormatter().date(from: text) { return max(date.timeIntervalSince1970, Date().timeIntervalSince1970 + 1) }
    }
    return Date().timeIntervalSince1970 + 300
}

func configuredClaudeEffort(account: Account, cwd: String, model: String) -> String? {
    var folders: [URL] = [], folder = URL(fileURLWithPath: cwd)
    while true {
        folders.insert(folder, at: 0)
        let parent = folder.deletingLastPathComponent()
        if parent.path == folder.path { break }; folder = parent
    }
    let files = [URL(fileURLWithPath: account.home ?? NSHomeDirectory() + "/.claude").appendingPathComponent("settings.json")] + folders.flatMap { folder in [".claude/settings.json", ".claude/settings.local.json"].map { folder.appendingPathComponent($0) } }
    var effort: String?, modelEffort: String?
    for file in files {
        guard let data = try? Data(contentsOf: file), let settings = try? JSONSerialization.jsonObject(with: data) as? JSON else { continue }
        effort = settings["effortLevel"] as? String ?? effort
        modelEffort = ((settings["modelSettings"] as? JSON)?[model] as? JSON)?["effortLevel"] as? String ?? modelEffort
    }
    return modelEffort ?? effort
}

@MainActor
final class ClaudeConnection: Connection {
    var event: (JSON) -> Void = { _ in }
    let account: Account
    private(set) var cwd: String
    private let initialDirectory: String
    var fleetFile: String?
    var logFile: String?
    private var log: (path: String, start: UInt64)?
    var thread = "claude:" + UUID().uuidString.lowercased()
    var model = "Claude"
    var history = ""
    var usageReader: (Account) async throws -> JSON = readClaudeUsage
    private var process: Process?
    private var input: FileHandle?
    private var reader: ProviderJSONReader?
    private var turn = ""
    private var closed = false
    private var tools: [String: JSON] = [:]
    private var controls: [String: JSON] = [:]
    private var blocks: [Int: (id: String, text: String)] = [:]
    private var messageID = ""
    private var lastAnswer = ""
    private var servedModel: String?
    private var limit: JSON?
    private var rateLimited = false
    private var stopped = false
    private var command: [String]?
    private var pendingUsers: [String] = []
    private var metadata: JSON?
    private var waiting: [String: CheckedContinuation<JSON, Error>] = [:]
    private var timers: [String: DispatchWorkItem] = [:]
    private var mode = Settings.shared.value.mode
    private var developerInstructions = ""
    init(account: Account, cwd: String) { self.account = account; self.cwd = cwd; initialDirectory = cwd }
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
        process.arguments = (command ?? (["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio", "--permission-mode", mode == "bypass" ? "bypassPermissions" : "default", "--allow-dangerously-skip-permissions"] +
            [resume ? "--resume" : "--session-id", String(thread.dropFirst(7))] + (model == "Claude" ? [] : ["--model", model]))) + (developerInstructions.isEmpty ? [] : ["--append-system-prompt", developerInstructions])
        process.currentDirectoryURL = URL(fileURLWithPath: initialDirectory)
        process.environment = agentEnvironment(account, fleet: fleetFile)
        // Claude names a --resume ID it cannot find only on stderr. A file, unlike a pipe, still takes writes after a live swap ends this process.
        let errors = try agentLog(logFile)
        process.standardInput = incoming; process.standardOutput = outgoing; process.standardError = errors.writer
        try process.run()
        try? errors.writer.close()
        try attach(process, input: incoming.fileHandleForWriting, output: outgoing.fileHandleForReading, log: (errors.path, errors.start))
    }
    private func attach(_ process: Process, input: FileHandle, output: FileHandle, leftover: Data = Data(), log: (path: String, start: UInt64)? = nil) throws {
        self.process = process; self.input = input; self.log = log
        let reader = try ProviderJSONReader(handle: output, leftover: leftover, receive: { [weak self] message in
            guard let self, !closed, self.process === process else { return }; receive(message)
        }, invalid: { [weak self] message in
            guard let self, !closed, self.process === process, message != "Provider sent invalid JSON." else { return }
            emit("cx/error", ["message": message.replacingOccurrences(of: "Provider", with: "Claude")])
        }, disconnected: { [weak self] in
            guard let self, !closed, self.process === process else { return }
            self.process = nil
            Task { [weak self] in
                // A TERM or HUP from outside (the ck/tk skills' kill.sh) ends the session on purpose.
                let (crash, missing) = await Task.detached { () -> (JSON, Bool) in
                    process.waitUntilExit()
                    return (agentCrash(process, log: log), agentLogTail(log).contains("No conversation found"))
                }.value
                guard let self, !closed else { return }
                if missing { emit("cx/resumeFailed", [:]); return }
                emit("cx/disconnected", crash.isEmpty ? ["ended": true, "message": "Claude session ended."] : crash.merging(["message": "Claude disconnected. Reconnect to continue the saved conversation."]) { $1 })
            }
        })
        self.reader = reader; reader.start()
        // claude -p leaves Remote Control to its host; enabling it again on an adopted process keeps the bridge it has.
        if command == nil { Task { [weak self] in _ = try? await self?.controlResult(["subtype": "remote_control", "enabled": true], timeout: 60) } }
    }
    private var resumed = false
    func request(_ method: String, _ params: JSON = [:], timeout: Double = 120) async throws -> JSON {
        switch method {
        case "thread/start":
            developerInstructions = params["developerInstructions"] as? String ?? ""
            mode = params["approvalPolicy"] as? String == "never" ? "bypass" : "ask"; return ["thread": ["id": thread], "model": model]
        case "thread/resume":
            if let instructions = params["developerInstructions"] as? String { developerInstructions = instructions }
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
        case "thread/list": return [:]
        case "account/rateLimits/read": return ["rateLimits": try claudeRateLimits(await usageReader(account))]
        case "turn/start", "turn/steer":
            if process == nil { try launch(resume: resumed); resumed = true }
            let content = try claudeContent(params["input"] as? [JSON] ?? [])
            let steering = method == "turn/steer"
            if !steering, let effort = params["effort"] as? String {
                _ = try await controlResult(["subtype": "apply_flag_settings", "settings": ["effortLevel": effort]], timeout: 15)
            }
            if steering, params["expectedTurnId"] as? String != turn { throw CXError(message: "The Claude turn has changed. Your draft has been kept.") }
            if !steering {
                turn = UUID().uuidString; stopped = false; lastAnswer = ""; limit = nil; rateLimited = false
                tools.removeAll(); blocks.removeAll(); pendingUsers.removeAll()
            }
            let userID = params["clientUserMessageId"] as? String ?? UUID().uuidString
            try write(["type": "user", "uuid": userID, "message": ["role": "user", "content": content]])
            resumed = true; pendingUsers.append(userID)
            if !steering { emit("turn/started", ["turn": ["id": turn]]) }
            return ["turn": ["id": turn]]
        case "turn/interrupt": stopped = true; try control(["subtype": "interrupt"]); return [:]
        // Claude refuses bypass live unless it was launched with --allow-dangerously-skip-permissions, which an older VCX build did not pass.
        case "cx/mode":
            let value = params["mode"] as? String == "bypass" ? "bypass" : "ask", native = value == "bypass" ? "bypassPermissions" : "default"
            var result: JSON = [:]
            if process != nil { result = try await controlResult(["subtype": "set_permission_mode", "mode": native], timeout: 15); metadata?["current_permission_mode"] = native }
            mode = value; return result
        // Claude drops a prompt only while it waits in its queue; once the turn has taken it in, it answers cancelled: false.
        case "cx/unsend":
            guard let id = params["id"] as? String else { throw CXError(message: "Missing message ID.") }
            let result = try await controlResult(["subtype": "cancel_async_message", "message_uuid": id], timeout: 5)
            if result["cancelled"] as? Bool == true { pendingUsers.removeAll { $0 == id } }
            return result
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
            if message["subtype"] as? String == "background_tasks_changed" { emit("cx/backgroundTasks", ["count": (message["tasks"] as? [Any])?.count ?? 0]) }
            // A safeguard stop, a model fallback or a prompt a hook dropped; Claude Code keeps "info" lines for its transcript view.
            if ["informational", "model_fallback", "model_consent_fallback", "model_refusal_fallback", "model_refusal_no_fallback"].contains(message["subtype"] as? String ?? ""),
               message["level"] as? String != "info", let content = message["content"] as? String, !content.isEmpty { emit("warning", ["message": content]) }
            // A refusal fallback swaps the session's model unless only a subagent or side question fell back.
            if message["subtype"] as? String == "model_refusal_fallback", message["scope"] as? String != "local", let model = message["fallback_model"] as? String { self.model = model; emit("cx/model", ["model": model]) }
            // Idle Claude answers a finished background task with a turn of its own.
            if message["subtype"] as? String == "task_notification", pendingUsers.isEmpty {
                turn = UUID().uuidString; stopped = false; emit("turn/started", ["turn": ["id": turn]])
            }
        case "control_cancel_request":
            if let id = message["request_id"] as? String { controls.removeValue(forKey: id); emit("serverRequest/resolved", ["requestId": id]) }
        // "queued" when a prompt waits for the running turn, "started" once the turn has taken it in.
        case "command_lifecycle":
            if let id = message["command_uuid"] as? String { emit("cx/userQueue", ["id": id, "queued": message["state"] as? String == "queued"]) }
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
            if message["error"] as? String == "rate_limit" {
                // Only the plan's own limit says usage_limit_reached; a server throttle or capacity 429 is retried on the same account.
                if message["api_error"] as? String == "usage_limit_reached" { limit = (message["api_error_params"] as? JSON)?["rate_limit_info"] as? JSON ?? ["error": "usage_limit_reached"] }
                else { rateLimited = true }
                return
            }
            let body = message["message"] as? JSON ?? [:], id = body["id"] as? String ?? UUID().uuidString
            if let usage = body["usage"] as? JSON {
                let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].compactMap { usage[$0] as? Int }.reduce(0, +)
                servedModel = body["model"] as? String ?? servedModel
                emit("cx/context", ["used": used, "model": servedModel ?? model])
            }
            for (index, block) in (body["content"] as? [JSON] ?? []).enumerated() {
                if block["type"] as? String == "text", let text = block["text"] as? String {
                    lastAnswer = text
                    // Each assistant event holds one block, so its index is 0 even when the stream put a thinking block first.
                    let streamed = blocks.filter { $0.value.id.hasPrefix(id + "-") }.keys.min().flatMap { blocks.removeValue(forKey: $0)?.id }
                    emit("item/completed", ["item": ["id": streamed ?? id + "-\(index)", "type": "agentMessage", "text": text, "provider": "Claude"]])
                } else if block["type"] as? String == "tool_use", let toolID = block["id"] as? String {
                    let input = block["input"] as? JSON ?? [:], name = block["name"] as? String ?? "Tool"
                    var tool: JSON = ["id": toolID, "type": "commandExecution", "command": input["command"] as? String ?? name + "\n" + pretty(input), "cwd": cwd, "status": "inProgress"]
                    if name == "Bash", let description = input["description"] as? String { tool["description"] = description }
                    if name == "SendMessage" { tool = peerItem(id: toolID, direction: "sent", peer: input["to"] as? String ?? "", text: input["message"] as? String ?? "") }
                    tools[toolID] = tool; emit("item/started", ["item": tool])
                }
            }
        case "user":
            // Replayed prompts come back too; only a peer session's message has an origin.
            if let origin = message["origin"] as? JSON, origin["kind"] as? String == "peer" {
                if pendingUsers.isEmpty { turn = UUID().uuidString; stopped = false; emit("turn/started", ["turn": ["id": turn]]) }
                emit("item/completed", ["item": peerItem(id: message["uuid"] as? String ?? UUID().uuidString, direction: "received", peer: origin["name"] as? String ?? "", pid: origin["verifiedPeerPid"] as? Int, text: origin["body"] as? String ?? "")])
                return
            }
            for block in (message["message"] as? JSON)?["content"] as? [JSON] ?? [] {
                if let id = block["tool_use_id"] as? String, var tool = tools[id] {
                    tool["aggregatedOutput"] = String((block["content"] as? String ?? pretty(block["content"] ?? "")).suffix(16384))
                    tool["status"] = block["is_error"] as? Bool == true ? "failed" : "completed"
                    if let directory = shellDirectory(tool, current: cwd, initial: initialDirectory) { cwd = directory }
                    tools[id] = tool; emit("item/completed", ["item": tool])
                }
            }
        case "rate_limit_event":
            let info = message["rate_limit_info"] as? JSON ?? [:]
            // The stream carries the plan windows; polling /api/oauth/usage from every session gets HTTP 429.
            var limits: JSON = [:]
            for (source, target, minutes) in [("five_hour", "primary", 300), ("seven_day", "secondary", 10080)] {
                guard let window = (info["unifiedWindows"] as? JSON)?[source] as? JSON, let used = (window["utilization"] as? NSNumber)?.doubleValue else { continue }
                var rate: JSON = ["usedPercent": used * 100, "windowDurationMins": minutes]
                rate["resetsAt"] = (window["resetsAt"] as? NSNumber)?.doubleValue
                limits[target] = rate
            }
            if !limits.isEmpty { emit("account/rateLimits/updated", ["rateLimits": limits]) }
            if info["status"] as? String == "rejected" { limit = info }
        case "result":
            // `model` can be "Claude" or an alias; modelUsage is keyed by the model that served the turn.
            let served = servedModel ?? model
            if let models = message["modelUsage"] as? [String: JSON], let limit = (models[served] ?? models[model])?["contextWindow"] as? Int { emit("cx/context", ["limit": limit, "model": served]) }
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
            let failed = rateLimited || message["is_error"] as? Bool == true
            if queued == 0 || stopped || failed { pendingUsers.removeAll() }
            if !pendingUsers.isEmpty || (queued ?? 0) > 0 { return }
            var result: JSON = ["id": turn, "status": stopped ? "interrupted" : "completed"]
            if failed { result["error"] = ["message": message["result"] as? String ?? "Claude did not finish the turn.", "rateLimited": rateLimited] }
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
        var result = try await controlResult(["subtype": "initialize"], timeout: 20)
        let models = result["models"] as? [JSON] ?? []
        if model == "Claude", let resolved = models.first(where: { $0["value"] as? String == "default" })?["resolvedModel"] as? String { model = resolved; emit("cx/model", ["model": resolved]) }
        // "default" duplicates the alias it resolves to; the menu highlights that alias instead.
        result["models"] = models.filter { $0["value"] as? String != "default" }
        metadata = result
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
        closed = true; reader?.close(); reader = nil; try? input?.close(); input = nil; if let process { endProcess(process) }; process = nil }
}

extension ClaudeConnection: AdoptableConnection {
    func freezeForSwap() -> JSON? {
        guard waiting.isEmpty, controls.isEmpty, pendingUsers.isEmpty else { return nil }
        var state: JSON = ["kind": "claude", "thread": thread, "model": model, "history": history, "mode": mode, "developerInstructions": developerInstructions,
                           "resumed": resumed, "cwd": cwd, "initialDirectory": initialDirectory, "closed": closed]
        state["account"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(account))
        state["command"] = command; state["metadata"] = metadata; state["servedModel"] = servedModel
        guard !closed, let process else { return state }
        guard process.isRunning, let input, let reader, let leftover = reader.freeze() else { return nil }
        state["agent"] = ["pid": Int(process.processIdentifier), "input": Int(input.fileDescriptor), "output": Int(reader.descriptor), "leftover": leftover.base64EncodedString()]
        if let log { state["log"] = log.path; state["logStart"] = Int(log.start) }
        return state
    }

    func thawSwap() { reader?.thaw() }

    convenience init(adopting state: JSON) throws {
        guard let encoded = (state["account"] as? JSON).flatMap({ try? JSONSerialization.data(withJSONObject: $0) }), let account = try? JSONDecoder().decode(Account.self, from: encoded),
              let cwd = state["cwd"] as? String, let initial = state["initialDirectory"] as? String, let thread = state["thread"] as? String else { throw CXError(message: "Invalid adopted Claude connection.") }
        self.init(account: account, cwd: initial)
        self.cwd = cwd; self.thread = thread
        model = state["model"] as? String ?? model; history = state["history"] as? String ?? ""
        mode = state["mode"] as? String ?? mode; developerInstructions = state["developerInstructions"] as? String ?? ""
        resumed = state["resumed"] as? Bool ?? false; closed = state["closed"] as? Bool ?? false
        command = state["command"] as? [String]; metadata = state["metadata"] as? JSON; servedModel = state["servedModel"] as? String
        if let agent = try adoptedAgent(state) { try attach(agent.process, input: agent.input, output: agent.output, leftover: agent.leftover, log: (state["log"] as? String).map { ($0, UInt64(state["logStart"] as? Int ?? 0)) }) }
    }
}

func pretty(_ value: Any) -> String {
    if let text = value as? String { return text }
    return (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

var claudeSessionsFolder = NSHomeDirectory() + "/.claude/sessions"
func claudeRegistry(_ pid: Int) -> JSON? {
    (try? Data(contentsOf: URL(fileURLWithPath: claudeSessionsFolder + "/\(pid).json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON }
}

// SendMessage names a peer by its ListAgents name, maybe followed by " [ref]", or by its uds:/…/<pid>.sock address.
func peerItem(id: String, direction: String, peer: String, pid: Int? = nil, text: String) -> JSON {
    let name = peer.components(separatedBy: " [")[0]
    var pid = pid ?? Int(name.replacingOccurrences(of: #"^uds:.*/(\d+)\.sock$"#, with: "$1", options: .regularExpression))
    var entry = pid.flatMap(claudeRegistry)
    if pid == nil {
        entry = ((try? FileManager.default.contentsOfDirectory(atPath: claudeSessionsFolder)) ?? []).compactMap { Int($0.replacingOccurrences(of: ".json", with: "")) }
            .compactMap(claudeRegistry).filter { entry in entry["name"] as? String == name && (entry["pid"] as? Int).map { $0 > 0 && kill(pid_t($0), 0) == 0 } == true }
            .max { ($0["startedAt"] as? Double ?? 0) < ($1["startedAt"] as? Double ?? 0) }
        pid = entry?["pid"] as? Int
    }
    var item: JSON = ["id": id, "type": "peerMessage", "direction": direction, "name": entry?["name"] as? String ?? (name.hasPrefix("uds:") ? "another session" : name), "text": text, "status": direction == "sent" ? "inProgress" : "completed"]
    if let pid, let started = entry?["startedAt"] { item["pid"] = pid; item["startedAt"] = started }
    return item
}

// The start time tells the peer apart from a later process that reused its pid.
func peerTarget(_ item: JSON) -> Int? {
    guard let pid = item["pid"] as? Int, pid > 0, kill(pid_t(pid), 0) == 0, let started = item["startedAt"] as? Double,
          claudeRegistry(pid)?["startedAt"] as? Double == started else { return nil }
    return pid
}

// Fleet raises the peer's VCX window or terminal tab; a peer that is gone is left alone.
func focusPeer(_ item: JSON) {
    guard let pid = peerTarget(item) else { return }
    let fleet = Process()
    fleet.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Fleet.app/Contents/MacOS/Fleet")
    fleet.arguments = ["--focus", String(pid)]
    fleet.standardOutput = FileHandle.nullDevice; fleet.standardError = FileHandle.nullDevice
    try? fleet.run()
}

@MainActor
final class QwenConnection: Connection {
    var event: (JSON) -> Void = { _ in }
    var thread = "qwen:" + UUID().uuidString
    var messages: [JSON] = [["role": "system", "content": "You are Qwen in Vibe Code X, a coding assistant. Use run_command to inspect or change files when the user asks. Check the project instructions before changing code. Never claim to have performed an action unless its tool result confirms it. Stop when the task is complete."]]
    private var developerInstructions = ""
    private var task: Task<Void, Never>?
    private var turn = ""
    var preferences: Preferences
    private(set) var cwd: String
    private let initialDirectory: String
    var fleetFile: String?
    private var selectedModel: String?
    private var permissions: [String: CheckedContinuation<Bool, Never>] = [:]
    private var commandProcess: Process?
    private var network: URLSession?
    private func connection() throws -> URLSession {
        if let network { return network }
        let session = try qwenNetwork(preferences); network = session; return session
    }
    init(preferences: Preferences, cwd: String = FileManager.default.currentDirectoryPath) { self.preferences = preferences; self.cwd = cwd; initialDirectory = cwd }
    func start(command: [String]? = nil) async throws {
        guard preferences.qwenWake else { return }
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("background.py"), FileManager.default.fileExists(atPath: helper.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path, "--ensure-qwen"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let status = await Task.detached { process.waitUntilExit(); return process.terminationStatus }.value
        guard status == 0 else { throw CXError(message: "Qwen is unavailable. Check the remote machine and the Windows wake setting.") }
    }
    func request(_ method: String, _ params: JSON = [:], timeout: Double = 120) async throws -> JSON {
        switch method {
        case "thread/start", "thread/resume":
            if let instructions = params["developerInstructions"] as? String { developerInstructions = instructions }
            if let id = params["threadId"] as? String { thread = id }
            if let model = params["model"] as? String { selectedModel = model }
            return ["thread": ["id": thread], "model": selectedModel ?? preferences.qwenModel]
        case "thread/turns/list", "thread/list": return ["data": []]
        case "account/rateLimits/read": return [:]
        case "cx/mode": preferences.mode = params["mode"] as? String == "bypass" ? "bypass" : "ask"; return [:]
        case "model/list": return ["data": [["id": preferences.qwenModel], ["id": preferences.qwenVisionModel]]]
        case "turn/start":
            if let path = params["cwd"] as? String, let directory = workingDirectory(path, within: initialDirectory) { cwd = directory }
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
            let project = messages.count == 1 ? qwenProject(text, cwd: cwd).flatMap { workingDirectory($0, within: initialDirectory) } : nil
            messages.append(message)
            // Bound remote context without loading a local model or asking another model to summarize.
            if messages.count > 41 { messages.removeSubrange(1..<(messages.count - 40)) }
            turn = UUID().uuidString
            let current = turn, item = UUID().uuidString
            emit("turn/started", ["turn": ["id": current]])
            if let project {
                // Reported as the lone cd Claude would run, so the window moves the way it does for Claude.
                emit("item/completed", ["item": ["id": UUID().uuidString, "type": "commandExecution", "command": "cd " + project, "cwd": cwd, "aggregatedOutput": "", "exitCode": 0, "status": "completed"]])
                cwd = project
            }
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
        var outgoing = messages
        outgoing[0]["content"] = (messages[0]["content"] as? String ?? "") + "\n" + developerInstructions
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": outgoing, "stream": true, "keep_alive": "5m", "think": false, "tools": [tool]])
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
        let directory = cwd
        emit("item/started", ["item": ["id": id, "type": "commandExecution", "command": command, "cwd": directory, "status": "inProgress"]])
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
        process.currentDirectoryURL = URL(fileURLWithPath: cwd); process.environment = agentEnvironment(fleet: fleetFile).merging(["VCX_THREAD_ID": thread]) { $1 }
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
        let item: JSON = ["id": id, "type": "commandExecution", "command": command, "cwd": directory, "aggregatedOutput": result.0, "exitCode": result.1, "status": result.1 == 0 ? "completed" : "failed"]
        if let directory = shellDirectory(item, current: cwd, initial: initialDirectory) { cwd = directory }
        emit("item/completed", ["item": item])
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

// Claude picks its project from his CLAUDE.md; Qwen reads none, and the 8B model chains `cd x && …` into wrong folders,
// so VCX picks the one ~/self project the first request names: a folder, a Mac app (my-apps) or Qwen's own words.
func qwenProject(_ text: String, cwd: String) -> String? {
    let root = NSHomeDirectory() + "/self"
    guard !cwd.hasPrefix(root + "/") else { return nil }
    let lower = text.lowercased()
    func named(_ word: String) -> Bool { lower.range(of: "(?<![a-z0-9_-])" + NSRegularExpression.escapedPattern(for: word.lowercased()) + "(?![a-z0-9_-])", options: .regularExpression) != nil }
    func folders(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { name in
            var directory: ObjCBool = false
            return !name.hasPrefix(".") && (try? FileManager.default.destinationOfSymbolicLink(atPath: path + "/" + name)) == nil
                && FileManager.default.fileExists(atPath: path + "/" + name, isDirectory: &directory) && directory.boolValue
        }
    }
    // ponytail: word match only; "temp" and "archive" are left out as everyday words, not projects to work in.
    var hits = Set(folders(root).filter { !["temp", "archive"].contains($0) && named($0) })
    if folders(root + "/my-apps").contains(where: named) { hits.insert("my-apps") }
    if ["qwen", "llama.cpp", "llama", "ollama", "fuse", "gguf"].contains(where: named) { hits.insert("qwen") }
    return hits.count == 1 ? root + "/" + hits.first! : nil
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
