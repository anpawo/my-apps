import Foundation

// The fill spec: a page scope and ordered steps, decoded from JSON by hand so that any unknown
// key is an error (Codable would silently ignore it, and an ignored "lable" is a skipped field).

enum Value {
    case literal(String)
    case ref(String)
    case file(String)
}

struct Locator {
    var id: String?
    var label: String?
    var placeholder: String?
    var after: String?
    var nth: Int = 1
    var nthExplicit = false
    var isEmpty: Bool { id == nil && label == nil && placeholder == nil && after == nil }
    var described: String {
        for (k, v) in [("id", id), ("label", label), ("placeholder", placeholder), ("after", after)] where v != nil {
            return nth > 1 ? "\(k)=\"\(v!)\" #\(nth)" : "\(k)=\"\(v!)\""
        }
        return "?"
    }
}

enum Action {
    case set(Value)
    case split(Value, prefix: String?)
    case pick(option: String, type: String?)
    case select(String)
    case check(Bool)
    case press(Bool)
    var name: String {
        switch self {
        case .set: return "set"; case .split: return "split"; case .pick: return "pick"
        case .select: return "select"; case .check: return "check"; case .press: return "press"
        }
    }
}

struct Step {
    let locator: Locator
    let action: Action
}

struct Spec {
    let page: String
    let steps: [Step]
}

struct SpecError: Error { let message: String }  // the key path only, never a value

private let locatorKeys: Set<String> = ["id", "label", "placeholder", "after", "nth"]
private let actionKeys: Set<String> = ["set", "split", "pick", "select", "check", "press"]
private let modifierKeys: Set<String> = ["type", "prefix"]

enum SpecParser {
    static func parse(_ data: Data) throws -> Spec {
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data) }
        catch { throw SpecError(message: "not JSON") }
        guard let obj = any as? [String: Any] else { throw SpecError(message: "top level is not an object") }
        for key in obj.keys where key != "page" && key != "steps" {
            throw SpecError(message: "unknown key '\(key)' at spec root")
        }
        guard let page = obj["page"] as? String else { throw SpecError(message: "'page' missing or not a string") }
        guard let rawSteps = obj["steps"] as? [Any] else { throw SpecError(message: "'steps' missing or not an array") }
        let steps = try rawSteps.enumerated().map { try step($1, at: $0) }
        return Spec(page: page, steps: steps)
    }

    private static func step(_ any: Any, at i: Int) throws -> Step {
        guard let obj = any as? [String: Any] else { throw SpecError(message: "step \(i) is not an object") }
        for key in obj.keys where !(locatorKeys.contains(key) || actionKeys.contains(key) || modifierKeys.contains(key)) {
            throw SpecError(message: "unknown key '\(key)' in step \(i)")
        }
        var loc = Locator()
        loc.id = try string(obj["id"], "id", i)
        loc.label = try string(obj["label"], "label", i)
        loc.placeholder = try string(obj["placeholder"], "placeholder", i)
        loc.after = try string(obj["after"], "after", i)
        if let n = obj["nth"] {
            guard let n = n as? Int, n >= 1 else { throw SpecError(message: "'nth' in step \(i) is not a positive integer") }
            loc.nth = n
            loc.nthExplicit = true
        }
        if loc.isEmpty { throw SpecError(message: "step \(i) has no locator (id/label/placeholder/after)") }

        let present = obj.keys.filter { actionKeys.contains($0) }
        guard present.count == 1 else {
            throw SpecError(message: "step \(i) must have exactly one action, has \(present.sorted())")
        }
        let action = try buildAction(present[0], obj, i)
        return Step(locator: loc, action: action)
    }

    private static func buildAction(_ key: String, _ obj: [String: Any], _ i: Int) throws -> Action {
        switch key {
        case "set":
            try reject(obj, i, allow: [])
            return .set(try value(obj["set"], "set", i))
        case "split":
            try reject(obj, i, allow: ["prefix"])
            return .split(try value(obj["split"], "split", i), prefix: try string(obj["prefix"], "prefix", i))
        case "pick":
            try reject(obj, i, allow: ["type"])
            return .pick(option: try literalString(obj["pick"], "pick", i), type: try string(obj["type"], "type", i))
        case "select":
            try reject(obj, i, allow: [])
            return .select(try literalString(obj["select"], "select", i))
        case "check":
            try reject(obj, i, allow: [])
            guard let b = obj["check"] as? Bool else { throw SpecError(message: "'check' in step \(i) is not a boolean") }
            return .check(b)
        case "press":
            try reject(obj, i, allow: [])
            guard let b = obj["press"] as? Bool else { throw SpecError(message: "'press' in step \(i) is not a boolean") }
            return .press(b)
        default:
            throw SpecError(message: "unreachable action \(key)")
        }
    }

    // A modifier (type/prefix) is legal only with the action that allows it.
    private static func reject(_ obj: [String: Any], _ i: Int, allow: Set<String>) throws {
        for k in obj.keys where modifierKeys.contains(k) && !allow.contains(k) {
            throw SpecError(message: "'\(k)' in step \(i) is not valid for this action")
        }
    }

    private static func string(_ any: Any?, _ key: String, _ i: Int) throws -> String? {
        guard let any else { return nil }
        guard let s = any as? String else { throw SpecError(message: "'\(key)' in step \(i) is not a string") }
        return s
    }

    private static func literalString(_ any: Any?, _ key: String, _ i: Int) throws -> String {
        guard let s = any as? String else { throw SpecError(message: "'\(key)' in step \(i) must be a string") }
        return s
    }

    private static func value(_ any: Any?, _ key: String, _ i: Int) throws -> Value {
        if let s = any as? String { return .literal(s) }
        if let o = any as? [String: Any] {
            guard o.count == 1, let (k, v) = o.first, let name = v as? String, k == "ref" || k == "file" else {
                throw SpecError(message: "'\(key)' in step \(i) object must be a single {\"ref\"|\"file\": string}")
            }
            return k == "ref" ? .ref(name) : .file(name)
        }
        throw SpecError(message: "'\(key)' in step \(i) is neither a string nor a ref/file object")
    }
}

// Normalized exact match: trimmed, a trailing '*' or ':' dropped (labels carry a required marker).
func normalizeLabel(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = t.last, last == "*" || last == ":" {
        t = String(t.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return t
}
