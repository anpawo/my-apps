import AppKit
import Darwin

@MainActor
enum RecoveryCheck {
    private final class Fixture: Connection {
        private let rpc = RPC()
        private let command: [String]
        var event: (JSON) -> Void { get { rpc.event } set { rpc.event = newValue } }
        init(command: [String], account: Account, cwd: String) { self.command = command; rpc.account = account; rpc.cwd = cwd }
        func start(command: [String]?) async throws { try await rpc.start(command: self.command) }
        func request(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON { try await rpc.request(method, params, timeout: timeout) }
        func respond(_ id: Any, _ result: JSON) throws { try rpc.respond(id, result) }
        func reject(_ id: Any, method: String) throws { try rpc.reject(id, method: method) }
        func close() { rpc.close() }
    }

    static func connection(command: [String], account: Account, cwd: String) -> any Connection { Fixture(command: command, account: account, cwd: cwd) }

    private static func value(_ file: URL) throws -> JSON { try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? JSON ?? [:] }
    private static func write(_ value: JSON, to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func wait(_ description: String, until condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while try !condition() {
            guard Date() < deadline else { throw CXError(message: "Recovery check timed out: " + description) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func frontend(directory: URL, socketPath: String, stage: String) async throws {
        let newSession = stage == "first" || stage == "closing"
        let recovered = newSession ? nil : try RuntimeRecovery.pending().first
        guard newSession || recovered != nil else { throw CXError(message: "Recovery registry did not restore the crashed frontend.") }
        let session = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("frontend-state"))
        let client = RuntimeClient(session: session, cwd: directory.path, resumeRuntimeID: recovered?.sessionID, socketPath: socketPath, recovery: recovered)
        session.runtimeClient = client
        try await client.connect(resume: nil)
        try await wait("frontend ready") { session.ready }
        if stage == "closing" {
            try RuntimeRecovery.requestClose(sessionID: client.sessionID)
        } else if stage == "first" {
            await session.send(text: "recovery fixture submission", images: [])
            try await wait("blocked tool") { FileManager.default.fileExists(atPath: directory.appendingPathComponent("tool-started.json").path) }
            session.editDraft(runtimeDraft([["text": "recovery unsent draft"], ["path": directory.appendingPathComponent("attachment.png").path]]))
            try await client.checkpointWindow(["follow": false, "frame": "{{10, 20}, {900, 700}}", "selection": [3, 2]])
        } else if stage == "second" {
            guard session.busy else { throw CXError(message: "Frontend crash interrupted the tool.") }
        } else {
            try await wait("pending approval") { session.permissions.count == 1 }
            let approval = session.permissions[0]
            _ = try await client.perform("answer", ["rpcID": approval.rpcID, "method": approval.method, "result": ["decision": "accept"]])
            try await wait("completed turn") { !session.busy && session.permissions.isEmpty }
        }
        guard stage == "closing" || (session.draft.string.contains("recovery unsent draft") && draftContent(session.draft).count == 2) else { throw CXError(message: "Recovered draft or attachment was lost.") }
        let provider = try value(directory.appendingPathComponent("provider.json"))
        try write(["sessionId": client.sessionID, "threadID": session.threadID ?? "", "providerPID": provider["pid"] ?? 0,
                   "draftGeneration": session.draftGeneration, "busy": session.busy], to: directory.appendingPathComponent(stage + "-ready.json"))
        try await Task.sleep(nanoseconds: 30_000_000_000)
        client.close(); session.close()
    }

    static func run() async throws -> Int {
        let directory = URL(fileURLWithPath: "/tmp/vcx-recovery-check-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let previousHome = ProcessInfo.processInfo.environment["VCX_RUNTIME_HOME"]
        let runtimeHome = directory.appendingPathComponent("runtime")
        setenv("VCX_RUNTIME_HOME", runtimeHome.path, 1)
        defer {
            if let previousHome { setenv("VCX_RUNTIME_HOME", previousHome, 1) } else { unsetenv("VCX_RUNTIME_HOME") }
        }
        let fixtureSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/runtime_peer.py")
        let fixture = Bundle.main.url(forResource: "runtime_peer", withExtension: "py") ?? fixtureSource
        let command = directory.appendingPathComponent("command.json")
        try JSONSerialization.data(withJSONObject: ["/usr/bin/python3", fixture.path, directory.path]).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: command.path)
        let config = directory.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try write(["provider": "codex", "mode": "ask", "accounts": [["id": "codex-default", "name": "Fixture", "provider": "codex", "enabled": true]]], to: config.appendingPathComponent("settings.json"))
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("attachment.png"))
        guard mkfifo(directory.appendingPathComponent("release-tool").path, 0o600) == 0 else { throw CXError(message: "Cannot create recovery fixture tool gate.") }
        let socketPath = runtimeHome.appendingPathComponent("worker.sock").path
        var environment = ProcessInfo.processInfo.environment
        environment["VCX_CONFIG_HOME"] = config.path
        environment.removeValue(forKey: "BUILD_STACK_FD")
        let executable = Bundle.main.executableURL!
        var processes: [Process] = []
        func launch(_ arguments: [String]) throws -> Process {
            let process = Process(); process.executableURL = executable; process.arguments = arguments; process.environment = environment
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); processes.append(process); return process
        }
        defer {
            for process in processes where process.isRunning { process.terminate() }
            for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        let workerArguments = ["--runtime-worker", socketPath, "--runtime-test", "--runtime-recovery-test", "--runtime-fixture-command", command.path]
        let worker = try launch(workerArguments)
        var count = 0
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw CXError(message: "Recovery check failed: " + description) }; count += 1
        }
        let legacyIdentity = RuntimeRecovery.workerInstance(["pid": Int(getpid())])
        try check(legacyIdentity?.hasPrefix("process:\(getpid()):") == true && legacyIdentity == RuntimeRecovery.workerInstance(["pid": Int(getpid())]), "legacy worker identity was not stable and tied to its process start")
        let bootIdentity = UUID().uuidString
        try check(RuntimeRecovery.workerInstance(["pid": Int(getpid()), "instanceID": bootIdentity]) == bootIdentity, "new worker identity did not take precedence over the legacy fallback")
        try check(RuntimeRecovery.workerInstance(["pid": 0]) == nil, "an unavailable worker process received a fabricated identity")
        try check(RuntimeRecovery.workerInstance(["pid": Int(getpid()), "instanceID": "invalid"]) == legacyIdentity, "invalid boot identity prevented safe legacy worker identification")
        var original: JSON = [:]
        var providerIdentity: (pid_t, UInt64)?
        for stage in ["first", "second", "third"] {
            let frontend = try launch(["--recovery-frontend", directory.path, socketPath, stage])
            let milestone = directory.appendingPathComponent(stage + "-ready.json")
            try await wait(stage + " frontend") { FileManager.default.fileExists(atPath: milestone.path) || !frontend.isRunning }
            try check(frontend.isRunning, "fixture frontend exited before its milestone")
            let report = try value(milestone)
            if stage == "first" {
                original = report
                guard let pid = report["providerPID"] as? Int32 else { throw CXError(message: "Fixture provider identity is missing.") }
                var info = proc_bsdinfo()
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_ppid == UInt32(worker.processIdentifier) else { throw CXError(message: "Fixture provider ownership was not established.") }
                providerIdentity = (pid, info.pbi_start_tvsec)
            } else {
                try check(report["sessionId"] as? String == original["sessionId"] as? String, "crash changed the runtime session")
                try check(report["providerPID"] as? Int == original["providerPID"] as? Int, "crash restarted the provider")
                try check(report["threadID"] as? String == original["threadID"] as? String, "crash changed the conversation")
            }
            kill(frontend.processIdentifier, SIGKILL)
            await Task.detached { frontend.waitUntilExit() }.value
            let entries = try RuntimeRecovery.pending()
            try check(entries.count == 1, "crashed frontend was not discoverable in the recovery registry")
            try check(entries[0].windowState["follow"] as? Bool == false, "crash lost the saved viewport state")
            try check((entries[0].state["draft"] as? [JSON])?.count == 2, "crash lost the text or image draft")
            if stage == "second" {
                let gate = Darwin.open(directory.appendingPathComponent("release-tool").path, O_WRONLY | O_NONBLOCK)
                guard gate >= 0 else { throw CXError(message: "Cannot release recovery fixture tool.") }
                var byte: UInt8 = 1
                guard Darwin.write(gate, &byte, 1) == 1 else { Darwin.close(gate); throw CXError(message: "Cannot release recovery fixture tool.") }
                Darwin.close(gate)
                try await wait("approval fixture") { FileManager.default.fileExists(atPath: directory.appendingPathComponent("approval-pending.json").path) }
            }
        }
        let completion = try value(directory.appendingPathComponent("turn-completed.json"))
        try check(completion["turns"] as? Int == 1 && completion["approvals"] as? Int == 1, "frontend recovery repeated a submission or approval")
        let saved = try RuntimeRecovery.pending()[0]
        try check(RuntimeRecovery.hasSavedRecord(saved), "normal session persistence did not produce recoverable native history")
        let turnFile = directory.appendingPathComponent("turns.json")
        let turnDate = try turnFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        kill(worker.processIdentifier, SIGKILL)
        await Task.detached { worker.waitUntilExit() }.value
        if let (pid, start) = providerIdentity {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_start_tvsec == start { kill(pid, SIGTERM) }
        }
        let coldWorker = try launch(workerArguments)
        try await wait("cold runtime") { (try? RuntimeChannel.connect(path: socketPath)).map { $0.close(); return true } ?? false }
        let session = Session(cwd: saved.cwd, stateDirectory: directory.appendingPathComponent("recovered-frontend"))
        let client = RuntimeClient(session: session, cwd: saved.cwd, resumeRuntimeID: saved.sessionID, socketPath: socketPath, recovery: saved)
        session.runtimeClient = client
        defer { client.close(); session.close() }
        try await client.connect(resume: nil)
        try await wait("cold history restored") { session.ready && session.rows.contains { $0.kind == "notice" && $0.items.contains { $0.text.contains("not replayed") } } }
        try check(session.rows.contains { $0.kind == "user" && $0.items.contains { ($0.data["content"] as? [JSON])?.contains { $0["text"] as? String == "recovery fixture submission" } == true } }, "cold recovery lost saved conversation rows")
        try check(session.draft.string.contains("recovery unsent draft") && draftContent(session.draft).count == 2, "cold recovery lost the durable unsent text or image")
        try check(!session.busy && session.permissions.isEmpty, "cold recovery treated interrupted work as still running")
        try check(try turnFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == turnDate, "cold recovery automatically replayed a tool-producing turn")
        try check(try RuntimeRecovery.pending().isEmpty, "live frontend was restored a second time")
        let missingSession = Session(cwd: saved.cwd, stateDirectory: directory.appendingPathComponent("missing-frontend"))
        let missingClient = RuntimeClient(session: missingSession, cwd: saved.cwd, resumeRuntimeID: UUID().uuidString, socketPath: socketPath)
        defer { missingClient.close(); missingSession.close() }
        var rejectedMissingSession = false
        do { try await missingClient.connect(resume: nil) } catch { rejectedMissingSession = true }
        try check(rejectedMissingSession, "a missing runtime session was silently recreated as an empty conversation")
        let closingFrontend = try launch(["--recovery-frontend", directory.path, socketPath, "closing"])
        let closingMilestone = directory.appendingPathComponent("closing-ready.json")
        try await wait("unacknowledged close intent") { FileManager.default.fileExists(atPath: closingMilestone.path) || !closingFrontend.isRunning }
        try check(closingFrontend.isRunning, "close-intent fixture exited before saving its intent")
        kill(closingFrontend.processIdentifier, SIGKILL)
        await Task.detached { closingFrontend.waitUntilExit() }.value
        try check(try RuntimeRecovery.pending().isEmpty, "a frontend that crashed after requesting close was reopened")
        try check(try await RuntimeRecovery.finishRequestedCloses() == 1, "startup did not finish the interrupted close request")
        try check(coldWorker.isRunning && client.isAttached, "finishing one close interrupted another session in its project runtime")
        try check(try turnFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == turnDate, "finishing a close replayed a model turn")
        _ = try await client.perform("close")
        client.close()
        try await wait("explicitly ended runtime") { !coldWorker.isRunning }
        try check(try RuntimeRecovery.pending().isEmpty, "explicit close resurrected an ended session")
        try check(!FileManager.default.fileExists(atPath: runtimeHome.appendingPathComponent("recovery/" + saved.sessionID + ".checkpoint.json").path), "explicit close retained a worker checkpoint")
        let registryID = UUID().uuidString
        let registryFile = runtimeHome.appendingPathComponent("recovery/" + registryID + ".window.json")
        var state: JSON = ["cwd": directory.path, "conversationDirectory": directory.path, "recordID": UUID().uuidString,
                           "draft": [["text": "submitted draft"]], "draftGeneration": 1]
        try RuntimeRecovery.saveWindow(sessionID: registryID, socketPath: socketPath, state: state, instanceID: "registry-fixture")
        var fileInfo = stat()
        try check(lstat(registryFile.path, &fileInfo) == 0 && fileInfo.st_mode & 0o777 == 0o600, "window recovery data was not private")
        try check(try RuntimeRecovery.pending().isEmpty, "a live frontend's recovery data was treated as a crash")
        func staleOwner() throws {
            var record = try value(registryFile)
            record["ownerStart"] = (record["ownerStart"] as? UInt64 ?? 0) + 1
            try write(record, to: registryFile)
        }
        try staleOwner()
        try check(try RuntimeRecovery.pending().count == 1, "a reused frontend PID hid an older crashed session")
        try RuntimeRecovery.saveCheckpoint(sessionID: registryID, state: ["cwd": directory.path, "draft": [], "draftGeneration": 1, "consumedGeneration": 1])
        try check((try RuntimeRecovery.pending()[0].state["draft"] as? [JSON])?.isEmpty == true, "a consumed submission draft was resurrected after a crash")
        state["draft"] = [["text": "newer unsent draft"]]; state["draftGeneration"] = 2
        try RuntimeRecovery.saveWindow(sessionID: registryID, socketPath: socketPath, state: state, instanceID: "registry-fixture")
        try staleOwner()
        try check((try RuntimeRecovery.pending()[0].state["draft"] as? [JSON])?.first?["text"] as? String == "newer unsent draft", "an unacknowledged newer local draft was lost after a crash")
        try RuntimeRecovery.requestClose(sessionID: registryID)
        try check(try RuntimeRecovery.pending().isEmpty, "a close request with a lost acknowledgment resurrected the window")
        try RuntimeRecovery.remove(sessionID: registryID)
        print("\(count) crash recovery checks passed")
        return count
    }
}
