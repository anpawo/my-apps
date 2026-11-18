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

    let store: Store
    private var started = false

    init(path: String = "/", store: Store = Store()) {
        self.path = path
        self.store = store
        store.onChange = { [weak self] in self?.fill() }
    }

    /// At launch: the saved weights show at once, then only what changed since is measured again.
    func start() {
        guard !started else { return }
        started = true
        follow { $0.start() }
        let store = store
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: nil) { _ in store.queue.sync { store.save() } }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in store.queue.async { store.save() } }
    }

    func scan() { follow { $0.fullScan() } }

    private func follow(_ work: @escaping @Sendable (Store) -> Void) {
        guard !scanning else { return }
        scanning = true
        let store = store
        store.queue.async {
            work(store)
            DispatchQueue.main.async { self.scanning = false; self.fill() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.scanning else { return timer.invalidate() }
                self.files = store.files
                self.fill()
            }
        }
        load()
    }

    /// Measures `root` in full, without the app's timers: for the self-check and the render.
    func adopt(_ root: String) {
        store.queue.sync { store.fullScan(root) }
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
            return Item(id: full, name: name, isDir: isDir, size: isDir ? nil : Int64(s.st_blocks) * 512,
                        unscanned: isDir && Measure.outside(full, s))
        }
        fill()
    }

    func fill() {
        let busy = store.busy
        for i in items.indices where items[i].isDir {
            items[i].size = store[items[i].id] ?? (busy || items[i].unscanned ? nil : 0)
        }
        items.sort { a, b in
            (a.size ?? -1, b.name.lowercased()) > (b.size ?? -1, a.name.lowercased())
        }
        total = store[path]
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
        let store = store, at = item.id
        store.queue.sync { store.apply([at]) }
        items.removeAll { $0.id == item.id }
        fill()
    }
}

func gigabytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "…" }
    let gb = Double(bytes) / 1e9
    if gb < 0.01 { return "< 0.01 GB" }
    return String(format: gb < 10 ? "%.2f GB" : "%.1f GB", gb)
}
