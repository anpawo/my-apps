import Darwin
import Foundation
import SQLite3

// The state folder was ~/.local/state/cx until 25/11/2026. Processes of older builds keep that path in memory, so the move swaps
// both names in one rename and leaves cx as a link to vcx; the link goes once every running VCX app process is a build that knows vcx.
enum StateHome {
    nonisolated(unsafe) static var parent = NSHomeDirectory() + "/.local/state"
    nonisolated(unsafe) static var runningApps: () -> [pid_t] = appProcesses
    static var legacy: String { parent + "/cx" }
    static var current: String { parent + "/" + linkTarget }
    static let linkCheckInterval: TimeInterval = 60
    private static let mergeWaitMilliseconds: Int32 = 10_000
    private static let linkTarget = "vcx"
    private static let processName = "VCX"
    // The update markers RuntimeUpdate writes; a stale installed-build kept from vcx made every frontend replace itself in a loop (26/11).
    private static let pointers: Set<String> = ["installed-build", "manual-build", "update-request"]
    // One empty file per running process of a build that knows the move, named <pid>-<start>.
    private static var registry: String { current + "/.moved" }

    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["VCX_STATE_HOME"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return URL(fileURLWithPath: isFolder(legacy) && !isFolder(current) ? legacy : current, isDirectory: true)
    }

    // A path saved or passed on by an older build (recovery files, restore and live update tickets, worker sockets).
    static func relocated(_ path: String) -> String {
        guard path == legacy || path.hasPrefix(legacy + "/"), isFolder(current) else { return path }
        return current + path.dropFirst(legacy.count)
    }

    static func relocated(_ url: URL) -> URL {
        let path = relocated(url.path)
        return path == url.path ? url : URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
    }

    // Runs before anything opens a state path; a check with its own homes never touches the real folders.
    static func migrate() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VCX_STATE_HOME"] == nil, environment["VCX_RUNTIME_HOME"] == nil else { return }
        adopt()
    }

    // The move, then this process's entry in the registry, under whatever folder `parent` names.
    static func adopt() {
        if isFolder(legacy) {
            let lock = open(legacy, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if lock >= 0 {
                flock(lock, LOCK_EX)
                if isFolder(legacy) { isFolder(current) ? merge() : move() }
                close(lock)
            }
        }
        guard isLegacyLink() else { return }
        if let start = startTime(getpid()) {
            try? FileManager.default.createDirectory(atPath: registry, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: registry + "/\(getpid())-\(start)", contents: nil, attributes: [.posixPermissions: 0o600])
        }
        removeLegacyLinkIfUnused()
    }

    // vcx first holds a link to itself, so the swap leaves no instant where either name is missing.
    private static func move() {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: current)) == linkTarget { unlink(current) }
        guard symlink(linkTarget, current) == 0 else { return NSLog("VCX: state stays in %@: %@ already exists", legacy, current) }
        guard renamex_np(legacy, current, UInt32(RENAME_SWAP)) == 0 else {
            NSLog("VCX: cannot move the state folder: %s", strerror(errno))
            unlink(current); return
        }
        NSLog("VCX: moved the state folder to %@", current)
    }

    // A process holding the old path made cx again once the link was gone (25/11/2026 16:24), and every window opened
    // after it kept its state there, so Watcher's resumes of earlier conversations found nothing. cx becomes the link
    // again first, so no new write lands there, then its entries join vcx; what cannot join stays in the leftover folder.
    private static func merge() {
        let leftover = parent + "/cx-merged-\(Int(Date().timeIntervalSince1970))"
        guard symlink(linkTarget, leftover) == 0 else { return NSLog("VCX: cannot merge %@: %s", legacy, strerror(errno)) }
        guard renamex_np(leftover, legacy, UInt32(RENAME_SWAP)) == 0 else {
            NSLog("VCX: cannot merge %@: %s", legacy, strerror(errno))
            unlink(leftover); return
        }
        mergeEntries(leftover, into: current)
        mergeDatabase(leftover + "/conversations.sqlite", into: current + "/conversations.sqlite")
        NSLog("VCX: merged a cx state folder made again into %@; what could not join stays in %@", current, leftover)
    }

    // A rename keeps the inode, so a live socket or a held lock follows its file. A name in both keeps vcx's, unless it
    // is a record or pointer written later in cx.
    private static func mergeEntries(_ source: String, into target: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: source)) ?? [] where !name.hasPrefix("conversations.sqlite") {
            let from = source + "/" + name, to = target + "/" + name
            var info = stat()
            if lstat(to, &info) != 0 { rename(from, to) }
            else if isFolder(from) && isFolder(to) { mergeEntries(from, into: to) }
            else if name.hasSuffix(".json") || pointers.contains(name), modified(from) > modified(to) { rename(from, to) }
        }
    }

    private static func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    // Conversation ids are UUIDs and blobs are keyed by their hash, so a row in both files is the same row; a
    // conversation keeps its latest record. Events get new ids after vcx's own.
    private static func mergeDatabase(_ source: String, into target: String) {
        guard FileManager.default.fileExists(atPath: source) else { return }
        guard FileManager.default.fileExists(atPath: target) else {
            for suffix in ["", "-wal", "-shm"] { rename(source + suffix, target + suffix) }
            return
        }
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open(target, &connection) == SQLITE_OK else { return NSLog("VCX: cannot open %@ to merge", target) }
        sqlite3_busy_timeout(connection, mergeWaitMilliseconds)
        func run(_ sql: String) -> Bool { sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK }
        func names(_ sql: String) -> [String] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            var result: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(String(cString: sqlite3_column_text(statement, 0))) }
            return result
        }
        guard run("ATTACH DATABASE '\(source.replacingOccurrences(of: "'", with: "''"))' AS legacy"), run("BEGIN IMMEDIATE") else {
            return NSLog("VCX: cannot merge %@: %s", source, sqlite3_errmsg(connection))
        }
        var merged = true
        for table in names("SELECT name FROM legacy.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") {
            let present = Set(names("SELECT name FROM pragma_table_info('\(table)', 'main')"))
            let columns = names("SELECT name FROM pragma_table_info('\(table)', 'legacy')").filter { present.contains($0) && !(table == "events" && $0 == "id") }
            guard !columns.isEmpty else { continue }
            let list = columns.map { "\"\($0)\"" }.joined(separator: ", ")
            let rows = "INTO \"\(table)\" (\(list)) SELECT \(list) FROM legacy.\"\(table)\" WHERE true ORDER BY rowid"
            let newer = columns.filter { $0 != "id" }.map { "\"\($0)\" = excluded.\"\($0)\"" }.joined(separator: ", ")
            merged = merged && run(table == "conversations"
                ? "INSERT " + rows + " ON CONFLICT(id) DO UPDATE SET " + newer + " WHERE excluded.updated_at > conversations.updated_at"
                : "INSERT OR IGNORE " + rows)
        }
        if !merged { NSLog("VCX: cannot merge %@: %s", source, sqlite3_errmsg(connection)) }
        _ = run(merged ? "COMMIT" : "ROLLBACK")
    }

    // Returns whether the cx link is still there.
    @discardableResult
    static func removeLegacyLinkIfUnused() -> Bool {
        guard isLegacyLink() else { return false }
        let running = Set(runningApps().compactMap { pid in startTime(pid).map { "\(pid)-\($0)" } })
        let known = Set((try? FileManager.default.contentsOfDirectory(atPath: registry)) ?? [])
        for gone in known.subtracting(running) { unlink(registry + "/" + gone) }
        guard running.isSubset(of: known) else { return true }
        unlink(legacy)
        try? FileManager.default.removeItem(atPath: registry)
        NSLog("VCX: removed the %@ link, no older build runs", legacy)
        return false
    }

    // By the kernel's process name, not proc_pidpath: that fails once an install has replaced the running binary, which on
    // 25/11/2026 hid every older process and removed the link under them.
    static func appProcesses() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(count, 0)).filter { pid in
            guard pid > 0, let info = processInfo(pid) else { return false }
            return withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == processName
        }
    }

    private static func startTime(_ pid: pid_t) -> UInt64? {
        processInfo(pid).map { $0.pbi_start_tvsec * 1_000_000 + $0.pbi_start_tvusec }
    }

    private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
              info.pbi_uid == getuid() else { return nil }
        return info
    }

    // ./vcx is the link put back by hand after that removal.
    private static func isLegacyLink() -> Bool {
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: legacy)
        return target == linkTarget || target == "./" + linkTarget
    }

    private static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
