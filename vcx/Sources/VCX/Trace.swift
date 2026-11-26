import Foundation
import Darwin
import SQLite3

enum Trace {
    static let longestString = 600
    private static let maxMigrationStates = 16
    private static let migrationInterval: TimeInterval = 60
    private static let busyTimeout: Int32 = 1000
    private static let retryDelay: TimeInterval = 0.05
    private static let applicationID: Int32 = 0x56435841
    private static let schemaVersion: Int32 = 1
    private static let queue = DispatchQueue(label: "vcx.trace", qos: .utility)
    private static let migrations = DispatchQueue(label: "vcx.trace-migration", qos: .utility)
    private static let lock = NSLock()
    private static var failed: [URL: [(Data, JSON)]] = [:]
    private static var serializationFailures = Set<URL>()
    private static var migrationTimes: [URL: Date] = [:]
    private static var migrating = Set<URL>()
    private enum Failure: Error { case retry, unsafePath, foreignDatabase, sqlite }
    private static let schema = """
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY, time TEXT, session TEXT, thread TEXT, type TEXT,
            payload BLOB NOT NULL, legacy_file TEXT, legacy_offset INTEGER,
            UNIQUE(legacy_file, legacy_offset));
        CREATE TABLE IF NOT EXISTS trace_imports (
            name TEXT PRIMARY KEY, sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL,
            line_count INTEGER NOT NULL, imported_at INTEGER NOT NULL)
        """

    static func write(_ directory: URL, _ type: String, _ data: JSON) {
        migrate(directory)
        var entry = clip(data) as? JSON ?? [:]
        entry["time"] = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        entry["type"] = type; entry["pid"] = getpid()
        guard let payload = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            queue.async { serializationFailures.insert(directory) }
            return
        }
        queue.async {
            if !store(directory, payload: payload, entry: entry) { failed[directory, default: []].append((payload, entry)) }
        }
    }

    private static func safeDirectory(_ directory: URL) throws {
        let path = directory.path
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            var value = stat()
            if lstat(current, &value) == 0 {
                if value.st_mode & S_IFMT == S_IFLNK { throw Failure.unsafePath }
            } else if errno != ENOENT { throw Failure.unsafePath }
        }
    }

    private static func ownedFile(_ path: String, create: Bool) throws -> (Int32, stat) {
        let fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | (create ? O_CREAT : 0), 0o600)
        guard fd >= 0 else { throw Failure.unsafePath }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == getuid(), value.st_mode & 0o777 == 0o600, value.st_nlink == 1 else {
            close(fd); throw Failure.unsafePath
        }
        return (fd, value)
    }

    private static func scalar(_ connection: OpaquePointer?, _ sql: String) throws -> Int32 {
        var statement: OpaquePointer?
        try checked(sqlite3_prepare_v2(connection, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { try checked(result); throw Failure.sqlite }
        return sqlite3_column_int(statement, 0)
    }

    private static func checked(_ code: Int32) throws {
        if code == SQLITE_BUSY || code == SQLITE_LOCKED { throw Failure.retry }
        guard code == SQLITE_OK || code == SQLITE_DONE else { throw Failure.sqlite }
    }

    private static func database(_ directory: URL, create: Bool) throws -> OpaquePointer {
        let directory = try canonicalArchiveRoot(directory)
        try safeDirectory(directory)
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try safeDirectory(directory)
        let (gate, _) = try ownedFile(directory.appendingPathComponent(".archive.lock").path, create: create)
        defer { flock(gate, LOCK_UN); close(gate) }
        guard flock(gate, LOCK_EX) == 0 else { throw Failure.unsafePath }
        return try openDatabase(directory, create: create)
    }

    private static func openDatabase(_ directory: URL, create: Bool) throws -> OpaquePointer {
        let file = directory.appendingPathComponent("conversations.sqlite")
        var created = false
        if create {
            let initial = open(file.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if initial >= 0 { created = true; close(initial) }
            else if errno != EEXIST { throw Failure.unsafePath }
        }
        let (fd, identity) = try ownedFile(file.path, create: false)
        defer { close(fd) }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = file.path + suffix
            var value = stat()
            if lstat(sidecar, &value) == 0 {
                let (sidecarFD, _) = try ownedFile(sidecar, create: false)
                close(sidecarFD)
            } else if errno != ENOENT { throw Failure.unsafePath }
        }
        var connection: OpaquePointer?
        let flags = (create ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_NOFOLLOW
        do {
            try checked(sqlite3_open_v2(file.path, &connection, flags, nil))
            guard let connection else { throw Failure.sqlite }
            sqlite3_busy_timeout(connection, busyTimeout)
            var current = stat()
            guard lstat(file.path, &current) == 0, current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else { throw Failure.unsafePath }
            if created {
                try checked(sqlite3_exec(connection, "PRAGMA application_id=\(applicationID); PRAGMA user_version=\(schemaVersion);", nil, nil, nil))
            }
            guard try scalar(connection, "PRAGMA application_id") == applicationID,
                  try scalar(connection, "PRAGMA user_version") == schemaVersion else { throw Failure.foreignDatabase }
            if create { try checked(sqlite3_exec(connection, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;" + schema, nil, nil, nil)) }
            return connection
        } catch { sqlite3_close(connection); throw error }
    }

    private static func insert(_ directory: URL, payload: Data, entry: JSON) throws {
        let connection = try database(directory, create: true)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        try checked(sqlite3_prepare_v2(connection, "INSERT INTO events(time,session,thread,type,payload) VALUES(?,?,?,?,?)", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, key) in ["time", "record", "thread", "type"].enumerated() {
            if let value = entry[key] as? String { try checked(sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient)) }
        }
        try payload.withUnsafeBytes { try checked(sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32($0.count), transient)) }
        try checked(sqlite3_step(statement))
    }

    private static func store(_ directory: URL, payload: Data, entry: JSON) -> Bool {
        while true {
            do { try insert(directory, payload: payload, entry: entry); return true }
            catch Failure.retry { Thread.sleep(forTimeInterval: retryDelay) }
            catch { return false }
        }
    }

    static func drain(_ directory: URL) async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            queue.async {
                let retrying = failed.removeValue(forKey: directory) ?? []
                for (payload, entry) in retrying {
                    if !store(directory, payload: payload, entry: entry) { failed[directory, default: []].append((payload, entry)) }
                }
                guard failed[directory, default: []].isEmpty else {
                    result.resume(throwing: VCXError(message: "Conversation diagnostics could not be saved; close was stopped to keep the pending events.")); return
                }
                if serializationFailures.remove(directory) != nil {
                    result.resume(throwing: VCXError(message: "A diagnostic event could not be encoded; retry close to acknowledge this diagnostic failure.")); return
                }
                result.resume()
            }
        }
    }

    static func flush() { queue.sync {} }

    static func latest(_ directory: URL) -> JSON? {
        flush()
        guard let connection = try? database(directory, create: false) else { return nil }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "SELECT payload FROM events WHERE legacy_file IS NULL OR EXISTS (SELECT 1 FROM trace_imports WHERE name=legacy_file) ORDER BY id DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let payload = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return (try? JSONSerialization.jsonObject(with: payload)) as? JSON
    }

    static func migrate(_ directory: URL, force: Bool = false) {
        lock.lock()
        let now = Date()
        guard !migrating.contains(directory), migrating.count < maxMigrationStates,
              force || now.timeIntervalSince(migrationTimes[directory] ?? .distantPast) >= migrationInterval else { lock.unlock(); return }
        if migrationTimes.count >= maxMigrationStates, let oldest = migrationTimes.min(by: { $0.value < $1.value })?.key { migrationTimes.removeValue(forKey: oldest) }
        migrationTimes[directory] = now
        migrating.insert(directory)
        lock.unlock()
        migrations.async {
            defer { lock.lock(); migrating.remove(directory); lock.unlock() }
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("trace_archive.py")
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("trace_archive.py")
            let script = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? source
            let process = Process(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path]
            process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["state": directory.path]))
                try input.fileHandleForWriting.close()
                process.waitUntilExit()
            } catch { try? input.fileHandleForWriting.close() }
        }
    }

    static func clip(_ value: Any) -> Any {
        switch value {
        case let text as String: return text.count > longestString ? String(text.prefix(longestString / 2)) + " … " + String(text.suffix(longestString / 2)) : text
        case let object as JSON: return object.mapValues(clip)
        case let list as [Any]: return list.map(clip)
        case is NSNumber, is NSNull: return value
        default: return String(describing: value)
        }
    }
}
