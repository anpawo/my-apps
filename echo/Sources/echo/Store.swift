import Foundation

/// The state the checker (`~/.claude/skills/checker`) keeps on disk. The app and the MCP server both read it here;
/// nothing talks to a running app.
enum Store {
    static let state = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/state/checker")
    static var inbox: URL { state.appending(path: "inbox") }
    static let pastShown = 20

    /// Today's line by its hour alone, written the French way (10h40); an older one with its day (13/10 10h40).
    static func when(_ ms: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH'h'mm" : "dd/MM HH'h'mm"
        return f.string(from: date)
    }

    static func lines(in folder: URL) -> [InboxItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(InboxItem.self, from: Data(contentsOf: $0)) }
            .sorted { $0.at < $1.at }
    }

    /// Sets a line aside as done (`done/`, still on disk). False when no such line waits.
    @discardableResult
    static func take(_ id: String, in folder: URL = inbox) -> Bool {
        let from = folder.appending(path: "\(id).json")
        guard FileManager.default.fileExists(atPath: from.path) else { return false }
        let done = folder.appending(path: "done")
        try? FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: done.appending(path: "\(id).json"))
        return (try? FileManager.default.moveItem(at: from, to: done.appending(path: "\(id).json"))) != nil
    }
}

/// One line the watcher of awaited answers left for Marius: a headless follow-up that finished something (`done`)
/// or stopped on something of his (`needs`), and the session it ended in.
struct InboxItem: Codable, Equatable {
    let id: String
    let at: Double
    let kind: String
    let subject: String
    let line: String
    let dir: String
    /// What `claude` takes to come back to it: `--resume <id>`, or the run's own options when it broke.
    let options: [String]
    /// Only for a run that broke: its task, handed to the session again.
    let prompt: String?

    var session: String? {
        options.firstIndex(of: "--resume").flatMap { options.indices.contains($0 + 1) ? options[$0 + 1] : nil }
    }
}

/// One thing the hourly checker watches or watched: still waiting (`<id>.json`), arrived (`fired/`), or dropped
/// (`fired/` with a `dropped` stamp: nothing watches it any more).
struct CheckEntry: Equatable {
    enum State: String { case waiting, dropped, arrived }

    let id: String
    let name: String
    let watching: String
    let state: State
    /// ms: when it began waiting, arrived or was dropped.
    let at: Double

    var short: String {
        switch state {
        case .waiting: return "since \(Store.when(at))"
        case .arrived: return "arrived \(Store.when(at))"
        case .dropped: return "dropped \(Store.when(at))"
        }
    }

    var detail: String {
        switch state {
        case .waiting: return "waiting since \(Store.when(at))"
        case .arrived: return "arrived \(Store.when(at))"
        case .dropped: return "dropped \(Store.when(at)) — nothing watches it"
        }
    }

    /// Waiting first, then dropped, then arrived, each newest first: a dropped watch must not hide behind old arrivals.
    static func load(state: URL = Store.state) -> (entries: [CheckEntry], last: String) {
        func read(_ folder: URL) -> [[String: Any]] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }
                .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        }
        func entry(_ json: [String: Any]) -> CheckEntry? {
            guard let id = json["id"] as? String else { return nil }
            let what = json["what"] as? String ?? ""
            let name = json["name"] as? String ?? String(what.prefix(40))
            let watching = (json["chat"] as? String).map { "WhatsApp “\($0)”" }
                ?? (json["cmd"] != nil ? "command" : "Gmail")
            func stamp(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
            let fired = (json["fired"] as? [String: Any]).flatMap { stamp($0["at"]) }
            let (state, at): (State, Double?) = stamp(json["dropped"]).map { (.dropped, $0) }
                ?? fired.map { (.arrived, $0) } ?? (.waiting, stamp(json["since"]))
            return CheckEntry(id: id, name: name, watching: watching, state: state, at: at ?? 0)
        }
        let all = (read(state) + read(state.appending(path: "fired"))).compactMap(entry)
        let order: [State] = [.waiting, .dropped, .arrived]
        let entries = all.sorted {
            let (x, y) = (order.firstIndex(of: $0.state)!, order.firstIndex(of: $1.state)!)
            return x != y ? x < y : $0.at > $1.at
        }
        return (entries, lastRun(in: state.appending(path: "check.log")))
    }

    /// The newest summary line of the log, "2026-10-19 23:10:02  8 awaited, 0 arrived, 0 errors, 35 s", as "23h10 · 8 awaited, …".
    static func lastRun(in log: URL) -> String {
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
        guard let line = lines.last(where: { $0.contains(" awaited, ") }), line.count > 21 else { return "no check recorded" }
        let parsed = DateFormatter()
        parsed.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let at = parsed.date(from: String(line.prefix(19))).map { Store.when($0.timeIntervalSince1970 * 1000) } ?? String(line.prefix(19))
        let counts = line.dropFirst(21).split(separator: ",").dropLast().joined(separator: ",")
        return "\(at) · \(counts)"
    }
}
