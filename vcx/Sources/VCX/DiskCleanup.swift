import Foundation

// cleanup.py frees what sessions leave on disk (idle /tmp scratch, Rust incremental caches, other worktrees' builds,
// compose volumes no recent branch declares). It throttles itself to once an hour per project, so every turn can ask.
enum DiskCleanup {
    static func run(_ cwd: String, force: Bool = false) {
        guard ProcessInfo.processInfo.environment["VCX_NO_CLEANUP"] == nil,
              let script = Bundle.main.resourceURL?.appendingPathComponent("cleanup.py"), FileManager.default.fileExists(atPath: script.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, cwd] + (force ? ["--force"] : [])
        process.qualityOfService = .background
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
