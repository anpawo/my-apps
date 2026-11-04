import AppKit
import Foundation

@MainActor
enum RuntimeBoundsCheck {
    private final class Backend: RuntimeBackend {
        var onChange: ((JSON) -> Void)?
        var executed: [Int] = []
        var blocked = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var large = false
        var closed = false
        var controls = 0
        func snapshot() -> JSON { large ? ["padding": String(repeating: "x", count: RuntimeChannel.maximumFrame)] : ["executed": executed] }
        func perform(action: String, params: JSON) async throws -> JSON {
            switch action {
            case "increment", "block":
                let value = params["n"] as? Int ?? 0
                executed.append(value)
                if action == "block", blocked { await withCheckedContinuation { waiting.append($0) } }
                return ["n": value]
            case "answer", "checkpoint": controls += 1; return [:]
            case "stop": release(); return [:]
            case "close": close(); return [:]
            default: throw CXError(message: "Unknown bounds fixture action.")
            }
        }
        func release() { blocked = false; let pending = waiting; waiting.removeAll(); pending.forEach { $0.resume() } }
        func close() { closed = true; release() }
    }

    private final class Peer {
        let channel: RuntimeChannel
        var responses: [String: JSON] = [:]
        var events: [JSON] = []
        var closed = false
        init(path: String) throws {
            channel = try RuntimeChannel.connect(path: path)
            channel.onMessage = { [weak self] value in
                guard let self else { return }
                if let id = value["id"] as? String { responses[id] = value }
                else { events.append(value); if events.count > 256 { events.removeFirst() } }
            }
            channel.onClose = { [weak self] in self?.closed = true }
            channel.start()
        }
        func send(_ method: String, _ params: JSON) throws -> String {
            let id = UUID().uuidString
            try channel.send(["id": id, "method": method, "params": params])
            return id
        }
        func response(_ id: String) async throws -> JSON {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let value = responses.removeValue(forKey: id) { return value }
                if closed { throw CXError(message: "Bounds fixture connection closed before response.") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw CXError(message: "Bounds fixture response timed out.")
        }
        func call(_ method: String, _ params: JSON = [:]) async throws -> JSON { try await response(send(method, params)) }
        func attach(_ id: String, cwd: String) async throws -> JSON {
            _ = try await call("hello", ["protocol": 1])
            let reply = try await call("attach", ["sessionId": id, "cwd": cwd])
            guard let result = reply["result"] as? JSON else { throw CXError(message: "Bounds fixture attach failed.") }
            return result
        }
        func arguments(_ session: JSON, _ sequence: Int, _ action: String, _ params: JSON = [:]) -> JSON {
            ["sessionId": session["sessionId"]!, "lease": session["lease"]!, "sequence": sequence, "action": action, "params": params]
        }
        func perform(_ session: JSON, _ sequence: Int, _ action: String, _ params: JSON = [:]) async throws -> JSON {
            try await call("perform", arguments(session, sequence, action, params))
        }
        func close() { channel.close() }
    }

    static func run() async throws -> Int {
        let directory = URL(fileURLWithPath: "/tmp/vcx-bounds-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let previousRuntimeHome = ProcessInfo.processInfo.environment["VCX_RUNTIME_HOME"]
        setenv("VCX_RUNTIME_HOME", directory.appendingPathComponent("runtime").path, 1)
        defer {
            if let previousRuntimeHome { setenv("VCX_RUNTIME_HOME", previousRuntimeHome, 1) }
            else { unsetenv("VCX_RUNTIME_HOME") }
        }
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw CXError(message: "Runtime bounds: " + message) }
            count += 1
        }
        func errorCode(_ value: JSON) -> String? { (value["error"] as? JSON)?["code"] as? String }
        func writerFinished(_ semaphore: DispatchSemaphore, after seconds: Double) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 1_000_000) }
            throw CXError(message: "Runtime bounds fixture did not reach its gate.")
        }
        var backends: [String: Backend] = [:]
        let path = directory.appendingPathComponent("server.sock").path
        let server = RuntimeServer(socketPath: path, build: "bounds-fixture") { params in
            let backend = Backend()
            backends[params["sessionId"] as! String] = backend
            return backend
        }
        var retired = false
        server.onEmpty = { retired = true }
        try server.start()
        let first = try Peer(path: path), second = try Peer(path: path)
        defer { first.close(); second.close(); server.stop(); try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        let attached = try await first.attach(id, cwd: directory.path)
        let backend = backends[id]!
        let hello = try await first.call("hello", ["protocol": 1])["result"] as? JSON ?? [:]
        let otherHello = try await second.call("hello", ["protocol": 1])["result"] as? JSON ?? [:]
        try check(hello["instanceID"] as? String == otherHello["instanceID"] as? String && UUID(uuidString: hello["instanceID"] as? String ?? "") != nil, "runtime boot identity changed across peers")
        try check(hello["maximumQueuedFrames"] as? Int == RuntimeChannel.maximumQueuedFrames, "outgoing frame count bound was not advertised")
        let missing = try await second.call("attach", ["sessionId": UUID().uuidString, "cwd": directory.path, "existingOnly": true])
        try check(errorCode(missing) == "unknownSession" && backends.count == 1, "reattach created a fresh session after loss")

        for sequence in 1...140 {
            let result = try await first.perform(attached, sequence, "increment", ["n": sequence])
            try check((result["result"] as? JSON)?["n"] as? Int == sequence, "ordered action receipt returned the wrong result")
        }
        let expired = try await first.perform(attached, 1, "increment", ["n": 1])
        try check(errorCode(expired) == "alreadyAccepted" && backend.executed.count == 140, "evicted receipt replayed its action")
        let conflict = try await first.perform(attached, 140, "increment", ["n": -1])
        try check(errorCode(conflict) == "sequenceConflict" && backend.executed.count == 140, "reused receipt changed its action payload")

        backend.large = true
        let oversized = try await second.call("attach", ["sessionId": id, "cwd": directory.path])
        try check(errorCode(oversized) == "snapshotTooLarge", "oversized conversation attachment was accepted")
        try check(!first.events.contains { $0["method"] as? String == "session/leaseLost" }, "failed oversized attachment displaced the original writer")
        backend.large = false
        let preserved = try await first.perform(attached, 141, "increment", ["n": 141])
        try check((preserved["result"] as? JSON)?["n"] as? Int == 141, "old frontend lost ownership after failed snapshot")

        let blockedID = UUID().uuidString
        let blockedSession = try await second.attach(blockedID, cwd: directory.path)
        let blocked = backends[blockedID]!
        blocked.blocked = true
        var pending: [String] = []
        for sequence in 1...64 { pending.append(try second.send("perform", second.arguments(blockedSession, sequence, "block", ["n": sequence]))) }
        try await wait { blocked.executed.count == 1 }
        let overflow = try await second.call("list")
        try check(errorCode(overflow) == "busy", "ordinary request admission exceeded its bound")
        let checkpoint = try await second.perform(blockedSession, 65, "checkpoint")
        let answer = try await second.perform(blockedSession, 66, "answer")
        try check(checkpoint["result"] != nil && answer["result"] != nil && blocked.controls == 2 && blocked.executed.count == 1, "ordinary request saturation blocked checkpoint or approval")
        let stopped = try await second.perform(blockedSession, 67, "stop")
        try check(stopped["result"] != nil, "ordinary request saturation blocked stop")
        for (offset, request) in pending.enumerated() {
            let reply = try await second.response(request)
            try check((reply["result"] as? JSON)?["n"] as? Int == offset + 1, "admitted commands were lost or reordered while unblocking")
        }
        try check(blocked.executed == Array(1...64), "blocked ordinary actions executed out of order")

        let listenerPath = directory.appendingPathComponent("slow.sock").path
        var sending: RuntimeChannel?
        let listener = RuntimeListener(path: listenerPath) { channel in sending = channel; channel.start() }
        try listener.start()
        let unread = try RuntimeChannel.connect(path: listenerPath)
        defer { unread.close(); sending?.close(); listener.close() }
        try await wait { sending != nil }
        let padding = String(repeating: "x", count: 1024)
        var bounded = false
        for sequence in 0..<(RuntimeChannel.maximumQueuedFrames + 1024) {
            do { try sending!.send(["n": sequence, "padding": padding]) }
            catch { bounded = true; break }
        }
        try check(bounded, "an unread frontend accumulated more than the outgoing frame limit")

        do {
            let pipe = Pipe(), writerDone = DispatchSemaphore(value: 0)
            let line = try JSONSerialization.data(withJSONObject: ["padding": String(repeating: "x", count: 8 * 1024 * 1024)]) + Data([10])
            let reader = try ProviderJSONReader(handle: pipe.fileHandleForReading, receive: { _ in }, disconnected: {})
            reader.start()
            DispatchQueue.global().async {
                defer { try? pipe.fileHandleForWriting.close(); writerDone.signal() }
                for _ in 0..<20 { do { try pipe.fileHandleForWriting.write(contentsOf: line) } catch { break } }
            }
            let deadline = Date().addingTimeInterval(5)
            while reader.queuedMessages < 7, Date() < deadline { usleep(1000) }
            usleep(100_000)
            try check(reader.queuedBytes <= ProviderJSONReader.maximumBytes && reader.queuedMessages == 7, "provider byte budget did not apply backpressure")
            reader.close()
            try check(writerFinished(writerDone, after: 2), "closing a byte-backpressured provider reader left its writer blocked")
        }
        do {
            let pipe = Pipe(), writerDone = DispatchSemaphore(value: 0)
            let lines = (0..<5000).map { "{\"n\":\($0),\"padding\":\"" + String(repeating: "x", count: 128) + "\"}\n" }.joined()
            let data = Data(lines.utf8)
            let reader = try ProviderJSONReader(handle: pipe.fileHandleForReading, receive: { _ in }, disconnected: {})
            reader.start()
            DispatchQueue.global().async {
                defer { try? pipe.fileHandleForWriting.close(); writerDone.signal() }
                try? pipe.fileHandleForWriting.write(contentsOf: data)
            }
            let deadline = Date().addingTimeInterval(2)
            while reader.queuedMessages < ProviderJSONReader.maximumMessages, Date() < deadline { usleep(1000) }
            try check(reader.queuedMessages == ProviderJSONReader.maximumMessages, "provider message budget did not stop a flood")
            try check(!writerFinished(writerDone, after: 0), "provider flood did not exercise a blocked writer")
            reader.close()
            try check(writerFinished(writerDone, after: 2), "closing a message-backpressured provider reader left its writer blocked")
        }
        do {
            let pipe = Pipe()
            var values: [Int] = [], ended = false, invalid = 0
            let reader = try ProviderJSONReader(handle: pipe.fileHandleForReading, receive: { message in
                if let value = message["n"] as? Int { values.append(value) }
            }, invalid: { _ in invalid += 1 }, disconnected: { ended = true })
            reader.start()
            DispatchQueue.global().async {
                defer { try? pipe.fileHandleForWriting.close() }
                let lines = (0..<5000).map { "{\"n\":\($0)}\n" }.joined()
                try? pipe.fileHandleForWriting.write(contentsOf: Data(lines.utf8))
            }
            try await wait { ended }
            try check(values == Array(0..<5000) && invalid == 0, "bounded provider delivery dropped or reordered valid messages")
            reader.close()
        }
        do {
            let pipe = Pipe()
            var bytes = 0, ended = false
            let size = 2 * 1024 * 1024
            let data = try JSONSerialization.data(withJSONObject: ["padding": String(repeating: "x", count: size)]) + Data([10])
            let reader = try ProviderJSONReader(handle: pipe.fileHandleForReading, receive: { bytes = ($0["padding"] as? String)?.utf8.count ?? 0 }, disconnected: { ended = true })
            let start = DispatchTime.now().uptimeNanoseconds
            reader.start()
            DispatchQueue.global().async {
                defer { try? pipe.fileHandleForWriting.close() }
                for offset in stride(from: 0, to: data.count, by: 1024) {
                    do { try pipe.fileHandleForWriting.write(contentsOf: data.subdata(in: offset..<min(offset + 1024, data.count))) }
                    catch { break }
                }
            }
            try await wait { ended }
            try check(bytes == size, "fragmented large provider frame was lost")
            print(String(format: "Fragmented 2 MiB provider frame: %.3f s", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000))
            reader.close()
        }

        let session = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
        session.rows = (0..<1000).map { Row("assistant", [Item(["id": "history-\($0)", "type": "agentMessage", "text": String(repeating: "h", count: 128)])]) }
        let projection = SessionBackend(session: session)
        defer { projection.close() }
        var patches: [JSON] = []
        projection.onChange = { patches.append($0) }
        try await wait { !patches.isEmpty }
        patches.removeAll()
        session.rows[500].items[0].data["text"] = "changed fixture item"
        try await wait { !patches.isEmpty }
        let patch = patches[0]
        try check(patch["rowOrder"] == nil && patch["rowUpdates"] == nil && (patch["items"] as? [JSON])?.count == 1, "one streaming item republished the transcript structure")
        try check(try JSONSerialization.data(withJSONObject: patch).count < 4096, "one streaming item produced a history-sized patch")
        patches.removeAll()
        for generation in 1...200 { _ = try await projection.perform(action: "checkpoint", params: ["generation": generation, "draft": [["text": "fixture draft \(generation)"]]]) }
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(patches.count < 20 && session.draftGeneration == 200, "rapid draft edits caused a publication for each keystroke")
        try check((projection.snapshot()["rows"] as? [JSON])?.count == 1000, "resource checks silently truncated old conversation rows")

        _ = try await first.perform(attached, 142, "close")
        _ = try await second.perform(blockedSession, 68, "close")
        first.close(); second.close()
        try await wait { retired }
        try check(backend.closed && blocked.closed && retired, "explicit close did not retire an empty runtime")
        print("\(count) runtime resource-bound checks passed")
        print("Resource limits still absent: transcript paging and a shared provider-tool concurrency budget.")
        return count
    }
}
