import AppKit

@MainActor
enum CloseControl {
    static let suffix = ".close.json"
    static let timeout: TimeInterval = 10
    static let pollInterval: TimeInterval = 0.1

    static func reason(_ session: Session, window: NSWindow) -> String? {
        if session.disabled || session.frontendReplacing { return "session is working or reconnecting" }
        if session.backgroundTasks > 0 { return "background work is running" }
        if session.draft.length > 0 { return "the composer contains a draft" }
        if !session.permissions.isEmpty || window.attachedSheet != nil { return "a decision is pending" }
        return nil
    }

    static func request(_ args: [String]) -> Int32 {
        let windows = AgentMessages.windows()
        guard args.count == 1, let target = AgentMessages.match(args[0], windows) else {
            fputs("usage: vcx --close <unique window id or name>\n", stderr); return 2
        }
        guard target.state == "ready", AgentMessages.caller(windows)?.id != target.id else {
            fputs("SKIP: the session is active or is the calling session.\n", stderr); return 1
        }
        do {
            let ticket = try RuntimeUpdate.writeTicket(["sessionId": target.id, "sentAt": Date().timeIntervalSince1970], suffix: suffix)
            let result = ticket.appendingPathExtension("result")
            defer { try? FileManager.default.removeItem(at: ticket); try? FileManager.default.removeItem(at: result) }
            DistributedNotificationCenter.default().postNotificationName(RuntimeUpdate.openNotification, object: nil, userInfo: nil, deliverImmediately: true)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let data = try? Data(contentsOf: result), let message = String(data: data, encoding: .utf8), message != "requested" {
                    fputs("SKIP: " + message + "\n", stderr); return 1
                }
                if !AgentMessages.windows().contains(where: { $0.id == target.id }) { print("closed"); return 0 }
                Thread.sleep(forTimeInterval: pollInterval)
            }
            fputs("Window close was not confirmed; the session was preserved.\n", stderr); return 1
        } catch { fputs(error.localizedDescription + "\n", stderr); return 1 }
    }

    static func drain(_ windows: [AppDelegate.FrontendWindow]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: RuntimeIdentity.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix(suffix) {
            guard let ticket = try? RuntimeUpdate.readTicket(file.path, suffix: suffix),
                  let id = ticket["sessionId"] as? String else { continue }
            guard Date().timeIntervalSince1970 - (ticket["sentAt"] as? Double ?? 0) < timeout else {
                try? FileManager.default.removeItem(at: file); continue
            }
            guard let entry = windows.first(where: { $0.session.runtimeClient?.sessionID == id }) else { continue }
            let refusal = reason(entry.session, window: entry.window)
            let result = file.appendingPathExtension("result")
            let message = refusal ?? "requested"
            guard FileManager.default.createFile(atPath: result.path, contents: Data(message.utf8), attributes: [.posixPermissions: 0o600]) else { continue }
            try? FileManager.default.removeItem(at: file)
            if refusal == nil { entry.window.performClose(nil) }
        }
    }
}
