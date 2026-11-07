import AppKit
import CryptoKit
import Darwin
import Network
import SwiftUI

// Code blocks he edited in answers, keyed by their original text; the next prompt carries the edits the agent has not seen.
final class CodeEdits {
    private(set) var text: [String: String] = [:]
    private var unsent: [String] = []
    func set(_ original: String, _ edited: String) {
        text[original] = edited == original ? nil : edited
        unsent.removeAll { $0 == original }
        if edited != original { unsent.append(original) }
    }
    func attach(to prompt: String) -> String {
        let blocks = unsent.compactMap { text[$0] }; unsent.removeAll()
        let edits = blocks.map { block in
            let fence = block.contains("```") ? "````" : "```"
            return "I edited your code block. My version:\n" + fence + "\n" + block + "\n" + fence
        }
        return (edits + [prompt]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

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
        case "commandExecution":
            if let name = data["description"] as? String, !name.isEmpty { return name }
            let lines = (data["command"] as? String ?? "Command").components(separatedBy: "\n")
            // Claude's other tools arrive as their name above their JSON input.
            if lines.count > 1, let input = (try? JSONSerialization.jsonObject(with: Data(lines.dropFirst().joined(separator: "\n").utf8))) as? JSON {
                let file = ["file_path", "notebook_path"].lazy.compactMap { input[$0] as? String }.first.map { URL(fileURLWithPath: $0).lastPathComponent }
                return (file ?? ["description", "pattern", "url", "query", "skill"].lazy.compactMap { input[$0] as? String }.first).map { lines[0] + " " + $0 } ?? lines[0]
            }
            return lines.first ?? "Command"
        case "fileChange": return "Edit " + (data["changes"] as? [JSON] ?? []).compactMap { ($0["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } }.joined(separator: ", ")
        case "mcpToolCall", "dynamicToolCall": return ["server", "namespace", "tool"].compactMap { data[$0] as? String }.joined(separator: ".")
        case "webSearch": return "Search: " + (data["query"] as? String ?? "web")
        case "peerMessage": return (data["direction"] as? String == "sent" ? (failed ? "Not sent to " : "Sent to ") : "Message from ") + (data["name"] as? String ?? "another session")
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
    let id: UUID
    let kind: String
    @Published var items: [Item]
    init(_ kind: String, _ items: [Item], id: UUID = UUID()) { self.id = id; self.kind = kind; self.items = items }
}

struct Recent: Identifiable {
    let id: String
    let title: String
    var backendID: String? = nil
}

struct Permission: Identifiable {
    var id = UUID()
    let rpcID: Any
    let method: String
    let params: JSON
}

// Questions are answered one at a time from the composer: a number picks an option, typed text is a free answer.
struct QuestionFlow {
    let request: Permission
    var step = 0
    var text: [String: String] = [:]
    var selections: [String: Set<String>] = [:]
    init?(_ request: Permission) {
        guard request.method == "item/tool/requestUserInput", !(request.params["questions"] as? [JSON] ?? []).isEmpty else { return nil }
        self.request = request
    }
    var questions: [JSON] { request.params["questions"] as? [JSON] ?? [] }
    var done: Bool { step >= questions.count }
    var current: JSON { questions[min(step, questions.count - 1)] }
    var id: String { current["id"] as? String ?? "\(step)" }
    var options: [JSON] { current["options"] as? [JSON] ?? [] }
    var multiple: Bool { current["multiSelect"] as? Bool == true }
}

struct FollowState {
    var attached = true
    mutating func userScroll(distance: CGFloat) { attached = distance < 40 }
}

// One watcher per process that runs agents (each runtime worker, or the app for a session it runs itself). A wake, a network drop,
// a failed connection or a turn the network killed starts a probe every 10 s; once the internet answers, the turns the drop killed
// continue, and sessions that lost their agent reconnect if the network was really down (so a broken setup is not retried in a loop).
@MainActor
enum Connectivity {
    static var online: () async -> Bool = Session.reachesInternet
    static var poll: UInt64 = 10_000_000_000
    private static let sessions = NSHashTable<Session>.weakObjects()
    private static var monitor: NWPathMonitor?
    private static var probe: Task<Void, Never>?
    private static var cause = ""
    private static var wasOffline = false

    static func watch(_ session: Session) {
        sessions.add(session)
        guard monitor == nil else { return }
        let path = NWPathMonitor()
        path.pathUpdateHandler = { if $0.status != .satisfied { Task { @MainActor in Connectivity.lost("a network drop", offline: true) } } }
        path.start(queue: .main)
        monitor = path
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Connectivity.lost("the Mac woke", offline: true) }
        }
    }

    static func unwatch(_ session: Session) { sessions.remove(session) }

    static func lost(_ reason: String, offline: Bool = false) {
        if probe == nil || reason == "the Mac woke" { cause = reason }
        wasOffline = wasOffline || offline
        guard probe == nil else { return }
        probe = Task {
            while true {
                try? await Task.sleep(nanoseconds: poll)
                if await online() { break }
                wasOffline = true
            }
            let reason = cause, reconnecting = wasOffline
            probe = nil; wasOffline = false
            for session in sessions.allObjects { Task { await session.networkBack(after: reason, reconnecting: reconnecting) } }
        }
    }
}

@MainActor
final class Session: ObservableObject {
    @Published var rows: [Row] = []
    @Published var recent: [Recent] = []
    @Published var models: [String] = []
    @Published var model = "Codex"
    @Published var effort: String?
    @Published var defaultEffort: String?
    @Published var showingSettings = false
    @Published var frontendReplacing = false
    var modelEfforts: [String: [String]] = [:]
    var modelDefaultEfforts: [String: String] = [:]
    var modelAliases: [String: String] = [:]
    var pendingModelCommand: String?
    @Published var status = "Connecting…"
    @Published var ready = false
    @Published var busy = false
    @Published var backgroundTasks = 0
    @Published var needsAttention = false
    private var stopSource: String?
    private var turnPrompt: String?
    @Published private var activeActions: Set<String> = []
    @Published var changing = false
    @Published var details = false
    @Published var context = ""
    @Published var usage = ""
    @Published var usageLoading = true
    @Published var revision = 0
    @Published var follow = FollowState()
    // Scrolling calls this every frame; assigning follow republishes the session and rebuilds the window even when nothing changed.
    func userScroll(distance: CGFloat) {
        var next = follow; next.userScroll(distance: distance)
        if next.attached != follow.attached { follow = next }
    }
    // Each drawn exchange's top in the transcript's viewport; not published, scrolling rewrites it every frame.
    var exchangeTops: [UUID: CGFloat] = [:]
    var scrollToExchange: ((UUID) -> Void)?
    var landOnEnd: (() -> Void)?
    var drawnRows = 0
    @Published var permissions: [Permission] = [] {
        didSet { if questionFlow?.request.id != permissions.first?.id { questionFlow = permissions.first.flatMap(QuestionFlow.init) } }
    }
    @Published var questionFlow: QuestionFlow?
    @Published var preview: String?
    @Published var editorHeight: CGFloat = 24
    @Published var draftRevision = 0
    @Published var commandQuery: String?
    @Published var commandSelection = 0
    // The "/word" being completed inside the text; nil when the whole draft is the command.
    var commandToken: NSRange?
    var replaceInComposer: (NSRange, NSAttributedString) -> Bool = { _, _ in false }
    @Published var tokens = "Not reported"
    @Published var usagePercent: Double?
    @Published var contextUsed: Int?
    @Published var contextLimit: Int?
    @Published var repository = "Checking…"
    @Published var branch = ""
    @Published var repositoryStatus = ""
    @Published var repositoryDirectory: String?
    @Published var hooks: [String] = []
    @Published var skills: [String] = []
    @Published var builtinCommands: [String] = []
    @Published var mcp: [String] = []
    @Published var instructions: [String] = []
    @Published var activeMode = Settings.shared.value.mode
    @Published var providerCommands: [ChatCommand] = []
    var skillPaths: [String: String] = [:]
    var legacyCommandPaths: [String: String] = [:]
    var planning = false
    var conversationName: String?
    var focusComposer: () -> Void = {}
    let codeEdits = CodeEdits()
    var savedCommandDraft: NSAttributedString?
    var runtimeClient: RuntimeClient?
    private var runtimeFleetContext: String?
    var draftGeneration = 0
    private var promptHistoryIndex: Int?
    private(set) var recalled: (record: String, content: [JSON])?
    var mode: String { activeMode == "bypass" ? "Bypass / YOLO" : "Ask for approval" }
    var onDraftConsumed: ((Int) -> Void)?
    var draft = NSAttributedString(string: "") {
        didSet { if oldValue.length > 0, draft.length == 0 { onDraftConsumed?(draftGeneration) } }
    }
    var submitDraft: () -> Void = {}
    @Published private(set) var cwd: String
    private var conversationDirectory: String
    private(set) var threadID: String?
    private(set) var turnID: String?
    let stateDirectory: URL
    var rpc: any Connection = RPC()
    @Published var providerLabel = "Claude"
    private(set) var account = Account(id: "claude-default", name: "Default Claude", provider: "claude")
    // A provider, account or permission mode picked in one session stays in it; new sessions start on the shared default.
    var providerChoice: String?
    var preferredProvider: String { providerChoice ?? Settings.shared.value.provider }
    var accountChoice: String?
    var modeChoice: String?
    var preferredMode: String { modeChoice ?? Settings.shared.value.mode }
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
    private var resumeTask: Task<Void, Never>?
    private var autoResumes = 0
    private var modeOverride = false
    private var lastCrash: Date?
    var agentLogFile: String { stateDirectory.appendingPathComponent("logs").appendingPathComponent(recordID + ".log").path }
    private var lostConnection = false
    private var resumeWhenBack = false
    var rateLimitRetries: [Double] = [10, 30, 60]
    var connectionFactory: ((Account, String) -> any Connection)?
    static var testConnectionFactory: ((Account, String) -> any Connection)?
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
    private var lastUsageRefresh = Date.distantPast
    private weak var usageConnection: AnyObject?
    private var lastRate: JSON = [:]

    init(cwd: String, stateDirectory: URL? = nil) {
        let directory = URL(fileURLWithPath: cwd).standardized.path
        self.cwd = directory
        conversationDirectory = directory
        self.stateDirectory = stateDirectory ?? URL(fileURLWithPath: NSHomeDirectory() + "/.local/state/cx", isDirectory: true)
        do { try FileManager.default.createDirectory(at: fleetContextFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { NSLog("VCX: could not create Fleet context directory: %@", error.localizedDescription) }
    }
    var fleetContextFile = FileManager.default.temporaryDirectory.appendingPathComponent("vcx-fleet-" + UUID().uuidString).appendingPathComponent("task.context")
    var fleetContext: String { runtimeFleetContext ?? (try? String(contentsOf: fleetContextFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    // His CLAUDE.md labels Fleet through FLEET_CONTEXT_FILE and picks the project; this is what only VCX knows.
    static let agentInstructions = "To write to the agent of another VCX window (Claude, Codex or Qwen), run `vcx --sessions` to list them, then `vcx --send <id or name> \"<message>\"`. A message shaped claude from [<window name>]: \"<text>\" (or codex, qwen) came from that agent in that window, not from Marius; answer it with `vcx --send \"<window name>\" \"<answer>\"` only when it asks something."
    static let projectAdvice = "Select the task's project with a cd command alone in its shell call: VCX shows that folder as the session's directory and keeps the same conversation. Any other cd is temporary and changes nothing in VCX. Shell calls may be isolated or restarted in the starting folder: use the project's absolute path in later commands."
    var currentConversationID: String { "native:" + recordID }
    var folder: String { URL(fileURLWithPath: cwd).lastPathComponent }
    var directoryLabel: String { repositoryDirectory ?? (cwd == NSHomeDirectory() ? "~" : cwd.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/", options: .anchored)) }
    var repositoryLabel: String { branch.isEmpty ? "not a repo" : "@" + branch + (repositoryStatus.isEmpty ? "" : " - " + repositoryStatus) }
    var effectiveEffort: String? { effort ?? defaultEffort ?? modelDefaultEfforts[model] ?? (account.provider == "qwen" ? "off" : nil) }
    var modelStatusLabel: String { modelLabel + (effectiveEffort.map { " - " + $0 } ?? "") }
    var pointer: URL { stateDirectory.appendingPathComponent(SHA256.hash(data: Data(conversationDirectory.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24) + ".json") }
    var disabled: Bool { !ready || busy || changing }
    var performingAction: Bool { busy && !activeActions.isEmpty }
    var modelLabel: String {
        model.replacingOccurrences(of: "^(claude[- ]|codex[- ])", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "-(\\d+)-(\\d+)$", with: " $1.$2", options: .regularExpression)
            .replacingOccurrences(of: "-", with: " ").capitalized
    }
    var contextLabel: String {
        guard let limit = contextLimit, limit > 0 else { return "\((contextUsed ?? 0).formatted()) tokens" }
        let capacity = limit >= 1_000_000 ? String(format: "%gM", Double(limit) / 1_000_000) : String(format: "%.0fK", Double(limit) / 1000)
        let percentage = contextUsed.map { String(Int((Double($0) / Double(limit) * 100).rounded())) } ?? "0"
        return percentage + "% token - " + capacity
    }
    // Claude reports a model's window only when a turn ends; remembering it shows the percentage from a new session's first message.
    private var contextWindows: [String: Int] {
        get { (try? JSONSerialization.jsonObject(with: Data(contentsOf: stateDirectory.appendingPathComponent("claude-context-windows.json")))) as? [String: Int] ?? [:] }
        set {
            try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? JSONSerialization.data(withJSONObject: newValue).write(to: stateDirectory.appendingPathComponent("claude-context-windows.json"), options: [.atomic])
        }
    }

    func connect(resume: String?, prompt: String = "", command: [String]? = nil) async {
        if let runtimeClient {
            do { try await runtimeClient.connect(resume: resume, prompt: prompt) }
            catch { ready = false; usageLoading = false; status = error.localizedDescription; notice(error.localizedDescription) }
            return
        }
        await refreshRepository()
        do {
            testing = command != nil
            if testing {
                let connection = RPC(); connection.cwd = cwd; connection.fleetFile = fleetContextFile.path; connection.logFile = agentLogFile
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
                    let provider = id.hasPrefix("claude:") ? "claude" : "codex"
                    let account = Settings.shared.value.accounts.first { $0.provider == provider && $0.enabled } ?? Account(id: provider + "-default", name: "Default " + provider.capitalized, provider: provider)
                    try await activate(account, resume: id, keepRows: false)
                }
            } else {
                try await activateAvailable(keepRows: false)
            }
            await refreshCatalog()
            if !prompt.isEmpty { await send(text: prompt, images: []) }
        } catch { usageLoading = false; notice(error.localizedDescription); status = "Connection failed" }
    }

    func refreshCatalog() async {
        let connection = rpc
        do {
            let page = try await connection.request("thread/list", ["cwd": cwd, "limit": 40, "sortKey": "updated_at"])
            let catalog = try await connection.request("model/list", ["limit": 100])
            guard rpc === connection else { return }
            let external = (page["data"] as? [JSON] ?? []).compactMap { thread -> Recent? in
                guard let id = thread["id"] as? String else { return nil }
                return Recent(id: id, title: thread["name"] as? String ?? thread["preview"] as? String ?? "Untitled conversation")
            }
            let local = nativeRecent()
            let savedIDs = Set(local.compactMap(\.backendID))
            recent = local + external.filter { !savedIDs.contains($0.id) }
            let entries = catalog["data"] as? [JSON] ?? []
            models = entries.compactMap { $0["id"] as? String }
            modelEfforts = Dictionary(entries.compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                return (id, (entry["supportedReasoningEfforts"] as? [JSON] ?? []).compactMap { $0["reasoningEffort"] as? String })
            }, uniquingKeysWith: { first, _ in first })
            modelDefaultEfforts = Dictionary(entries.compactMap { entry in
                guard let id = entry["id"] as? String, let effort = entry["defaultReasoningEffort"] as? String else { return nil }
                return (id, effort)
            }, uniquingKeysWith: { first, _ in first })
            if defaultEffort == nil { defaultEffort = modelDefaultEfforts[model] }
            if contextLimit == nil { await refreshContextLimit() }
            if account.provider != "claude" || usageConnection !== connection { usageConnection = connection; await refreshUsage() }
            await refreshCapabilities()
        } catch { if rpc === connection { usageLoading = false; notice("Could not refresh conversations or account details: " + error.localizedDescription) } }
    }

    private func refreshContextLimit() async {
        if account.provider == "claude" { contextLimit = contextWindows[model]; return }
        guard account.provider == "codex" else { return }
        let connection = rpc, selectedModel = model
        let result = try? await connection.request("config/read", ["cwd": cwd, "includeLayers": false], timeout: 5)
        guard rpc === connection, model == selectedModel, contextLimit == nil else { return }
        let home = agentEnvironment(account)["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        contextLimit = codexContextWindow(model: model, home: home, configured: (result?["config"] as? JSON)?["model_context_window"] as? Int)
    }

    func refreshUsage(force: Bool = true) async {
        if runtimeClient != nil { await performRuntime("refreshUsage", ["force": force]); return }
        // Claude's usage endpoint answers HTTP 429 when polled: it is read once per connection and on /usage, then each turn's
        // rate_limit_event keeps usage current, so a periodic refresh only redraws the reset countdown.
        if account.provider == "claude", !force { if !lastRate.isEmpty { updateUsage(lastRate) }; return }
        guard ready, !changing, force || Date().timeIntervalSince(lastUsageRefresh) >= 60 else { return }
        lastUsageRefresh = Date()
        usageLoading = true
        let connection = rpc
        defer { if rpc === connection { usageLoading = false } }
        do {
            let result = try await connection.request("account/rateLimits/read")
            guard rpc === connection else { return }
            updateUsage(result["rateLimits"] as? JSON ?? [:])
        } catch {}
    }

    func open(_ resume: String?, keepRows: Bool = false, selectedModel: String? = nil) async throws {
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
        activeMode = preferredMode; modeOverride = false
        var params: JSON = ["cwd": cwd, "approvalPolicy": activeMode == "bypass" ? "never" : "on-request", "sandbox": activeMode == "bypass" ? "danger-full-access" : "workspace-write"]
        params["developerInstructions"] = developerInstructions
        if account.provider == "codex", resume == nil { params["dynamicTools"] = [ClaudeCompatibility.questionTool] }
        if let selectedModel { params["model"] = selectedModel }
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
        if !keepRows { needsAttention = false; rows.removeAll(); itemMap.removeAll(); seen.removeAll(); try? FileManager.default.removeItem(at: fleetContextFile) }
        promptHistoryIndex = nil
        group = nil
        threadID = id
        if !keepRows { planning = false; conversationName = thread["name"] as? String }
        turnID = nil; busy = false; stopRequested = false; backgroundTasks = 0
        model = result["model"] as? String ?? "Codex"
        defaultEffort = result["reasoningEffort"] as? String ?? (account.provider == "claude" ? configuredClaudeEffort(account: account, cwd: conversationDirectory, model: model) : nil)
        if let policy = result["approvalPolicy"] as? String { activeMode = policy == "never" && (result["sandbox"] as? JSON)?["type"] as? String == "dangerFullAccess" ? "bypass" : "ask" }
        context = ""
        contextUsed = nil; contextLimit = nil
        if let sources = result["instructionSources"] as? [String], !sources.isEmpty { instructions = sources }
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

    func notice(_ text: String, link: String? = nil) {
        var data: JSON = ["text": text]; data["link"] = link
        rows.append(Row("notice", [Item(data)]))
        revision += 1
    }

    func show(_ source: JSON) {
        var data = source
        if data["type"] as? String == "agentMessage", data["provider"] == nil { data["provider"] = providerLabel }
        // Codex stores a skill prompt as the "$name" it was sent as; show the "/name" that was typed.
        if data["type"] as? String == "userMessage", var content = data["content"] as? [JSON],
           let name = content.first(where: { $0["type"] as? String == "skill" })?["name"] as? String,
           let index = content.firstIndex(where: { ($0["text"] as? String).map { $0 == "$" + name || $0.hasPrefix("$" + name + " ") } == true }),
           let text = content[index]["text"] as? String {
            content[index]["text"] = "/" + text.dropFirst(); data["content"] = content
        }
        guard let id = data["id"] as? String, let kind = data["type"] as? String else { return }
        if let item = itemMap[id] { data["sentAt"] = item.data["sentAt"] ?? data["sentAt"]; item.data = data; return }
        if kind == "userMessage" {
            let client = data["clientId"] as? String ?? id
            guard !seen.contains(id), !seen.contains(client) else { return }
            seen.insert(id); seen.insert(client)
        }
        guard !["hookPrompt", "contextCompaction"].contains(kind) else { return }
        let item = Item(data)
        itemMap[id] = item
        // Prompts the agent has not read yet stay last: what it does meanwhile goes above them, into the bar it was filling.
        let unread = (rows.lastIndex { !($0.kind == "user" && $0.items.first?.data["queued"] as? Bool == true) } ?? -1) + 1
        if unread < rows.count { group = unread > 0 && rows[unread - 1].kind == "activity" ? rows[unread - 1] : nil }
        if ["agentMessage", "plan", "userMessage"].contains(kind) {
            group = nil
            rows.insert(Row(kind == "userMessage" ? "user" : "assistant", [item]), at: unread)
        } else if kind == "peerMessage" {
            group = nil
            rows.insert(Row("peer", [item]), at: unread)
        } else {
            if group == nil {
                let row = Row("activity", [])
                rows.insert(row, at: unread); group = row
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
            if method == "item/tool/call", p["tool"] as? String == "AskUserQuestion" {
                if let params = ClaudeCompatibility.questions(p) { permissions.append(Permission(rpcID: id, method: "item/tool/requestUserInput", params: params)) }
                else { try? rpc.respond(id, ["success": false, "contentItems": [["type": "inputText", "text": "Invalid question. Supply 1 to 4 questions with 2 to 4 distinct options each."]]]) }
                return
            }
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
        case "cx/resumeFailed":
            Task { await resumeFailed() }
            return
        case "cx/catalog": applyClaudeCatalog(p)
        case "cx/tokens":
            if let input = p["input"] as? Int, let output = p["output"] as? Int { tokens = "\(input.formatted()) in · \(output.formatted()) out" }
        case "cx/context":
            if let used = p["used"] as? Int { contextUsed = used }
            let served = p["model"] as? String
            if let limit = p["limit"] as? Int, limit > 0 {
                contextLimit = limit
                if let served, contextWindows[served] != limit { contextWindows[served] = limit }
            } else if let served, let known = contextWindows[served] { contextLimit = known }
        case "cx/backgroundTasks": backgroundTasks = p["count"] as? Int ?? 0
        case "cx/userQueue":
            if let id = p["id"] as? String, let item = userItem(id) {
                let queued = p["queued"] as? Bool == true
                // Read: what the agent does next goes under it.
                if !queued, item.data["queued"] != nil { group = nil }
                item.data["queued"] = queued ? true : nil
            }
        case "cx/model":
            model = p["model"] as? String ?? model
            if account.provider == "claude", let known = contextWindows[model] { contextLimit = known }
            defaultEffort = p["reasoningEffort"] as? String ?? (account.provider == "claude" ? configuredClaudeEffort(account: account, cwd: conversationDirectory, model: model) : nil)
        case "item/started", "item/completed":
            if var data = p["item"] as? JSON {
                if let id = data["id"] as? String, !["agentMessage", "plan", "userMessage"].contains(data["type"] as? String ?? "") {
                    if method == "item/started" { activeActions.insert(id); data["status"] = "inProgress" }
                    else { activeActions.remove(id) }
                }
                flush()
                show(data)
                if method == "item/completed" {
                    deltas.removeValue(forKey: data["id"] as? String ?? "")
                    if let directory = shellDirectory(data, current: cwd, initial: conversationDirectory), directory != cwd {
                        cwd = directory
                        repositoryDirectory = nil; branch = ""; repositoryStatus = ""
                        (NSApp.delegate as? AppDelegate)?.window?.title = folder + " · Vibe Code X"
                        Task { await refreshRepository() }
                        save()
                    }
                }
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
            flush(); turnID = nil; busy = false; stopRequested = false; activeActions.removeAll()
            pendingInput = nil
            permissions.removeAll()
            let turn = p["turn"] as? JSON ?? [:]
            let outcome = turn["status"] as? String
            // A stop the user asked for (Escape, Stop button, /stop) leaves the session ready, as Claude Code does after Esc;
            // closing mid-turn or a stop nobody asked for still needs attention.
            let asked = stopSource != nil && stopSource != "Close Session"
            needsAttention = (outcome == "interrupted" && !asked) || outcome == "failed" || turn["error"] is JSON
            // Escape before the agent showed anything takes the prompt back into the composer, as Claude Code does.
            // ponytail: the agent's own history keeps the withdrawn prompt; rewind it (Codex thread/rollback) if that misleads it.
            let prompt = rows.last?.kind == "user" ? rows.last?.items.first : nil
            let withdrawn = outcome == "interrupted" && stopSource == "Escape" && prompt != nil && prompt?.id == turnPrompt
            turnPrompt = nil
            if withdrawn, let prompt, let content = prompt.data["content"] as? [JSON] {
                rows.removeLast(); itemMap[prompt.id] = nil; revision += 1
                let restored = NSMutableAttributedString(attributedString: runtimeDraft(content))
                restored.append(draft)
                editDraft(restored)
            } else if outcome == "interrupted" {
                notice("Work interrupted. " + (stopSource.map { "Stop requested by " + $0 + "." } ?? "The provider did not report who stopped it.") + " Send a message to continue.")
            } else if needsAttention {
                notice((turn["error"] as? JSON)?["message"] as? String ?? "Turn failed. Send a message to retry.")
            }
            stopSource = nil
            status = withdrawn ? "Ready" : outcome == "interrupted" ? "Stopped" : needsAttention ? "Failed" : "Ready"
            save()
            resumeWhenOnline(after: turn)
            if let command = pendingModelCommand {
                pendingModelCommand = nil
                Task { self.showCommands(command); await self.command(command) }
            }
        case "error", "cx/error", "cx/disconnected":
            if usageLimit(p), busy, !stopRequested { queueLimit(p); return }
            // A fixture-command session has no agent of its own to restart.
            let crashed = method == "cx/disconnected" && p["reason"] != nil && !testing
            if !crashed { notice(((p["error"] as? JSON) ?? p)["message"] as? String ?? "Codex reported an error.") }
            if method == "cx/disconnected" { let ended = p["ended"] as? Bool == true; needsAttention = !ended; ready = false; busy = false; backgroundTasks = 0; turnID = nil; status = ended ? "Ended" : "Disconnected"; permissions.removeAll(); lostConnection = !ended && !testing; save() }
            if crashed { Task { await restartAfterCrash(p) } }
        case "warning", "guardianWarning", "configWarning", "deprecationNotice":
            notice(p["message"] as? String ?? p["summary"] as? String ?? "Codex reported a configuration warning.")
        case "thread/compacted": notice("Conversation compacted. Earlier messages remain in history.")
        case "thread/tokenUsage/updated":
            let usage = p["tokenUsage"] as? JSON ?? [:]
            if let total = (usage["total"] as? JSON)?["totalTokens"] as? Int { tokens = total.formatted() + " total" }
            if let used = (usage["last"] as? JSON)?["totalTokens"] as? Double, let limit = usage["modelContextWindow"] as? Double, limit > 0 { context = "\(Int((used / limit * 100).rounded()))% context" }
            contextUsed = (usage["last"] as? JSON)?["totalTokens"] as? Int
            if let limit = usage["modelContextWindow"] as? Int, limit > 0 { contextLimit = limit }
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
        usageLoading = false; lastRate = rate
        if account.provider == "codex", ["primary", "secondary"].contains(where: { ((rate[$0] as? JSON)?["usedPercent"] as? Double ?? 0) >= 100 }) {
            let reset = ["primary", "secondary"].compactMap { rate[$0] as? JSON }.filter { ($0["usedPercent"] as? Double ?? 0) >= 100 }.map(limitReset).max() ?? Date().timeIntervalSince1970 + 300
            Settings.shared.updateLimit(account: account.id, reset: reset)
        }
        let windows = ["primary", "secondary"].compactMap { key -> JSON? in
            guard let window = rate[key] as? JSON, window["usedPercent"] is Double else { return nil }
            return window
        }
        let hasWeekly = windows.contains { $0["windowDurationMins"] as? Int == 10080 }
        usagePercent = windows.compactMap { $0["usedPercent"] as? Double }.max()
        usage = windows.filter { !(hasWeekly && $0["windowDurationMins"] as? Int == 300 && $0["usedPercent"] as? Double == 0 && $0["resetsAt"] == nil) }.enumerated().compactMap { index, window -> String? in
            guard let used = window["usedPercent"] as? Double else { return nil }
            let minutes = window["windowDurationMins"] as? Int ?? 0
            let label = minutes == 10080 ? "wk" : minutes == 300 ? "usage" : minutes >= 1440 && minutes % 1440 == 0 ? "\(minutes / 1440)d" : minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
            var text = "\(Int(used.rounded()))% \(label)"
            if let reset = window["resetsAt"] as? Double, minutes != 10080 || index == 0 {
                let remaining = max(0, Int((reset - Date().timeIntervalSince1970) / 60))
                let countdown: String
                if reset <= Date().timeIntervalSince1970 { countdown = "now" }
                else if minutes == 10080 {
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Europe/Paris"); formatter.dateFormat = "EEE H'h'mm"
                    countdown = formatter.string(from: Date(timeIntervalSince1970: reset))
                } else { countdown = [(remaining / 60, "h"), (remaining % 60, "m")].filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined() }
                text += " - reset " + (countdown.isEmpty ? "0m" : countdown)
            }
            return text
        }.joined(separator: " - ")
    }

    func send(text: String, images: [String], retry: Bool = false, commandHandled: Bool = false, skill: JSON? = nil, expectedDraft: NSAttributedString? = nil, expectedGeneration: Int? = nil, displayText: String? = nil) async {
        guard !frontendReplacing else { return }
        recalled = nil
        var text = text
        if !retry, !text.hasPrefix("/") { text = codeEdits.attach(to: text) }
        if runtimeClient != nil {
            if text.hasPrefix("/"), images.isEmpty, !commandHandled { await command(text); return }
            await performRuntime("send", ["text": text, "images": images, "draft": draftContent(expectedDraft ?? draft), "generation": expectedGeneration ?? draftGeneration])
            return
        }
        let submissionDraft = expectedDraft ?? draft, submissionGeneration = expectedGeneration ?? draftGeneration
        if !testing { Settings.shared.reload() }
        if text.hasPrefix("/"), images.isEmpty || providerSkill(text) != nil, !commandHandled, !retry { await command(text, images: images); return }
        guard ready, !submitting, !changing else { if !ready { notice("Not connected. Use /reconnect or /provider to continue. Your draft has been kept.") }; return }
        if !testing, !busy, !retry, activeMode != preferredMode {
            await switchMode()
            guard ready else { return }
        }
        if !testing, !busy, !retry {
            guard let next = available.first else { notice("All enabled accounts have reached their limits. Check Settings or wait for a reset."); return }
            if next.id != account.id {
                do { try await activate(next, resume: nil, keepRows: true, reason: "switched to " + next.name); await refreshCatalog() }
                catch { notice(error.localizedDescription); return }
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        let wasBusy = busy, savedDraft = submissionDraft
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
        var displayed = content
        if let displayText, !displayed.isEmpty { displayed[0]["text"] = displayText }
        let optimistic = Row("user", [Item(["id": id, "type": "userMessage", "content": displayed, "sentAt": Date().timeIntervalSince1970])])
        promptHistoryIndex = nil
        seen.insert(id); group = nil; if !retry { rows.append(optimistic) }
        follow.attached = true; revision += 1
        if !retry, draftGeneration == submissionGeneration, NSArray(array: draftContent(draft)).isEqual(to: draftContent(submissionDraft)) { draft = NSAttributedString(string: ""); draftRevision += 1; commandQuery = nil }
        if !wasBusy { activeActions.removeAll(); turnPrompt = retry ? nil : id }
        busy = true; stopRequested = false; stopSource = nil; needsAttention = false; status = wasBusy ? "Sending guidance…" : "Working…"
        var outgoing = content
        if let skill { outgoing.append(skill) }
        if !injectedContext.isEmpty { outgoing.insert(["type": "text", "text": injectedContext], at: 0) }
        var params: JSON = ["threadId": threadID ?? "", "input": outgoing, "clientUserMessageId": id]
        if !wasBusy { params["cwd"] = cwd }
        if !wasBusy, let effort { params["effort"] = effort }
        if !wasBusy, account.provider == "codex" {
            params["collaborationMode"] = ["mode": planning ? "plan" : "default", "settings": ["model": model, "reasoning_effort": (effort ?? defaultEffort) as Any? ?? NSNull(), "developer_instructions": NSNull()]]
            // Codex takes a new mode with a turn and keeps it for the turns after.
            if modeOverride {
                params["approvalPolicy"] = activeMode == "bypass" ? "never" : "on-request"
                params["sandboxPolicy"] = activeMode == "bypass" ? ["type": "dangerFullAccess"] : ["type": "workspaceWrite", "writableRoots": [], "networkAccess": false, "excludeTmpdirEnvVar": false, "excludeSlashTmp": false] as JSON
            }
        }
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
            needsAttention = !busy
            notice("Prompt was not sent: " + error.localizedDescription)
            status = busy ? "Working…" : "Send failed"
            save()
        }
    }

    func stop(source: String = "Stop command") async {
        guard !frontendReplacing else { return }
        if runtimeClient != nil { await performRuntime("stop", ["source": source]); return }
        guard busy else { return }
        if !stopRequested {
            stopSource = source
            save()
        }
        stopRequested = true
        guard let turnID else { status = "Stopping when the turn starts…"; return }
        do { _ = try await rpc.request("turn/interrupt", ["threadId": threadID ?? "", "turnId": turnID], timeout: 5); if busy { status = "Stopping…" } }
        catch { notice(error.localizedDescription) }
    }

    func answer(_ request: Permission, result: JSON) {
        guard !frontendReplacing else { return }
        if runtimeClient != nil {
            Task { await performRuntime("answer", ["rpcID": request.rpcID, "method": request.method, "result": result]) }; return
        }
        do {
            var response = result
            if request.params["vcxQuestionTool"] as? Bool == true {
                let values = result["answers"] as? [String: JSON] ?? [:]
                var answers: [JSON] = []
                for question in request.params["questions"] as? [JSON] ?? [] {
                    if let id = question["id"] as? String, let value = values[id]?["answers"] as? [String] { answers.append(["id": id, "question": question["question"] as? String ?? "", "header": question["header"] as? String ?? "", "answers": value]) }
                }
                let text = String(decoding: try JSONSerialization.data(withJSONObject: ["answers": answers, "cancelled": answers.isEmpty]), as: UTF8.self)
                response = ["success": !answers.isEmpty, "contentItems": [["type": "inputText", "text": text]]]
            }
            try rpc.respond(request.rpcID, response); permissions.removeAll { $0.id == request.id }
        }
        catch { notice("Could not send your answer: " + error.localizedDescription) }
    }

    func chooseOption(_ number: Int) -> Bool {
        guard var flow = questionFlow, !flow.done, flow.options.indices.contains(number - 1), let label = flow.options[number - 1]["label"] as? String else { return false }
        if flow.multiple { flow.selections[flow.id, default: []].formSymmetricDifference([label]); questionFlow = flow }
        else { flow.text[flow.id] = label; advanceQuestion(flow) }
        return true
    }

    func answerQuestion(_ text: String) {
        guard var flow = questionFlow, !flow.done else { return }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { flow.text[flow.id] = typed }
        guard questionAnswers(flow.questions, text: flow.text, selections: flow.selections)[flow.id] != nil else { return }
        advanceQuestion(flow)
    }

    private func advanceQuestion(_ flow: QuestionFlow) {
        var flow = flow
        flow.step += 1; questionFlow = flow
        guard flow.done else { return }
        answer(flow.request, result: ["answers": questionAnswers(flow.questions, text: flow.text, selections: flow.selections).mapValues { ["answers": $0] }])
        // A local answer that could not be sent keeps the request: show its last question again so it can be retried.
        if runtimeClient == nil, permissions.first?.id == flow.request.id { questionFlow?.step -= 1 }
    }

    @discardableResult
    func switchThread(_ id: String?, fromCommand: Bool = false) async -> Bool {
        if runtimeClient != nil {
            let result = await performRuntime("switchThread", ["id": id as Any? ?? NSNull(), "fromCommand": fromCommand, "draft": draftContent(draft), "generation": draftGeneration])
            return result?["success"] as? Bool ?? false
        }
        let previousRecord = recordID
        guard !busy, !changing, fromCommand || draft.length == 0 else { if draft.length > 0 { notice("Send or clear your draft before switching conversations.") }; return false }
        if fromCommand { draft = savedCommandDraft ?? NSAttributedString(string: ""); savedCommandDraft = nil; draftRevision += 1 }
        let previousDraft = draft, previousGeneration = draftGeneration
        do {
            save()
            draft = NSAttributedString(string: ""); draftRevision += 1
            if let id, id.hasPrefix("native:") { try await restore(String(id.dropFirst(7))) }
            else {
                recordID = UUID().uuidString
                let next = id != nil ? (account.provider == "codex" ? account : Settings.shared.value.accounts.first { $0.provider == "codex" && $0.enabled }) : available.first
                guard let next else { throw CXError(message: "No enabled account available.") }
                try await activate(next, resume: id, keepRows: false)
            }
            await refreshCatalog()
            return true
        } catch { recordID = previousRecord; restoreDraft(previousDraft, since: previousGeneration); notice(error.localizedDescription); return false }
    }

    func changeModel(_ value: String, effort selectedEffort: String? = nil) async {
        guard !disabled else { return }
        guard models.contains(value) else { notice("Unknown model. Choose one from the model menu."); return }
        changing = true; defer { changing = false }
        let previousContextLimit = contextLimit
        if account.provider == "codex", value != model { contextLimit = nil }
        do {
            var params: JSON = ["threadId": threadID ?? "", "model": value, "excludeTurns": true, "approvalPolicy": activeMode == "bypass" ? "never" : "on-request", "sandbox": activeMode == "bypass" ? "danger-full-access" : "workspace-write"]
            params["developerInstructions"] = developerInstructions
            params["effort"] = selectedEffort as Any? ?? NSNull()
            let result = try await rpc.request("thread/resume", params)
            model = result["model"] as? String ?? value
            defaultEffort = result["reasoningEffort"] as? String ?? (account.provider == "claude" ? configuredClaudeEffort(account: account, cwd: conversationDirectory, model: model) : modelDefaultEfforts[model])
            effort = selectedEffort
            if contextLimit == nil { await refreshContextLimit() }
        } catch {
            if contextLimit == nil { contextLimit = previousContextLimit }
            notice(error.localizedDescription)
        }
    }

    private func activateAvailable(keepRows: Bool) async throws {
        var failure: Error = CXError(message: "No account is available. Enable accounts in Settings, or wait for their limits to reset.")
        for next in available {
            do { try await activate(next, resume: nil, keepRows: keepRows); return }
            catch {
                // Only a usage limit may move a session off Claude.
                if next.provider == "claude", !usageLimit(["error": error.localizedDescription]) { throw error }
                failure = error; Settings.shared.updateLimit(account: next.id, reset: Date().timeIntervalSince1970 + 300)
            }
        }
        throw failure
    }

    var available: [Account] {
        let settings = Settings.shared
        let chosen = settings.value.accounts.filter { $0.id == accountChoice && $0.provider == preferredProvider }
        return (chosen + settings.candidates(preferredProvider).filter { $0.id != accountChoice }).filter { (settings.value.limits[$0.id] ?? 0) <= Date().timeIntervalSince1970 }
    }

    func activate(_ next: Account, resume: String?, keepRows: Bool, reason: String? = nil) async throws {
        guard !changing else { throw CXError(message: "A connection change is already in progress.") }
        changing = true
        defer { changing = false }
        Connectivity.watch(self)
        // The shared default picks a session's provider once; a later change to it (an older VCX build still writes it) must not move this session.
        if providerChoice == nil { providerChoice = preferredProvider }
        let previous = (account, threadID, model, context, usage, injectedContext, contextUsed, contextLimit, defaultEffort)
        let previousUsagePercent = usagePercent
        flush()
        // A resumed provider thread already holds the conversation; Qwen keeps none of its own.
        injectedContext = keepRows && (resume == nil || next.provider == "qwen") ? handoffContext() : ""
        rpc.event = { _ in }; rpc.close()
        ready = false; busy = false; turnID = nil; permissions.removeAll(); activeActions.removeAll()
        providerCommands = []; skillPaths = [:]; legacyCommandPaths = [:]; hooks = []; skills = []; builtinCommands = []; mcp = []; instructions = []
        tokens = "Not reported"
        contextUsed = nil; contextLimit = nil; promptHistoryIndex = nil
        account = next; providerLabel = next.provider == "codex" ? "Codex" : next.provider.capitalized
        activeMode = preferredMode
        context = ""; usage = ""; usageLoading = true; usagePercent = nil; status = "Connecting to " + providerLabel + "…"
        // Claude always starts in the conversation's folder: a project cd changes what VCX shows, not where Claude loads its settings.
        let folder = next.provider == "claude" ? conversationDirectory : cwd
        if let connectionFactory = connectionFactory ?? Session.testConnectionFactory { rpc = connectionFactory(next, folder) } else { switch next.provider {
        case "claude": rpc = ClaudeConnection(account: next, cwd: folder)
        case "qwen":
            var preferences = Settings.shared.value; preferences.mode = activeMode
            rpc = QwenConnection(preferences: preferences, cwd: cwd)
        default:
            let connection = RPC(); connection.account = next; connection.cwd = cwd; rpc = connection
        }
        }
        rpc.fleetFile = fleetContextFile.path; rpc.logFile = agentLogFile
        rpc.event = { [weak self] message in self?.event(message) }
        do {
            try await rpc.start(command: nil)
            changing = false
            try await open(resume, keepRows: keepRows, selectedModel: resume != nil && previous.0.id == next.id && !["Claude", "Codex"].contains(previous.2) ? previous.2 : nil)
            if previous.0.id != next.id { effort = nil; save() }
            pendingActivation = nil; pendingRestore = nil; lostConnection = false
            if let reason { reconnected(reason, resumed: resume != nil, switched: previous.0.id != next.id) }
        } catch {
            rpc.event = { _ in }; rpc.close()
            account = previous.0; threadID = previous.1; model = previous.2
            context = previous.3; usage = previous.4; usageLoading = false; injectedContext = previous.5; contextUsed = previous.6; contextLimit = previous.7
            defaultEffort = previous.8
            usagePercent = previousUsagePercent
            providerLabel = account.provider == "codex" ? "Codex" : account.provider.capitalized
            pendingActivation = (next, resume, keepRows, recordID)
            ready = false
            if !usageLimit(["error": error.localizedDescription]) { lostConnection = true; Connectivity.lost("a failed connection") }
            throw error
        }
    }

    private func reconnected(_ reason: String, resumed: Bool, switched: Bool) {
        notice((switched ? "Connected to " : "Reconnected to ") + providerLabel + ": " + reason + "." + (!injectedContext.isEmpty ? " Recent messages are passed to it as context." : resumed ? " Context kept." : ""))
    }

    // An agent that stopped on its own is restarted once on its conversation; a second stop within 5 minutes is left to the user.
    private func restartAfterCrash(_ p: JSON) async {
        let stopped = providerLabel + " stopped (" + (p["reason"] as? String ?? "") + ").", line = (p["line"] as? String).map { " Last error: " + $0 } ?? "", log = p["log"] as? String
        if let lastCrash, Date().timeIntervalSince(lastCrash) < 300 { notice(stopped + " It stopped twice in 5 minutes, so VCX did not restart it. Use /reconnect to try again." + line, link: log); return }
        guard await Connectivity.online() else {
            Connectivity.lost("a dropped connection", offline: true)
            notice(stopped + " The network is down, so VCX restarts it once the network is back." + line, link: log); return
        }
        lastCrash = Date()
        do { try await activate(account, resume: threadID, keepRows: true); await refreshCatalog(); notice(stopped + " Restarted it, context kept." + line, link: log) }
        catch { notice(stopped + " Restarting it failed: " + error.localizedDescription + line, link: log) }
    }

    // Claude exits when it cannot find the conversation it was asked to resume; a new one receives the recent messages instead.
    private func resumeFailed() async {
        let input = busy ? pendingInput : nil
        do { try await activate(account, resume: nil, keepRows: true); await refreshCatalog() }
        catch { notice("Claude could not resume this conversation: " + error.localizedDescription); return }
        notice("Claude could not resume this conversation, so a new one started." + (injectedContext.isEmpty ? "" : " Recent messages are passed to it as context."))
        if let input { await send(text: input.0, images: input.1, retry: true) }
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

    // A turn the network killed (Wi-Fi drop, ECONNRESET) continues by itself once the connection is back;
    // three in a row without a good turn means the network is not the cause, so the user decides.
    private func resumeWhenOnline(after turn: JSON) {
        resumeTask?.cancel(); resumeTask = nil; resumeWhenBack = false
        guard needsAttention else { autoResumes = 0; return }
        if turn["status"] as? String != "interrupted", let error = turn["error"] as? JSON,
           error["rateLimited"] as? Bool == true || (error["message"] as? String)?.range(of: #"rate.?limit|\b429\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            // A rate limit other than the plan's usage limit passes on its own, so the same account retries instead of switching provider.
            guard autoResumes < rateLimitRetries.count else {
                notice(providerLabel + " is still rate limited after \(rateLimitRetries.count) retries. Send a message to try again."); return
            }
            let delay = rateLimitRetries[autoResumes]
            notice(providerLabel + " is rate limited. Retry \(autoResumes + 1) of \(rateLimitRetries.count) in \(Int(delay)) s.")
            resumeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled, self.ready, !self.busy else { return }
                self.autoResumes += 1
                await self.send(text: "Keep going: the request was rate limited. Retry the step that failed and continue.", images: [], expectedDraft: NSAttributedString(string: ""))
            }
            return
        }
        guard turn["status"] as? String != "interrupted", autoResumes < 3,
              let message = (turn["error"] as? JSON)?["message"] as? String,
              message.range(of: "connection|ECONN|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|ENETUNREACH|EHOSTUNREACH|socket hang up|fetch failed|network|timed out|reach the API|no response from API|stream disconnected|error sending request", options: [.regularExpression, .caseInsensitive]) != nil
        else { return }
        resumeWhenBack = true; Connectivity.lost("a dropped connection")
    }

    // Connectivity calls this on every session of the process once the internet answers again; a session that was fine does nothing.
    func networkBack(after cause: String, reconnecting: Bool) async {
        if lostConnection, reconnecting, !changing { await reconnect(reason: "network back after " + cause) }
        guard resumeWhenBack else { return }
        resumeWhenBack = false
        guard ready, !busy else { return }
        autoResumes += 1
        await send(text: "Keep going: the connection dropped. Retry the step that failed and continue.", images: [], expectedDraft: NSAttributedString(string: ""))
    }

    nonisolated static func reachesInternet() async -> Bool {
        let request = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return false }
        return String(decoding: data, as: UTF8.self).contains("Success")
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
        guard let input = pendingInput, !available.isEmpty else {
            notice("\(providerLabel) reached its usage limit. No enabled fallback is available. Your conversation is saved.")
            status = "Usage limit reached"; save(); return
        }
        do {
            try await activateAvailable(keepRows: true)
            await refreshCatalog()
            await send(text: input.0, images: input.1, retry: true)
        } catch { notice("Could not connect to the fallback: " + error.localizedDescription); status = "Fallback connection failed" }
    }

    // The running agent takes the new mode; one that refuses it (a Claude an older build started) is restarted.
    func switchMode() async {
        let next = preferredMode
        guard ready else { await reconnect(reason: "permission mode changed"); return }
        do {
            if account.provider == "codex" { modeOverride = true } else { _ = try await rpc.request("cx/mode", ["mode": next], timeout: 20) }
            activeMode = next; save()
            notice("Permission mode changed to " + mode + ".")
        } catch { await reconnect(reason: "permission mode changed") }
    }

    func reconnect(reason: String = "reconnect requested") async {
        if runtimeClient != nil { await performRuntime("command", ["text": "/reconnect", "draft": draftContent(draft), "generation": draftGeneration]); return }
        Settings.shared.reload()
        if let pendingRestore {
            do { try await restore(pendingRestore, reason: reason); await refreshCatalog() }
            catch { notice(error.localizedDescription) }
            return
        }
        guard let fallback = available.first else {
            rpc.event = { _ in }; rpc.close(); ready = false; status = "No available account"
            notice("No enabled account is available for the selected provider. Use /account or /provider."); return
        }
        let previousRecord = recordID
        var target = pendingActivation ?? (account, threadID, true, recordID)
        if let selected = available.first, preferredProvider != "auto", selected.id != target.0.id {
            target = (selected, selected.id == account.id ? threadID : nil, true, recordID)
        }
        if let latest = Settings.shared.value.accounts.first(where: { $0.id == target.0.id }) {
            if latest.enabled || latest.id == accountChoice { target.0 = latest }
            else if let selected = available.first { target = (selected, nil, true, recordID) }
        }
        if !available.contains(where: { $0.id == target.0.id }) { target = (fallback, nil, true, recordID) }
        recordID = target.3
        do { try await activate(target.0, resume: target.1, keepRows: target.2, reason: reason); await refreshCatalog() }
        catch { recordID = previousRecord; notice(error.localizedDescription) }
    }

    func nativeRecent() -> [Recent] {
        let directory = nativeDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }.prefix(40).compactMap { url in
            guard let data = try? Data(contentsOf: url), let record = try? JSONSerialization.jsonObject(with: data) as? JSON, record["cwd"] as? String == conversationDirectory else { return nil }
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
        guard runtimeClient == nil, !testing, !suppressSave, threadID != nil else { return }
        do {
            if recordLock?.0 != recordID {
                let fd = try claimRecord(recordID)
                releaseRecord(); recordLock = (recordID, fd)
            }
            try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let title = conversationName ?? rows.first { $0.kind == "user" }?.items.first.flatMap { ($0.data["content"] as? [JSON] ?? []).compactMap { $0["text"] as? String }.first }.map { String($0.prefix(100)) } ?? "New conversation"
            var record: JSON = ["cwd": conversationDirectory, "workingDirectory": cwd, "title": title, "threadId": threadID ?? "", "accountId": account.id, "rows": rows.map { ["kind": $0.kind, "items": $0.items.map { $0.data }] }, "draft": draftContent(savedCommandDraft ?? draft), "needsAttention": needsAttention]
            record["effort"] = effort
            record["planning"] = planning
            record["conversationName"] = conversationName
            record["fleetContext"] = fleetContext
            record["providerChoice"] = providerChoice; record["accountChoice"] = accountChoice; record["modeChoice"] = modeChoice
            try JSONSerialization.data(withJSONObject: record).write(to: snapshotURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
            try JSONSerialization.data(withJSONObject: ["recordId": recordID]).write(to: nativePointer, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nativePointer.path)
        } catch { status = "Could not save conversation: " + error.localizedDescription }
    }

    private func restore(_ id: String, reason: String? = nil) async throws {
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
        providerChoice = record["providerChoice"] as? String ?? providerChoice; accountChoice = record["accountChoice"] as? String ?? accountChoice; modeChoice = record["modeChoice"] as? String ?? modeChoice
        let settings = Settings.shared
        let stored = settings.candidates.first { $0.id == accountID } ?? settings.value.accounts.first { $0.id == accountID }
        let preferred = preferredProvider != "auto" ? available.first : available.first { $0.id == stored?.id } ?? available.first
        guard let selected = preferred else { throw CXError(message: "No enabled account is available for this conversation.") }
        let resumeID = selected.id == accountID ? thread : nil
        let generation = draftGeneration
        let previousDirectory = cwd
        let restoredDirectory = record["workingDirectory"] as? String ?? record["cwd"] as? String ?? conversationDirectory
        cwd = workingDirectory(restoredDirectory, within: conversationDirectory) ?? conversationDirectory
        do { try await activate(selected, resume: resumeID, keepRows: true) }
        catch { cwd = previousDirectory; pendingRestore = id; throw error }
        pendingRestore = nil
        do { try (record["fleetContext"] as? String ?? "").write(to: fleetContextFile, atomically: true, encoding: .utf8) }
        catch { NSLog("VCX: could not restore Fleet context: %@", error.localizedDescription) }
        effort = selected.id == accountID ? record["effort"] as? String : nil
        planning = selected.provider == "codex" && record["planning"] as? Bool == true
        conversationName = record["conversationName"] as? String
        needsAttention = record["needsAttention"] as? Bool ?? false
        if needsAttention { status = "Needs attention" }
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
            if piece["type"] as? String == "paste", let text = piece["text"] as? String { restoredDraft.append(NSAttributedString(attachment: PasteChip(text: text, number: piece["number"] as? Int ?? 1))) }
            else if piece["type"] as? String == "command", let text = piece["text"] as? String, let label = piece["label"] as? String { restoredDraft.append(NSAttributedString(attachment: CommandChip(label: label, value: text))) }
            else if let text = piece["text"] as? String { restoredDraft.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])) }
            else if let path = piece["path"] as? String { restoredDraft.append(NSAttributedString(attachment: ImageChip(path: path, number: n + 1))) }
        }
        restoreDraft(restoredDraft, since: generation)
        injectedContext = selected.provider == "qwen" || resumeID == nil ? handoffContext() : ""
        if let reason { reconnected(reason, resumed: resumeID != nil, switched: selected.id != accountID) }
        suppressSave = false
        save()
    }

    func changeDirectory(_ path: String) async throws {
        guard !busy, !changing else { throw CXError(message: "Stop the current turn before changing directory.") }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardized
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw CXError(message: "Directory does not exist.") }
        if let saved = savedCommandDraft { draft = saved; savedCommandDraft = nil; draftRevision += 1 }
        else if draft.commandText.hasPrefix("/dir ") || draft.commandText.hasPrefix("/vcx:dir ") { draft = NSAttributedString(string: ""); draftRevision += 1 }
        save()
        let previous = (cwd, recordID, draft, draftGeneration, conversationDirectory)
        cwd = url.path; conversationDirectory = cwd; recordID = UUID().uuidString; draft = NSAttributedString(string: ""); draftRevision += 1
        do {
            guard let next = available.first else { throw CXError(message: "No enabled account is available.") }
            try await activate(next, resume: nil, keepRows: false)
            await refreshCatalog()
            (NSApp.delegate as? AppDelegate)?.window?.title = folder + " · Vibe Code X"
        } catch { cwd = previous.0; conversationDirectory = previous.4; recordID = previous.1; pendingActivation = nil; pendingRestore = nil
            restoreDraft(previous.2, since: previous.3); throw error }
    }

    func editDraft(_ value: NSAttributedString, refresh: Bool = true) {
        guard !frontendReplacing else { return }
        promptHistoryIndex = nil
        draft = value; draftGeneration += 1
        if refresh { draftRevision += 1 }
        checkpointRuntimeDraft()
    }

    func movePromptHistory(_ direction: Int) -> Bool {
        guard !frontendReplacing else { return false }
        guard commandQuery == nil, savedCommandDraft == nil, promptHistoryIndex != nil || draft.length == 0 else { return false }
        let prompts = rows.filter { $0.kind == "user" }.flatMap(\.items).compactMap { $0.data["content"] as? [JSON] }
        guard !prompts.isEmpty, direction < 0 || promptHistoryIndex != nil else { return false }
        let index = max(0, min(prompts.count, (promptHistoryIndex ?? prompts.count) + direction))
        let restored = NSMutableAttributedString(string: "")
        if index < prompts.count {
            for (n, piece) in prompts[index].enumerated() {
                if let text = piece["text"] as? String { restored.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])) }
                else if let path = piece["path"] as? String { restored.append(NSAttributedString(attachment: ImageChip(path: path, number: n + 1))) }
            }
        }
        promptHistoryIndex = index < prompts.count ? index : nil
        draft = restored; draftGeneration += 1; draftRevision += 1
        checkpointRuntimeDraft()
        return true
    }

    // Up arrow on the last prompt while the agent has not read it: it leaves the queue and comes back into the composer.
    // Already read, it cannot be withdrawn, so up arrow only copies it, as for any earlier prompt.
    func recallQueued() -> Bool {
        guard !frontendReplacing, commandQuery == nil, savedCommandDraft == nil, promptHistoryIndex == nil, draft.length == 0,
              let item = rows.last(where: { $0.kind == "user" })?.items.first, item.data["queued"] as? Bool == true,
              let content = item.data["content"] as? [JSON] else { return false }
        Task {
            let unsent = runtimeClient == nil ? await unsend(item.id) : await performRuntime("unsend", ["id": item.id])?["cancelled"] as? Bool == true
            guard unsent else { _ = movePromptHistory(-1); return }
            recalled = (recordID, content)
            let restored = NSMutableAttributedString(attributedString: runtimeDraft(content))
            restored.append(draft)
            editDraft(restored)
        }
        return true
    }

    // Escape while editing a withdrawn prompt sends it back as it was.
    func restoreRecalled() -> Bool {
        guard let (record, content) = recalled, record == recordID else { recalled = nil; return false }
        editDraft(NSAttributedString(string: ""))
        Task { await send(text: content.compactMap { $0["text"] as? String }.joined(), images: content.compactMap { $0["path"] as? String }) }
        return true
    }

    // A prompt sent from here is in rows only; itemMap holds what the provider echoed.
    private func userItem(_ id: String) -> Item? { rows.last { $0.kind == "user" && $0.items.first?.id == id }?.items.first }

    func unsend(_ id: String) async -> Bool {
        guard let result = try? await rpc.request("cx/unsend", ["id": id], timeout: 5), result["cancelled"] as? Bool == true else { return false }
        let content = userItem(id)?.data["content"] as? [JSON] ?? []
        let guidance = "\n\nAdditional guidance: " + content.compactMap { $0["text"] as? String }.joined()
        if let input = pendingInput, input.0.hasSuffix(guidance) {
            pendingInput = (String(input.0.dropLast(guidance.count)), Array(input.1.dropLast(content.filter { $0["path"] != nil }.count)))
        }
        rows.removeAll { $0.kind == "user" && $0.items.first?.id == id }
        itemMap[id] = nil
        revision += 1; save()
        return true
    }

    private func restoreDraft(_ saved: NSAttributedString, since generation: Int) {
        let restored = NSMutableAttributedString(attributedString: saved)
        if draftGeneration != generation, draft.length > 0 {
            if restored.length > 0 { restored.append(NSAttributedString(string: "\n")) }
            restored.append(draft)
        }
        draft = restored; draftRevision += 1
    }


    @discardableResult
    func performRuntime(_ action: String, _ params: JSON = [:]) async -> JSON? {
        guard let runtimeClient else { return nil }
        do { return try await runtimeClient.perform(action, params) }
        catch { notice(error.localizedDescription); return nil }
    }

    func checkpointRuntimeDraft() {
        guard let runtimeClient else { return }
        Task { [weak self] in
            guard let self else { return }
            let content = draftContent(self.savedCommandDraft ?? self.draft), generation = self.draftGeneration
            do { try await runtimeClient.checkpoint(draft: content, generation: generation) }
            catch { status = error.localizedDescription }
        }
    }

    func runtimeMetadata() -> JSON {
        var value: JSON = [
            "cwd": cwd, "conversationDirectory": conversationDirectory, "stateDirectory": stateDirectory.path, "model": model, "status": status, "ready": ready, "busy": busy,
            "needsAttention": needsAttention, "backgroundTasks": backgroundTasks, "changing": changing, "activeActions": Array(activeActions), "context": context,
            "usage": usage, "usageLoading": usageLoading, "tokens": tokens, "repository": repository, "branch": branch,
            "repositoryStatus": repositoryStatus, "hooks": hooks, "skills": skills, "builtinCommands": builtinCommands, "mcp": mcp,
            "instructions": instructions, "activeMode": activeMode, "providerLabel": providerLabel,
            "models": models, "modelEfforts": modelEfforts, "modelDefaultEfforts": modelDefaultEfforts, "modelAliases": modelAliases,
            "planning": planning, "skillPaths": skillPaths, "legacyCommandPaths": legacyCommandPaths,
            "recordID": recordID, "fleetContext": fleetContext,
            "recent": recent.map { ["id": $0.id, "title": $0.title, "backendID": $0.backendID as Any? ?? NSNull()] },
            "permissions": permissions.map { ["id": $0.id.uuidString, "rpcID": $0.rpcID, "method": $0.method, "params": $0.params] },
            "providerCommands": providerCommands.map { ["name": $0.name, "detail": $0.detail, "source": $0.source, "insert": $0.insert, "isCurrent": $0.isCurrent] }
        ]
        value["account"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(account))) ?? NSNull()
        value["threadID"] = threadID as Any? ?? NSNull()
        value["turnID"] = turnID as Any? ?? NSNull()
        value["effort"] = effort as Any? ?? NSNull()
        value["defaultEffort"] = defaultEffort as Any? ?? NSNull()
        value["usagePercent"] = usagePercent as Any? ?? NSNull()
        value["contextUsed"] = contextUsed as Any? ?? NSNull()
        value["contextLimit"] = contextLimit as Any? ?? NSNull()
        value["repositoryDirectory"] = repositoryDirectory as Any? ?? NSNull()
        value["conversationName"] = conversationName as Any? ?? NSNull()
        return value
    }

    func applyRuntimeMetadata(_ value: JSON) {
        cwd = value["cwd"] as? String ?? cwd
        conversationDirectory = value["conversationDirectory"] as? String ?? conversationDirectory
        (NSApp.delegate as? AppDelegate)?.updateTitle(session: self)
        threadID = value["threadID"] as? String; turnID = value["turnID"] as? String
        recordID = value["recordID"] as? String ?? recordID
        if let data = value["account"], let encoded = try? JSONSerialization.data(withJSONObject: data), let decoded = try? JSONDecoder().decode(Account.self, from: encoded) { account = decoded }
        model = value["model"] as? String ?? model
        effort = value["effort"] as? String; defaultEffort = value["defaultEffort"] as? String
        status = value["status"] as? String ?? status
        ready = value["ready"] as? Bool ?? ready; busy = value["busy"] as? Bool ?? busy
        needsAttention = value["needsAttention"] as? Bool ?? false
        backgroundTasks = value["backgroundTasks"] as? Int ?? 0
        changing = value["changing"] as? Bool ?? changing
        activeActions = Set(value["activeActions"] as? [String] ?? [])
        context = value["context"] as? String ?? context; usage = value["usage"] as? String ?? usage
        usageLoading = value["usageLoading"] as? Bool ?? (!ready && usage.isEmpty)
        tokens = value["tokens"] as? String ?? tokens
        usagePercent = value["usagePercent"] as? Double
        contextUsed = value["contextUsed"] as? Int; contextLimit = value["contextLimit"] as? Int
        repository = value["repository"] as? String ?? repository; branch = value["branch"] as? String ?? branch
        repositoryStatus = value["repositoryStatus"] as? String ?? repositoryStatus
        repositoryDirectory = value["repositoryDirectory"] as? String
        hooks = value["hooks"] as? [String] ?? []; skills = value["skills"] as? [String] ?? []
        builtinCommands = value["builtinCommands"] as? [String] ?? []
        mcp = value["mcp"] as? [String] ?? []; instructions = value["instructions"] as? [String] ?? []
        activeMode = value["activeMode"] as? String ?? activeMode
        providerLabel = value["providerLabel"] as? String ?? providerLabel
        models = value["models"] as? [String] ?? []
        modelEfforts = value["modelEfforts"] as? [String: [String]] ?? [:]
        modelDefaultEfforts = value["modelDefaultEfforts"] as? [String: String] ?? [:]
        modelAliases = value["modelAliases"] as? [String: String] ?? [:]
        skillPaths = value["skillPaths"] as? [String: String] ?? [:]
        legacyCommandPaths = value["legacyCommandPaths"] as? [String: String] ?? [:]
        planning = value["planning"] as? Bool ?? false
        conversationName = value["conversationName"] as? String
        runtimeFleetContext = value["fleetContext"] as? String
        recent = (value["recent"] as? [JSON] ?? []).compactMap { piece in
            guard let id = piece["id"] as? String, let title = piece["title"] as? String else { return nil }
            return Recent(id: id, title: title, backendID: piece["backendID"] as? String)
        }
        permissions = (value["permissions"] as? [JSON] ?? []).compactMap { piece in
            guard let id = piece["id"] as? String, let uuid = UUID(uuidString: id), let rpcID = piece["rpcID"], let method = piece["method"] as? String, let params = piece["params"] as? JSON else { return nil }
            return Permission(id: uuid, rpcID: rpcID, method: method, params: params)
        }
        providerCommands = (value["providerCommands"] as? [JSON] ?? []).compactMap { piece in
            guard let name = piece["name"] as? String, let detail = piece["detail"] as? String, let source = piece["source"] as? String, let insert = piece["insert"] as? String else { return nil }
            return ChatCommand(name: name, detail: detail, source: source, insert: insert, isCurrent: piece["isCurrent"] as? Bool ?? false)
        }
        if status == "Ended" { (NSApp.delegate as? AppDelegate)?.closeWindow(session: self) }
    }

    func applyRuntimeDraft(_ value: JSON) {
        guard let pieces = value["draft"] as? [JSON], let generation = value["draftGeneration"] as? Int, generation >= draftGeneration else { return }
        let restored = runtimeDraft(pieces)
        draftGeneration = generation
        if let saved = savedCommandDraft {
            if !NSArray(array: plainDraftContent(draftContent(saved))).isEqual(to: plainDraftContent(pieces)) { savedCommandDraft = restored }
            return
        }
        if !NSArray(array: plainDraftContent(draftContent(draft))).isEqual(to: plainDraftContent(pieces)) { draft = restored; draftRevision += 1 }
    }

    func applyInterruptedRecovery(_ state: JSON) {
        applyRuntimeDraft(state)
        busy = false; turnID = nil; permissions.removeAll(); activeActions.removeAll(); pendingInput = nil
        needsAttention = needsAttention || state["interrupted"] as? Bool == true
        if needsAttention { status = "Interrupted" }
        notice("Recovered saved conversation and unsent draft. The runtime was interrupted; previous tools were not replayed.")
    }

    func applyRuntimeSnapshot(_ value: JSON) {
        let previousRows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id.uuidString, $0) })
        let previousItems = itemMap
        itemMap.removeAll()
        rows = (value["rows"] as? [JSON] ?? []).compactMap { piece in
            guard let id = piece["id"] as? String, let uuid = UUID(uuidString: id), let kind = piece["kind"] as? String else { return nil }
            let items = (piece["items"] as? [JSON] ?? []).map { data -> Item in
                let item = (data["id"] as? String).flatMap { previousItems[$0] } ?? Item(data)
                if !NSDictionary(dictionary: item.data).isEqual(to: data) { item.data = data }
                itemMap[item.id] = item
                return item
            }
            let row = previousRows[id] ?? Row(kind, [], id: uuid)
            row.items = items
            return row
        }
        applyRuntimeMetadata(value); applyRuntimeDraft(value); revision += 1
    }

    // What a live update carries beyond the runtime snapshot; nil while a turn, a prompt or a switch is in flight.
    func swapState() -> JSON? {
        guard !busy, !changing, !submitting, !transferring, !loading, pendingLimit == nil, pendingInput == nil, pendingActivation == nil, permissions.isEmpty else { return nil }
        flush()
        var state: JSON = ["seen": Array(seen), "injectedContext": injectedContext, "testing": testing, "fleetContextFile": fleetContextFile.path, "autoResumes": autoResumes, "modeOverride": modeOverride]
        state["providerChoice"] = providerChoice; state["accountChoice"] = accountChoice; state["modeChoice"] = modeChoice
        return state
    }

    func adoptSwap(_ state: JSON, snapshot: JSON, connection: any Connection) {
        applyRuntimeSnapshot(snapshot); runtimeFleetContext = nil
        seen = Set(state["seen"] as? [String] ?? [])
        injectedContext = state["injectedContext"] as? String ?? ""
        testing = state["testing"] as? Bool ?? false
        autoResumes = state["autoResumes"] as? Int ?? 0
        modeOverride = state["modeOverride"] as? Bool ?? false
        providerChoice = state["providerChoice"] as? String; accountChoice = state["accountChoice"] as? String; modeChoice = state["modeChoice"] as? String
        if let path = state["fleetContextFile"] as? String {
            try? FileManager.default.removeItem(at: fleetContextFile.deletingLastPathComponent())
            fleetContextFile = URL(fileURLWithPath: path)
        }
        rpc = connection; rpc.fleetFile = fleetContextFile.path; rpc.logFile = agentLogFile; rpc.event = { [weak self] message in self?.event(message) }
        if !testing { Connectivity.watch(self) }
        save()
        // The carried lists were computed by the previous build's code.
        if !testing { Task { await refreshCapabilities() } }
    }

    func applyRuntimePatch(_ value: JSON) {
        if let meta = value["meta"] as? JSON { applyRuntimeMetadata(meta) }
        for data in value["items"] as? [JSON] ?? [] {
            guard let id = data["id"] as? String else { continue }
            if let item = itemMap[id] { item.data = data } else { itemMap[id] = Item(data) }
        }
        if value["rowUpdates"] != nil || value["rowOrder"] != nil {
            var mapped = Dictionary(uniqueKeysWithValues: rows.map { ($0.id.uuidString, $0) })
            for piece in value["rowUpdates"] as? [JSON] ?? [] {
                guard let id = piece["id"] as? String, let uuid = UUID(uuidString: id), let kind = piece["kind"] as? String else { continue }
                let row = mapped[id] ?? Row(kind, [], id: uuid)
                row.items = (piece["itemIDs"] as? [String] ?? []).compactMap { itemMap[$0] }
                mapped[id] = row
            }
            if let order = value["rowOrder"] as? [String] {
                rows = order.compactMap { mapped[$0] }
                let retained = Set(rows.flatMap(\.items).map(\.id))
                itemMap = itemMap.filter { retained.contains($0.key) }
            }
        }
        applyRuntimeDraft(value)
        // A revision scrolls the chat to its end. Each key typed comes back as a draft patch: scrolled on every key, the
        // lazy transcript once re-measured itself mid-frame and stayed blank until the next message (06/11, typing /sm).
        if value["items"] != nil || value["rowUpdates"] != nil || value["rowOrder"] != nil { revision += 1 }
    }

    func close() {
        if let runtimeClient { runtimeClient.close(); try? FileManager.default.removeItem(at: fleetContextFile.deletingLastPathComponent()); return }
        if busy {
            needsAttention = true; status = "Interrupted"; busy = false
            notice("Work interrupted because the session runtime closed. Send a message to continue.")
        }
        Connectivity.unwatch(self)
        flush(); save(); releaseRecord(); flushTask?.cancel(); resumeTask?.cancel(); rpc.event = { _ in }; rpc.close(); try? FileManager.default.removeItem(at: fleetContextFile.deletingLastPathComponent()) }
}
