import Darwin
import Foundation
import os

// NSLog from a worker never reached the system log; os_log does, so `log show --predicate 'subsystem == "com.mr.vcx"'` finds swaps.
// Check workers (with their own runtime home) write to stderr only, which the live update check reads, so the system log holds real swaps alone.
private let swapLogger = OSLog(subsystem: "com.mr.vcx", category: "live-update")
func swapLog(_ format: String, _ arguments: CVarArg...) {
    let message = String(format: format, arguments: arguments)
    if ProcessInfo.processInfo.environment["VCX_RUNTIME_HOME"] == nil { os_log("%{public}@", log: swapLogger, type: .default, message) }
    fputs(message + "\n", stderr)
}

@MainActor
protocol AdoptableConnection: AnyObject {
    // nil keeps the agent reader running: the connection has work in flight or cannot be carried over.
    func freezeForSwap() -> JSON?
    func thawSwap()
}

@MainActor
func adoptConnection(_ state: JSON) throws -> any Connection {
    switch state["kind"] as? String {
    case "claude": return try ClaudeConnection(adopting: state)
    case "codex": return try RPC(adopting: state)
    default: throw CXError(message: "This agent connection cannot be adopted.")
    }
}

// The handles never close on deallocation: no failure path may close an agent's last pipe.
func adoptedAgent(_ state: JSON) throws -> (process: Process, input: FileHandle, output: FileHandle, leftover: Data)? {
    guard let agent = state["agent"] as? JSON else { return nil }
    guard let pid = agent["pid"] as? Int, let input = agent["input"] as? Int, let output = agent["output"] as? Int,
          let leftover = Data(base64Encoded: agent["leftover"] as? String ?? "") else { throw CXError(message: "Invalid adopted agent.") }
    for fd in [input, output] { _ = fcntl(Int32(fd), F_SETFD, FD_CLOEXEC) }
    return (AdoptedProcess(pid: pid_t(pid)), FileHandle(fileDescriptor: Int32(input), closeOnDealloc: false), FileHandle(fileDescriptor: Int32(output), closeOnDealloc: false), leftover)
}

// An agent spawned by the previous image of this process: Foundation cannot adopt a pid, so this watches and reaps it.
final class AdoptedProcess: Process, @unchecked Sendable {
    private let pid: pid_t
    private let condition = NSCondition()
    private var status: Int32?
    private var source: DispatchSourceProcess?

    init(pid: pid_t) {
        self.pid = pid
        super.init()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in self?.reap() }
        self.source = source; source.resume()
        reap()
    }

    private func reap() {
        condition.lock(); defer { condition.unlock() }
        guard status == nil else { return }
        var raw: Int32 = 0
        let result = waitpid(pid, &raw, WNOHANG)
        if result == pid { status = raw } else if result < 0, errno == ECHILD { status = 0 } else { return }
        source?.cancel(); source = nil
        condition.broadcast()
    }

    private var exited: Int32? { condition.lock(); defer { condition.unlock() }; return status }
    override var processIdentifier: Int32 { pid }
    override var isRunning: Bool { exited == nil }
    override var terminationReason: Process.TerminationReason { (exited ?? 0) & 0x7f == 0 ? .exit : .uncaughtSignal }
    override var terminationStatus: Int32 { let raw = exited ?? 0; return raw & 0x7f == 0 ? (raw >> 8) & 0xff : raw & 0x7f }
    override func waitUntilExit() { condition.lock(); while status == nil { condition.wait() }; condition.unlock() }
    override func terminate() { if isRunning { kill(pid, SIGTERM) } }
    override func interrupt() { if isRunning { kill(pid, SIGINT) } }
}

// Moves a runtime worker onto a newly installed build with execv: same pid, so agents stay its children and keep their pipes.
@MainActor
final class RuntimeSwap {
    static let version = 1
    static let suffix = ".swap.json"
    static let maximumBytes = 1 << 30
    private let server: RuntimeServer
    private let executable: URL
    private var timer: Timer?
    private var handled: String?
    private var armed: String?
    private var preflighting = false

    // A worker with an overridden runtime home belongs to a check: it never execs the installed app.
    init?(server: RuntimeServer, testing: Bool) {
        let environment = ProcessInfo.processInfo.environment
        if testing, let override = environment["VCX_RUNTIME_SWAP_EXECUTABLE"] { executable = URL(fileURLWithPath: override) }
        else if environment["VCX_RUNTIME_HOME"] == nil { executable = RuntimeUpdate.installed.appendingPathComponent("Contents/MacOS/VCX") }
        else { return nil }
        self.server = server
    }

    func start() { schedule(2) }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    private func tick() {
        if let armed { attempt(armed); return }
        guard !preflighting, let marker = try? String(contentsOf: RuntimeIdentity.directory.appendingPathComponent("installed-build"), encoding: .utf8),
              marker != RuntimeIdentity.build, marker != handled else { return }
        handled = marker; preflighting = true
        Task {
            defer { preflighting = false }
            do { try await RuntimeClient.preflight(executable: executable) }
            catch { swapLog("VCX live update: preflight failed for build %@: %@", marker, error.localizedDescription); return }
            swapLog("VCX live update: armed for build %@", marker)
            armed = marker; schedule(0.2)
        }
    }

    // Everything from the idle check to execv runs in this one main-actor turn, so no request can slip in between.
    private func attempt(_ build: String) {
        guard var manifest = server.freezeForSwap() else { return }
        manifest["version"] = Self.version; manifest["build"] = build
        let file: URL
        do { file = try RuntimeUpdate.writeTicket(manifest, suffix: Self.suffix, maximumBytes: Self.maximumBytes) }
        catch { return rollback(nil, "cannot write the manifest: " + error.localizedDescription) }
        guard check(file) else { return rollback(file, "the new build rejected the manifest") }
        server.closePeersForSwap()
        var kept = [manifest["listener"], manifest["lock"]].compactMap { $0 as? Int }
        for session in manifest["sessions"] as? [JSON] ?? [] {
            if let agent = (((session["backend"] as? JSON)?["connection"] as? JSON)?["agent"] as? JSON) { kept += [agent["input"], agent["output"]].compactMap { $0 as? Int } }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        for fd in names.compactMap({ Int32($0) }) where fd > 2 { _ = fcntl(fd, F_SETFD, kept.contains(Int(fd)) ? 0 : FD_CLOEXEC) }
        var arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--adopt"), index + 1 < arguments.count { arguments.removeSubrange(index...index + 1) }
        arguments[0] = executable.path; arguments += ["--adopt", file.path]
        swapLog("VCX live update: executing build %@ with %d sessions", build, (manifest["sessions"] as? [JSON])?.count ?? 0)
        fflush(stdout); fflush(stderr)
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        argv.withUnsafeBufferPointer { _ = execv(executable.path, $0.baseAddress!) }
        let reason = String(cString: strerror(errno))
        argv.forEach { free($0) }
        for fd in kept { _ = fcntl(Int32(fd), F_SETFD, FD_CLOEXEC) }
        rollback(file, "execv failed: " + reason)
    }

    private func rollback(_ file: URL?, _ reason: String) {
        if let file { try? FileManager.default.removeItem(at: file) }
        server.thawSwap()
        armed = nil; schedule(2)
        swapLog("VCX live update: %@; staying on build %@", reason, RuntimeIdentity.build)
    }

    // Blocking on purpose: an await here would let requests run between the freeze and execv.
    private func check(_ manifest: URL) -> Bool {
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, 2, 2)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let paths: [String] = [executable.path, "--adopt-check", manifest.path]
        let argv: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ) == 0 else { return false }
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(10)
        while waitpid(pid, &status, WNOHANG) == 0 {
            guard Date() < deadline else { kill(pid, SIGKILL); waitpid(pid, &status, 0); return false }
            usleep(10_000)
        }
        return status == 0
    }

    static func manifest(_ path: String) throws -> JSON {
        let value = try RuntimeUpdate.readTicket(path, suffix: suffix, maximumBytes: maximumBytes)
        guard value["version"] as? Int == version, value["build"] as? String == RuntimeIdentity.build else { throw CXError(message: "The live update manifest was written for another build.") }
        return value
    }

    static func adopt(_ manifest: JSON, into server: RuntimeServer) throws {
        guard let listener = manifest["listener"] as? Int, let lock = manifest["lock"] as? Int else { throw CXError(message: "The live update manifest has no listener.") }
        var sessions: [(id: String, revision: Int, lastSequence: Int, backend: any RuntimeBackend)] = [], carried = 0
        for session in manifest["sessions"] as? [JSON] ?? [] {
            guard let id = session["sessionId"] as? String, let state = session["backend"] as? JSON else { continue }
            do {
                sessions.append((id, session["revision"] as? Int ?? 0, session["lastSequence"] as? Int ?? 0, try SessionBackend(adopting: state)))
                carried += (((state["connection"] as? JSON)?["agent"] as? JSON)?["leftover"] as? String).flatMap { Data(base64Encoded: $0) }?.count ?? 0
            } catch { swapLog("VCX live update: session %@ was not adopted: %@", id, error.localizedDescription) }
        }
        try server.adopt(listener: Int32(listener), lock: Int32(lock), closedIDs: manifest["closedIDs"] as? [String] ?? [], sessions: sessions)
        swapLog("VCX live update: adopted %d sessions on build %@, carrying %d unparsed bytes", sessions.count, RuntimeIdentity.build, carried)
    }
}
