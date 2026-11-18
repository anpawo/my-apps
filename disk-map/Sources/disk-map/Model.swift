import AppKit
import Foundation

struct Item: Identifiable, Equatable {
    let id: String  // full path
    let name: String
    let isDir: Bool
    var size: Int64?
    var unscanned = false
}

@MainActor
final class Model: ObservableObject {
    @Published var path: String
    @Published var items: [Item] = []
    @Published var total: Int64?
    @Published var files = 0
    @Published var scanning = false
    @Published var problem: String?

    private var sizes: [String: Int64] = [:]
    private var skipped = Set<String>()
    private let inbox = Inbox()

    init(path: String = "/") { self.path = path }

    func scan() {
        guard !scanning else { return }
        scanning = true
        sizes = [:]; skipped = []; files = 0
        _ = inbox.take()
        inbox.finished = false
        let root = "/", inbox = inbox
        Thread.detachNewThread {
            let total = Measure.run(root, record: { inbox.add(size: ($0, $1)) },
                                    skip: { inbox.add(skip: $0) }, progress: { inbox.files = $0 })
            inbox.add(size: (root, total))
            inbox.finished = true
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let (got, skips, files, done) = self.inbox.take()
                for (p, s) in got { self.sizes[p] = s }
                self.skipped.formUnion(skips)
                self.files = files
                if done { self.scanning = false; timer.invalidate() }
                if !got.isEmpty || done { self.fill() }
            }
        }
        load()
    }

    /// Loads a finished measure without the app's timer: for the self-check and the render.
    func adopt(_ root: String) {
        sizes = [:]
        sizes[root] = Measure.run(root, record: { self.sizes[$0] = $1 })
        load()
    }

    func open(_ item: Item) {
        if item.isDir { path = item.id; load() } else { NSWorkspace.shared.open(URL(fileURLWithPath: item.id)) }
    }

    func up() {
        guard path != "/" else { return }
        path = (path as NSString).deletingLastPathComponent
        load()
    }

    func load() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        items = names.map { name in
            let full = path == "/" ? "/" + name : path + "/" + name
            var s = stat()
            guard lstat(full, &s) == 0 else { return Item(id: full, name: name, isDir: false, size: nil) }
            let isDir = (s.st_mode & S_IFMT) == S_IFDIR
            return Item(id: full, name: name, isDir: isDir, size: isDir ? nil : Int64(s.st_blocks) * 512)
        }
        fill()
    }

    private func fill() {
        let done = !scanning
        for i in items.indices where items[i].isDir {
            let p = items[i].id
            items[i].unscanned = skipped.contains(p)
            // Under the record threshold a directory is never recorded: once the walk is over, it is small.
            items[i].size = sizes[p] ?? (done && !items[i].unscanned ? 0 : nil)
        }
        items.sort { a, b in
            (a.size ?? -1, b.name.lowercased()) > (b.size ?? -1, a.name.lowercased())
        }
        total = sizes[path]
    }

    func remove(_ item: Item, permanently: Bool) {
        do {
            if permanently {
                try FileManager.default.removeItem(atPath: item.id)
            } else {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.id), resultingItemURL: nil)
            }
        } catch {
            problem = error.localizedDescription
            return
        }
        let freed = item.size ?? 0
        var p = item.id
        while p != "/" {
            p = (p as NSString).deletingLastPathComponent
            if let s = sizes[p] { sizes[p] = s - freed }
        }
        sizes = sizes.filter { !$0.key.hasPrefix(item.id + "/") && $0.key != item.id }
        items.removeAll { $0.id == item.id }
        total = sizes[path]
    }
}

/// Hands the walk's results from its thread to the main one.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [(String, Int64)] = []
    private var skips: [String] = []
    private var _files = 0
    private var _finished = false

    var files: Int {
        get { lock.withLock { _files } }
        set { lock.withLock { _files = newValue } }
    }
    var finished: Bool {
        get { lock.withLock { _finished } }
        set { lock.withLock { _finished = newValue } }
    }
    func add(size: (String, Int64)) { lock.withLock { sizes.append(size) } }
    func add(skip: String) { lock.withLock { skips.append(skip) } }
    func take() -> ([(String, Int64)], [String], Int, Bool) {
        lock.withLock {
            defer { sizes = []; skips = [] }
            return (sizes, skips, _files, _finished)
        }
    }
}

func gigabytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "…" }
    let gb = Double(bytes) / 1e9
    if gb < 0.01 { return "< 0.01 GB" }
    return String(format: gb < 10 ? "%.2f GB" : "%.1f GB", gb)
}
