import AppKit

@MainActor
enum ModelControl {
    static let suffix = ".model.json"
    private static var active: Set<String> = []
    private static var retrying = false

    static func request(_ args: [String]) -> Int32 {
        guard (2...3).contains(args.count), let window = AgentMessages.match(args[0], AgentMessages.windows()), window.provider == "codex" else {
            fputs("usage: vcx --set-model <Codex window id or name> <model> [effort]\n", stderr)
            return 2
        }
        do {
            var value: JSON = ["sessionId": window.id, "model": args[1], "sentAt": Date().timeIntervalSince1970]
            if args.count == 3 { value["effort"] = args[2] }
            _ = try RuntimeUpdate.writeTicket(value, suffix: suffix)
            DistributedNotificationCenter.default().postNotificationName(RuntimeUpdate.openNotification, object: nil, userInfo: nil, deliverImmediately: true)
            print("Model change requested for \(window.name) (\(window.id.prefix(8))); active turns finish first.")
            return 0
        } catch { fputs(error.localizedDescription + "\n", stderr); return 1 }
    }

    static func drain(_ windows: [AppDelegate.FrontendWindow]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: RuntimeIdentity.directory, includingPropertiesForKeys: nil)) ?? []
        var waiting = false
        for file in files where file.lastPathComponent.hasSuffix(suffix) {
            guard !active.contains(file.path) else { continue }
            guard let value = try? RuntimeUpdate.readTicket(file.path, suffix: suffix), let id = value["sessionId"] as? String,
                  let model = value["model"] as? String, Date().timeIntervalSince1970 - (value["sentAt"] as? Double ?? 0) < 3600 else {
                try? FileManager.default.removeItem(at: file); continue
            }
            waiting = true
            guard let session = windows.first(where: { $0.session.runtimeClient?.sessionID == id })?.session,
                  !session.disabled, let client = session.runtimeClient else { continue }
            guard session.account.provider == "codex", session.models.contains(model),
                  (value["effort"] as? String).map({ session.modelEfforts[model, default: []].contains($0) }) ?? true else {
                NSLog("VCX rejected model control for %@", id)
                try? FileManager.default.removeItem(at: file); continue
            }
            active.insert(file.path)
            Task {
                defer { active.remove(file.path) }
                do {
                    _ = try await client.perform("setModel", value)
                    try? FileManager.default.removeItem(at: file)
                } catch {
                    // A busy worker or an older build retries after its current turn and live update.
                    NSLog("VCX model control pending for %@: %@", id, error.localizedDescription)
                }
            }
        }
        guard waiting, !retrying else { return }
        retrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { retrying = false; (NSApp.delegate as? AppDelegate)?.drainOpenRequests() }
        }
    }
}
