import AppKit
import Combine
import CryptoKit
import Darwin

@MainActor
enum RuntimeSwapCheck {
    private final class Fixture: Connection, AdoptableConnection {
        private let claude: ClaudeConnection
        private let command: [String]
        var event: (JSON) -> Void { get { claude.event } set { claude.event = newValue } }
        init(command: [String], account: Account, cwd: String) { self.command = command; claude = ClaudeConnection(account: account, cwd: cwd) }
        func start(command: [String]?) async throws { try await claude.start(command: self.command) }
        func request(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON { try await claude.request(method, params, timeout: timeout) }
        func respond(_ id: Any, _ result: JSON) throws { try claude.respond(id, result) }
        func reject(_ id: Any, method: String) throws { try claude.reject(id, method: method) }
        func close() { claude.close() }
        func freezeForSwap() -> JSON? { claude.freezeForSwap() }
        func thawSwap() { claude.thawSwap() }
    }

    static func connection(command: [String], account: Account, cwd: String) -> any Connection { Fixture(command: command, account: account, cwd: cwd) }

    // A session opened in a folder named codex runs the Codex app-server fake; the others run the Claude fake.
    static func start(_ backend: SessionBackend, params: JSON, command: [String]) {
        if (params["cwd"] as? String)?.hasSuffix("/codex") == true { return backend.startInBackground(params: params, command: command + ["--codex"]) }
        backend.session.connectionFactory = { account, cwd in connection(command: command, account: account, cwd: cwd) }
        backend.startInBackground(params: params)
    }

    private static func wait(_ description: String, seconds: Double = 10, until condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try !condition() {
            guard Date() < deadline else { throw CXError(message: "Runtime live update check timed out: " + description) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // Asks the worker directly on a socket of its own, after hello, without attaching.
    private static func probe(_ socket: String, _ method: String = "hello") async throws -> JSON {
        let channel = try RuntimeChannel.connect(path: socket)
        defer { channel.close() }
        var replies: [String: CheckedContinuation<JSON, Error>] = [:]
        channel.onMessage = { message in
            guard let id = message["id"] as? String, let reply = replies.removeValue(forKey: id) else { return }
            if let error = message["error"] as? JSON { reply.resume(throwing: CXError(message: error["message"] as? String ?? "Runtime probe failed.")) }
            else { reply.resume(returning: message["result"] as? JSON ?? [:]) }
        }
        channel.onClose = { for reply in replies.values { reply.resume(throwing: CXError(message: "Runtime probe disconnected.")) }; replies.removeAll() }
        channel.start()
        func call(_ method: String, _ params: JSON) async throws -> JSON {
            try await withCheckedThrowingContinuation { continuation in
                let id = UUID().uuidString
                replies[id] = continuation
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { replies.removeValue(forKey: id)?.resume(throwing: CXError(message: "Runtime probe timed out.")) }
                do { try channel.send(["id": id, "method": method, "params": params]) }
                catch { replies.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }
        let hello = try await call("hello", ["protocol": 1])
        return method == "hello" ? hello : try await call(method, [:])
    }

    static func run() async throws -> String {
        let files = FileManager.default
        let directory = URL(fileURLWithPath: "/tmp/vcx-swap-check-" + UUID().uuidString.prefix(8))
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for folder in ["runtime", "config", "claude-home", "next", "codex"] {
            try files.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func write(_ data: Data, _ name: String, mode: Int = 0o600) throws {
            let file = directory.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            try files.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        let account: JSON = ["id": "swap-claude", "name": "Swap fixture", "provider": "claude", "home": directory.appendingPathComponent("claude-home").path, "enabled": true]
        try write(JSONSerialization.data(withJSONObject: ["provider": "claude", "mode": "bypass", "accounts": [account]]), "config/settings.json")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/swap_peer.py")
        let peer = Bundle.main.url(forResource: "swap_peer", withExtension: "py") ?? source
        try write(JSONSerialization.data(withJSONObject: ["/usr/bin/python3", peer.path, directory.path]), "command.json")
        func install(_ data: Data) throws { try write(data, "next/VCX", mode: 0o700) }
        func publish(_ build: String) throws { try write(Data(build.utf8), "runtime/installed-build") }
        let socket = directory.appendingPathComponent("worker.sock").path, log = directory.appendingPathComponent("worker.log")
        func logged(_ pattern: String) -> Bool { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").range(of: pattern, options: .regularExpression) != nil }
        func manifests() throws -> [String] { try files.contentsOfDirectory(atPath: directory.appendingPathComponent("runtime").path).filter { $0.hasSuffix(RuntimeSwap.suffix) } }
        guard files.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]), let logHandle = FileHandle(forWritingAtPath: log.path) else { throw CXError(message: "Cannot create the live update worker log.") }

        let worker = Process()
        worker.executableURL = RuntimeIdentity.executable
        worker.arguments = ["--runtime-worker", socket, "--runtime-test", "--runtime-swap-test", "--runtime-fixture-command", directory.appendingPathComponent("command.json").path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "BUILD_STACK_FD")
        environment["VCX_RUNTIME_HOME"] = directory.appendingPathComponent("runtime").path
        environment["VCX_CONFIG_HOME"] = directory.appendingPathComponent("config").path
        environment["VCX_RUNTIME_SWAP_EXECUTABLE"] = directory.appendingPathComponent("next/VCX").path
        worker.environment = environment
        worker.standardInput = FileHandle.nullDevice; worker.standardOutput = FileHandle.nullDevice; worker.standardError = logHandle
        try worker.run()
        var passed = false
        defer {
            if worker.isRunning {
                worker.terminate()
                let pid = worker.processIdentifier, force = DispatchWorkItem { kill(pid, SIGKILL) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: force)
                worker.waitUntilExit(); force.cancel()
            }
            for line in ((try? String(contentsOf: directory.appendingPathComponent("agent-starts"), encoding: .utf8)) ?? "").split(separator: "\n") {
                if let pid = pid_t(line) { kill(pid, SIGKILL) }
            }
            if passed { try? files.removeItem(at: directory) }
        }
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CXError(message: "Runtime live update failed: " + message + " (log: " + log.path + ")") }
            count += 1
        }

        var first: JSON?
        for _ in 0..<250 where first == nil {
            first = try? await probe(socket)
            if first == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        guard let first, let buildA = first["build"] as? String else { throw CXError(message: "Runtime live update worker did not start.") }
        func frontend(_ folder: URL, _ name: String) async throws -> (Session, RuntimeClient) {
            let session = Session(cwd: folder.path, stateDirectory: directory.appendingPathComponent(name))
            let client = RuntimeClient(session: session, cwd: folder.path, socketPath: socket)
            session.runtimeClient = client
            try await client.connect(resume: nil)
            try await wait(name + " attach") { session.ready }
            return (session, client)
        }
        let (session, client) = try await frontend(directory, "frontend")
        defer { client.close(); session.close() }
        let (codex, codexClient) = try await frontend(directory.appendingPathComponent("codex"), "codex-frontend")
        defer { codexClient.close(); codex.close() }
        func replied(_ number: Int, _ target: Session? = nil, _ agent: String = "swap") -> Bool {
            let target = target ?? session
            return !target.busy && target.rows.flatMap(\.items).contains { $0.data["text"] as? String == "\(agent) reply \(number)" }
        }
        func send(_ text: String, _ target: Session? = nil) async { await (target ?? session).send(text: text, images: [], expectedDraft: NSAttributedString(string: ""), expectedGeneration: 0) }
        await send("first message")
        await send("first Codex message", codex)
        try await wait("first replies") { replied(1) && replied(1, codex, "codex") }

        try install(Data("#!/bin/sh\nexit 1\n".utf8))
        try publish("fixture-protocol-failure")
        try await wait("failed preflight", seconds: 15) { logged("preflight failed for build fixture-protocol-failure") }
        await send("after a failed preflight")
        try await wait("reply after a failed preflight") { replied(2) }
        try check(try await probe(socket)["build"] as? String == buildA, "a failed preflight moved the worker off build A")

        try install(Data("#!/bin/sh\n[ \"$1\" = --runtime-protocol ] && echo 1 && exit 0\nexit 1\n".utf8))
        try publish("fixture-adopt-failure")
        try await wait("rejected manifest", seconds: 15) { logged("the new build rejected the manifest") }
        await send("after a rejected manifest")
        try await wait("reply after a rejected manifest") { replied(3) }
        try check(try await probe(socket)["build"] as? String == buildA && (try manifests()).isEmpty, "a rejected manifest did not roll back to build A")

        try await client.checkpoint(draft: [["text": "swap draft"]], generation: 1)
        try await wait("draft") { session.draft.string == "swap draft" }
        await send("HOLD this turn")
        try await wait("held turn") { files.fileExists(atPath: directory.appendingPathComponent("holding").path) && session.busy }
        var image = try Data(contentsOf: RuntimeIdentity.executable)
        image.append(Data("vcx-swap-check".utf8))
        try install(image)
        let buildB = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        try write(Data(buildB.utf8), "runtime/manual-build")
        try publish(buildB)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try check(!logged("armed for build " + buildB), "a build installed with --manual armed without --update-now")
        try write(Data(buildB.utf8), "runtime/update-request")
        try await wait("armed swap", seconds: 15) { logged("armed for build " + buildB) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try check(try await probe(socket)["build"] as? String == buildA && session.busy && !logged("executing build"), "the worker swapped during a running turn")

        let rowIDs = session.rows.map(\.id)
        var statuses: [String] = [], readyDropped = false
        let watchers = [session, codex].flatMap { [$0.$status.sink { statuses.append($0) }, $0.$ready.sink { if !$0 { readyDropped = true } }] }
        defer { watchers.forEach { $0.cancel() } }
        try write(Data(), "release")
        var swapped: JSON?
        let deadline = Date().addingTimeInterval(20)
        while swapped == nil, Date() < deadline {
            if let hello = try? await probe(socket), hello["build"] as? String == buildB { swapped = hello }
            else { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        guard let swapped else { throw CXError(message: "Runtime live update failed: the idle worker did not move to build B (log: " + log.path + ")") }
        let starts = try String(contentsOf: directory.appendingPathComponent("agent-starts"), encoding: .utf8).split(separator: "\n").compactMap { pid_t($0) }
        var info = proc_bsdinfo()
        let parents = starts.map { proc_pidinfo($0, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) ? pid_t(info.pbi_ppid) : -1 }
        try check(swapped["pid"] as? Int == Int(worker.processIdentifier) && swapped["instanceID"] as? String == first["instanceID"] as? String, "the worker changed pid or instance across the swap")
        try check(parents == [worker.processIdentifier, worker.processIdentifier], "an agent was restarted or is no longer the worker's child")
        try check(logged("carrying [1-9][0-9]* unparsed bytes") && (try manifests()).isEmpty, "the swap did not carry the agent's unparsed output or left its manifest")

        var attached = false
        for _ in 0..<100 where !attached {
            let sessions = (try? await probe(socket, "list"))?["sessions"] as? [JSON] ?? []
            attached = [client.sessionID, codexClient.sessionID].allSatisfy { id in sessions.contains { $0["sessionId"] as? String == id && $0["attached"] as? Bool == true } }
            if !attached { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        try check(attached && !readyDropped && !statuses.contains { $0.hasPrefix("Reconnecting") || $0.localizedCaseInsensitiveContains("stopped") }, "the frontend did not reattach silently")
        await send("after the swap")
        await send("Codex after the swap", codex)
        try await wait("replies after the swap") { replied(5) && session.backgroundTasks == 2 && replied(2, codex, "codex") }
        try check(true, "messages after the swap were answered by the same Claude and Codex agents")

        let observer = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("observer"))
        let second = RuntimeClient(session: observer, cwd: directory.path, resumeRuntimeID: client.sessionID, socketPath: socket)
        observer.runtimeClient = second
        defer { second.close(); observer.close() }
        try await second.connect(resume: nil)
        try await wait("observer attach") { observer.ready }
        try check(Array(observer.rows.map(\.id).prefix(rowIDs.count)) == rowIDs && observer.draft.string == "swap draft", "rows or the draft did not survive the swap")
        for pid in starts { kill(pid, SIGKILL) }
        try await wait("adopted agents reaped") {
            observer.rows.contains { $0.items.first?.text.hasPrefix("Claude stopped (killed by signal 9). Restarted it, context kept.") == true } && codex.status == "Disconnected" && starts.allSatisfy { kill($0, 0) != 0 && errno == ESRCH }
        }
        try check(true, "an adopted agent's exit is reaped; Claude is restarted once and the fixture Codex reported as a disconnect")
        passed = true
        return "Runtime live update: \(count) checks passed (Claude and Codex sessions; busy wait, same worker and agent pids, silent reattach, rows and draft kept, adopted agents reaped, failed preflight and rejected manifest stay on the old build)"
    }
}
