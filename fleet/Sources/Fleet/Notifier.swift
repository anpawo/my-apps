import AppKit
import UserNotifications

/// Tells you when a session starts waiting on you.
///
/// The panel only appears when you go idle or when you ask for it, which means a session that
/// asks a question while you are working in another window says nothing at all until you happen
/// to look. That is the one state where waiting costs you: the session is stopped, and it is
/// stopped on you. A banner is the smallest thing that closes that gap, and clicking it goes
/// straight to the terminal that asked.
///
/// Deliberately only for `awaitingAnswer`. Notifying on "finished" would fire constantly — every
/// turn of every session ends — and would train you to ignore the ones that matter.
@MainActor
final class Notifier: NSObject {

    /// Clicking a banner hands back the session identity it named, nil for a banner about no session.
    var onSelect: ((String?) -> Void)?

    /// Sessions already announced, so a question that sits unanswered for ten minutes produces
    /// one banner rather than one per refresh. Cleared when the session stops waiting.
    private var announced: Set<String> = []
    private var authorized = false
    fileprivate var pendingActivation: NSObjectProtocol?

    /// `UNUserNotificationCenter` reads the running process's bundle, and a bare binary — `swift
    /// run`, `--render`, `--scan` — has none, which is a crash rather than a failure. Everything
    /// here is a no-op unless we are running from the .app.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func start() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error { NSLog("Fleet: notifications unavailable — \(error)") }
            // This answer arrives on whatever queue the notification centre feels like, which
            // is not the main one — asserting the isolation here rather than hopping to it
            // traps, and takes the app down at launch.
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// Called on every refresh with the current fleet.
    ///
    /// `panelVisible` suppresses the banner without suppressing the bookkeeping: if the panel is
    /// already on screen the question is right in front of you, and a banner on top of it is
    /// noise — but it still counts as announced, so dismissing the panel does not then produce a
    /// notification for something you have already seen.
    func update(sessions: [Session], panelVisible: Bool) {
        guard available else { return }

        let waiting = sessions.filter { $0.state == .awaitingAnswer }
        // Forget sessions that moved on — answered, or exited — so the next question they ask
        // gets its own banner.
        announced = announced.intersection(waiting.map(\.id))

        guard authorized else { return }
        for session in waiting where !announced.contains(session.id) {
            announced.insert(session.id)
            guard !panelVisible else { continue }
            post(for: session)
        }
    }

    /// A one-off banner that is not about a session — currently only the reaper reporting what
    /// it killed. Bypasses `announced`, which exists to stop a *standing* condition repeating
    /// itself; this is an event, and it happens once.
    /// `opening` is the file a click on the banner opens — the report behind a one-line verdict.
    func announce(title: String, body: String, opening: URL? = nil) {
        guard available, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let opening { content.userInfo = ["open": opening.path] }
        let request = UNNotificationRequest(identifier: "fleet.notice.\(UUID().uuidString)",
                                            content: content, trigger: nil)
        deliver(request)
    }

    /// Fleet's style is Alerts, which stay until dismissed; a banner's ~5 s is fixed by macOS.
    /// Removing the alert after 30 s is the only way to get a 30 s banner.
    private func deliver(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        let id = request.identifier
        center.add(request) { error in
            if let error { NSLog("Fleet: could not post notification — \(error)"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
            }
        }
    }

    private func post(for session: Session) {
        let content = UNMutableNotificationContent()
        // A banner's title is bold and its body is not: the folder, then the card's own name.
        content.title = session.dirName
        content.body = session.label ?? session.topic
        content.sound = .default
        content.userInfo = ["pid": Int(session.proc.pid), "sessionId": session.id]

        let request = UNNotificationRequest(
            identifier: "fleet.awaiting.\(session.id)",
            content: content,
            trigger: nil            // deliver now
        )
        deliver(request)
    }
}

extension Notifier: UNUserNotificationCenterDelegate {

    /// macOS suppresses a banner while its own app is frontmost. Fleet is frontmost exactly
    /// when its panel is up, and that case is already handled above, so ask for the banner
    /// anyway rather than losing it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if let path = info["open"] as? String {
            await MainActor.run { _ = NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            return
        }
        let id = info["sessionId"] as? String ?? (info["pid"] as? Int).map { "pid:\($0)" }
        await MainActor.run { self.select(id) }
    }
}

extension Notifier {
    /// usernoted brings Fleet front about 10 ms after this handler runs, which took the focus
    /// straight back from the session just raised (13-11-2026: VCX front at .817, Fleet at .827).
    /// So the handoff waits for Fleet to be active, or 1 s if that never comes.
    fileprivate func select(_ id: String?) {
        guard !NSApp.isActive else { onSelect?(id); return }
        pendingActivation.map(NotificationCenter.default.removeObserver)
        pendingActivation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handOff(id) } }
        let token = pendingActivation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, pendingActivation === token else { return }
            handOff(id)
        }
    }

    private func handOff(_ id: String?) {
        guard let token = pendingActivation else { return }
        NotificationCenter.default.removeObserver(token)
        pendingActivation = nil
        onSelect?(id)
    }
}
