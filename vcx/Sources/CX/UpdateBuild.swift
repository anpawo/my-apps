import Foundation

/// The update `auto-update.sh` is building: it writes `building` (start time, tab, the commit's subject) while it runs,
/// and `last-duration` once one is installed, which paces the status bar's line.
@MainActor
final class UpdateBuild: ObservableObject {
    static let shared = UpdateBuild()
    struct Build: Equatable { var started: Date; var words: String; var expected: TimeInterval }
    @Published var build: Build?
    private var timer: Timer?
    private let directory = URL(fileURLWithPath: NSHomeDirectory() + "/.local/share/vcx-update")

    func watch() {
        guard timer == nil else { return }
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { UpdateBuild.shared.read() } }
    }

    func read() {
        let text = try? String(contentsOf: directory.appendingPathComponent("building"), encoding: .utf8)
        let last = (try? String(contentsOf: directory.appendingPathComponent("last-duration"), encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let next = text.flatMap { Self.parse($0, expected: last ?? 270) }
        if next != build { build = next }
    }

    // A file left by a killed run is ignored after an hour.
    static func parse(_ text: String, expected: TimeInterval, now: Date = Date()) -> Build? {
        let parts = text.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2, let start = Double(parts[0]) else { return nil }
        let started = Date(timeIntervalSince1970: start)
        guard now.timeIntervalSince(started) < 3600 else { return nil }
        return Build(started: started, words: parts[1].trimmingCharacters(in: .whitespacesAndNewlines), expected: max(30, expected))
    }

    // Past the previous build's time it keeps creeping toward the end, never reaching it before the file goes.
    static func progress(_ build: Build, at now: Date) -> Double {
        let t = max(0, now.timeIntervalSince(build.started)) / build.expected
        return t < 0.9 ? t : 1 - 0.1 * exp(-(t - 0.9) * 2)
    }
}
