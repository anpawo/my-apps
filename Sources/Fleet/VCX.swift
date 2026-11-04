import AppKit
import Darwin

@MainActor
enum VCX {
    static let root = NSHomeDirectory() + "/.local/state/cx"

    static func sessions() -> [Session] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mr.vcx")
        return apps.compactMap { app in
            let pid = app.processIdentifier
            guard let bsd = ProcessScanner.bsdInfo(pid) else { return nil }
            let file = root + "/fleet/\(pid).json"
            if let record = object(file),
               let session = session(record, pid: pid, startedAt: bsd.pbi_start_tvsec, path: file) {
                return session
            }
            // shortcut: pre-bridge windows infer state from saved history; reopen them for live approvals.
            guard let path = legacyPath(pid),
                  var record = object(path) else { return nil }
            record["pid"] = pid
            record["startedAt"] = bsd.pbi_start_tvsec
            record["state"] = (record["rows"] as? [[String: Any]])?.last?["kind"] as? String == "user" ? "working" : "ready"
            record["updatedAt"] = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970
            record["preview"] = (record["rows"] as? [[String: Any]] ?? []).suffix(16).flatMap { row in
                (row["items"] as? [[String: Any]] ?? []).suffix(4).map { item -> [String: Any] in
                    let kind = row["kind"] as? String ?? "assistant"
                    let text = kind == "user" ? (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                        : kind == "activity" ? item["command"] as? String ?? item["type"] as? String ?? "Tool" : item["text"] as? String ?? ""
                    return ["kind": kind == "activity" ? "tool" : kind, "text": String(text.prefix(2000))]
                }
            }
            return session(record, pid: pid, startedAt: bsd.pbi_start_tvsec, path: path)
        }
    }

    static func session(_ record: [String: Any], pid: pid_t, startedAt: UInt64, path: String) -> Session? {
        guard record["pid"] as? pid_t == pid,
              record["startedAt"] as? UInt64 == startedAt,
              let cwd = record["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
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
        case "fresh": state = .fresh
        case "ready": state = prompt == nil ? .fresh : .ready
        default: return nil
        }
        let started = Date(timeIntervalSince1970: TimeInterval(startedAt))
        let activity = (record["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? started
        let info = TranscriptInfo(path: path, title: record["title"] as? String,
                                  lastPrompt: prompt,
                                  lastPromptAt: (record["lastPromptAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
                                  hasPendingTool: false, pendingToolNames: [], pendingToolLabels: [], pendingTaskIDs: [],
                                  cwd: cwd, turnOpen: state == .running, lastActivity: activity, preview: preview)
        return Session(proc: ClaudeProcess(pid: pid, ppid: 1, cwd: cwd, tty: "", startedAt: started,
                                          cpuNanos: 0, vcx: true),
                       transcript: info, state: state, cpuPercent: 0)
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
