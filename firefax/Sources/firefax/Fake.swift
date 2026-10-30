import Foundation

// The in-memory accessibility world that --selftest runs against: no real tree, window, clock,
// keychain or files. Fixtures are JSON with behaviours (lagging readback, maxlength cut, a dropped
// write, a list that appears only after a key, a field enabled after a pick, a redirect mid-run, a
// challenge page, a password field, an ambiguous label), so the polling and the rails are exercised.

final class FakeClock: Clock {
    private var t = 0.0
    func now() -> Double { t }
    func sleep(_ seconds: Double) { t += seconds }
}

struct FakeSecrets: SecretStore {
    var values: [String: String]
    func value(_ name: String) -> String? { values[name] }
    func names() -> [(name: String, length: Int)] { values.map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name } }
}

struct FakeFiles: FileReader {
    var values: [String: Result<String, ValueError>]
    func read(_ path: String) throws -> String {
        guard let r = values[path] else { throw ValueError(reason: "no fake file \(path)") }
        return try r.get()
    }
}

final class FakeNav: NavCounter {
    private var stamps: [String: [Double]] = [:]
    let clock: Clock
    init(_ clock: Clock, seed: [String: Int] = [:]) {
        self.clock = clock
        for (h, n) in seed { stamps[h] = Array(repeating: clock.now(), count: n) }
    }
    func recentCount(_ host: String) -> Int { (stamps[host] ?? []).filter { clock.now() - $0 < 3600 }.count }
    func record(_ host: String) { stamps[host, default: []].append(clock.now()) }
}

final class FakeTree {
    var currentRoot: FakeNode
    var altRoot: FakeNode?
    var lease: LeaseResult = .typed
    var windowGone = false
    init(root: FakeNode) { currentRoot = root }
    func navigated() { if let a = altRoot { currentRoot = a } }
    func pickHappened() { currentRoot.enableDeferred() }
}

final class FakeNode: AXNode {
    let roleName: String
    var attrs: [String: String]
    var storedValue: String
    var numValue: Int?
    var enabledFlag: Bool
    var children: [FakeNode]
    weak var tree: FakeTree?

    var readbackLag = 0
    var lateChildren = 0
    var dropWrite = false
    var maxlength: Int?
    var hidden = false
    var revealTarget: FakeNode?
    var revealTargetSet: FakeNode?
    var fillsField: FakeNode?
    var enabledAfterPick = false
    var navigate = false
    var tag: String?

    private var pending: String?
    private var lagLeft = 0
    private var childReads = 0

    init(role: String, attrs: [String: String], value: String, numValue: Int?, enabled: Bool, children: [FakeNode]) {
        self.roleName = role
        self.attrs = attrs
        self.storedValue = value
        self.numValue = numValue
        self.enabledFlag = enabled
        self.children = children
    }

    func str(_ attr: String) -> String? {
        switch attr {
        case "AXRole": return roleName
        case "AXValue": return readback()
        default: return attrs[attr]
        }
    }
    func num(_ attr: String) -> Int? {
        if attr == "AXValue" { return numValue }
        return attrs[attr].flatMap(Int.init)
    }
    func bool(_ attr: String) -> Bool? { attr == "AXEnabled" ? enabledFlag : nil }
    func kids() -> [AXNode] {
        if hidden { return [] }
        if lateChildren > 0 { childReads += 1; if childReads <= lateChildren { return [] } }
        return children
    }
    func parent() -> AXNode? { nil }

    @discardableResult func setValue(_ s: String) -> Bool {
        if !dropWrite {
            let eff = maxlength.map { String(s.prefix($0)) } ?? s
            if readbackLag > 0 { pending = eff; lagLeft = readbackLag } else { storedValue = eff }
        }
        revealTargetSet?.hidden = false
        if navigate { tree?.navigated() }
        return true
    }
    @discardableResult func focus() -> Bool { true }
    @discardableResult func press() -> Bool {
        if let f = fillsField { f.storedValue = labelText(); tree?.pickHappened() }
        if roleName == "AXCheckBox" || roleName == "AXRadioButton" { numValue = (numValue ?? 0) == 0 ? 1 : 0 }
        if navigate { tree?.navigated() }
        return true
    }
    func same(as other: AXNode) -> Bool { self === (other as? FakeNode) }

    func enableDeferred() {
        if enabledAfterPick { enabledFlag = true; hidden = false }
        for c in children { c.enableDeferred() }
    }

    private func labelText() -> String { attrs["AXTitle"] ?? attrs["AXDescription"] ?? storedValue }

    private func readback() -> String {
        if pending != nil {
            if lagLeft > 0 { lagLeft -= 1; return storedValue }
            storedValue = pending!; pending = nil
        }
        return storedValue
    }
}

// ---- JSON fixtures ----

struct FxNode: Decodable {
    let role: String
    var id: String?
    var title: String?
    var desc: String?
    var placeholder: String?
    var value: String?
    var url: String?
    var subrole: String?
    var enabled: Bool?
    var checkState: Int?
    var readbackLag: Int?
    var lateChildren: Int?
    var dropWrite: Bool?
    var maxlength: Int?
    var hidden: Bool?
    var revealKey: String?
    var revealSet: String?
    var fills: String?
    var enabledAfterPick: Bool?
    var navigate: Bool?
    var tag: String?
    var children: [FxNode]?
}

struct FxTree: Decodable {
    let host: String
    let path: String
    let root: FxNode
    var alt: FxNode?
    var lease: String?
    var windowGone: Bool?
}

enum Fixture {
    // Builds a FakePage and a lookup of nodes by tag, so asserts can name fields.
    static func load(_ json: String) -> (page: FakePage, tagged: [String: FakeNode]) {
        let fx = try! JSONDecoder().decode(FxTree.self, from: Data(json.utf8))
        var byId: [String: FakeNode] = [:]
        var tagged: [String: FakeNode] = [:]
        let root = build(fx.root, &byId, &tagged)
        let tree = FakeTree(root: root)
        let altNode = fx.alt.map { build($0, &byId, &tagged) }
        tree.altRoot = altNode
        tree.windowGone = fx.windowGone ?? false
        switch fx.lease {
        case "focusLost": tree.lease = .focusLost
        case "notIdle": tree.lease = .notIdle
        default: tree.lease = .typed
        }
        link(fx.root, root, byId)
        if let alt = fx.alt, let altNode { link(alt, altNode, byId) }
        setTree(root, tree)
        if let a = tree.altRoot { setTree(a, tree) }
        return (FakePage(tree: tree, host: fx.host, path: fx.path), tagged)
    }

    private static func build(_ fx: FxNode, _ byId: inout [String: FakeNode], _ tagged: inout [String: FakeNode]) -> FakeNode {
        var attrs: [String: String] = [:]
        if let v = fx.title { attrs["AXTitle"] = v }
        if let v = fx.desc { attrs["AXDescription"] = v }
        if let v = fx.placeholder { attrs["AXPlaceholderValue"] = v }
        if let v = fx.id { attrs["AXDOMIdentifier"] = v }
        if let v = fx.url { attrs["AXURL"] = v }
        if let v = fx.subrole { attrs["AXSubrole"] = v }
        let kids = (fx.children ?? []).map { build($0, &byId, &tagged) }
        let node = FakeNode(role: fx.role, attrs: attrs, value: fx.value ?? "", numValue: fx.checkState,
                            enabled: fx.enabled ?? true, children: kids)
        node.readbackLag = fx.readbackLag ?? 0
        node.lateChildren = fx.lateChildren ?? 0
        node.dropWrite = fx.dropWrite ?? false
        node.maxlength = fx.maxlength
        node.hidden = fx.hidden ?? false
        node.enabledAfterPick = fx.enabledAfterPick ?? false
        node.navigate = fx.navigate ?? false
        node.tag = fx.tag
        if let id = fx.id { byId[id] = node }
        if let t = fx.tag { tagged[t] = node }
        return node
    }

    private static func link(_ fx: FxNode, _ node: FakeNode, _ byId: [String: FakeNode]) {
        if let r = fx.revealKey { node.revealTarget = byId[r] }
        if let r = fx.revealSet { node.revealTargetSet = byId[r] }
        if let f = fx.fills { node.fillsField = byId[f] }
        for (cfx, cnode) in zip(fx.children ?? [], node.children) { link(cfx, cnode, byId) }
    }

    private static func setTree(_ node: FakeNode, _ tree: FakeTree) {
        node.tree = tree
        for c in node.children { setTree(c, tree) }
    }
}

final class FakePage: Page {
    let tree: FakeTree
    let host: String
    let path: String
    init(tree: FakeTree, host: String, path: String) { self.tree = tree; self.host = host; self.path = path }

    func webArea() -> AXNode? { tree.windowGone ? nil : tree.currentRoot }
    func sameWindow() -> Bool { !tree.windowGone }
    func typeUnderLease(_ chars: String, into target: AXNode, human: Bool) -> LeaseResult {
        if tree.lease != .typed { return tree.lease }
        guard let node = target as? FakeNode else { return .focusLost }
        if node.roleName == "AXPopUpButton" { node.storedValue = chars }
        else { node.storedValue += chars; node.revealTarget?.hidden = false }
        return .typed
    }
    func restore() {}
}
