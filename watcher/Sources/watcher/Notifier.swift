import AppKit
import UserNotifications

/// A macOS banner when a check arrives and when its follow-up leaves a line: the menu bar count alone went unseen
/// (25/11: Codex came back at 15:10 and nothing popped up). A click opens the panel on what it announced.
@MainActor
final class Notifier: NSObject {
    /// macOS keeps a banner about 5 s; an Alert stays until this removes it.
    nonisolated static let shownFor: TimeInterval = 30
    static let poll: TimeInterval = 5

    private let inbox: Inbox
    private let fired: URL
    private var seenFired: Set<String>?
    private var firedDate: Date?
    private var authorized = false

    init(inbox: Inbox, state: URL = Store.state) {
        self.inbox = inbox
        fired = state.appending(path: "fired")
    }

    /// `UNUserNotificationCenter` crashes a process with no bundle (`--render`, a bare build): a no-op there.
    func start() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error { NSLog("%@", "watcher: notifications unavailable — \(error)") }
            Task { @MainActor in self?.authorized = granted }
        }
        inbox.notify = { [weak self] item in self?.announce(item) }
        arrivals()
        Timer.scheduledTimer(withTimeInterval: Self.poll, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.arrivals() }
        }
    }

    /// A check newly in `fired/` that arrived (not dropped). Not on the first read: those were there before Watcher.
    private func arrivals() {
        let date = (try? FileManager.default.attributesOfItem(atPath: fired.path))?[.modificationDate] as? Date
        guard date != firedDate else { return }
        firedDate = date
        let files = ((try? FileManager.default.contentsOfDirectory(at: fired, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        let ids = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        defer { seenFired = ids }
        guard let seen = seenFired else { return }
        for file in files where !seen.contains(file.deletingPathExtension().lastPathComponent) {
            guard let json = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                  json["dropped"] == nil, json["fired"] != nil else { continue }
            let name = json["name"] as? String ?? json["what"] as? String ?? "A check"
            let how = (json["fired"] as? [String: Any])?["how"] as? String
            post(title: "Arrived: \(name)", body: how == "resumed" ? "A follow-up session is on it." : json["what"] as? String ?? "",
                 line: nil)
        }
    }

    private func announce(_ item: InboxItem) {
        post(title: item.kind == "needs" ? "Needs you: \(item.subject)" : item.subject, body: item.line, line: item.id)
    }

    private func post(title: String, body: String, line: String?) {
        guard authorized else { return NSLog("%@", "watcher: notifications not allowed, no banner for \(title)") }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let line { content.userInfo = ["line": line] }
        let id = "watcher.\(UUID().uuidString)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { return NSLog("%@", "watcher: could not post a banner — \(error)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.shownFor) {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
            }
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let line = response.notification.request.content.userInfo["line"] as? String
        await MainActor.run { inbox.reveal(line) }
    }
}
