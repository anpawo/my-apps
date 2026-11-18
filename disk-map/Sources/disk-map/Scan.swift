import Darwin
import Foundation

struct Measure {
    // The Data volume shows up twice: through its firmlinks (/Users, /Applications…) and under /System/Volumes/Data.
    static let skipped: Set<String> = ["/System/Volumes", "/Volumes"]
    static let allowedDevices: Set<dev_t> = Set(["/", "/System/Volumes/Data"].compactMap { path in
        var s = stat()
        return lstat(path, &s) == 0 ? s.st_dev : nil
    })

    /// A folder the walk leaves out: another disk or mount, or a second view of the startup disk.
    static func outside(_ path: String, _ st: stat) -> Bool {
        !allowedDevices.contains(st.st_dev) || skipped.contains(path)
    }

    /// Walks `root` without following links or leaving the startup disk, calls `record` with the weight of every
    /// directory under it (itself included), and returns the allocated bytes under `root`.
    static func run(_ root: String, record: (String, Int64) -> Void, progress: (Int) -> Void = { _ in }) -> Int64 {
        var hardLinks = Set<[UInt64]>()
        var files = 0
        var total: Int64 = 0
        guard let fts = root.withCString({ c -> UnsafeMutablePointer<FTS>? in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(c), nil]
            defer { free(argv[0]) }
            return fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil)
        }) else { return 0 }
        defer { fts_close(fts) }
        while let e = fts_read(fts) {
            let level = e.pointee.fts_level
            let st = e.pointee.fts_statp
            let own = st.map { Int64($0.pointee.st_blocks) * 512 } ?? 0
            switch Int32(e.pointee.fts_info) {
            case FTS_D:
                if level > 0, let st, outside(clean(String(cString: e.pointee.fts_path)), st.pointee) {
                    fts_set(fts, e, FTS_SKIP)
                    continue
                }
                e.pointee.fts_number = 0
            case FTS_DP:
                let path = clean(String(cString: e.pointee.fts_path))
                // A skipped directory still comes back here, and an NFS mount point's own blocks are its whole disk.
                if level > 0, let st, outside(path, st.pointee) { continue }
                let size = Int64(e.pointee.fts_number) + own
                record(path, size)
                if level == 0 { total = size } else { e.pointee.fts_parent.pointee.fts_number += Int(size) }
            case FTS_DC, FTS_ERR, FTS_NS:
                continue
            default:  // files, links, and directories it could not read (counted as their own entry)
                if let st, st.pointee.st_nlink > 1, (st.pointee.st_mode & S_IFMT) != S_IFDIR,
                   !hardLinks.insert([UInt64(bitPattern: Int64(st.pointee.st_dev)), st.pointee.st_ino]).inserted {
                    continue
                }
                if level == 0 { total = own } else { e.pointee.fts_parent.pointee.fts_number += Int(own) }
                files += 1
                if files % 20_000 == 0 { progress(files) }
            }
        }
        progress(files)
        return total
    }

    static func clean(_ path: String) -> String {
        path.count > 1 && path.hasPrefix("//") ? String(path.dropFirst()) : path
    }
}
