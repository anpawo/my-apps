import CoreServices
import Foundation

private func expect(_ ok: Bool, _ what: String) {
    if !ok { FileHandle.standardError.write("selftest failed: \(what)\n".data(using: .utf8)!); exit(1) }
}

private func blocks(_ path: String) -> Int64 {
    var s = stat()
    precondition(lstat(path, &s) == 0, path)
    return Int64(s.st_blocks) * 512
}

@MainActor func selfCheck() {
    let fm = FileManager.default
    // realpath, not resolvingSymlinksInPath: that one turns /private/var into /var, FSEvents names /private/var.
    let root = String(cString: realpath(NSTemporaryDirectory(), nil)) + "/disk-map-check-\(getpid())"
    defer { try? fm.removeItem(atPath: root) }
    try! fm.createDirectory(atPath: root + "/a/deep", withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
    try! Data(repeating: 7, count: 3 << 20).write(to: URL(fileURLWithPath: root + "/a/deep/big"))
    try! Data(repeating: 1, count: 10).write(to: URL(fileURLWithPath: root + "/a/small"))
    try! Data(repeating: 2, count: 2 << 20).write(to: URL(fileURLWithPath: root + "/b/one"))
    try! fm.linkItem(atPath: root + "/b/one", toPath: root + "/b/two")
    try! fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/a")

    var sizes: [String: Int64] = [:]
    let total = Measure.run(root, record: { sizes[$0] = $1 })
    let a = blocks(root + "/a") + blocks(root + "/a/deep") + blocks(root + "/a/deep/big") + blocks(root + "/a/small")
    expect(sizes[root + "/a"] == a, "a/ is \(sizes[root + "/a"] ?? -1), expected \(a)")
    expect(sizes[root + "/a/deep"] != nil, "a/deep (3 MB) was not recorded")
    let b = blocks(root + "/b") + blocks(root + "/b/one")
    expect(sizes[root + "/b"] == b, "b/ is \(sizes[root + "/b"] ?? -1), expected \(b): its hard link counted twice?")
    expect(total == blocks(root) + a + b + blocks(root + "/link"), "total \(total)")

    let cache = root + "-sizes.tsv"
    defer { try? fm.removeItem(atPath: cache) }
    let store = Store(file: URL(fileURLWithPath: cache))
    let model = Model(path: root, store: store)
    model.adopt(root)
    expect(model.items.map(\.name) == ["a", "b", "link"], "order \(model.items.map(\.name))")
    expect(model.items.first { $0.name == "link" }?.isDir == false, "the link was taken for a folder")
    model.open(model.items.first { $0.name == "a" }!)
    expect(model.path == root + "/a" && model.items.first?.name == "deep", "opening a/ shows \(model.items.map(\.name))")
    model.remove(model.items.first { $0.name == "deep" }!, permanently: true)
    expect(!fm.fileExists(atPath: root + "/a/deep"), "deep/ still on disk")
    expect(model.total == blocks(root + "/a") + blocks(root + "/a/small"), "a/ total after delete: \(model.total ?? -1)")
    model.up()
    expect(model.path == root, "up goes back to \(model.path)")

    // Only what changed is measured again: a grown folder, a new one, a deleted one.
    try! Data(repeating: 3, count: 1 << 20).write(to: URL(fileURLWithPath: root + "/a/grown"))
    try! fm.createDirectory(atPath: root + "/c/d", withIntermediateDirectories: true)
    try! Data(repeating: 4, count: 2 << 20).write(to: URL(fileURLWithPath: root + "/c/d/new"))
    try! fm.removeItem(atPath: root + "/b")
    store.queue.sync { store.apply([root + "/a", root + "/c/d", root + "/b"]) }
    var fresh: [String: Int64] = [:]
    fresh[root] = Measure.run(root, record: { fresh[$0] = $1 })
    for p in [root, root + "/a", root + "/c", root + "/c/d"] {
        expect(store[p] == fresh[p], "\(p) is \(store[p] ?? -1) after the update, a full walk says \(fresh[p] ?? -1)")
    }
    expect(store[root + "/b"] == nil, "b/ is still weighed after its deletion")

    store.queue.sync { store.save() }
    let again = Store(file: URL(fileURLWithPath: cache))
    expect(again.load() && again.count == store.count && again[root] == store[root] && again[root + "/c/d"] == store[root + "/c/d"],
           "the saved weights do not load back the same")

    // FSEvents reports a change on its own.
    store.queue.sync { store.watch(paths: [root], since: FSEventStreamEventId(kFSEventStreamEventIdSinceNow)) }
    usleep(300_000)
    try! Data(repeating: 5, count: 1 << 20).write(to: URL(fileURLWithPath: root + "/c/live"))
    let want = Measure.run(root + "/c", record: { _, _ in })
    var seen = false
    for _ in 0..<100 where !seen {
        usleep(100_000)
        seen = store[root + "/c"] == want
    }
    expect(seen, "FSEvents did not bring the new file in c/: \(store[root + "/c"] ?? -1), expected \(want)")
}
