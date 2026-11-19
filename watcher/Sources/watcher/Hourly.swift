import Foundation

/// The checker's look for awaited answers (`checker.mjs check`, every 3 minutes since 19/11/2026: "un check par heure
/// c'est pas suffisant"), run by Watcher since 2026-10-30. As a
/// LaunchAgent of its own it was a second row in Login Items beside Watcher's: macOS nests an app's agents under its
/// row only for an app signed with a Team ID, and Watcher has none.
///
/// A slot is owed until `check.log`, which every finished run appends to, is newer than it. So a slot missed while
/// the Mac slept or was off runs at the next tick, a run `online` put off for want of network (75) is tried again, and
/// a run that ended in errors waits for the next slot, as under launchd.
@MainActor
enum Hourly {
    private static let log = Store.state.appending(path: "check.log")
    private static var running = false
    private static var started = Date.distantPast

    static func start() {
        tick()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
    }

    static let every: TimeInterval = 180

    /// The last 3-minute mark at or before `now`.
    static func slot(before now: Date) -> Date {
        Date(timeIntervalSince1970: (now.timeIntervalSince1970 / every).rounded(.down) * every)
    }

    /// `checker.mjs sweep`, every minute: a new mail sends the checks it concerns to `check` at once.
    private static var sweeping = false

    private static func sweep() {
        guard !sweeping else { return }
        sweeping = true
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        task.arguments = [NSHomeDirectory() + "/.claude/skills/checker/checker.mjs", "sweep"]
        task.qualityOfService = .utility
        task.standardOutput = FileHandle.standardError
        task.terminationHandler = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { sweeping = false } } }
        do { try task.run() } catch { sweeping = false }
    }

    private static func tick() {
        sweep()
        let now = Date()
        let done = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        // One slot between two starts: a run that dies before writing its line must not start again every minute.
        guard !running, done < slot(before: now), now.timeIntervalSince(started) >= every - 5 else { return }
        running = true
        started = now
        let task = Process()
        task.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/online")
        task.arguments = ["/opt/homebrew/bin/node", NSHomeDirectory() + "/.claude/skills/checker/checker.mjs", "check"]
        task.qualityOfService = .utility
        // Watcher's stderr, which launchd sends to /tmp/watcher.log; each run's summary also goes to check.log.
        task.standardOutput = FileHandle.standardError
        task.terminationHandler = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { running = false } } }
        do { try task.run() } catch {
            running = false
            NSLog("%@", "watcher: could not start the check — \(error)")
        }
    }
}
