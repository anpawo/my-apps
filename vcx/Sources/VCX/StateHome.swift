import Darwin
import Foundation

// The state folder was ~/.local/state/cx until 25/11/2026. Processes of older builds keep that path in memory, so the move swaps
// both names in one rename and leaves cx as a link to vcx; the link goes once every running VCX app process is a build that knows vcx.
enum StateHome {
    nonisolated(unsafe) static var parent = NSHomeDirectory() + "/.local/state"
    nonisolated(unsafe) static var runningApps: () -> [pid_t] = appProcesses
    static var legacy: String { parent + "/cx" }
    static var current: String { parent + "/" + linkTarget }
    static let linkCheckInterval: TimeInterval = 60
    private static let linkTarget = "vcx"
    // One empty file per running process of a build that knows the move, named <pid>-<start>.
    private static var registry: String { current + "/.moved" }

    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["VCX_STATE_HOME"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return URL(fileURLWithPath: isFolder(legacy) ? legacy : current, isDirectory: true)
    }

    // A path saved or passed on by an older build (recovery files, restore and live update tickets, worker sockets).
    static func relocated(_ path: String) -> String {
        guard path == legacy || path.hasPrefix(legacy + "/"), !isFolder(legacy), isFolder(current) else { return path }
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
                if isFolder(legacy) { move() }
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

    private static func appProcesses() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(max(count, 0)).filter { pid in
            pid > 0 && proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).hasSuffix(".app/Contents/MacOS/VCX")
        }
    }

    private static func startTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
              info.pbi_uid == getuid() else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private static func isLegacyLink() -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: legacy)) == linkTarget }

    private static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
