import Foundation

/// What a window's agent is waiting on, drawn in the status bar like an update. The agent writes one line to
/// $VCX_PROGRESS_FILE: "<label>\t<file being written>\t<final bytes>" (a download, any output of known size) or
/// "<label>\t<start epoch seconds>\t<expected seconds>" (a run of known length), and deletes it when the work ends.
struct TaskProgress: Equatable {
    enum Source: Equatable { case file(path: String, total: Double), timer(start: Date, seconds: Double) }
    var label: String
    var source: Source
    var fraction = 0.0
    var detail = ""

    // A line left by a session that died is dropped after a day; a timer twice past its length is over.
    static let staleAfter: TimeInterval = 86400
    static let rateWindow: TimeInterval = 30

    static func parse(_ text: String) -> TaskProgress? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        guard parts.count == 3, !parts[0].isEmpty, let last = Double(parts[2]), last > 0 else { return nil }
        if parts[1].hasPrefix("/") { return TaskProgress(label: parts[0], source: .file(path: parts[1], total: last)) }
        guard let start = Double(parts[1]) else { return nil }
        return TaskProgress(label: parts[0], source: .timer(start: Date(timeIntervalSince1970: start), seconds: last))
    }

    /// Fills fraction and detail; `samples` keeps (time, bytes) of the last half minute for the rate.
    mutating func measure(now: Date, size: Double?, samples: inout [(Date, Double)]) -> Bool {
        switch source {
        case .timer(let start, let seconds):
            let elapsed = now.timeIntervalSince(start)
            guard elapsed < seconds * 2 else { return false }
            fraction = min(1, max(0, elapsed / seconds))
            detail = Self.remaining(seconds - elapsed)
        case .file(_, let total):
            let done = size ?? 0
            samples.append((now, done)); samples.removeAll { now.timeIntervalSince($0.0) > Self.rateWindow }
            fraction = min(1, done / total)
            var words = [Self.percent(fraction), Self.bytes(done) + " of " + Self.bytes(total)]
            if let first = samples.first, now.timeIntervalSince(first.0) >= 4, done > first.1 {
                let rate = (done - first.1) / now.timeIntervalSince(first.0)
                words += [Self.bytes(rate) + "/s", Self.remaining((total - done) / rate)]
            }
            detail = done >= total ? "done" : words.joined(separator: " · ")
        }
        return true
    }

    static func percent(_ value: Double) -> String { String(Int(value * 100)) + "%" }
    static func bytes(_ value: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
    static func remaining(_ seconds: Double) -> String {
        guard seconds > 0 else { return "any moment" }
        return seconds < 60 ? "\(Int(seconds)) s left" : seconds < 3600 ? "\(Int(seconds / 60)) min left" : String(format: "%.1f h left", seconds / 3600)
    }
}
