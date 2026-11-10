import Foundation
import os

// The 11-05, 11-06 and 11-08 freezes (main thread stuck in SwiftUI's flush) never came back offscreen. When the main thread
// spins without answering, a background thread writes which callbacks kept firing meanwhile, the windows' recent shapes,
// and a sample of the process, again every minute while it stays stuck.
enum FreezeTrace {
    struct Shape: Equatable {
        var window = "", sections = 0, headerOnly = 0, pinned = "none", viewport: CGFloat = 0, composer: CGFloat = 0, drawn = 0
    }
    private struct State {
        var beat: TimeInterval = 0
        var counts: [String: Int] = [:]
        var shapes: [(time: TimeInterval, shape: Shape)] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated(unsafe) static var folder = URL(fileURLWithPath: NSHomeDirectory() + "/.local/state/cx/freezes", isDirectory: true)
    // Uptime stops while the Mac sleeps: on wall time, 7 of the 8 first reports were a night's sleep, not a freeze.
    nonisolated(unsafe) static var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    static func note(_ key: String) { state.withLock { $0.counts[key, default: 0] += 1 } }

    // Each window's transcript shape when its composer height or its drawn rows change; the last 64 go in a report.
    static func shape(_ shape: Shape) {
        let now = uptime()
        state.withLock {
            guard $0.shapes.last(where: { $0.shape.window == shape.window })?.shape != shape else { return }
            $0.shapes.append((now, shape))
            if $0.shapes.count > 64 { $0.shapes.removeFirst($0.shapes.count - 64) }
        }
    }

    @MainActor static func shape(of session: Session) {
        var sections = 0, headerOnly = 0, open = false
        for row in session.rows {
            let head = headsSection(row)
            if head { if open { headerOnly += 1 }; sections += 1 }
            open = head
        }
        if open { headerOnly += 1 }
        let pinned = session.pinnedQuestion.map { String($0.uuidString.prefix(8)) } ?? "none"
        let window = URL(fileURLWithPath: session.cwd).lastPathComponent + "#" + String(UInt(bitPattern: ObjectIdentifier(session).hashValue), radix: 16).suffix(6)
        shape(Shape(window: window, sections: sections, headerOnly: headerOnly, pinned: pinned, viewport: session.viewportHeight, composer: session.editorHeight, drawn: session.drawnRows))
    }

    // A stall is a freeze only if the main thread spent most of it on the CPU: blocked or idle, it is something else.
    static func spinning(stalled: TimeInterval, cpu: TimeInterval) -> Bool { cpu > stalled / 2 }

    static func cpuTime(_ thread: mach_port_t) -> TimeInterval {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) } }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }

    @MainActor static func start(stall: TimeInterval = 5, resample: TimeInterval = 60) {
        let main = mach_thread_self()
        state.withLock { $0.beat = uptime() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in let now = uptime(); state.withLock { $0.beat = now } }
        RunLoop.main.add(timer, forMode: .common)
        Thread.detachNewThread {
            var fresh = (beat: state.withLock { $0.beat }, at: uptime(), cpu: cpuTime(main))
            var stuck: (stamp: String, samples: Int, last: TimeInterval)?
            let clock = ISO8601DateFormatter(); clock.timeZone = .current
            func sample(_ name: String) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                process.arguments = ["\(getpid())", "3", "-file", folder.appendingPathComponent(name).path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try? process.run(); process.waitUntilExit()
            }
            while true {
                Thread.sleep(forTimeInterval: 1)
                let now = uptime(), (beat, before) = state.withLock { ($0.beat, $0.counts) }, cpu = cpuTime(main)
                if beat != fresh.beat { fresh = (beat, now, cpu); stuck = nil; continue }
                guard now - beat > stall else { continue }
                if var current = stuck {
                    guard now - current.last >= resample else { continue }
                    current.samples += 1; current.last = now; stuck = current
                    sample("\(current.stamp).sample-\(current.samples).txt")
                    continue
                }
                // CPU from the first check that saw the last beat, so a beat seen late does not count as idle time.
                guard spinning(stalled: now - fresh.at, cpu: cpu - fresh.cpu) else { continue }
                let stamp = clock.string(from: Date()).replacingOccurrences(of: ":", with: "-")
                stuck = (stamp, 1, now)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                sample("\(stamp).sample.txt")
                let (after, shapes) = state.withLock { ($0.counts, $0.shapes) }
                let fired = after.map { ($0.key, $0.value - (before[$0.key] ?? 0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
                let since = clock.string(from: Date().addingTimeInterval(beat - now))
                var report = "Main thread busy since \(since): \(String(format: "%.1f", cpu - fresh.cpu)) s of CPU in \(String(format: "%.1f", now - beat)) s; callbacks fired in the 3 s after:\n"
                report += fired.isEmpty ? "none\n" : fired.map { "\($0.1)\t\($0.0)\n" }.joined()
                report += "Window shapes, oldest first (seconds before the stall, window, sections, header-only, pinned, viewport, composer, drawn rows):\n"
                report += shapes.map { entry in
                    let s = entry.shape
                    return String(format: "%.1f", beat - entry.time) + "\t\(s.window)\t\(s.sections)\t\(s.headerOnly)\t\(s.pinned)\t\(Int(s.viewport))\t\(Int(s.composer))\t\(s.drawn)\n"
                }.joined()
                try? report.write(to: folder.appendingPathComponent("\(stamp).txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}
