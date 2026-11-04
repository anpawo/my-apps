import AppKit
import CryptoKit
import Darwin

@MainActor
enum RuntimeRecovery {
    struct Entry {
        let sessionID: String
        let cwd: String
        let socketPath: String
        let windowState: JSON
        let state: JSON
        let instanceID: String?
        let resume: String?
    }

    private static let maximumBytes = RuntimeChannel.maximumFrame
    private static var directory: URL { RuntimeIdentity.directory.appendingPathComponent("recovery", isDirectory: true) }

    private static func file(_ sessionID: String, kind: String) throws -> URL {
        guard let id = UUID(uuidString: sessionID) else { throw CXError(message: "Invalid recovery session identifier.") }
        try RuntimeIdentity.prepareDirectory()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
            throw CXError(message: "Recovery folder must be private and owned by your account.")
        }
        return directory.appendingPathComponent(id.uuidString + "." + kind + ".json")
    }

    private static func read(_ file: URL) throws -> JSON? {
        var info = stat()
        if lstat(file.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw CXError(message: "Cannot inspect session recovery data.")
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_size <= maximumBytes else {
            throw CXError(message: "Session recovery data has unsafe ownership, permissions or size.")
        }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CXError(message: "Cannot open session recovery data.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
              let value = try JSONSerialization.jsonObject(with: handle.readDataToEndOfFile()) as? JSON else {
            throw CXError(message: "Session recovery data is invalid.")
        }
        return value
    }

    private static func write(_ value: JSON, to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= maximumBytes else { throw CXError(message: "Session recovery data exceeds the size limit.") }
        if let previous = try read(file), NSDictionary(dictionary: previous).isEqual(to: value) { return }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CXError(message: "Cannot save session recovery data.") }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CXError(message: "Cannot write session recovery data.") }
                offset += written
            }
        }
        guard rename(temporary.path, file.path) == 0 else { throw CXError(message: "Cannot commit session recovery data.") }
    }

    private static func ownerStart(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    static func workerInstance(_ hello: JSON) -> String? {
        if let raw = hello["instanceID"] as? String, let id = UUID(uuidString: raw) { return id.uuidString }
        guard let pid = hello["pid"] as? Int32, pid > 1 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == getuid() else { return nil }
        return "process:\(pid):\(info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)"
    }

    static func selectState(_ value: JSON) -> JSON {
        let names = ["cwd", "conversationDirectory", "stateDirectory", "recordID", "threadID", "draft", "draftGeneration", "windowState", "consumedGeneration", "accountID", "interrupted"]
        return value.filter { names.contains($0.key) }
    }

    static func saveWindow(sessionID: String, socketPath: String, state: JSON, instanceID: String?) throws {
        guard let cwd = state["cwd"] as? String, cwd.hasPrefix("/"), socketPath.hasPrefix("/") else { throw CXError(message: "Invalid recovery workspace.") }
        let destination = try file(sessionID, kind: "window")
        if try read(destination)?["closeRequested"] as? Bool == true { return }
        var value: JSON = ["sessionId": sessionID, "socket": socketPath, "ownerPID": Int(getpid()),
                           "ownerStart": ownerStart(getpid()) ?? 0, "state": selectState(state)]
        value["instanceID"] = instanceID
        try write(value, to: destination)
    }

    static func requestClose(sessionID: String) throws {
        let destination = try file(sessionID, kind: "window")
        guard var value = try read(destination) else { return }
        value["closeRequested"] = true
        try write(value, to: destination)
    }

    static func cancelClose(sessionID: String) throws {
        let destination = try file(sessionID, kind: "window")
        guard var value = try read(destination), value["ownerPID"] as? Int == Int(getpid()),
              value["ownerStart"] as? UInt64 == ownerStart(getpid()) else { return }
        value.removeValue(forKey: "closeRequested")
        try write(value, to: destination)
    }

    static func remove(sessionID: String) throws {
        for kind in ["window", "checkpoint"] {
            let destination = try file(sessionID, kind: kind)
            _ = try read(destination)
            if unlink(destination.path) != 0, errno != ENOENT { throw CXError(message: "Cannot remove ended session recovery data.") }
        }
    }

    static func saveCheckpoint(sessionID: String, state: JSON) throws {
        try write(selectState(state), to: file(sessionID, kind: "checkpoint"))
    }

    static func removeCheckpoint(sessionID: String) throws {
        let destination = try file(sessionID, kind: "checkpoint")
        _ = try read(destination)
        if unlink(destination.path) != 0, errno != ENOENT { throw CXError(message: "Cannot remove ended session checkpoint.") }
    }

    static func pending() throws -> [Entry] { try entries(closing: false) }

    private static func entries(closing: Bool) throws -> [Entry] {
        _ = try file(UUID().uuidString, kind: "window")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var entries: [Entry] = []
        for candidate in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where candidate.lastPathComponent.hasSuffix(".window.json") {
            guard entries.count < 1024 else { throw CXError(message: "Too many sessions require recovery.") }
            guard let value = try read(candidate), (value["closeRequested"] as? Bool == true) == closing,
                  let rawID = value["sessionId"] as? String, let id = UUID(uuidString: rawID),
                  candidate.lastPathComponent == id.uuidString + ".window.json",
                  let socket = value["socket"] as? String, socket.hasPrefix("/"), var state = value["state"] as? JSON else { continue }
            if let pid = value["ownerPID"] as? Int32, let started = value["ownerStart"] as? UInt64, started > 0, ownerStart(pid) == started { continue }
            if let checkpoint = try read(file(id.uuidString, kind: "checkpoint")) {
                let localGeneration = state["draftGeneration"] as? Int ?? -1
                let workerGeneration = checkpoint["draftGeneration"] as? Int ?? -1
                let localDraft = state["draft"], localWindow = state["windowState"]
                state.merge(checkpoint) { _, worker in worker }
                if localGeneration > workerGeneration { state["draft"] = localDraft; state["draftGeneration"] = localGeneration }
                if let localWindow { state["windowState"] = localWindow }
            }
            guard let cwd = state["conversationDirectory"] as? String ?? state["cwd"] as? String, cwd.hasPrefix("/") else { continue }
            let record = (state["recordID"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }
            entries.append(Entry(sessionID: id.uuidString, cwd: cwd, socketPath: socket, windowState: state["windowState"] as? JSON ?? [:],
                                 state: state, instanceID: value["instanceID"] as? String, resume: record.map { "native:" + $0 }))
        }
        return entries
    }

    static func finishRequestedCloses() async throws -> Int {
        var completed = 0
        for entry in try entries(closing: true) {
            let session = Session(cwd: entry.cwd)
            let client = RuntimeClient(session: session, cwd: entry.cwd, resumeRuntimeID: entry.sessionID, socketPath: entry.socketPath)
            session.runtimeClient = client
            do {
                try await client.connect(resume: nil)
                _ = try await client.perform("close")
                completed += 1
            } catch let response as RuntimeResponseError where ["closed", "unknownSession"].contains(response.code ?? "") {
                try remove(sessionID: entry.sessionID)
                completed += 1
            } catch {}
            client.close(); session.close()
        }
        return completed
    }

    static func hasSavedRecord(_ entry: Entry) -> Bool {
        guard let recordID = entry.state["recordID"] as? String, UUID(uuidString: recordID) != nil,
              let stateDirectory = entry.state["stateDirectory"] as? String, stateDirectory.hasPrefix("/") else { return false }
        let group = SHA256.hash(data: Data(entry.cwd.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        let path = URL(fileURLWithPath: stateDirectory).appendingPathComponent("native").appendingPathComponent(String(group)).appendingPathComponent(recordID + ".json")
        guard let record = try? read(path) else { return false }
        return record["cwd"] as? String == entry.cwd && record["threadId"] as? String != nil && record["accountId"] as? String != nil
    }

    static func restore(_ state: JSON, to session: Session) {
        session.applyInterruptedRecovery(state)
    }
}
