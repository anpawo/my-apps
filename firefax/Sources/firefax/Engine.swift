import Foundation

// The deterministic core: scan a page into ready locators, or fill it from a spec, one call, one line
// of report per step, never a value. No LLM here. Every live effect goes through the Page/AXNode/Clock
// protocols, so --selftest runs the whole of this against FakeAX.

struct Timing {
    var poll = 0.025
    var text = 1.0
    var listSelect = 3.0
    var wholeCall = 90.0
}

protocol NavCounter {
    func recentCount(_ host: String) -> Int   // navigating presses in the last hour
    func record(_ host: String)
    func lockMinutesLeft(_ host: String) -> Int?   // a challenge locked this host; nil once it expires
    func lock(_ host: String)
    func unlock(_ host: String)
}

let challengeLock = 3600.0

private let controlRoles: Set<String> = [
    "AXTextField", "AXComboBox", "AXTextArea", "AXPopUpButton",
    "AXCheckBox", "AXRadioButton", "AXButton", "AXLink", "AXMenuItem",
]
private let textFieldRoles: Set<String> = ["AXTextField", "AXComboBox", "AXTextArea"]
private let navAllowlist = ["suivant", "continuer", "next", "etape suivante"]
private let attestations = ["je confirme", "j'atteste", "je declare", "certifie sur l'honneur"]
private let navCap = 20

func fold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

struct Engine {
    let clock: Clock
    let store: SecretStore
    let files: FileReader
    let nav: NavCounter
    var timing = Timing()
    var human = false
    var dryRun = false
    var showTiming = false
    var finals: [String] = []

    // ---- scan ----

    static func lockLine(_ host: String, _ minutes: Int) -> String {
        "firefax: \(host) is locked after a challenge, \(minutes) min left; solve it in Firefox, then firefax unlock \(host)"
    }

    func scan(_ page: Page) -> (Int32, [String]) {
        if let left = nav.lockMinutesLeft(page.host) { return (5, [Engine.lockLine(page.host, left)]) }
        guard let web = page.webArea() else { return (3, ["firefax scan: no web area on the current tab"]) }
        let flats = flatten(web)
        let controls = flats.filter { controlRoles.contains($0.node.role) }
        var lines = ["page \(page.host)\(safePath(page.path))  controls \(controls.count)  filled \(controls.filter { filled($0.node) }.count)"]
        let titles = controls.map { controlTitle($0) }
        for (i, c) in controls.enumerated() {
            lines.append(scanLine(c, index: i, controls: controls, titles: titles))
        }
        return (0, lines)
    }

    private func scanLine(_ c: Flat, index: Int, controls: [Flat], titles: [String]) -> String {
        let locator = strongestLocator(c, index: index, controls: controls, titles: titles)
        let roleShort = String(c.node.role.dropFirst(2)).lowercased()
        var tags = [roleShort, filled(c.node) ? "filled" : "empty"]
        if !c.node.enabled { tags.append("disabled") }
        if c.node.secure { tags.append("secure") }
        return pad(locator, 36) + tags.joined(separator: "  ")
    }

    // The strongest unique key: id, then label, then placeholder, then preceding text; nth for a tie.
    private func strongestLocator(_ c: Flat, index: Int, controls: [Flat], titles: [String]) -> String {
        if let id = c.node.str("AXDOMIdentifier"), !id.isEmpty { return "{\"id\": \"\(id)\"}" }
        let title = titles[index]
        if !title.isEmpty {
            let ties = titles.enumerated().filter { normalizeLabel($0.element) == normalizeLabel(title) }
            if ties.count == 1 { return "{\"label\": \"\(title)\"}" }
            let nth = ties.firstIndex { $0.offset == index }.map { $0 + 1 } ?? 1
            return "{\"label\": \"\(title)\", \"nth\": \(nth)}"
        }
        if let ph = c.node.str("AXPlaceholderValue"), !ph.isEmpty { return "{\"placeholder\": \"\(ph)\"}" }
        if !c.preceding.isEmpty { return "{\"after\": \"\(c.preceding)\"}" }
        return "{\"nth\": \(index + 1)}"
    }

    // ---- fill ----

    func fill(_ spec: Spec, _ page: Page) -> (Int32, [String]) {
        let (wantHost, wantPath) = splitPage(spec.page)
        if let left = nav.lockMinutesLeft(wantHost) { return (5, [Engine.lockLine(wantHost, left)]) }
        guard page.host == wantHost, page.path.hasPrefix(wantPath) else {
            return (3, ["firefax fill: the current page is \(page.host)\(safePath(page.path)), not \(spec.page)"])
        }
        if let bad = specShape(spec) { return (2, ["firefax fill: \(bad)"]) }
        guard let startArea = page.webArea() else { return (3, ["firefax fill: no web area"]) }

        var results: [StepResult] = []
        let begin = clock.now()
        var code: Int32 = 0
        var stopped = false

        for (i, step) in spec.steps.enumerated() {
            if stopped { results.append(StepResult(index: i + 1, action: step.action.name, status: .skip, locator: step.locator.described)); continue }
            if clock.now() - begin > timing.wholeCall {
                results.append(StepResult(index: i + 1, action: step.action.name, status: .failed, locator: step.locator.described, detail: "90 s call cap reached"))
                code = 1; stopped = true; continue
            }
            if !page.sameWindow() { return close(3, results, page, note: "window gone", from: i + 1, action: step.action.name) }
            guard let web = page.webArea() else { return close(3, results, page, note: "web area gone", from: i + 1, action: step.action.name) }
            if !web.same(as: startArea) {
                switch challenge(web) {
                case .challenge(let what): return close(5, results, page, note: "challenge: \(what)", from: i + 1, action: step.action.name)
                case .expired: return close(3, results, page, note: "session expirée", from: i + 1, action: step.action.name)
                case nil: return close(3, results, page, note: "page navigated away", from: i + 1, action: step.action.name)
                }
            }
            if let ch = challenge(web) {
                switch ch {
                case .challenge(let what): return close(5, results, page, note: "challenge: \(what)", from: i + 1, action: step.action.name)
                case .expired: return close(3, results, page, note: "session expirée", from: i + 1, action: step.action.name)
                }
            }

            let t0 = clock.now()
            let r = run(step, index: i + 1, web: web, page: page)
            if showTiming { FileHandle.standardError.write(Data("step \(i + 1) \(step.action.name) \(ms(clock.now() - t0))\n".utf8)) }
            results.append(r)
            if r.status != .ok { code = exitFor(r.status); stopped = true }
        }

        let out = render(results, page)
        if !dryRun { page.restore() }
        return (code, out)
    }

    private func run(_ step: Step, index: Int, web: AXNode, page: Page) -> StepResult {
        let r = StepResult(index: index, action: step.action.name, status: .ok, locator: step.locator.described)
        let flats = flatten(web)

        switch resolveNode(step.locator, flats) {
        case .notFound:
            var f = r; f.status = .notFound; return f
        case .ambiguous(let n):
            var f = r; f.status = .ambiguous; f.detail = "\(n) matches"; return f
        case .found(let node, let by):
            var f = r; f.matchedBy = by
            if isSecret(node) && !isPressAction(step.action) {
                f.status = .refused; f.detail = "a password / code field is his to type"; return f
            }
            return act(step.action, on: node, flats: flats, page: page, result: f)
        }
    }

    private func act(_ action: Action, on node: AXNode, flats: [Flat], page: Page, result: StepResult) -> StepResult {
        var r = result
        switch action {
        case .set(let v):
            return doSet(v, node: node, result: r, page: page)
        case .split(let v, let prefix):
            return doSplit(v, prefix: prefix, node: node, flats: flats, result: r)
        case .pick(let option, let type):
            return doPick(option: option, type: type, node: node, flats: flats, page: page, result: r)
        case .select(let option):
            return doSelect(option, node: node, page: page, result: r)
        case .check(let want):
            let cur = (node.num("AXValue") ?? 0) != 0
            if cur != want { if dryRun { r.detail = "dry" } else { node.press() } }
            r.verified = dryRun ? nil : poll(timing.text) { ((node.num("AXValue") ?? 0) != 0) == want }  // AXPress lands async
            r.via = "ax"
            if r.verified == false { r.status = .failed }
            return r
        case .press(let go):
            return doPress(go, node: node, page: page, result: r)
        }
    }

    private func doSet(_ v: Value, node: AXNode, result: StepResult, page: Page) -> StepResult {
        var r = result
        let text: String
        do { text = try resolve(v, store: store, files: files) }
        catch let e as ValueError { r.status = .refused; r.detail = e.reason; return r }
        catch { r.status = .refused; r.detail = "value unreadable"; return r }
        r.len = text.count
        if dryRun { r.detail = "dry"; r.via = "ax"; return r }
        if human, case .literal = v {
            switch page.typeUnderLease(text, into: node, human: true) {
            case .typed: r.via = "keys"
            case .focusLost: r.status = .refused; r.detail = "focus lost while typing"; return r
            case .notIdle: r.status = .refused; r.detail = "not idle 2 s"; return r
            }
        } else {
            node.setValue(text)
            r.via = "ax"
        }
        r.verified = poll(timing.text) { node.axValue == text }
        if r.verified == false { r.status = .failed; r.detail = "len \(node.axValue.count) of \(text.count)" }
        return r
    }

    // One value spread over adjacent boxes; AX hides maxlength, so write, read what stuck, carry the rest.
    private func doSplit(_ v: Value, prefix: String?, node: AXNode, flats: [Flat], result: StepResult) -> StepResult {
        var r = result
        var text: String
        do { text = try resolve(v, store: store, files: files) }
        catch let e as ValueError { r.status = .refused; r.detail = e.reason; return r }
        catch { r.status = .refused; r.detail = "value unreadable"; return r }
        text = text.replacingOccurrences(of: " ", with: "")
        if let p = prefix, text.hasPrefix(p) { text = String(text.dropFirst(p.count)) }
        r.len = text.count
        r.via = "ax"
        let boxes = adjacentFields(from: node, flats: flats)
        if dryRun { r.detail = "dry (\(boxes.count) boxes)"; return r }
        var remaining = Substring(text)
        var usedBoxes = 0
        for box in boxes {
            if remaining.isEmpty { break }
            box.setValue(String(remaining))
            _ = poll(timing.text) { !box.axValue.isEmpty }
            let stuck = box.axValue
            usedBoxes += 1
            guard !stuck.isEmpty, remaining.hasPrefix(stuck) else {
                r.status = .failed; r.detail = "box \(usedBoxes) kept something other than the next segment"; return r
            }
            remaining = remaining.dropFirst(stuck.count)
        }
        r.verified = remaining.isEmpty
        r.detail = "\(usedBoxes) boxes"
        if !remaining.isEmpty { r.status = .failed; r.detail = "\(remaining.count) chars did not fit in \(boxes.count) boxes" }
        return r
    }

    private func doPick(option: String, type: String?, node: AXNode, flats: [Flat], page: Page, result: StepResult) -> StepResult {
        var r = result
        r.via = "ax"
        if dryRun { r.detail = "dry"; return r }
        var baseline: Set<String>? = nil
        if let q = type, !q.isEmpty {
            // A page's own nav lists are AXLists too, and a typeahead menu is plain divs: what appears after the write is the answer.
            let before = Set(pageTexts(page).map { label(of: $0) })
            baseline = before
            node.setValue(String(q.dropLast()))
            let shown = { listOptions(node: node, page: page).contains { normalizeLabel(label(of: $0)) == normalizeLabel(option) } }
            if !poll(timing.text, { !freshTexts(page, before).isEmpty || shown() }) {
                switch page.typeUnderLease(String(q.suffix(1)), into: node, human: human) {
                case .typed: r.via = "keys"
                case .focusLost: r.status = .refused; r.detail = "focus lost while typing the query"; return r
                case .notIdle: r.status = .refused; r.detail = "not idle 2 s"; return r
                }
            }
        }
        var options: [AXNode] = []
        _ = poll(timing.listSelect) {
            options = (baseline.map { freshTexts(page, $0) } ?? []) + listOptions(node: node, page: page)
            return options.contains { normalizeLabel(label(of: $0)) == normalizeLabel(option) }
        }
        guard let hit = options.first(where: { normalizeLabel(label(of: $0)) == normalizeLabel(option) }) else {
            r.status = .failed
            r.detail = "no option equal to the pick; " + Report.options(options.map { label(of: $0) })
            return r
        }
        hit.press()
        r.verified = poll(timing.text) { !node.axValue.isEmpty }
        r.detail = "readback=pick"
        return r
    }

    private func doSelect(_ option: String, node: AXNode, page: Page, result: StepResult) -> StepResult {
        var r = result
        r.via = "keys"
        if dryRun { r.detail = "dry"; return r }
        // Native select: no options in AX; type-ahead under the lease, never Return.
        switch page.typeUnderLease(option, into: node, human: human) {
        case .typed: break
        case .focusLost: r.status = .refused; r.detail = "focus lost while selecting"; return r
        case .notIdle: r.status = .refused; r.detail = "not idle 2 s"; return r
        }
        r.verified = poll(timing.listSelect) { normalizeLabel(node.axValue) == normalizeLabel(option) }
        if r.verified == false { r.status = .failed; r.detail = "the option did not take" }
        return r
    }

    private func doPress(_ go: Bool, node: AXNode, page: Page, result: StepResult) -> StepResult {
        var r = result
        let title = fold(label(of: node))
        let allowed = navAllowlist.contains(title)
        let hasFinal = finals.map(fold).contains(title)
        if isSecret(node) { r.status = .refused; r.detail = "a captcha / code control is his"; return r }
        if !allowed && !hasFinal {
            let why = attestations.contains(where: { title.contains($0) }) ? "an attestation needs --final" : "a committing button needs --final '<label>'"
            r.status = .refused; r.detail = why; return r
        }
        if nav.recentCount(page.host) >= navCap { r.status = .refused; r.detail = "navigation cap \(navCap)/h reached for \(page.host)"; return r }
        if dryRun { r.detail = "dry (would press)"; return r }
        nav.record(page.host)
        node.press()
        r.detail = "pressed"  // the next call's scan waits for whatever page this leads to
        r.via = "ax"
        return r
    }

    // ---- resolution ----

    struct Flat { let node: AXNode; let preceding: String }

    private func flatten(_ web: AXNode) -> [Flat] {
        var out: [Flat] = []
        var lastText = ""
        func walk(_ n: AXNode, _ depth: Int) {
            if out.count > 12000 || depth > 80 { return }
            if n.role == "AXStaticText" {
                let v = normalizeLabel(n.axValue)
                if !v.isEmpty && v != "*" { lastText = v }
            }
            out.append(Flat(node: n, preceding: lastText))
            for c in n.kids() { walk(c, depth + 1) }
        }
        walk(web, 0)
        return out
    }

    enum Resolve { case found(AXNode, by: String); case notFound; case ambiguous(Int) }

    private func resolveNode(_ loc: Locator, _ flats: [Flat]) -> Resolve {
        let matches: [AXNode]
        let by: String
        if let id = loc.id {
            matches = flats.filter { $0.node.str("AXDOMIdentifier") == id }.map(\.node); by = "id"
        } else if let lbl = loc.label {
            let want = normalizeLabel(lbl)
            matches = flats.filter { controlRoles.contains($0.node.role) && normalizeLabel(controlTitle($0)) == want }.map(\.node); by = "label"
        } else if let ph = loc.placeholder {
            matches = flats.filter { $0.node.str("AXPlaceholderValue") == ph }.map(\.node); by = "placeholder"
        } else if let af = loc.after {
            let want = normalizeLabel(af)
            matches = flats.filter { controlRoles.contains($0.node.role) && $0.preceding == want }.map(\.node); by = "after"
        } else {
            return .notFound
        }
        if matches.isEmpty { return .notFound }
        if matches.count == 1 { return .found(matches[0], by: by) }
        if loc.nthExplicit && loc.nth <= matches.count { return .found(matches[loc.nth - 1], by: by) }
        return .ambiguous(matches.count)
    }

    private func adjacentFields(from node: AXNode, flats: [Flat]) -> [AXNode] {
        guard let start = flats.firstIndex(where: { $0.node.same(as: node) }) else { return [node] }
        var out: [AXNode] = []
        for f in flats[start...] {
            if textFieldRoles.contains(f.node.role) { out.append(f.node) } else if !out.isEmpty { break }
        }
        return out.isEmpty ? [node] : out
    }

    private func listOptions(node: AXNode, page: Page) -> [AXNode] {
        guard let web = page.webArea() else { return [] }
        var out: [AXNode] = []
        func walk(_ n: AXNode, _ depth: Int) {
            if depth > 80 { return }
            if n.role == "AXList" || n.role == "AXMenu" { collectLeaves(n, into: &out) }
            for c in n.kids() { walk(c, depth + 1) }
        }
        walk(web, 0)
        return out
    }

    private func pageTexts(_ page: Page) -> [AXNode] {
        guard let web = page.webArea() else { return [] }
        var out: [AXNode] = []
        collectLeaves(web, into: &out)
        return out
    }

    private func freshTexts(_ page: Page, _ before: Set<String>) -> [AXNode] {
        pageTexts(page).filter { let l = label(of: $0); return !l.isEmpty && !before.contains(l) }
    }

    private func collectLeaves(_ n: AXNode, into out: inout [AXNode], _ depth: Int = 0) {
        if depth > 40 { return }
        if n.role == "AXStaticText" || n.role == "AXMenuItem" || n.role == "AXCell" { out.append(n) }
        for c in n.kids() { collectLeaves(c, into: &out, depth + 1) }
    }

    // ---- challenge detection ----

    private func challenge(_ web: AXNode) -> Challenge? {
        var hostsHit: String?
        var texts: [String] = []
        func walk(_ n: AXNode, _ depth: Int) {
            if depth > 80 { return }
            if n.role == "AXWebArea", let urlStr = n.str("AXURL"), let h = URL(string: urlStr)?.host {
                for bad in ["captcha-delivery.com", "challenges.cloudflare.com", "recaptcha"] where h.contains(bad) { hostsHit = h }
            }
            if n.role == "AXStaticText" { texts.append(n.axValue) }
            for c in n.kids() { walk(c, depth + 1) }
        }
        walk(web, 0)
        if let h = hostsHit { return .challenge(h) }
        let blob = fold(texts.joined(separator: " "))
        for phrase in ["too many requests", "reference #", "requested url was rejected"] where blob.contains(phrase) {
            return .challenge(phrase)
        }
        if blob.contains("session expiree") || blob.contains("session expired") { return .expired }
        return nil
    }

    // ---- helpers ----

    private func poll(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let start = clock.now()
        repeat {
            if cond() { return true }
            clock.sleep(timing.poll)
        } while clock.now() - start < timeout
        return cond()
    }

    private func controlTitle(_ f: Flat) -> String {
        for a in ["AXTitle", "AXDescription"] {
            if let s = f.node.str(a)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        }
        if textFieldRoles.contains(f.node.role) { return f.preceding }
        return ""
    }

    private func label(of node: AXNode) -> String {
        for a in ["AXTitle", "AXDescription", "AXValue"] {
            if let s = node.str(a)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        }
        return ""
    }

    private func filled(_ node: AXNode) -> Bool {
        if textFieldRoles.contains(node.role) { return !node.axValue.isEmpty }
        if node.role == "AXCheckBox" || node.role == "AXRadioButton" { return (node.num("AXValue") ?? 0) != 0 }
        return false
    }

    private func isSecret(_ node: AXNode) -> Bool {
        if node.secure { return true }
        let words = fold(label(of: node)).split(separator: " ").map(String.init)
        let blob = words.joined(separator: " ")
        if blob.contains("password") || blob.contains("mot de passe") || blob.contains("cryptogramme") || blob.contains("captcha") { return true }
        if words.contains("pin") || words.contains("otp") { return true }
        if words.contains("code") {
            let security = ["securite", "verification", "confirmation", "sms", "otp", "activation", "usage", "unique", "secret"]
            if security.contains(where: { words.contains($0) }) { return true }
        }
        return false
    }

    private func isPressAction(_ a: Action) -> Bool { if case .press = a { return true }; return false }

    private func specShape(_ spec: Spec) -> String? {
        let presses = spec.steps.enumerated().filter { if case .press = $0.element.action { return true }; return false }
        if presses.count > 1 { return "at most one press per page" }
        if let p = presses.first, p.offset != spec.steps.count - 1 { return "a press must be the last step" }
        return nil
    }

    private func exitFor(_ s: Status) -> Int32 {
        switch s { case .refused: return 4; default: return 1 }
    }

    private func close(_ code: Int32, _ results: [StepResult], _ page: Page, note: String, from: Int, action: String) -> (Int32, [String]) {
        var rs = results
        if code == 5 { nav.lock(page.host) }  // a challenge stops this host for later calls too
        rs.append(StepResult(index: from, action: action, status: code == 5 ? .refused : .failed, locator: "-", detail: note))
        if !dryRun { page.restore() }
        return (code, render(rs, page))
    }

    private func render(_ results: [StepResult], _ page: Page) -> [String] {
        let ok = results.filter { $0.status == .ok }.count
        let failed = results.filter { $0.status != .ok && $0.status != .skip }.count
        var out = ["firefax fill \(page.host)\(safePath(page.path)): \(results.count) steps, \(ok) ok, \(failed) failed, mode \(human ? "human" : "fast")\(dryRun ? " (dry-run)" : "")"]
        out += results.map(Report.line)
        if !dryRun { out.append("restored: front app, pointer") }
        return out
    }

    private func splitPage(_ page: String) -> (String, String) {
        guard let slash = page.firstIndex(of: "/") else { return (page, "") }
        return (String(page[..<slash]), String(page[slash...]))
    }

    private func safePath(_ p: String) -> String {
        "/" + p.split(separator: "/").map { $0.count < 20 ? String($0) : "<\($0.count)>" }.joined(separator: "/")
    }

    private func ms(_ s: Double) -> String { "\(Int((s * 1000).rounded())) ms" }
    private func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }
}
