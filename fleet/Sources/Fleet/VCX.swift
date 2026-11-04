import AppKit
import Darwin
import NaturalLanguage

@MainActor
enum VCX {
    static let root = NSHomeDirectory() + "/.local/state/cx"

    static func sessions() -> [Session] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mr.vcx")
        let found = apps.flatMap { app -> [Session] in
            guard app.activationPolicy != .prohibited else { return [] }
            let pid = app.processIdentifier
            guard let bsd = ProcessScanner.bsdInfo(pid) else { return [] }
            let file = root + "/fleet/\(pid).json"
            if let record = object(file) {
                let found = sessions(record, pid: pid, startedAt: bsd.pbi_start_tvsec, path: file)
                if !found.isEmpty { return found }
            }
            // shortcut: pre-bridge windows infer state from saved history; reopen them for live approvals.
            guard let path = legacyPath(pid),
                  var record = object(path) else { return [] }
            record["pid"] = pid
            record["startedAt"] = bsd.pbi_start_tvsec
            record["context"] = record["fleetContext"]
            let rows = record["rows"] as? [[String: Any]] ?? []
            record["prompt"] = (rows.last { $0["kind"] as? String == "user" }?["items"] as? [[String: Any]])?
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            record["state"] = rows.last?["kind"] as? String == "user" ? "working" : "ready"
            record["updatedAt"] = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970
            record["preview"] = rows.suffix(16).flatMap { row in
                (row["items"] as? [[String: Any]] ?? []).suffix(4).map { item -> [String: Any] in
                    let kind = row["kind"] as? String ?? "assistant"
                    let text = kind == "user" ? (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                        : kind == "activity" ? item["command"] as? String ?? item["type"] as? String ?? "Tool" : item["text"] as? String ?? ""
                    return ["kind": kind == "activity" ? "tool" : kind, "text": String(text.prefix(2000))]
                }
            }
            return session(record, pid: pid, startedAt: bsd.pbi_start_tvsec, path: path).map { [$0] } ?? []
        }
        var unique: [String: Session] = [:]
        for session in found {
            if let previous = unique[session.id], previous.proc.startedAt > session.proc.startedAt ||
                (previous.proc.startedAt == session.proc.startedAt && previous.proc.pid > session.proc.pid) { continue }
            unique[session.id] = session
        }
        return Array(unique.values)
    }

    static func sessions(_ record: [String: Any], pid: pid_t, startedAt: UInt64, path: String) -> [Session] {
        if let records = record["sessions"] as? [[String: Any]] {
            var seen = Set<String>()
            return records.compactMap { value in
                guard let session = session(value, pid: pid, startedAt: startedAt, path: path),
                      session.runtimeSessionID != nil, seen.insert(session.id).inserted else { return nil }
                return session
            }
        }
        return session(record, pid: pid, startedAt: startedAt, path: path).map { [$0] } ?? []
    }

    static func session(_ record: [String: Any], pid: pid_t, startedAt: UInt64, path: String) -> Session? {
        guard record["pid"] as? pid_t == pid,
              record["startedAt"] as? UInt64 == startedAt,
              let cwd = record["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
        let runtimeID = record["sessionId"] as? String
        if let runtimeID, UUID(uuidString: runtimeID) == nil { return nil }
        let preview = (record["preview"] as? [[String: Any]] ?? []).compactMap { line -> PreviewLine? in
            guard let text = line["text"] as? String, !text.isEmpty else { return nil }
            let kind: PreviewLine.Kind
            switch line["kind"] as? String {
            case "user": kind = .user
            case "assistant": kind = .assistant
            case "tool": kind = .tool
            default: return nil
            }
            return PreviewLine(kind: kind, text: text)
        }
        let prompt = record["prompt"] as? String ?? preview.last { $0.kind == .user }?.text
        let state: SessionState
        switch record["state"] as? String {
        case "working": state = .running
        case "waiting": state = .awaitingAnswer
        case "failed": state = .apiError
        case "fresh": state = .fresh
        case "pending": state = .delegated
        case "ready": state = prompt == nil ? .fresh : .ready
        default: return nil
        }
        let started = Date(timeIntervalSince1970: TimeInterval(startedAt))
        let activity = (record["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? started
        let context = (record["context"] as? String).map { String($0.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ").prefix(48)) }
        let info = TranscriptInfo(path: path, title: shortTitle(prompt ?? record["title"] as? String ?? "New session"),
                                  lastPrompt: prompt,
                                  lastPromptAt: (record["lastPromptAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
                                  hasPendingTool: false, pendingToolNames: [], pendingToolLabels: [], pendingTaskIDs: [],
                                  cwd: cwd, turnOpen: state == .running, lastActivity: activity, preview: preview)
        return Session(proc: ClaudeProcess(pid: pid, ppid: 1, cwd: cwd, tty: "", startedAt: started,
                                          cpuNanos: 0, vcx: true),
                       runtimeSessionID: runtimeID, runtimeWindowID: (record["windowId"] as? NSNumber)?.uint32Value,
                       transcript: info, state: state, cpuPercent: 0, context: context.flatMap { $0.isEmpty ? nil : $0 } ?? (runtimeID == nil ? nil : info.title))
    }

    static func shortTitle(_ text: String) -> String {
        let text = String(text.prefix(2000))
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var words: [String] = []
        let ignored: Set<String> = ["context", "conversation", "user", "assistant", "thing"]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = text[range].lowercased()
            if tag == .noun,
               !ignored.contains(word), !words.contains(word), (words + [word]).joined(separator: " ").count <= 24 {
                words.append(word)
            }
            return words.count < 3
        }
        return words.isEmpty ? "VCX session" : words.joined(separator: " ")
    }

    private static func object(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func legacyPath(_ pid: pid_t) -> String? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard read > 0 else { return nil }
        for fd in fds.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                 Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
            let path = withUnsafePointer(to: info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard path.hasPrefix(root + "/locks/"), path.hasSuffix(".lock") else { continue }
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension + ".json"
            for dir in (try? FileManager.default.contentsOfDirectory(atPath: root + "/native")) ?? [] {
                let snapshot = root + "/native/" + dir + "/" + name
                if FileManager.default.fileExists(atPath: snapshot) {
                    return snapshot
                }
            }
        }
        return nil
    }
}
