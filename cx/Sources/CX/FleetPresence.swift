import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class FleetPresence {
    private static var records: [URL: [String: JSON]] = [:]
    private static var pendingWrites: [URL: Task<Void, Never>] = [:]
    private let file: URL
    private let identity: String
    private var closed = false
    private var changes: AnyCancellable?
    private let startedAt: UInt64

    init(session: Session) {
        file = session.stateDirectory.appendingPathComponent("fleet/\(getpid()).json")
        identity = session.runtimeClient?.sessionID ?? UUID().uuidString
        var info = proc_bsdinfo()
        proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        startedAt = info.pbi_start_tvsec
        publish(session)
        changes = session.objectWillChange
            .receive(on: RunLoop.main)
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self, weak session] in
                guard let session else { return }
                self?.publish(session, coalesced: true)
            }
    }

    func publish(_ session: Session, coalesced: Bool = false) {
        guard !closed else { return }
        let user = session.rows.last { $0.kind == "user" }
        let lastPromptAt = user?.items.last?.data["sentAt"] as? Double
        let prompt = user?.items.flatMap { ($0.data["content"] as? [JSON] ?? []).compactMap { $0["text"] as? String } }.joined(separator: "\n")
        let preview: [JSON] = session.rows.suffix(16).flatMap { row in
            row.items.suffix(4).compactMap { item in
                let text = row.kind == "user" ? (item.data["content"] as? [JSON] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    : row.kind == "activity" ? item.title : item.text
                guard !text.isEmpty else { return nil }
                return ["kind": row.kind == "user" ? "user" : row.kind == "activity" ? "tool" : "assistant", "text": String(text.prefix(2000))]
            }
        }
        let state = !session.permissions.isEmpty ? "waiting" : session.busy || session.changing ? "working" : user == nil ? "fresh" : "ready"
        var record: JSON = ["pid": getpid(), "startedAt": startedAt, "cwd": session.cwd,
                            "state": state, "preview": preview, "updatedAt": Date().timeIntervalSince1970]
        record["prompt"] = prompt.map { String($0.prefix(2000)) }
        record["lastPromptAt"] = lastPromptAt
        if !session.fleetContext.isEmpty { record["context"] = session.fleetContext }
        record["sessionId"] = identity
        if let window = (NSApp?.delegate as? AppDelegate)?.windows.first(where: { $0.session === session })?.window {
            record["windowId"] = window.windowNumber
        }
        Self.records[file, default: [:]][identity] = record
        if !coalesced {
            Self.pendingWrites.removeValue(forKey: file)?.cancel()
            Self.write(file)
            return
        }
        guard Self.pendingWrites[file] == nil else { return }
        let destination = file
        Self.pendingWrites[destination] = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            Self.pendingWrites[destination] = nil
            Self.write(destination)
        }
    }

    static func refreshFocus() {
        for file in records.keys { write(file) }
    }

    private static func write(_ file: URL) {
        guard let values = records[file], !values.isEmpty else { try? FileManager.default.removeItem(at: file); return }
        let focused = (NSApp?.delegate as? AppDelegate)?.session?.runtimeClient?.sessionID
        let entries = values.keys.sorted().compactMap { values[$0] }
        var record = focused.flatMap { values[$0] } ?? entries.first { $0["state"] as? String == "waiting" }
            ?? entries.first { $0["state"] as? String == "working" } ?? entries[0]
        record["sessions"] = entries
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("Fleet presence could not be written: %@", error.localizedDescription) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        changes?.cancel()
        Self.records[file]?[identity] = nil
        if Self.records[file]?.isEmpty == true { Self.records[file] = nil }
        Self.pendingWrites.removeValue(forKey: file)?.cancel()
        Self.write(file)
    }
}
