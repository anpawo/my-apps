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
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("disk-map-check-\(getpid())").path
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

    let model = Model(path: root)
    model.adopt(root)
    expect(model.items.map(\.name) == ["a", "b", "link"], "order \(model.items.map(\.name))")
    expect(model.items.first { $0.name == "link" }?.isDir == false, "the link was taken for a folder")
    model.open(model.items.first { $0.name == "a" }!)
    expect(model.path == root + "/a" && model.items.first?.name == "deep", "opening a/ shows \(model.items.map(\.name))")
    let before = model.total ?? 0
    model.remove(model.items.first { $0.name == "deep" }!, permanently: true)
    expect(!fm.fileExists(atPath: root + "/a/deep"), "deep/ still on disk")
    expect((model.total ?? 0) == before - (a - blocks(root + "/a") - blocks(root + "/a/small")), "a/ total after delete")
    model.up()
    expect(model.path == root, "up goes back to \(model.path)")
}
