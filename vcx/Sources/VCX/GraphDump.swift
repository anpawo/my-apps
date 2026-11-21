import AppKit
import SwiftUI
import os

// SwiftUI's view graph, read from a background thread while the main thread is stuck in it: AttributeGraph's own
// profiler counts each attribute's updates and its JSON archive names them, so a freeze names the views it relays out.
// Racy by design (the graph is read while the main thread mutates it): run only on a frozen frontend or on demand.
enum GraphDump {
    private typealias Archive = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias Graph = @convention(c) (OpaquePointer?) -> Void
    private static let library = dlopen("/System/Library/PrivateFrameworks/AttributeGraph.framework/AttributeGraph", RTLD_NOW)
    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? { dlsym(library, name).map { unsafeBitCast($0, to: type) } }
    private static let busy = NSLock()
    nonisolated(unsafe) private static var signals: DispatchSourceSignal?

    /// `kill -USR1 <frontend pid>` dumps the graph of a live frontend into the freezes folder, stuck or not.
    static func listen(folder: @escaping @Sendable () -> URL) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
        source.setEventHandler { capture(folder: folder(), stamp: stamp() + "-usr1") }
        source.resume(); signals = source
    }

    static func stamp() -> String {
        let clock = ISO8601DateFormatter(); clock.timeZone = .current
        return clock.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    /// Profiles every graph for `seconds`, archives it once and writes `<stamp>.graph.txt`: the most updated attributes,
    /// their types and the views they belong to. Returns the summary's URL. One archive, not one at each end: each takes
    /// 3 to 4 s of a spinning frontend's graph, and mac-guard restarts that frontend after 10 s.
    @discardableResult
    static func capture(folder: URL, stamp: String, seconds: TimeInterval = 1.5) -> URL? {
        guard busy.try() else { return nil }
        defer { busy.unlock() }
        guard let archive = symbol("AGGraphArchiveJSON", Archive.self), let start = symbol("AGGraphStartProfiling", Graph.self),
              let stop = symbol("AGGraphStopProfiling", Graph.self), let reset = symbol("AGGraphResetProfile", Graph.self) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reset(nil); start(nil)
        Thread.sleep(forTimeInterval: seconds)
        let name = "vcx-graph-\(getpid())-\(stamp)", target = folder.appendingPathComponent("\(stamp).graph.json")
        archive(name)
        stop(nil)
        let written = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        guard (try? FileManager.default.moveItem(at: written, to: target)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let report = folder.appendingPathComponent("\(stamp).graph.txt")
        try? summary(target, seconds: seconds).write(to: report, atomically: true, encoding: .utf8)
        return report
    }

    static func summary(_ url: URL, seconds: TimeInterval) -> String {
        guard let data = try? Data(contentsOf: url), let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return "" }
        var lines = ["AttributeGraph profiled from \(seconds) s before its archive to its end (counts are updates in that window)."]
        for graph in root["graphs"] as? [JSON] ?? [] {
            let id = graph["id"] as? Int ?? -1
            let nodes = graph["nodes"] as? [JSON] ?? []
            let profiled = nodes.compactMap { node -> (Int, JSON)? in
                guard let count = (node["profile"] as? JSON)?["update_count"] as? Int, count > 0 else { return nil }
                return (count, node)
            }
            guard !profiled.isEmpty else { continue }
            lines.append("")
            lines.append("graph \(id): \(profiled.reduce(0) { $0 + $1.0 }) updates, \(nodes.count) nodes")
            // A node's view: the VCX types named in its subgraph's attribute types, most frequent first.
            var owner: [Int: String] = [:], known: [String: Bool] = [:]
            func ours(_ word: String) -> Bool {
                if let cached = known[word] { return cached }
                let found = _typeByName("3VCX\(word.count)\(word)V").map { $0 is any View.Type } ?? false; known[word] = found; return found
            }
            for subgraph in graph["subgraphs"] as? [JSON] ?? [] {
                let members = (subgraph["nodes"] as? [Int] ?? []).filter { $0 < nodes.count }
                var counts: [String: Int] = [:]
                for member in members {
                    let desc = nodes[member]["desc"] as? String ?? ""
                    for word in desc.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) where word.first?.isUppercase == true && ours(String(word)) { counts[String(word), default: 0] += 1 }
                }
                let name = counts.sorted { $0.value > $1.value }.prefix(2).map(\.key).joined(separator: "/")
                for member in members { owner[member] = name.isEmpty ? "-" : name }
            }
            let position = Dictionary(nodes.enumerated().compactMap { index, node in (node["id"] as? Int).map { ($0, index) } }, uniquingKeysWith: { a, _ in a })
            lines.append("most updated attributes (count, type, view):")
            for (count, node) in profiled.sorted(by: { $0.0 > $1.0 }).prefix(40) {
                let view = (node["id"] as? Int).flatMap { position[$0] }.flatMap { owner[$0] } ?? "?"
                lines.append("\(count)\t\((node["desc"] as? String ?? "?").prefix(160))\t\(view)")
            }
            var byType: [String: Int] = [:]
            for (count, node) in profiled { byType[node["desc"] as? String ?? "?", default: 0] += count }
            lines.append("most updated types:")
            for (name, count) in byType.sorted(by: { $0.value > $1.value }).prefix(25) { lines.append("\(count)\t\(name)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // GraphDump must name the views a busy main thread keeps relaying out, read from another thread mid-layout.
    @MainActor static func check(output: String) -> Int32 {
        let session = Session(cwd: output, stateDirectory: URL(fileURLWithPath: output + "/state-probe"))
        session.ready = true; session.status = "Ready"
        for index in 0..<12 {
            session.show(["id": "question-\(index)", "type": "userMessage", "content": [["type": "text", "text": "Question \(index)"]]])
            session.show(["id": "answer-\(index)", "type": "agentMessage", "text": (1...12).map { "Line \($0) of answer \(index)." }.joined(separator: "\n\n")])
        }
        session.revision += 1
        let host = NSHostingView(rootView: CXView(session: session))
        host.sizingOptions = []; host.frame = CGRect(x: 0, y: 0, width: 1176, height: 803)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5)); host.layoutSubtreeIfNeeded()
        let result = OSAllocatedUnfairLock<URL??>(initialState: nil)
        Thread.detachNewThread {
            let report = capture(folder: URL(fileURLWithPath: output), stamp: "check", seconds: 1.5)
            result.withLock { $0 = .some(report) }
        }
        var height = 803.0
        while result.withLock({ $0 }) == nil {
            height = height == 803 ? 775 : 803
            host.setFrameSize(CGSize(width: 1176, height: height)); host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        window.close(); session.close()
        guard let report = result.withLock({ $0 }) ?? nil, let text = try? String(contentsOf: report, encoding: .utf8) else { print("FAIL: no graph summary"); return 1 }
        let updates = text.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("graph "), let part = line.split(separator: ":").dropFirst().first else { return nil }
            return Int(part.split(separator: " ").first ?? "")
        }.max() ?? 0
        let named = text.contains("CXView") || text.contains("ConversationRow") || text.contains("UserBubble")
        print("\(updates > 10 && named ? "PASS" : "FAIL"): graph summary at \(report.path), \(updates) updates, VCX views named: \(named)")
        return updates > 10 && named ? 0 : 1
    }
}
