import Foundation

/// What filled the disk (asked 2026-11-18): an hourly `du` of the folders that hold it, kept a
/// week, and the folders that grew by half a gigabyte or more since about a day ago.
@MainActor final class DiskGrowth: ObservableObject {
    struct Row: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let bytes: Int64
    }
    private struct Snapshot: Codable {
        let at: Date
        let free: Int64
        /// Kilobytes per folder, three levels down. Folders under 50 MB are left out: a folder
        /// that was under that a day ago reads as grown from zero, an error of 50 MB at most.
        let kb: [String: Int64]
    }

    @Published private(set) var rows: [Row] = []
    /// The reading the rows are measured from; nil before the second scan.
    @Published private(set) var since: Date?
    @Published private(set) var lastScan: Date?

    nonisolated static let threshold: Int64 = 500_000_000
    nonisolated private static let scanInterval: TimeInterval = 3600
    nonisolated private static let minimumScanInterval: TimeInterval = 60
    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/fleet/disk-sizes.json")
    nonisolated private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    // `.mounts` is sshfs: remote disks, not this one.
    nonisolated private static let roots = [home, "/Applications", "/Library", "/private/var"]
    private var snapshots: [Snapshot] = []
    private var scanning = false

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([Snapshot].self, from: data) {
            snapshots = saved
        }
        refresh()
    }

    /// Called on the reaper's slow tick; a scan is about a minute of `du` at the lowest priority.
    func tick() {
        guard !pretending, !scanning else { return }
        let elapsed = Date().timeIntervalSince(snapshots.last?.at ?? .distantPast)
        let freeChange = Int64(MemoryPressure.disk().free) - (snapshots.last?.free ?? 0)
        guard Self.scanDue(elapsed: elapsed, freeChange: freeChange) else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let snap = Self.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning = false
                    guard let snap else { return }
                    self.snapshots = self.snapshots.filter { snap.at.timeIntervalSince($0.at) < 7 * 86400 } + [snap]
                    try? JSONEncoder().encode(self.snapshots).write(to: Self.file, options: .atomic)
                    self.refresh()
                }
            }
        }
    }

    nonisolated static func scanDue(elapsed: TimeInterval, freeChange: Int64) -> Bool {
        elapsed >= scanInterval || (elapsed >= minimumScanInterval && abs(freeChange) >= threshold)
    }

    private nonisolated static func scan() -> Snapshot? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        p.arguments = ["-n", "20", "/usr/bin/du", "-x", "-d", "3", "-k", "-I", ".mounts"] + roots
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var kb: [String: Int64] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let n = Int64(line[..<tab]), n >= 51_200 else { continue }
            kb[String(line[line.index(after: tab)...])] = n
        }
        guard !kb.isEmpty else { return nil }
        return Snapshot(at: Date(), free: Int64(MemoryPressure.disk().free), kb: kb)
    }

    private var pretending = false

    /// Invented folders, for a picture that can be published: see `DemoFleet.fill`.
    func pretend(_ rows: [Row], since: Date) {
        pretending = true
        self.rows = rows
        self.since = since
        lastScan = Date()
    }

    private func refresh() {
        lastScan = snapshots.last?.at
        guard let now = snapshots.last, snapshots.count > 1 else { rows = []; since = nil; return }
        let base = snapshots.last { now.at.timeIntervalSince($0.at) >= 86400 } ?? snapshots[0]
        since = base.at
        rows = Self.growth(from: base.kb, to: now.kb, freeDrop: base.free - now.free)
    }

    /// The deepest folders that grew by `threshold`; a parent too when what grew in it outside
    /// those is still that much. Then whatever the drop in free space leaves unexplained.
    nonisolated static func growth(from old: [String: Int64], to new: [String: Int64], freeDrop: Int64) -> [Row] {
        let deltas = new.reduce(into: [String: Int64]()) { $0[$1.key] = ($1.value - (old[$1.key] ?? 0)) * 1024 }
        var kept: [String: Int64] = [:]
        for (path, delta) in deltas.sorted(by: { $0.key.count > $1.key.count }) where delta >= threshold {
            let inside = kept.filter { $0.key.hasPrefix(path + "/") }.values.reduce(0, +)
            // Only what the folder's kept children have not already said.
            if delta - inside >= threshold { kept[path] = delta - inside }
        }
        var rows = kept.map { Row(path: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
        let tracked = roots.compactMap { deltas[$0] }.reduce(0, +)
        if freeDrop - tracked >= threshold {
            rows.append(Row(path: "System, snapshots, other", bytes: freeDrop - tracked))
        }
        return rows
    }

    /// `~/Library/Containers/com.docker.docker` rather than the full path.
    static func label(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
