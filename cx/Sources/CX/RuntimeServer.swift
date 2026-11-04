import CryptoKit
import Darwin
import Foundation

@MainActor
protocol RuntimeBackend: AnyObject {
    var onChange: ((JSON) -> Void)? { get set }
    func snapshot() -> JSON
    func perform(action: String, params: JSON) async throws -> JSON
    func close()
}

private struct RuntimeFault: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class RuntimeServer {
    private final class Peer {
        let channel: RuntimeChannel
        var ready = false
        var requests = 0
        init(_ channel: RuntimeChannel) { self.channel = channel }
    }

    private final class Receipt {
        let fingerprint: String
        var task: Task<JSON, Error>!
        var completed = false
        var bytes = 0
        init(_ fingerprint: String) { self.fingerprint = fingerprint }
    }

    private final class Entry {
        let id: String
        var creation: Task<any RuntimeBackend, Error>!
        var backend: (any RuntimeBackend)?
        weak var writer: RuntimeChannel?
        var lease = ""
        var attachment = 0
        var revision = 0
        var lastSequence = 0
        var receipts: [Int: Receipt] = [:]
        var orderedAction: Task<JSON, Error>?
        var ended = false
        var closeSequence: Int?
        var closeCompleted = false
        init(_ id: String) { self.id = id }
    }

    private let socketPath: String
    private let build: String
    private let makeSession: (JSON) async throws -> any RuntimeBackend
    private var listener: RuntimeListener?
    private var peers: [UUID: Peer] = [:]
    private var entries: [String: Entry] = [:]
    private var closedIDs: Set<String> = []
    private var requestBytes = 0
    private var stopped = false
    var onEmpty: () -> Void = {}

    init(socketPath: String, build: String, makeSession: @escaping (JSON) async throws -> any RuntimeBackend) {
        self.socketPath = socketPath; self.build = build; self.makeSession = makeSession
    }

    func start() throws {
        guard listener == nil, !stopped else { throw CXError(message: "Runtime server is already started or stopped.") }
        let listener = RuntimeListener(path: socketPath) { [weak self] channel in self?.accept(channel) }
        try listener.start()
        self.listener = listener
    }

    private func accept(_ channel: RuntimeChannel) {
        guard !stopped, peers.count < 128 else { channel.close(); return }
        let peer = Peer(channel)
        peers[channel.id] = peer
        channel.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, !self.stopped else { return }
            self.receive(message, from: peer)
        }
        channel.onClose = { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.peers[channel.id] = nil
            for entry in Array(self.entries.values) where entry.writer === channel {
                entry.writer = nil
                self.releaseClosed(entry)
            }
            self.checkEmpty()
        }
        channel.start()
    }

    private func receive(_ message: JSON, from peer: Peer) {
        guard let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let method = message["method"] as? String, method.utf8.count <= 64,
              let params = message["params"] as? JSON else { peer.channel.close(); return }
        guard let encoded = try? JSONSerialization.data(withJSONObject: message) else { peer.channel.close(); return }
        let bytes = encoded.count
        guard peer.requests < 64, requestBytes + bytes <= RuntimeChannel.maximumBuffered else {
            fail(id, peer, RuntimeFault(code: "busy", message: "Too many pending runtime requests.")); return
        }
        peer.requests += 1; requestBytes += bytes
        Task {
            defer { peer.requests -= 1; requestBytes -= bytes }
            do {
                guard !stopped else { throw CancellationError() }
                if method == "hello" {
                    guard params["protocol"] as? Int == 1 else { throw RuntimeFault(code: "protocolMismatch", message: "This frontend uses an incompatible runtime protocol.") }
                    peer.ready = true
                    try reply(id, peer, ["protocol": 1, "build": build, "pid": Int(getpid()), "maximumFrameBytes": RuntimeChannel.maximumFrame, "maximumBufferedBytes": RuntimeChannel.maximumBuffered])
                    return
                }
                guard peer.ready else { throw RuntimeFault(code: "handshakeRequired", message: "Runtime hello must succeed before session requests.") }
                switch method {
                case "attach": try await attach(id, peer, params)
                case "perform":
                    let result = try await perform(peer, params)
                    try reply(id, peer, result)
                case "detach":
                    let entry = try writable(peer, params)
                    entry.writer = nil; entry.lease = ""
                    try reply(id, peer, [:])
                    releaseClosed(entry)
                case "list":
                    try reply(id, peer, ["sessions": entries.values.map { ["sessionId": $0.id, "revision": $0.revision, "lastSequence": $0.lastSequence, "attached": $0.writer != nil, "ended": $0.ended] }])
                default: throw RuntimeFault(code: "unknownMethod", message: "Unknown runtime method.")
                }
            } catch { fail(id, peer, error) }
        }
    }

    private func attach(_ id: String, _ peer: Peer, _ params: JSON) async throws {
        guard let rawID = params["sessionId"] as? String, let uuid = UUID(uuidString: rawID),
              let cwd = params["cwd"] as? String, cwd.hasPrefix("/") else { throw RuntimeFault(code: "invalidAttach", message: "Attach requires a session UUID and absolute working directory.") }
        let sessionID = uuid.uuidString
        guard !closedIDs.contains(sessionID) else { throw RuntimeFault(code: "closed", message: "This runtime session has ended and cannot be reopened.") }
        let entry: Entry
        if let existing = entries[sessionID] { entry = existing }
        else {
            let active = entries.values.filter { !$0.ended }.count
            guard active < 256, active + closedIDs.count < 65_536 else { throw RuntimeFault(code: "busy", message: "Runtime session capacity reached. Existing sessions remain available.") }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue else { throw RuntimeFault(code: "invalidAttach", message: "Session working directory is unavailable.") }
            entry = Entry(sessionID)
            entries[sessionID] = entry
            entry.creation = Task {
                let backend = try await makeSession(params)
                guard !stopped else { backend.close(); throw CancellationError() }
                return backend
            }
        }
        entry.attachment += 1
        let attachment = entry.attachment
        if let previous = entry.writer, previous !== peer.channel {
            try? previous.send(["method": "session/leaseLost", "params": ["sessionId": entry.id]])
        }
        entry.writer = nil; entry.lease = ""
        let backend: any RuntimeBackend
        do { backend = try await entry.creation.value }
        catch {
            if entries[sessionID] === entry { entries[sessionID] = nil }
            throw error
        }
        guard !stopped, peers[peer.channel.id] === peer, entry.attachment == attachment else { throw RuntimeFault(code: "superseded", message: "This attachment was superseded or disconnected.") }
        if entry.backend == nil {
            entry.backend = backend
            backend.onChange = { [weak self, weak entry] patch in
                guard let self, let entry, !self.stopped else { return }
                entry.revision += 1
                guard let writer = entry.writer else { return }
                do { try writer.send(["method": "session/update", "params": ["sessionId": entry.id, "revision": entry.revision, "patch": patch]]) }
                catch { writer.close() }
            }
        }
        entry.writer = peer.channel; entry.lease = UUID().uuidString
        // Enqueue the snapshot before yielding so no update can overtake attachment.
        try reply(id, peer, ["sessionId": entry.id, "lease": entry.lease, "revision": entry.revision, "state": backend.snapshot(), "lastSequence": entry.lastSequence])
    }

    private func writable(_ peer: Peer, _ params: JSON) throws -> Entry {
        guard let rawID = params["sessionId"] as? String, let uuid = UUID(uuidString: rawID) else { throw RuntimeFault(code: "unknownSession", message: "Runtime session does not exist.") }
        guard let entry = entries[uuid.uuidString] else {
            if closedIDs.contains(uuid.uuidString) { throw RuntimeFault(code: "closed", message: "This runtime session has ended.") }
            throw RuntimeFault(code: "unknownSession", message: "Runtime session does not exist.")
        }
        guard entry.writer === peer.channel, let lease = params["lease"] as? String, !lease.isEmpty, lease == entry.lease else { throw RuntimeFault(code: "staleLease", message: "Another frontend owns this session. Reattach before writing.") }
        return entry
    }

    private func perform(_ peer: Peer, _ params: JSON) async throws -> JSON {
        let entry = try writable(peer, params)
        guard let sequence = params["sequence"] as? Int, sequence > 0,
              let action = params["action"] as? String, !action.isEmpty, action.utf8.count <= 64,
              let arguments = params["params"] as? JSON else { throw RuntimeFault(code: "invalidAction", message: "Invalid runtime action.") }
        let payload = try JSONSerialization.data(withJSONObject: ["action": action, "params": arguments], options: [.sortedKeys])
        let fingerprint = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        if entry.ended, !(action == "close" && sequence == entry.closeSequence) { throw RuntimeFault(code: "closed", message: "This runtime session has ended.") }
        if sequence <= entry.lastSequence {
            guard let receipt = entry.receipts[sequence] else { throw RuntimeFault(code: "alreadyAccepted", message: "This sequence was already accepted and its receipt has expired. It will not execute again.") }
            guard receipt.fingerprint == fingerprint else { throw RuntimeFault(code: "sequenceConflict", message: "This sequence was already used for a different action.") }
            return try await receipt.task.value
        }
        guard sequence == entry.lastSequence + 1 else { throw RuntimeFault(code: "sequenceGap", message: "Runtime actions must use the next sequence number.") }
        guard !entry.ended, let backend = entry.backend else { throw RuntimeFault(code: "closed", message: "This runtime session has ended.") }
        guard entry.receipts.values.filter({ !$0.completed }).count < 64 else { throw RuntimeFault(code: "busy", message: "Too many pending session actions.") }
        let receipt = Receipt(fingerprint)
        let interrupts = ["answer", "stop", "close", "checkpoint"].contains(action)
        let previous = interrupts ? nil : entry.orderedAction
        entry.lastSequence = sequence; entry.receipts[sequence] = receipt
        if action == "close" { entry.ended = true; entry.closeSequence = sequence; closedIDs.insert(entry.id) }
        // An admitted task belongs to the session, even when its requesting socket disappears.
        receipt.task = Task {
            if let previous { _ = try? await previous.value }
            do {
                let result = try await backend.perform(action: action, params: arguments)
                receipt.completed = true
                receipt.bytes = (try? JSONSerialization.data(withJSONObject: result).count) ?? 0
                if action == "close" { completeClose(entry) }
                prune(entry)
                return result
            } catch {
                receipt.completed = true
                if action == "close" { completeClose(entry) }
                prune(entry)
                throw error
            }
        }
        if !interrupts { entry.orderedAction = receipt.task }
        return try await receipt.task.value
    }

    private func prune(_ entry: Entry) {
        var bytes = entry.receipts.values.reduce(0) { $0 + $1.bytes }
        for sequence in entry.receipts.keys.sorted() {
            guard entry.receipts.count > 128 || bytes > 8 * 1024 * 1024 else { break }
            guard let receipt = entry.receipts[sequence], receipt.completed else { continue }
            bytes -= receipt.bytes; entry.receipts[sequence] = nil
        }
    }

    private func completeClose(_ entry: Entry) {
        entry.backend?.onChange = nil
        entry.backend?.close(); entry.backend = nil
        entry.creation = nil; entry.orderedAction = nil
        entry.closeCompleted = true
        entry.receipts = entry.receipts.filter { $0.key == entry.closeSequence }
        releaseClosed(entry)
        checkEmpty()
    }

    private func releaseClosed(_ entry: Entry) {
        if entry.closeCompleted, entry.writer == nil { entries[entry.id] = nil }
    }

    private func checkEmpty() {
        guard !stopped, !closedIDs.isEmpty, peers.isEmpty, entries.values.allSatisfy({ $0.ended && $0.closeCompleted }) else { return }
        onEmpty()
    }

    private func reply(_ id: String, _ peer: Peer, _ result: JSON) throws { try peer.channel.send(["id": id, "result": result]) }

    private func fail(_ id: String, _ peer: Peer, _ error: Error) {
        let fault = error as? RuntimeFault
        do { try peer.channel.send(["id": id, "error": ["code": fault?.code ?? "actionFailed", "message": error.localizedDescription]]) }
        catch { peer.channel.close() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        listener?.close(); listener = nil
        for peer in peers.values { peer.channel.close() }
        peers.removeAll()
        for entry in entries.values {
            entry.creation?.cancel()
            entry.backend?.onChange = nil
            entry.backend?.close()
            if entry.backend == nil, let creation = entry.creation {
                Task {
                    if let backend = try? await creation.value { backend.onChange = nil; backend.close() }
                }
            }
        }
        entries.removeAll()
    }
}
