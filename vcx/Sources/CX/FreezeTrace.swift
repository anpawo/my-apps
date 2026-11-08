import Foundation
import os

// The 11-05, 11-06 and 11-08 freezes (main thread stuck in SwiftUI's flush) never came back offscreen. When the main thread
// stops answering, a background thread writes which geometry callbacks kept firing meanwhile, and a sample of the process.
enum FreezeTrace {
    private static let state = OSAllocatedUnfairLock(initialState: (beat: Date(), counts: [String: Int]()))
    nonisolated(unsafe) static var folder = URL(fileURLWithPath: NSHomeDirectory() + "/.local/state/cx/freezes", isDirectory: true)

    static func note(_ key: String) { state.withLock { $0.counts[key, default: 0] += 1 } }

    @MainActor static func start(stall: TimeInterval = 5) {
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in state.withLock { $0.beat = Date() } }
        RunLoop.main.add(timer, forMode: .common)
        Thread.detachNewThread {
            var reported = false
            while true {
                Thread.sleep(forTimeInterval: 1)
                let (beat, before) = state.withLock { ($0.beat, $0.counts) }
                guard Date().timeIntervalSince(beat) > stall else { reported = false; continue }
                guard !reported else { continue }
                reported = true
                let clock = ISO8601DateFormatter(); clock.timeZone = .current
                let stamp = clock.string(from: Date()).replacingOccurrences(of: ":", with: "-")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let sample = Process()
                sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sample.arguments = ["\(getpid())", "3", "-file", folder.appendingPathComponent("\(stamp).sample.txt").path]
                sample.standardOutput = FileHandle.nullDevice; sample.standardError = FileHandle.nullDevice
                try? sample.run(); sample.waitUntilExit()
                let after = state.withLock { $0.counts }
                let fired = after.map { ($0.key, $0.value - (before[$0.key] ?? 0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
                let report = "Main thread silent since \(clock.string(from: beat)); callbacks fired in the 3 s after:\n" + (fired.isEmpty ? "none\n" : fired.map { "\($0.1)\t\($0.0)\n" }.joined())
                try? report.write(to: folder.appendingPathComponent("\(stamp).txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}
