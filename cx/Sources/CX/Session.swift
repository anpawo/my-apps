import AppKit
import CryptoKit
import Darwin
import SwiftUI

final class Item: ObservableObject, Identifiable {
    let id: String
    @Published var data: JSON
    init(_ data: JSON) { self.id = data["id"] as? String ?? UUID().uuidString; self.data = data }
    var kind: String { data["type"] as? String ?? "activity" }
    var text: String { data["text"] as? String ?? "" }
    var failed: Bool {
        ["failed", "declined"].contains(data["status"] as? String ?? "") || data["success"] as? Bool == false ||
        (data["error"] != nil && !(data["error"] is NSNull)) || (data["exitCode"] as? Int ?? 0) != 0
    }
    var title: String {
        switch kind {
        case "commandExecution": return (data["command"] as? String ?? "Command").components(separatedBy: "\n").first ?? "Command"
        case "fileChange": return "Edit " + (data["changes"] as? [JSON] ?? []).compactMap { ($0["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } }.joined(separator: ", ")
        case "mcpToolCall", "dynamicToolCall": return ["server", "namespace", "tool"].compactMap { data[$0] as? String }.joined(separator: ".")
        case "webSearch": return "Search: " + (data["query"] as? String ?? "web")
        case "reasoning": return "Thinking"
        default: return kind.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
        }
    }
    var output: String {
        var parts: [String] = []
        if kind == "fileChange" { parts = (data["changes"] as? [JSON] ?? []).compactMap { $0["diff"] as? String } }
        else if kind == "reasoning" { parts = data["summary"] as? [String] ?? [] }
        else {
            parts = ["aggregatedOutput", "result", "error", "contentItems", "output"].compactMap { key in
                guard let value = data[key], !(value is NSNull) else { return nil }
                if let text = value as? String { return text }
                return (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted])).flatMap { String(data: $0, encoding: .utf8) }
            }
        }
        let text = parts.joined(separator: "\n")
        // shortcut: bound displayed tool output to 16 KB; the complete output stays in Codex history.
        return String(text.suffix(16384)) + (data["exitCode"] as? Int).map { "\nExit: \($0)" }.orEmpty
    }
}

extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }

final class Row: ObservableObject, Identifiable {
    let id = UUID()
    let kind: String
    @Published var items: [Item]
    init(_ kind: String, _ items: [Item]) { self.kind = kind; self.items = items }
}

struct Recent: Identifiable {
    let id: String
    let title: String
    var backendID: String? = nil
}

struct Permission: Identifiable {
    let id = UUID()
    let rpcID: Any
    let method: String
    let params: JSON
}

struct FollowState {
    var attached = true
    mutating func userScroll(distance: CGFloat) { attached = distance < 40 }
}

@MainActor
final class Session: ObservableObject {
    @Published var rows: [Row] = []
    @Published var recent: [Recent] = []
    @Published var models: [String] = []
    @Published var model = "Codex"
    @Published var status = "Connecting…"
    @Published var ready = false
    @Published var busy = false
    @Published var changing = false
    @Published var details = false
    @Published var context = ""
    @Published var usage = ""
    @Published var revision = 0
    @Published var follow = FollowState()
    @Published var permissions: [Permission] = []
    @Published var preview: String?
    @Published var editorHeight: CGFloat = 24
    @Published var draftRevision = 0
    var draft = NSAttributedString(string: "")
    var submitDraft: () -> Void = {}
    private(set) var cwd: String
    private(set) var threadID: String?
    private(set) var turnID: String?
    let stateDirectory: URL
    var rpc: any Connection = RPC()
    @Published var providerLabel = "Claude"
    private(set) var account = Account(id: "claude-default", name: "Default Claude", provider: "claude")
    private var recordID = UUID().uuidString
    private var pendingInput: (String, [String])?
    private var transferring = false
    private var injectedContext = ""
    private var testing = false
    private var suppressSave = false
    private var recordLock: (String, Int32)?
    private var pendingActivation: (Account, String?, Bool, String)?
    private var pendingRestore: String?
    private var pendingLimit: JSON?
    var connectionFactory: ((Account, String) -> any Connection)?
    var nativeDirectory: URL { stateDirectory.appendingPathComponent("native").appendingPathComponent(pointer.deletingPathExtension().lastPathComponent) }
    private var snapshotURL: URL { nativeDirectory.appendingPathComponent(recordID + ".json") }
    private var nativePointer: URL { pointer.deletingPathExtension().appendingPathExtension("native.json") }

    private var itemMap: [String: Item] = [:]
    private var seen = Set<String>()
    private var group: Row?
    private var loading = false
    private var bufferedEvents: [JSON] = []
    private var submitting = false
    private var stopRequested = false
    private var deltas: [String: String] = [:]
    private var flushTask: Task<Void, Never>?

    init(cwd: String, stateDirectory: URL? = nil) {
        self.cwd = URL(fileURLWithPath: cwd).standardized.path
        self.stateDirectory = stateDirectory ?? URL(fileURLWithPath: NSHomeDirectory() + "/.local/state/cx", isDirectory: true)
    }
    var currentConversationID: String { "native:" + recordID }
    var folder: String { URL(fileURLWithPath: cwd).lastPathComponent }
    var pointer: URL { stateDirectory.appendingPathComponent(SHA256.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24) + ".json") }
    var disabled: Bool { !ready || busy || changing }

    func connect(resume: String?, prompt: String = "", command: [String]? = nil) async {
        do {
            testing = command != nil
            if testing {
                let connection = RPC(); connection.cwd = cwd
                rpc = connection
                account = Account(id: "codex-default", name: "Default Codex", provider: "codex")
                providerLabel = "Codex"
                rpc.event = { [weak self] message in self?.event(message) }
                try await rpc.start(command: command)
                try await open(nil)
            } else if let resume {
                if resume == "last", let record = try? JSONSerialization.jsonObject(with: Data(contentsOf: nativePointer)) as? JSON, let id = record["recordId"] as? String {
                    try await restore(id)
                } else if resume.hasPrefix("native:") { try await restore(String(resume.dropFirst(7))) }
                else {
                    var id = resume
                    if resume == "last" {
                        guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: pointer)) as? JSON, let thread = saved["threadId"] as? String else { throw CXError(message: "No saved conversation in this folder.") }
                        id = thread
                    }
                    let codex = Settings.shared.value.accounts.first { $0.provider == "codex" && $0.enabled } ?? Account(id: "codex-default", name: "Default Codex", provider: "codex")
                    try await activate(codex, resume: id, keepRows: false)
                }
            } else {
                guard let first = available.first else { throw CXError(message: "No account is available. Enable accounts in Settings, or wait for their limits to reset.") }
                try await activate(first, resume: nil, keepRows: false)
            }
            await refreshCatalog()
            if !prompt.isEmpty { await send(text: prompt, images: []) }
        } catch { notice(error.localizedDescription); status = "Connection failed" }
    }

    func refreshCatalog() async {
        do {
            let page = try await rpc.request("thread/list", ["cwd": cwd, "limit": 40, "sortKey": "updated_at"])
            let external = (page["data"] as? [JSON] ?? []).compactMap { thread -> Recent? in
                guard let id = thread["id"] as? String else { return nil }
                return Recent(id: id, title: thread["name"] as? String ?? thread["preview"] as? String ?? "Untitled conversation")
            }
            let local = nativeRecent()
            let savedIDs = Set(local.compactMap(\.backendID))
            recent = local + external.filter { !savedIDs.contains($0.id) }
            let catalog = try await rpc.request("model/list", ["limit": 100])
            models = (catalog["data"] as? [JSON] ?? []).compactMap { $0["id"] as? String }
            let result = try await rpc.request("account/rateLimits/read")
            updateUsage(result["rateLimits"] as? JSON ?? [:])
        } catch { notice("Could not refresh conversations or account details: " + error.localizedDescription) }
    }

    func open(_ resume: String?, keepRows: Bool = false) async throws {
        guard !busy, !changing else { return }
        changing = true
        loading = true
        defer {
            changing = false
            loading = false
            let pending = bufferedEvents
            bufferedEvents.removeAll()
            for message in pending { event(message) }
        }
        var params: JSON = ["cwd": cwd]
        if let resume { params["threadId"] = resume; params["excludeTurns"] = true }
        let result = try await rpc.request(resume == nil ? "thread/start" : "thread/resume", params)
        guard let thread = result["thread"] as? JSON, let id = thread["id"] as? String else { throw CXError(message: "Codex did not return a conversation.") }
        var history: [JSON] = []
        if resume != nil && !keepRows {
            var cursor: String?
            repeat {
                var pageParams: JSON = ["threadId": id, "limit": 50, "sortDirection": "asc", "itemsView": "full"]
                if let cursor { pageParams["cursor"] = cursor }
                let page = try await rpc.request("thread/turns/list", pageParams)
                history += page["data"] as? [JSON] ?? []
                cursor = page["nextCursor"] as? String
            } while cursor != nil
        }
        flushTask?.cancel(); flushTask = nil; deltas.removeAll()
        if !keepRows { rows.removeAll(); itemMap.removeAll(); seen.removeAll() }
        group = nil
        threadID = id
        turnID = nil; busy = false; stopRequested = false
        model = result["model"] as? String ?? "Codex"
        context = ""
        if account.provider == "codex" { do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: ["threadId": id]).write(to: pointer, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pointer.path)
        } catch { notice("Could not save the resume pointer: " + error.localizedDescription) } }
        for turn in history {
            group = nil
            for item in turn["items"] as? [JSON] ?? [] { show(item) }
            if turn["status"] as? String == "inProgress" { turnID = turn["id"] as? String; busy = true }
        }
        ready = true
        status = busy ? "Working…" : "Ready"
        follow.attached = true
        revision += 1
        save()
    }

    func notice(_ text: String) {
        rows.append(Row("notice", [Item(["text": text])]))
        revision += 1
    }

    func show(_ source: JSON) {
        var data = source
        if data["type"] as? String == "agentMessage", data["provider"] == nil { data["provider"] = providerLabel }
        guard let id = data["id"] as? String, let kind = data["type"] as? String else { return }
        if let item = itemMap[id] { item.data = data; return }
        if kind == "userMessage" {
            let client = data["clientId"] as? String ?? id
            guard !seen.contains(id), !seen.contains(client) else { return }
            seen.insert(id); seen.insert(client)
        }
        guard !["hookPrompt", "contextCompaction"].contains(kind) else { return }
        let item = Item(data)
        itemMap[id] = item
        if ["agentMessage", "plan", "userMessage"].contains(kind) {
            group = nil
            rows.append(Row(kind == "userMessage" ? "user" : "assistant", [item]))
        } else {
            if group == nil {
                let row = Row("activity", [])
                rows.append(row); group = row
            }
            group?.items.append(item)
            if busy, !item.failed { status = "Working: " + String(item.title.prefix(100)) }
        }
    }

    func event(_ message: JSON) {
        if loading { bufferedEvents.append(message); return }
        let method = message["method"] as? String ?? ""
        let p = message["params"] as? JSON ?? [:]
        if let id = p["threadId"] as? String, id != threadID { return }
        if let id = message["id"], message["method"] != nil {
            if ["item/tool/requestUserInput", "item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method) {
                var params = p
                if method == "item/fileChange/requestApproval", let itemID = p["itemId"] as? String { params["changes"] = itemMap[itemID]?.data["changes"] }
                permissions.append(Permission(rpcID: id, method: method, params: params))
            } else {
                do { try rpc.reject(id, method: method); notice("Unsupported request declined: " + method) }
                catch { notice(error.localizedDescription) }
            }
            return
        }
        switch method {
        case "cx/limit":
            queueLimit(p["limit"] as? JSON ?? [:])
            return
        case "cx/claudeLimit":
            if let percent = p["utilization"] as? Double { usage = "\(Int((percent * 100).rounded()))% " + (p["rateLimitType"] as? String ?? "usage") }
        case "cx/model": model = p["model"] as? String ?? model
        case "item/started", "item/completed":
            if let data = p["item"] as? JSON {
                flush()
                show(data)
                if method == "item/completed" { deltas.removeValue(forKey: data["id"] as? String ?? "") }
            }
        case "item/agentMessage/delta", "item/plan/delta", "item/commandExecution/outputDelta":
            guard let id = p["itemId"] as? String, let delta = p["delta"] as? String else { return }
            if itemMap[id] == nil { show(["id": id, "type": "agentMessage", "text": ""]) }
            deltas[id, default: ""] += delta
            scheduleFlush()
            return
        case "turn/started":
            turnID = (p["turn"] as? JSON)?["id"] as? String; busy = true; status = "Working…"
            if stopRequested { Task { await stop() } }
        case "turn/completed":
            if let turn = p["turn"] as? JSON, usageLimit(turn), !stopRequested {
                queueLimit(turn); return
            }
            flush(); turnID = nil; busy = false; stopRequested = false
            pendingInput = nil
            permissions.removeAll()
            let turn = p["turn"] as? JSON ?? [:]
            if let error = turn["error"] as? JSON { notice(error["message"] as? String ?? "Turn failed.") }
            status = turn["status"] as? String == "interrupted" ? "Stopped" : "Ready"
            save()
        case "error", "cx/error", "cx/disconnected":
            if usageLimit(p), busy, !stopRequested { queueLimit(p); return }
            notice(((p["error"] as? JSON) ?? p)["message"] as? String ?? "Codex reported an error.")
            if method == "cx/disconnected" { ready = false; busy = false; turnID = nil; status = "Disconnected"; permissions.removeAll() }
        case "warning", "guardianWarning", "configWarning", "deprecationNotice":
            notice(p["message"] as? String ?? p["summary"] as? String ?? "Codex reported a configuration warning.")
        case "thread/compacted": notice("Conversation compacted. Earlier messages remain in history.")
        case "thread/tokenUsage/updated":
            let usage = p["tokenUsage"] as? JSON ?? [:]
            if let used = (usage["last"] as? JSON)?["totalTokens"] as? Double, let limit = usage["modelContextWindow"] as? Double, limit > 0 { context = "\(Int((used / limit * 100).rounded()))% context" }
        case "account/rateLimits/updated": updateUsage(p["rateLimits"] as? JSON ?? [:])
        case "serverRequest/resolved":
            if let id = p["requestId"] { permissions.removeAll { String(describing: $0.rpcID) == String(describing: id) } }
        default: return
        }
        revision += 1
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flush()
        }
    }

    func flush() {
        guard !deltas.isEmpty else { return }
        for (id, delta) in deltas {
            guard let item = itemMap[id] else { continue }
            let key = item.kind == "commandExecution" ? "aggregatedOutput" : "text"
            let text = (item.data[key] as? String ?? "") + delta
            item.data[key] = key == "aggregatedOutput" ? String(text.suffix(16384)) : text
        }
        deltas.removeAll()
        revision += 1
    }

    func updateUsage(_ rate: JSON) {
        if account.provider == "codex", ["primary", "secondary"].contains(where: { ((rate[$0] as? JSON)?["usedPercent"] as? Double ?? 0) >= 100 }) {
            let reset = ["primary", "secondary"].compactMap { rate[$0] as? JSON }.filter { ($0["usedPercent"] as? Double ?? 0) >= 100 }.map(limitReset).max() ?? Date().timeIntervalSince1970 + 300
            Settings.shared.updateLimit(account: account.id, reset: reset)
        }
        usage = ["primary", "secondary"].compactMap { key -> String? in
            guard let window = rate[key] as? JSON, let used = window["usedPercent"] as? Double else { return nil }
            let minutes = window["windowDurationMins"] as? Int ?? 0
            let label = minutes == 300 ? "5h" : minutes == 10080 ? "weekly" : "\(minutes)m"
            return "\(Int(used.rounded()))% \(label)"
        }.joined(separator: " / ")
    }

    func send(text: String, images: [String], retry: Bool = false) async {
        if !testing { Settings.shared.reload() }
        guard ready, !submitting, !changing else { return }
        if !testing, !busy, !retry {
            guard let next = available.first else { notice("All enabled accounts have reached their limits. Check Settings or wait for a reset."); return }
            if next.id != account.id {
                do { try await activate(next, resume: nil, keepRows: true); await refreshCatalog() }
                catch { notice(error.localizedDescription); return }
            }
        }
        if text.hasPrefix("/"), images.isEmpty { await command(text); return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        let wasBusy = busy, savedDraft = draft
        guard !busy || turnID != nil else { notice("The current turn is still starting. Your draft has been kept."); return }
        submitting = true
        defer { submitting = false; drainLimit() }
        let id = UUID().uuidString
        var content: [JSON] = text.isEmpty ? [] : [["type": "text", "text": text]]
        if !retry {
            if wasBusy, let previous = pendingInput { pendingInput = (previous.0 + "\n\nAdditional guidance: " + text, previous.1 + images) }
            else { pendingInput = (text, images) }
        }
        content += images.map { ["type": "localImage", "path": $0] }
        let optimistic = Row("user", [Item(["id": id, "type": "userMessage", "content": content])])
        seen.insert(id); group = nil; if !retry { rows.append(optimistic) }
        follow.attached = true; revision += 1
        if !retry { draft = NSAttributedString(string: ""); draftRevision += 1 }
        busy = true; stopRequested = false; status = wasBusy ? "Sending guidance…" : "Working…"
        var outgoing = content
        if !injectedContext.isEmpty { outgoing.insert(["type": "text", "text": injectedContext], at: 0) }
        var params: JSON = ["threadId": threadID ?? "", "input": outgoing, "clientUserMessageId": id]
        if wasBusy { params["expectedTurnId"] = turnID }
        do {
            let result = try await rpc.request(wasBusy ? "turn/steer" : "turn/start", params)
            if busy, turnID == nil { turnID = (result["turn"] as? JSON)?["id"] as? String }
            injectedContext = ""
            save()
            if stopRequested { await stop() }
        } catch {
            if usageLimit(["error": error.localizedDescription]), !stopRequested {
                pendingLimit = [:]; return
            }
            rows.removeAll { $0.id == optimistic.id }; seen.remove(id)
            if !wasBusy, turnID == nil { busy = false }
            let restored = NSMutableAttributedString(attributedString: savedDraft)
            if restored.length > 0, draft.length > 0 { restored.append(NSAttributedString(string: "\n")) }
            restored.append(draft); if !retry { draft = restored; draftRevision += 1 }
            notice("Prompt was not sent: " + error.localizedDescription)
            status = busy ? "Working…" : "Ready"
        }
    }

    func stop() async {
        stopRequested = true
        guard let turnID else { status = "Stopping when the turn starts…"; return }
        do { _ = try await rpc.request("turn/interrupt", ["threadId": threadID ?? "", "turnId": turnID], timeout: 5); if busy { status = "Stopping…" } }
        catch { notice(error.localizedDescription) }
    }

    func answer(_ request: Permission, result: JSON) {
        do { try rpc.respond(request.rpcID, result); permissions.removeAll { $0.id == request.id } }
        catch { notice("Could not send your answer: " + error.localizedDescription) }
    }

    func switchThread(_ id: String?) async {
        let previousRecord = recordID
        guard !busy, !changing, draft.length == 0 else { if draft.length > 0 { notice("Send or clear your draft before switching conversations.") }; return }
        do {
            save()
            if let id, id.hasPrefix("native:") { try await restore(String(id.dropFirst(7))) }
            else {
                recordID = UUID().uuidString
                let next = id != nil ? Settings.shared.value.accounts.first { $0.provider == "codex" && $0.enabled } : available.first
                guard let next else { throw CXError(message: "No enabled account available.") }
                try await activate(next, resume: id, keepRows: false)
            }
            await refreshCatalog()
        } catch { recordID = previousRecord; notice(error.localizedDescription) }
    }

    func changeModel(_ value: String) async {
        guard !disabled else { return }
        guard models.contains(value) else { notice("Unknown model. Choose one from the model menu."); return }
        changing = true; defer { changing = false }
        do {
            let result = try await rpc.request("thread/resume", ["threadId": threadID ?? "", "model": value, "excludeTurns": true])
            model = result["model"] as? String ?? value
        } catch { notice(error.localizedDescription) }
    }

    func command(_ source: String) async {
        let parts = source.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "/new", "/clear", "/resume":
            guard !disabled else { notice("Stop the current turn before changing conversations."); return }
            do {
                var id: String?
                if parts.first == "/resume" {
                    if !argument.isEmpty { id = argument }
                    else if let record = try? JSONSerialization.jsonObject(with: Data(contentsOf: nativePointer)) as? JSON, let saved = record["recordId"] as? String { id = "native:" + saved }
                    else { id = (try JSONSerialization.jsonObject(with: Data(contentsOf: pointer)) as? JSON)?["threadId"] as? String }
                }
                let saved = draft
                draft = NSAttributedString(string: ""); draftRevision += 1
                await switchThread(id)
                if !ready { draft = saved; draftRevision += 1 }
                await refreshCatalog()
            } catch { notice(error.localizedDescription) }
        case "/model":
            if argument.isEmpty { notice("Available models: " + models.joined(separator: ", ")) }
            else { await changeModel(argument) }
        case "/compact", "/review":
            guard !disabled else { notice("Stop the current turn first."); return }
            do {
                if parts.first == "/compact" { _ = try await rpc.request("thread/compact/start", ["threadId": threadID ?? ""]) }
                else {
                    let target: JSON = argument.isEmpty ? ["type": "uncommittedChanges"] : ["type": "custom", "instructions": argument]
                    _ = try await rpc.request("review/start", ["threadId": threadID ?? "", "target": target, "delivery": "inline"])
                }
            } catch { notice(error.localizedDescription) }
        case "/details", "/focus": details.toggle()
        case "/status": notice("Session: \(threadID ?? "Not connected")\nFolder: \(cwd)\nModel: \(model)")
        case "/quit", "/exit": NSApp.terminate(nil)
        case "/help": notice("/new · /resume [id] · /model [name] · /compact · /review · /status · /details · /focus · /quit\nReturn sends. Shift+Return adds a line. Escape stops the turn.")
        default: notice("Unknown command. Use /help, or start with a space to send a slash prompt literally."); return
        }
        if draft.string == source { draft = NSAttributedString(string: ""); draftRevision += 1 }
    }

    var available: [Account] {
        let settings = Settings.shared
        return settings.candidates.filter { (settings.value.limits[$0.id] ?? 0) <= Date().timeIntervalSince1970 }
    }

    private func activate(_ next: Account, resume: String?, keepRows: Bool) async throws {
        let previous = (account, threadID, model, context, usage, injectedContext)
        flush()
        injectedContext = keepRows ? handoffContext() : ""
        rpc.event = { _ in }; rpc.close()
        ready = false; busy = false; turnID = nil; permissions.removeAll()
        account = next; providerLabel = next.provider == "codex" ? "Codex" : next.provider.capitalized
        context = ""; usage = ""; status = "Connecting to " + providerLabel + "…"
        if let connectionFactory { rpc = connectionFactory(next, cwd) } else { switch next.provider {
        case "claude": rpc = ClaudeConnection(account: next, cwd: cwd)
        case "qwen": rpc = QwenConnection(preferences: Settings.shared.value, cwd: cwd)
        default:
            let connection = RPC(); connection.account = next; connection.cwd = cwd; rpc = connection
        }
        }
        rpc.event = { [weak self] message in self?.event(message) }
        do {
            try await rpc.start(command: nil)
            try await open(resume, keepRows: keepRows)
            pendingActivation = nil; pendingRestore = nil
        } catch {
            rpc.event = { _ in }; rpc.close()
            account = previous.0; threadID = previous.1; model = previous.2
            context = previous.3; usage = previous.4; injectedContext = previous.5
            providerLabel = account.provider == "codex" ? "Codex" : account.provider.capitalized
            pendingActivation = (next, resume, keepRows, recordID)
            ready = false
            throw error
        }
    }

    private func handoffContext() -> String {
        let lines = rows.suffix(60).flatMap { row -> [String] in
            row.items.suffix(12).map { item in
                if row.kind == "user" {
                    return "User: " + (item.data["content"] as? [JSON] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                if row.kind == "assistant" { return (item.data["provider"] as? String ?? "Assistant") + ": " + item.text }
                if row.kind == "activity" { return "Action (\(item.failed ? "failed" : "recorded")): " + item.title + "\n" + String(item.output.suffix(1500)) }
                return ""
            }
        }
        let text = String(lines.joined(separator: "\n\n").suffix(48000))
        return text.isEmpty ? "" : "Context from this conversation, truncated to the latest 48 KB if necessary. Continue from the work already done. Check the current files before acting; do not repeat successful actions. The latest request follows this context.\n\n" + text + "\n\nEnd of conversation context."
    }

    private func queueLimit(_ info: JSON) { pendingLimit = info; drainLimit() }
    private func drainLimit() {
        guard !submitting, !transferring, let info = pendingLimit else { return }
        pendingLimit = nil
        Task { await limitReached(info) }
    }

    private func limitReached(_ info: JSON) async {
        guard !transferring, !stopRequested else { return }
        transferring = true; defer { transferring = false; drainLimit() }
        flush()
        Settings.shared.updateLimit(account: account.id, reset: limitReset(info))
        busy = false; turnID = nil
        guard let input = pendingInput, let next = available.first else {
            notice("\(providerLabel) reached its usage limit. No enabled fallback is available. Your conversation is saved.")
            status = "Usage limit reached"; save(); return
        }
        notice("\(account.name) reached its usage limit. Continuing with \(next.name), with recent conversation context.")
        do {
            try await activate(next, resume: nil, keepRows: true)
            await refreshCatalog()
            await send(text: input.0, images: input.1, retry: true)
        } catch { notice("Could not connect to the fallback: " + error.localizedDescription); status = "Fallback connection failed" }
    }

    func reconnect() async {
        Settings.shared.reload()
        if let pendingRestore {
            do { try await restore(pendingRestore); await refreshCatalog() }
            catch { notice(error.localizedDescription) }
            return
        }
        let previousRecord = recordID
        var target = pendingActivation ?? (account, threadID, true, recordID)
        if let selected = available.first, Settings.shared.value.provider != "auto", selected.id != target.0.id {
            target = (selected, selected.id == account.id ? threadID : nil, true, recordID)
        }
        recordID = target.3
        do { try await activate(target.0, resume: target.1, keepRows: target.2); await refreshCatalog() }
        catch { recordID = previousRecord; notice(error.localizedDescription) }
    }

    private func nativeRecent() -> [Recent] {
        let directory = nativeDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }.prefix(40).compactMap { url in
            guard let data = try? Data(contentsOf: url), let record = try? JSONSerialization.jsonObject(with: data) as? JSON, record["cwd"] as? String == cwd else { return nil }
            return Recent(id: "native:" + url.deletingPathExtension().lastPathComponent, title: record["title"] as? String ?? "New conversation", backendID: record["threadId"] as? String)
        }
    }

    private func claimRecord(_ id: String) throws -> Int32 {
        let directory = stateDirectory.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent(id + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CXError(message: "Could not open the conversation lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw CXError(message: "This conversation is already open in another window. Use that window, or start a new conversation here.")
        }
        return fd
    }
    private func releaseRecord() {
        if let lock = recordLock { flock(lock.1, LOCK_UN); Darwin.close(lock.1); recordLock = nil }
    }

    func save() {
        guard !testing, !suppressSave, threadID != nil else { return }
        do {
            if recordLock?.0 != recordID {
                let fd = try claimRecord(recordID)
                releaseRecord(); recordLock = (recordID, fd)
            }
            try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let title = rows.first { $0.kind == "user" }?.items.first.flatMap { ($0.data["content"] as? [JSON] ?? []).compactMap { $0["text"] as? String }.first }.map { String($0.prefix(100)) } ?? "New conversation"
            let record: JSON = ["cwd": cwd, "title": title, "threadId": threadID ?? "", "accountId": account.id, "rows": rows.map { ["kind": $0.kind, "items": $0.items.map { $0.data }] }, "draft": draftContent(draft)]
            try JSONSerialization.data(withJSONObject: record).write(to: snapshotURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
            try JSONSerialization.data(withJSONObject: ["recordId": recordID]).write(to: nativePointer, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nativePointer.path)
        } catch { status = "Could not save conversation: " + error.localizedDescription }
    }

    private func restore(_ id: String) async throws {
        guard UUID(uuidString: id) != nil else { throw CXError(message: "Invalid saved conversation ID.") }
        let claimed = recordLock?.0 == id ? nil : try claimRecord(id)
        var accepted = false
        suppressSave = true
        defer {
            suppressSave = false
            if !accepted, let claimed { flock(claimed, LOCK_UN); Darwin.close(claimed) }
        }
        let url = nativeDirectory.appendingPathComponent(id + ".json")
        guard let record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSON, let accountID = record["accountId"] as? String, let thread = record["threadId"] as? String else { throw CXError(message: "The saved conversation is invalid.") }
        let settings = Settings.shared
        let stored = settings.candidates.first { $0.id == accountID } ?? settings.value.accounts.first { $0.id == accountID }
        let preferred = settings.value.provider != "auto" || stored?.enabled == false ? available.first : stored ?? available.first
        guard let selected = preferred else { throw CXError(message: "No enabled account is available for this conversation.") }
        let resumeID = selected.id == accountID ? thread : nil
        do { try await activate(selected, resume: resumeID, keepRows: true) }
        catch { pendingRestore = id; throw error }
        pendingRestore = nil
        recordID = id
        if let claimed { releaseRecord(); recordLock = (id, claimed) }
        accepted = true
        rows.removeAll(); itemMap.removeAll(); seen.removeAll(); group = nil
        for row in record["rows"] as? [JSON] ?? [] {
            let items = (row["items"] as? [JSON] ?? []).map(Item.init)
            for item in items { itemMap[item.id] = item; if item.kind == "userMessage" { seen.insert(item.id) } }
            rows.append(Row(row["kind"] as? String ?? "notice", items))
        }
        let restoredDraft = NSMutableAttributedString(string: "")
        for (n, piece) in (record["draft"] as? [JSON] ?? []).enumerated() {
            if let text = piece["text"] as? String { restoredDraft.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white])) }
            else if let path = piece["path"] as? String { restoredDraft.append(NSAttributedString(attachment: ImageChip(path: path, number: n + 1))) }
        }
        draft = restoredDraft; draftRevision += 1
        injectedContext = selected.provider == "qwen" || resumeID == nil ? handoffContext() : ""
        suppressSave = false
        save()
    }

    func close() { flush(); save(); releaseRecord(); flushTask?.cancel(); rpc.event = { _ in }; rpc.close() }
}
