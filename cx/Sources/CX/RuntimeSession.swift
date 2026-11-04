import AppKit
import Combine

@MainActor
func runtimeDraft(_ pieces: [JSON]) -> NSAttributedString {
    let value = NSMutableAttributedString(string: "")
    for (index, piece) in pieces.enumerated() {
        if let text = piece["text"] as? String {
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

    init(session: Session) {
        self.session = session
        session.onDraftConsumed = { [weak self] generation in self?.consumedGeneration = max(self?.consumedGeneration ?? -1, generation) }
        subscriptions.append(session.objectWillChange.sink { [weak self] _ in self?.schedule() })
        subscriptions.append(session.$rows.sink { [weak self] rows in self?.observe(rows) })
    }

    convenience init(cwd: String, stateDirectory: URL? = nil) {
        self.init(session: Session(cwd: cwd, stateDirectory: stateDirectory))
    }

    func start(params: JSON, command: [String]? = nil) async {
        await session.connect(resume: params["resume"] as? String, prompt: params["prompt"] as? String ?? "", command: command)
    }

    func startInBackground(params: JSON, command: [String]? = nil) {
        guard startupTask == nil, !closed else { return }
        startupTask = Task { [weak self] in
            guard let self else { return }
            await start(params: params, command: command)
            startupTask = nil
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
            schedule()
            return [:]
        case "send":
            guard let text = params["text"] as? String, let images = params["images"] as? [String] else { throw CXError(message: "Invalid message payload.") }
            if text.hasPrefix("/"), images.isEmpty {
                return try await perform(action: "command", params: ["text": text])
            }
            await session.send(text: text, images: images, expectedDraft: (params["draft"] as? [JSON]).map(runtimeDraft), expectedGeneration: params["generation"] as? Int)
        case "stop": await session.stop()
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
        case "close": close()
        default: throw CXError(message: "Unknown runtime action.")
        }
        publish()
        return [:]
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
