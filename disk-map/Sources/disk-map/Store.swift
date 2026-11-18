import CoreServices
import Foundation

/// The weight of every directory, kept in a file between launches. FSEvents keeps its own history on disk, so at
/// launch the folders changed since the saved event are measured again, and only them; then it follows live.
final class Store: @unchecked Sendable {
    static let defaultFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Disk Map/sizes.tsv")

    /// Every change runs here, one at a time; the main thread only reads, under `lock`.
    let queue = DispatchQueue(label: "disk-map.store")
    let file: URL
    var onChange: (() -> Void)?

    private let lock = NSLock()
    private var total: [String: Int64] = [:]
    private var removed = Set<String>()
    private var lastEvent = FSEventStreamEventId(0)
    private var _files = 0
    private var _busy = false
    private var stream: FSEventStreamRef?
    private let events = DispatchQueue(label: "disk-map.events")
    private var pending = Pending()
    private var scannedAt = Date.distantPast

    init(file: URL = Store.defaultFile) { self.file = file }

    subscript(path: String) -> Int64? { lock.withLock { total[path] } }
    var files: Int { lock.withLock { _files } }
    var busy: Bool { lock.withLock { _busy } }
    var count: Int { lock.withLock { total.count } }

    // MARK: on `queue`

    /// Loads the saved weights, else measures the whole disk; then follows the changes from where it stopped.
    func start(root: String = "/") {
        dispatchPrecondition(condition: .onQueue(queue))
        if !load() || lock.withLock({ lastEvent }) > FSEventsGetCurrentEventId() { fullScan(root) }
        watch(paths: [root], since: lock.withLock { lastEvent })
    }

    func fullScan(_ root: String = "/") {
        let since = FSEventsGetCurrentEventId()
        lock.withLock { _files = 0; _busy = true }
        // The old weights stay on screen until the new ones replace them.
        var fresh: [String: Int64] = [:]
        _ = Measure.run(root, record: { fresh[$0] = $1; self.set($0, $1) },
                        progress: { n in self.lock.withLock { self._files = n } })
        lock.withLock { total = fresh; removed = []; lastEvent = since; _busy = false }
        scannedAt = Date()
        save()
    }

    /// Measures again the directories FSEvents named: `paths` one level (their files, their known subfolders),
    /// `deep` whole, then carries each difference up to `/`.
    func apply(_ paths: [String], deep: [String] = []) {
        var levels: [Int: Set<String>] = [:]
        func add(_ p: String) { levels[depth(p), default: []].insert(p) }
        for p in deep where !excluded(p) {
            // A whole-disk scan blocks the queue long enough for FSEvents to drop events and name "/": rescanning
            // at once would loop forever.
            if p == "/" {
                if Date().timeIntervalSince(scannedAt) > 600 { return fullScan() }
                add("/")
                continue
            }
            if isDirectory(p) {
                let before = self[p] ?? 0
                let after = Measure.run(p, record: set)
                carry(after - before, above: p)
            }
            add(parent(p))
        }
        for p in paths where !excluded(p) { if let k = known(p) { add(k) } }
        while let d = levels.keys.max() {
            for dir in levels.removeValue(forKey: d)! {
                guard isDirectory(dir) else {
                    let old = lock.withLock { () -> Int64 in removed.insert(dir); return total.removeValue(forKey: dir) ?? 0 }
                    carry(-old, above: dir)
                    if dir != "/" { add(parent(dir)) }
                    continue
                }
                let new = weighOneLevel(dir)
                let old = self[dir] ?? 0
                set(dir, new)
                carry(new - old, above: dir)
            }
        }
    }

    // ponytail: a hard link counts once in a full walk but once per folder here, until the next full walk.
    private func weighOneLevel(_ dir: String) -> Int64 {
        var st = stat()
        guard lstat(dir, &st) == 0 else { return 0 }
        var sum = Int64(st.st_blocks) * 512
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            let child = dir == "/" ? "/" + name : dir + "/" + name
            guard lstat(child, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) != S_IFDIR {
                sum += Int64(st.st_blocks) * 512
            } else if !Measure.outside(child, st) {
                sum += self[child] ?? Measure.run(child, record: set)
            }
        }
        return sum
    }

    /// A folder deleted then made again is no longer one to drop at the next save.
    private func set(_ path: String, _ size: Int64) {
        lock.withLock { total[path] = size; removed.remove(path) }
    }

    private func carry(_ delta: Int64, above path: String) {
        guard delta != 0, path != "/" else { return }
        lock.withLock {
            var p = path
            repeat {
                p = parent(p)
                if let t = total[p] { total[p] = t + delta }
            } while p != "/"
        }
    }

    /// The nearest directory already weighed: a folder FSEvents names for the first time is new, and its
    /// parent's one-level weighing measures it whole. Nil outside what was weighed.
    private func known(_ path: String) -> String? {
        var p = path
        while self[p] == nil {
            if p == "/" { return nil }
            p = parent(p)
        }
        return p
    }

    func save() {
        let (sizes, gone, event) = lock.withLock { (total, removed, lastEvent) }
        var out = "disk-map 1\t\(event)\n"
        out.reserveCapacity(sizes.count * 64)
        for (p, s) in sizes where !p.contains("\n") && !under(p, gone) { out += "\(s)\t\(p)\n" }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? out.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        lock.withLock { removed.subtract(gone) }
    }

    @discardableResult func load() -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)[...]
        guard let head = lines.popFirst(), head.hasPrefix("disk-map 1\t"),
              let event = FSEventStreamEventId(head.split(separator: "\t").last ?? "") else { return false }
        var sizes: [String: Int64] = [:]
        sizes.reserveCapacity(lines.count)
        for line in lines {
            guard let tab = line.firstIndex(of: "\t"), let s = Int64(line[..<tab]) else { continue }
            sizes[String(line[line.index(after: tab)...])] = s
        }
        lock.withLock { total = sizes; lastEvent = event }
        return true
    }

    // MARK: FSEvents

    func watch(paths: [String], since: FSEventStreamEventId) {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, ids in
            let store = Unmanaged<Store>.fromOpaque(info!).takeUnretainedValue()
            let cPaths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                | kFSEventStreamEventFlagKernelDropped)
            var plain: [String] = [], deep: [String] = [], wrapped = false
            for i in 0..<count {
                let f = flags[i]
                if f & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
                if f & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 { wrapped = true }
                let p = normalize(String(cString: cPaths[i]))
                if f & rescan != 0 { deep.append(p) } else { plain.append(p) }
            }
            store.enqueue(plain, deep: deep, wrapped: wrapped, last: (0..<count).map { ids[$0] }.max() ?? 0)
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray, since, 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, events)
        FSEventStreamStart(s)
    }

    /// The callback only queues the paths: one that waits for a long weighing makes FSEvents drop events, and a
    /// drop names "/", a whole-disk scan.
    private func enqueue(_ plain: [String], deep: [String], wrapped: Bool, last: FSEventStreamEventId) {
        let first = lock.withLock { () -> Bool in
            let idle = pending.plain.isEmpty && pending.deep.isEmpty && !pending.wrapped && pending.last == 0
            pending.plain.formUnion(plain); pending.deep.formUnion(deep)
            pending.wrapped = pending.wrapped || wrapped; pending.last = max(pending.last, last)
            return idle
        }
        guard first else { return }
        queue.async {
            let batch = self.lock.withLock { () -> Pending in let b = self.pending; self.pending = Pending(); return b }
            if batch.wrapped { self.fullScan() } else { self.apply(Array(batch.plain), deep: Array(batch.deep)) }
            self.lock.withLock { if batch.last > self.lastEvent { self.lastEvent = batch.last } }
            DispatchQueue.main.async { self.onChange?() }
        }
    }
}

private struct Pending {
    var plain = Set<String>(), deep = Set<String>(), wrapped = false, last = FSEventStreamEventId(0)
}

// Not NSString's deletingLastPathComponent: its bridged strings hash slowly, and save() hashes millions of them.
private func parent(_ path: String) -> String {
    guard let i = path.lastIndex(of: "/"), i != path.startIndex else { return "/" }
    return String(path[..<i])
}
private func depth(_ path: String) -> Int { path.reduce(0) { $1 == "/" ? $0 + 1 : $0 } }
private func isDirectory(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
}
private func excluded(_ path: String) -> Bool {
    Measure.skipped.contains { path == $0 || path.hasPrefix($0 + "/") }
}
private func under(_ path: String, _ gone: Set<String>) -> Bool {
    guard !gone.isEmpty else { return false }
    var p = path
    while true {
        if gone.contains(p) { return true }
        if p == "/" { return false }
        p = parent(p)
    }
}

/// FSEvents names a firmlinked folder by its place on the Data volume.
func normalize(_ raw: String) -> String {
    var p = raw
    while p.count > 1, p.hasSuffix("/") { p.removeLast() }
    let data = "/System/Volumes/Data"
    if p == data { return "/" }
    if p.hasPrefix(data + "/") { p.removeFirst(data.count) }
    return p
}
