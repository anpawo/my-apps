import Foundation
import Darwin

// Every prompt, agent launch, provider event (commands and their output included) and notice goes to trace.jsonl in the
// state folder, one JSON line each, to trace what led to a bug. Streaming deltas are left out: they repeat the item that completes.
enum Trace {
    static let rotateAt = 100_000_000
    static let longestString = 600

    static func write(_ directory: URL, _ type: String, _ data: JSON) {
        let url = directory.appendingPathComponent("trace.jsonl")
        var entry = clip(data) as? JSON ?? [:]
        entry["time"] = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        entry["type"] = type; entry["pid"] = getpid()
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) > rotateAt {
            _ = rename(url.path, url.path + ".1")
        }
        // O_APPEND keeps lines whole when the frontend and runtime workers write at once.
        let file = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard file >= 0 else { return }
        _ = line.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
        close(file)
    }

    static func clip(_ value: Any) -> Any {
        switch value {
        case let text as String: return text.count > longestString ? String(text.prefix(longestString / 2)) + " … " + String(text.suffix(longestString / 2)) : text
        case let object as JSON: return object.mapValues(clip)
        case let list as [Any]: return list.map(clip)
        case is NSNumber, is NSNull: return value
        default: return String(describing: value)
        }
    }
}
