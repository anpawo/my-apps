import AppKit
import Combine

@MainActor
func runtimeDraft(_ pieces: [JSON]) -> NSAttributedString {
    let value = NSMutableAttributedString(string: "")
    for (index, piece) in pieces.enumerated() {
        if piece["type"] as? String == "paste", let text = piece["text"] as? String {
            value.append(NSAttributedString(attachment: PasteChip(text: text, number: piece["number"] as? Int ?? 1)))
        } else if let text = piece["text"] as? String {
            value.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black]))
        } else if let path = piece["path"] as? String {
            value.append(NSAttributedString(attachment: ImageChip(path: path, number: index + 1)))
        }
    }
    return value
}

@MainActor
final class SessionBackend: RuntimeBackend {
    let session: Session
    var onChange: ((JSON) -> Void)?
    private var subscriptions: [AnyCancellable] = []
    private var rowSubscriptions: [UUID: AnyCancellable] = [:]
    private var itemSubscriptions: [String: AnyCancellable] = [:]
    private var pendingRows: [UUID: Row] = [:]
    private var pendingItems: [String: JSON] = [:]
    private var rowOrder: [String]?
    private var lastMetadata: JSON = [:]
    private var lastDraftRevision = -1
    private var lastDraftGeneration = -1
    private var windowState: JSON = [:]
    private var checkpointDraft: NSAttributedString?
    private var checkpointGeneration = 0
    private var publication: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var closed = false
    private var consumedGeneration = -1
    private var runtimeID: String?
    private var persistedCheckpoint: Data?
    private var recoveryState: JSON?
    private var configured = false

    init(session: Session) {
        self.session = session
        session.onDraftConsumed = { [weak self] generation in
            guard let self, recoveryState == nil else { return }
            consumedGeneration = max(consumedGeneration, generation)
        }
        subscriptions.append(session.objectWillChange.sink { [weak self] _ in self?.schedule() })
        subscriptions.append(session.$rows.sink { [weak self] rows in self?.observe(rows) })
    }

    convenience init(cwd: String, stateDirectory: URL? = nil) {
        self.init(session: Session(cwd: cwd, stateDirectory: stateDirectory))
    }

    func start(params: JSON, command: [String]? = nil) async {
        configure(params)
        await session.connect(resume: params["resume"] as? String, prompt: params["prompt"] as? String ?? "", command: command)
        if var recovery = recoveryState {
            if let checkpointDraft {
                recovery["draft"] = draftContent(checkpointDraft); recovery["draftGeneration"] = checkpointGeneration
            }
            recovery["windowState"] = windowState
            RuntimeRecovery.restore(recovery, to: session)
            if session.ready { recoveryState = nil }
        }
        saveCheckpointNotice()
    }

    func startInBackground(params: JSON, command: [String]? = nil) {
        guard startupTask == nil, !closed else { return }
        configure(params)
        startupTask = Task { [weak self] in
            guard let self else { return }
            await start(params: params, command: command)
            startupTask = nil
        }
    }

    private func configure(_ params: JSON) {
        guard !configured else { return }
        configured = true
        runtimeID = params["sessionId"] as? String
        if let recovery = params["recovery"] as? JSON {
            recoveryState = recovery
            windowState = recovery["windowState"] as? JSON ?? [:]
            consumedGeneration = recovery["consumedGeneration"] as? Int ?? -1
            checkpointDraft = runtimeDraft(recovery["draft"] as? [JSON] ?? [])
            checkpointGeneration = recovery["draftGeneration"] as? Int ?? 0
            session.draft = checkpointDraft!; session.draftGeneration = checkpointGeneration; session.draftRevision += 1
        }
    }

    private func saveCheckpoint() throws {
        guard let runtimeID else { return }
        let metadata = session.runtimeMetadata()
        var state: JSON = ["cwd": session.cwd, "conversationDirectory": metadata["conversationDirectory"] ?? session.cwd,
                           "recordID": metadata["recordID"] ?? "", "stateDirectory": session.stateDirectory.path,
                           "draft": draftContent(session.savedCommandDraft ?? session.draft),
                           "draftGeneration": session.draftGeneration, "windowState": windowState,
                           "consumedGeneration": consumedGeneration, "interrupted": session.busy, "accountID": session.account.id]
        state["threadID"] = session.threadID
        if let recoveryState {
            for key in ["cwd", "conversationDirectory", "recordID", "threadID", "stateDirectory", "accountID", "interrupted"] { state[key] = recoveryState[key] }
            if let checkpointDraft { state["draft"] = draftContent(checkpointDraft); state["draftGeneration"] = checkpointGeneration }
        }
        let encoded = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        guard encoded != persistedCheckpoint else { return }
        try RuntimeRecovery.saveCheckpoint(sessionID: runtimeID, state: state)
        persistedCheckpoint = encoded
    }

    private func saveCheckpointNotice() {
        do { try saveCheckpoint() }
        catch {
            let message = "Could not checkpoint recovery state: " + error.localizedDescription
            if session.status != message { session.status = message }
        }
    }

    private func observe(_ rows: [Row]) {
        rowOrder = rows.map { $0.id.uuidString }
        let rowIDs = Set(rows.map(\.id))
        rowSubscriptions = rowSubscriptions.filter { rowIDs.contains($0.key) }
        let itemIDs = Set(rows.flatMap(\.items).map(\.id))
        itemSubscriptions = itemSubscriptions.filter { itemIDs.contains($0.key) }
        for row in rows where rowSubscriptions[row.id] == nil {
            rowSubscriptions[row.id] = row.$items.sink { [weak self, weak row] items in
                guard let self, let row else { return }
                self.pendingRows[row.id] = row
                for item in items where self.itemSubscriptions[item.id] == nil {
                    let id = item.id
                    self.itemSubscriptions[id] = item.$data.sink { [weak self] data in
                        var value = data; value["id"] = id
                        self?.pendingItems[id] = value
                        self?.schedule()
                    }
                }
                self.schedule()
            }
        }
        schedule()
    }

    private func schedule() {
        guard !closed, publication == nil else { return }
        publication = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, !Task.isCancelled else { return }
            self.publication = nil
            self.publish()
        }
    }

    private func publish() {
        guard !closed else { return }
        saveCheckpointNotice()
        var patch: JSON = [:]
        let metadata = session.runtimeMetadata()
        if !NSDictionary(dictionary: lastMetadata).isEqual(to: metadata) {
            patch["meta"] = metadata
            lastMetadata = metadata
        }
        if let rowOrder { patch["rowOrder"] = rowOrder; self.rowOrder = nil }
        if !pendingRows.isEmpty {
            patch["rowUpdates"] = pendingRows.values.map { ["id": $0.id.uuidString, "kind": $0.kind, "itemIDs": $0.items.map(\.id)] }
            pendingRows.removeAll()
        }
        if !pendingItems.isEmpty { patch["items"] = Array(pendingItems.values); pendingItems.removeAll() }
        if lastDraftRevision != session.draftRevision || lastDraftGeneration != session.draftGeneration {
            patch["draft"] = draftContent(session.savedCommandDraft ?? session.draft)
            patch["draftGeneration"] = session.draftGeneration
            lastDraftRevision = session.draftRevision; lastDraftGeneration = session.draftGeneration
        }
        if !patch.isEmpty { onChange?(patch) }
    }

    func snapshot() -> JSON {
        var value = session.runtimeMetadata()
        value["rows"] = session.rows.map { ["id": $0.id.uuidString, "kind": $0.kind, "items": $0.items.map { item -> JSON in var data = item.data; data["id"] = item.id; return data }] }
        value["draft"] = draftContent(session.savedCommandDraft ?? session.draft)
        value["draftGeneration"] = session.draftGeneration
        value["windowState"] = windowState
        return value
    }

    func perform(action: String, params: JSON) async throws -> JSON {
        guard !closed else { throw CXError(message: "This runtime session is closed.") }
        if recoveryState != nil, startupTask == nil, session.ready { recoveryState = nil }
        if let pieces = params["draft"] as? [JSON], let generation = params["generation"] as? Int, generation >= session.draftGeneration, generation > consumedGeneration {
            let restored = runtimeDraft(pieces)
            checkpointDraft = restored; checkpointGeneration = generation
            session.draft = restored
            session.draftGeneration = generation
            session.draftRevision += 1
        }
        switch action {
        case "checkpoint":
            if let value = params["windowState"] as? JSON {
                guard let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 65536 else { throw CXError(message: "Window state is too large.") }
                windowState = value
            }
            try saveCheckpoint()
            schedule()
            return [:]
        case "send":
            guard let text = params["text"] as? String, let images = params["images"] as? [String] else { throw CXError(message: "Invalid message payload.") }
            if text.hasPrefix("/"), images.isEmpty {
                return try await perform(action: "command", params: ["text": text])
            }
            await session.send(text: text, images: images, expectedDraft: (params["draft"] as? [JSON]).map(runtimeDraft), expectedGeneration: params["generation"] as? Int)
        case "stop": await session.stop(source: params["source"] as? String ?? "Stop command")
        case "answer":
            guard let rpcID = params["rpcID"], let method = params["method"] as? String, let result = params["result"] as? JSON,
                  let permission = session.permissions.first(where: { $0.method == method && NSDictionary(dictionary: ["id": $0.rpcID]).isEqual(to: ["id": rpcID]) }) else {
                throw CXError(message: "This approval is no longer pending.")
            }
            session.answer(permission, result: result)
        case "command":
            guard let text = params["text"] as? String else { throw CXError(message: "Invalid command payload.") }
            let token = String(text.split(whereSeparator: \.isWhitespace).first ?? "").lowercased()
            let verb = "/" + (token.split(separator: ":").last.map(String.init) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !["/window", "/settings", "/login", "/attach", "/preview", "/quit", "/exit"].contains(verb) else {
                throw CXError(message: "This command belongs to the frontend.")
            }
            Settings.shared.reload()
            let preservedDraft = session.savedCommandDraft ?? session.draft, generation = session.draftGeneration
            await session.command(text)
            if let query = session.commandQuery {
                session.commandQuery = nil
                session.draft = checkpointGeneration > generation ? (checkpointDraft ?? preservedDraft) : preservedDraft
                session.draftGeneration = max(generation, checkpointGeneration)
                session.draftRevision += 1
                session.save()
                publish()
                return ["commandQuery": query]
            }
        case "refreshCatalog": await session.refreshCatalog()
        case "refreshUsage": await session.refreshUsage(force: params["force"] as? Bool ?? true)
        case "refreshRepository": await session.refreshRepository()
        case "switchThread":
            let success = await session.switchThread(params["id"] as? String, fromCommand: params["fromCommand"] as? Bool ?? false)
            publish()
            return ["success": success]
        case "close":
            if session.busy { await session.stop(source: "Close Session") }
            if let runtimeID { try RuntimeRecovery.removeCheckpoint(sessionID: runtimeID) }
            close()
        default: throw CXError(message: "Unknown runtime action.")
        }
        publish()
        return [:]
    }

    // The connection freezes last, so a session that cannot swap leaves its agent reader untouched.
    func swapState() -> JSON? {
        guard !closed, startupTask == nil, let extras = session.swapState(), let adoptable = session.rpc as? AdoptableConnection else { return nil }
        let value = snapshot()
        guard let connection = adoptable.freezeForSwap() else { return nil }
        try? saveCheckpoint()
        var state: JSON = ["snapshot": value, "session": extras, "connection": connection, "windowState": windowState, "consumedGeneration": consumedGeneration, "checkpointGeneration": checkpointGeneration]
        state["runtimeID"] = runtimeID; state["recoveryState"] = recoveryState
        state["checkpointDraft"] = checkpointDraft.map(draftContent)
        return state
    }

    func thawSwap() { (session.rpc as? AdoptableConnection)?.thawSwap() }

    convenience init(adopting state: JSON) throws {
        guard let value = state["snapshot"] as? JSON, let extras = state["session"] as? JSON, let connection = state["connection"] as? JSON,
              let cwd = value["cwd"] as? String, let directory = value["stateDirectory"] as? String else { throw CXError(message: "Invalid live update session.") }
        let rpc = try adoptConnection(connection)
        self.init(session: Session(cwd: cwd, stateDirectory: URL(fileURLWithPath: directory, isDirectory: true)))
        configured = true
        windowState = state["windowState"] as? JSON ?? [:]
        consumedGeneration = state["consumedGeneration"] as? Int ?? -1
        checkpointGeneration = state["checkpointGeneration"] as? Int ?? 0
        checkpointDraft = (state["checkpointDraft"] as? [JSON]).map(runtimeDraft)
        runtimeID = state["runtimeID"] as? String; recoveryState = state["recoveryState"] as? JSON
        session.adoptSwap(extras, snapshot: value, connection: rpc)
    }

    func close() {
        guard !closed else { return }
        closed = true
        startupTask?.cancel(); startupTask = nil
        publication?.cancel(); publication = nil
        subscriptions.removeAll(); rowSubscriptions.removeAll(); itemSubscriptions.removeAll()
        session.close()
    }
}
