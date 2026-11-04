import Combine
import Darwin
import Foundation

@MainActor
final class FleetPresence {
    private let file: URL
    private var changes: AnyCancellable?
    private let startedAt: UInt64

    init(session: Session) {
        file = session.stateDirectory.appendingPathComponent("fleet/\(getpid()).json")
        var info = proc_bsdinfo()
        proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        startedAt = info.pbi_start_tvsec
        publish(session)
        changes = session.objectWillChange
            .receive(on: RunLoop.main)
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self, weak session] in
                guard let session else { return }
                self?.publish(session)
            }
    }

    func publish(_ session: Session) {
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
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("VCX: could not publish Fleet state: %@", error.localizedDescription) }
    }

    func close() {
        changes?.cancel()
        try? FileManager.default.removeItem(at: file)
    }
}
