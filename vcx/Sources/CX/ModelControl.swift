import AppKit

@MainActor
enum ModelControl {
    static let suffix = ".model.json"
    private static var active: Set<String> = []
    private static var retrying = false

    static let providers = ["auto", "claude", "codex", "qwen"]

    static func request(_ args: [String]) -> Int32 {
        let all = AgentMessages.windows()
        let window = args.first.flatMap { $0 == "self" ? AgentMessages.caller(all) : AgentMessages.match($0, all) }
        var rest = Array(args.dropFirst())
        let provider = rest.first.flatMap { providers.contains($0) ? $0 : nil }
        if provider != nil { rest.removeFirst() }
        guard let window, (provider == nil ? 1...2 : 0...2).contains(rest.count) else {
            fputs("usage: vcx --set-model <window id or name | self> [auto|claude|codex|qwen] [model] [effort]\n", stderr)
            return 2
        }
        do {
            var value: JSON = ["sessionId": window.id, "provider": provider ?? window.provider, "sentAt": Date().timeIntervalSince1970]
            if rest.count >= 1 { value["model"] = rest[0] }
            if rest.count == 2 { value["effort"] = rest[1] }
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
                  Date().timeIntervalSince1970 - (value["sentAt"] as? Double ?? 0) < 3600 else {
                try? FileManager.default.removeItem(at: file); continue
            }
            waiting = true
            guard let session = windows.first(where: { $0.session.runtimeClient?.sessionID == id })?.session,
                  !session.disabled, let client = session.runtimeClient else { continue }
            let provider = value["provider"] as? String ?? "codex", model = value["model"] as? String
            var effort = value["effort"] as? String
            // The other provider's catalog is only known once it is connected: /model checks it there.
            if provider == session.account.provider, let model {
                let efforts = session.modelEfforts[model, default: []]
                guard session.models.contains(model), effort.map(efforts.contains) ?? true else {
                    NSLog("VCX rejected model control for %@", id)
                    try? FileManager.default.removeItem(at: file); continue
                }
                if effort == nil, !efforts.isEmpty {
                    effort = session.effectiveEffort.flatMap { efforts.contains($0) ? $0 : nil } ?? session.modelDefaultEfforts[model] ?? efforts.first
                }
            }
            let text = (["/model", provider] + [model, effort].compactMap { $0 }).joined(separator: " ")
            active.insert(file.path)
            Task {
                defer { active.remove(file.path) }
                do {
                    // A busy session keeps it as its pending /model and applies it when the turn ends.
                    _ = try await client.perform("command", ["text": text])
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
