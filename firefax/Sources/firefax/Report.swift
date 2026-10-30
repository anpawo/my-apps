import Foundation

// The report the caller trusts: one line per step, never a field value. A failed pick is the one
// place option labels are printed, and they go through a word allowlist: plain words and 5-digit
// postal codes stay, any other digit token becomes its length (a house number, an id leaked in a
// suggestion).

enum Status: String {
    case ok, failed, skip, ambiguous, refused
    case notFound = "not-found"
}

struct StepResult {
    let index: Int
    let action: String
    var status: Status
    var locator: String
    var matchedBy: String? = nil
    var len: Int? = nil
    var verified: Bool? = nil
    var via: String? = nil
    var detail: String? = nil
}

enum Report {
    static func line(_ r: StepResult) -> String {
        var parts = ["\(r.index)", pad(r.status.rawValue, 9), pad(r.action, 6), r.locator]
        if let by = r.matchedBy { parts.append("by \(by)") }
        if let len = r.len { parts.append("len \(len)") }
        if let v = r.verified { parts.append(v ? "verified" : "unverified") }
        if let via = r.via { parts.append("via \(via)") }
        if let d = r.detail { parts.append(d) }
        return parts.joined(separator: "  ")
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    // Up to five option labels, each cleaned through the allowlist.
    static func options(_ labels: [String]) -> String {
        let shown = labels.prefix(5).map { "\"\(allowlist($0))\"" }
        let more = labels.count > 5 ? " (+\(labels.count - 5) more)" : ""
        return "\(labels.count) shown: " + shown.joined(separator: ", ") + more
    }

    static func allowlist(_ label: String) -> String {
        joinDigitGroups(label).split(separator: " ").map { token -> String in
            let t = String(token)
            if t.allSatisfy(\.isNumber) { return t.count == 5 ? t : "<\(t.count)>" }  // 5-digit postal code kept
            if t.contains(where: \.isNumber) { return "<\(t.count)>" }  // a word carrying digits is a length
            return t
        }.joined(separator: " ")
    }

    // "NNN NNN NNN" is one number, not three short ones.
    static func joinDigitGroups(_ s: String) -> String {
        var out = "", prevDigit = false
        for token in s.split(separator: " ", omittingEmptySubsequences: true) {
            let digit = token.allSatisfy(\.isNumber)
            if !out.isEmpty && !(digit && prevDigit) { out += " " }
            out += token
            prevDigit = digit
        }
        return out
    }
}
