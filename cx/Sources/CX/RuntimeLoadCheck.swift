import AppKit
import Darwin
import SwiftUI

@MainActor
enum RuntimeLoadCheck {
    private struct Sample {
        let cpu: UInt64
        let rss: UInt64
        init(_ pid: pid_t) throws {
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size) else {
                throw CXError(message: "Cannot sample a load-test process.")
            }
            cpu = info.pti_total_user + info.pti_total_system
            rss = info.pti_resident_size
        }
    }

    private static let rowsPerSession = 100
    private static let memoryLimit: UInt64 = 2 * 1024 * 1024 * 1024

    static func worker(socketPath: String, directory: URL) throws -> RuntimeServer {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard Settings.directory.path.hasPrefix(directory.path + "/") else { throw CXError(message: "Load worker requires isolated configuration.") }
        try FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var preferences = Preferences()
        preferences.provider = "codex"
        preferences.accounts = [Account(id: "load-fixture", name: "Load fixture", provider: "codex", home: directory.path)]
        try JSONEncoder().encode(preferences).write(to: Settings.directory.appendingPathComponent("settings.json"), options: .atomic)
        Settings.shared.reload()
        return RuntimeServer(socketPath: socketPath, build: RuntimeIdentity.build) { params in
            let session = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
            let connection = LoadConnection()
            session.connectionFactory = { _, _ in connection }
            let backend = SessionBackend(session: session)
            await backend.start(params: params)
            guard session.ready else { throw CXError(message: "Load fixture did not connect.") }
            for index in 0..<(rowsPerSession / 2) {
                session.show(["id": "history-user-\(index)", "type": "userMessage", "content": [["type": "text", "text": "Synthetic history question \(index)."]]])
                session.show(["id": "history-answer-\(index)", "type": "agentMessage", "text": String(repeating: "Synthetic transcript content for native view measurement. ", count: 8)])
            }
            return LoadBackend(backend: backend, connection: connection)
        }
    }

    static func run(reportPath: String) async throws -> Int {
        _ = RuntimeIdentity.build
        let root = URL(fileURLWithPath: "/tmp/vcx-load-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let process = ProcessInfo.processInfo
        var averages = [Double](repeating: 0, count: 3)
        let averageCount = getloadavg(&averages, 3)
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let environment: JSON = ["startedAt": ISO8601DateFormatter().string(from: Date()), "buildConfiguration": configuration,
                                 "activeProcessorCount": process.activeProcessorCount, "physicalMemoryBytes": process.physicalMemory,
                                 "lowPowerMode": process.isLowPowerModeEnabled, "thermalState": [0: "nominal", 1: "fair", 2: "serious", 3: "critical"][process.thermalState.rawValue] ?? "unknown",
                                 "systemLoadAverages": Array(averages.prefix(max(0, Int(averageCount)))),
                                 "latencyScope": "Observed on this Mac alongside its existing workload; not isolated hardware." ]
        var report: JSON = ["schema": 1, "provider": "deterministic in-process Connection", "providerProcesses": 0,
                            "realModelCostIncluded": false, "windowsDisplayed": false, "rowsPerSession": rowsPerSession,
                            "memoryLimitBytes": memoryLimit, "cpuPercentConvention": "100% is one CPU core",
                            "memoryConvention": "Sum of process resident sizes includes pages shared by frontend and worker; not incremental system physical memory.",
                            "environment": environment,
                            "streamWorkload": "10 synthetic deltas per second per active session throughout each 3.3-second sample; streams stop afterward with a 30-second safety cap.",
                            "handoffScope": "Two complete native view and client generations overlap in one frontend process. Excludes a second frontend process and its additional framework mappings; overlap RSS is not a real two-process update peak.",
                            "frontendScope": "Native Session, RuntimeClient, FleetPresence and initialized offscreen CXView hosting views; one view rasterized during stream phases. No compositor or Space transitions."]
        var results: [JSON] = [], checks = 0
        func save() throws {
            report["scenarios"] = results; report["checks"] = checks
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportPath)
        }
        do {
            for count in [20, 50, 100] {
                let result = try await scenario(count: count, directory: root.appendingPathComponent(String(count)), checks: &checks)
                results.append(result)
                try save()
                print("Load check: \(count) sessions completed")
            }
            report["status"] = "passed"
            report["completedAt"] = ISO8601DateFormatter().string(from: Date())
            try save()
            print("\(checks) load checks passed; report: \(reportPath)")
            return checks
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            try? save()
            throw error
        }
    }

    private static func scenario(count: Int, directory: URL, checks: inout Int) async throws -> JSON {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let worker = Process()
        worker.executableURL = Bundle.main.executableURL!
        let socketPath = directory.appendingPathComponent("worker.sock").path
        worker.arguments = ["--runtime-load-worker", socketPath, directory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["VCX_CONFIG_HOME"] = directory.appendingPathComponent("config").path
        environment["VCX_RUNTIME_HOME"] = directory.appendingPathComponent("runtime").path
        environment.removeValue(forKey: "BUILD_STACK_FD")
        worker.environment = environment
        worker.standardInput = FileHandle.nullDevice; worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
        try worker.run()
        var sessions: [Session] = [], clients: [RuntimeClient] = [], hosts: [NSView] = [], presences: [FleetPresence] = []
        defer {
            for presence in presences { presence.close() }
            hosts.removeAll()
            for client in clients { client.close() }
            for session in sessions { session.close() }
            if worker.isRunning {
                worker.terminate()
                let force = DispatchWorkItem { if worker.isRunning { kill(worker.processIdentifier, SIGKILL) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: force)
                worker.waitUntilExit(); force.cancel()
            }
        }
        func check(_ condition: Bool, _ message: String) throws {
            checks += 1
            guard condition else { throw CXError(message: "Load check: " + message) }
        }
        for attempt in 0..<100 {
            if FileManager.default.fileExists(atPath: socketPath) { break }
            guard worker.isRunning, attempt < 99 else { throw CXError(message: "Load worker did not start.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let baseline = try Sample(getpid()), workerBaseline = try Sample(worker.processIdentifier), startup = DispatchTime.now().uptimeNanoseconds
        var attachTimes: [Double] = []
        for index in 0..<count {
            let session = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("frontend"))
            let client = RuntimeClient(session: session, cwd: directory.path, socketPath: socketPath)
            session.runtimeClient = client
            sessions.append(session); clients.append(client); presences.append(FleetPresence(session: session))
            let start = DispatchTime.now().uptimeNanoseconds
            try await client.connect(resume: nil)
            attachTimes.append(milliseconds(since: start))
            try check(session.ready && session.rows.count == rowsPerSession, "session snapshot did not restore seeded history")
            let host = NSHostingView(rootView: CXView(session: session))
            host.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
            host.layoutSubtreeIfNeeded()
            hosts.append(host)
            if index % 10 == 0 { try check(try Sample(getpid()).rss + Sample(worker.processIdentifier).rss <= memoryLimit, "combined frontend and worker memory exceeded 2 GiB") }
        }
        try check(Set(clients.map(\.sessionID)).count == count, "sessions shared an identity")
        try check(NSApp.windows.allSatisfy { !$0.isVisible }, "load check displayed a window")
        let setupMilliseconds = milliseconds(since: startup)
        try await Task.sleep(nanoseconds: 300_000_000)
        var phases: [JSON] = []
        phases.append(try await phase(name: "session_and_native_view_setup", elapsed: milliseconds(since: startup) / 1000, frontBefore: baseline, frontAfter: Sample(getpid()), workerBefore: workerBaseline, workerAfter: Sample(worker.processIdentifier), childCPU: childCPU(clients[0]), frames: []))
        phases.append(try await measure(name: "idle", seconds: 2, worker: worker.processIdentifier, client: clients[0], host: nil))
        for client in clients.prefix(8) { _ = try await client.perform("send", ["text": "load-stream", "images": []]) }
        try await Task.sleep(nanoseconds: 250_000_000)
        phases.append(try await measure(name: "eight_streams_one_offscreen_raster", seconds: 3.3, worker: worker.processIdentifier, client: clients[0], host: hosts[0]))
        try check(sessions.prefix(8).allSatisfy(\.busy), "a measured stream ended before the sample completed")
        try await stopStreams(Array(clients.prefix(8)))
        try await settled(sessions)
        let revisions = sessions.map(\.revision)
        for client in clients { _ = try await client.perform("send", ["text": "load-stream", "images": []]) }
        try await Task.sleep(nanoseconds: 250_000_000)
        phases.append(try await measure(name: "all_streams_one_offscreen_raster", seconds: 3.3, worker: worker.processIdentifier, client: clients[0], host: hosts[0]))
        try check(sessions.allSatisfy(\.busy), "a measured stream ended before the sample completed")
        try await stopStreams(clients)
        try await settled(sessions)
        try check(zip(revisions, sessions).allSatisfy { $1.revision > $0 }, "some sessions did not receive streamed updates")
        try check(sessions.allSatisfy { $0.rows.flatMap(\.items).contains { $0.text.contains("load-token-") } }, "some session streams were lost")

        let refreshFront = try Sample(getpid()), refreshWorker = try Sample(worker.processIdentifier)
        let childBefore = try await childCPU(clients[0]), refreshStart = DispatchTime.now().uptimeNanoseconds
        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in clients { group.addTask { _ = try await client.perform("refreshRepository") } }
            try await group.waitForAll()
        }
        let refreshElapsed = milliseconds(since: refreshStart) / 1000
        let childAfter = try await childCPU(clients[0])
        phases.append(try phase(name: "all_session_repository_refresh", elapsed: refreshElapsed, frontBefore: refreshFront, frontAfter: Sample(getpid()), workerBefore: refreshWorker, workerAfter: Sample(worker.processIdentifier), childCPU: childAfter - childBefore, frames: []))

        let latency = try await withThrowingTaskGroup(of: (Double, Double).self, returning: [(Double, Double)].self) { group in
            for (index, client) in clients.enumerated() {
                let session = sessions[index]
                group.addTask { @MainActor in
                    let start = DispatchTime.now().uptimeNanoseconds
                    try await client.checkpoint(draft: [["text": "unsent load draft \(index)"]], generation: 10)
                    let ack = milliseconds(since: start)
                    for _ in 0..<400 where session.draftGeneration < 10 { try await Task.sleep(nanoseconds: 5_000_000) }
                    guard session.draftGeneration == 10 else { throw CXError(message: "A load-test projection did not catch up.") }
                    return (ack, milliseconds(since: start))
                }
            }
            var values: [(Double, Double)] = []
            for try await value in group { values.append(value) }
            return values
        }
        try check(latency.count == count, "latency sample did not cover every session")
        let previousClients = clients
        let replacements = try await withThrowingTaskGroup(of: (Int, Session, RuntimeClient, NSView, Double, FleetPresence).self, returning: [(Int, Session, RuntimeClient, NSView, Double, FleetPresence)].self) { group in
            for (index, previous) in previousClients.enumerated() {
                group.addTask { @MainActor in
                    let start = DispatchTime.now().uptimeNanoseconds
                    let session = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("replacement-frontend"))
                    let client = RuntimeClient(session: session, cwd: directory.path, resumeRuntimeID: previous.sessionID, socketPath: socketPath)
                    session.runtimeClient = client
                    let presence = FleetPresence(session: session)
                    let host = NSHostingView(rootView: CXView(session: session))
                    host.appearance = NSAppearance(named: .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
                    host.layoutSubtreeIfNeeded()
                    try await client.connect(resume: nil)
                    host.layoutSubtreeIfNeeded()
                    return (index, session, client, host, milliseconds(since: start), presence)
                }
            }
            var values: [(Int, Session, RuntimeClient, NSView, Double, FleetPresence)] = []
            for try await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }
        }
        let overlapFront = try Sample(getpid()), overlapWorker = try Sample(worker.processIdentifier)
        try check(replacements.count == count && previousClients.allSatisfy { !$0.isAttached }, "replacement did not fence every original writer")
        try check(overlapFront.rss + overlapWorker.rss <= memoryLimit, "overlapping frontends exceeded 2 GiB")
        for client in previousClients { client.close() }
        for presence in presences { presence.close() }
        sessions = replacements.map(\.1); clients = replacements.map(\.2); hosts = replacements.map(\.3)
        presences = replacements.map(\.5)
        try check(sessions.enumerated().allSatisfy { $0.element.draft.string == "unsent load draft \($0.offset)" }, "reattachment lost drafts")
        try check(clients.allSatisfy(\.isAttached), "a load-test session did not reattach")
        let front = try Sample(getpid()), backend = try Sample(worker.processIdentifier)
        try check(front.rss + backend.rss <= memoryLimit, "combined memory exceeded 2 GiB")
        return ["sessions": count, "nativeHostingViews": hosts.count, "providerProcesses": 0, "setupMs": setupMilliseconds,
                "frontendBaselineRSSBytes": baseline.rss, "frontendRSSBytes": front.rss, "workerRSSBytes": backend.rss,
                "combinedRSSBytes": front.rss + backend.rss, "attachReadyMs": distribution(attachTimes),
                "checkpointAckMs": distribution(latency.map(\.0)), "checkpointProjectionMs": distribution(latency.map(\.1)),
                "replacementAttachMs": distribution(replacements.map(\.4)),
                "handoffHostingViews": count * 2, "handoffOverlapRSSBytes": overlapFront.rss + overlapWorker.rss, "phases": phases]
    }

    private static func stopStreams(_ clients: [RuntimeClient]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in clients { group.addTask { _ = try await client.perform("stop") } }
            try await group.waitForAll()
        }
    }

    private static func settled(_ sessions: [Session]) async throws {
        for _ in 0..<400 {
            if sessions.allSatisfy({ !$0.busy }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CXError(message: "Synthetic streams did not finish.")
    }

    private static func measure(name: String, seconds: Double, worker: pid_t, client: RuntimeClient, host: NSView?) async throws -> JSON {
        let beforeFront = try Sample(getpid()), beforeWorker = try Sample(worker), beforeChild = try await childCPU(client)
        let start = DispatchTime.now().uptimeNanoseconds
        var frames: [Double] = []
        while milliseconds(since: start) < seconds * 1000 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let host {
                let frameStart = DispatchTime.now().uptimeNanoseconds
                try autoreleasepool {
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CXError(message: "Offscreen native frame could not render.") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                frames.append(milliseconds(since: frameStart))
            }
        }
        let elapsed = milliseconds(since: start) / 1000
        return try await phase(name: name, elapsed: elapsed, frontBefore: beforeFront, frontAfter: Sample(getpid()), workerBefore: beforeWorker, workerAfter: Sample(worker), childCPU: childCPU(client) - beforeChild, frames: frames)
    }

    private static func phase(name: String, elapsed: Double, frontBefore: Sample, frontAfter: Sample, workerBefore: Sample, workerAfter: Sample, childCPU: Double, frames: [Double]) throws -> JSON {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0,
              frontAfter.cpu >= frontBefore.cpu, workerAfter.cpu >= workerBefore.cpu, childCPU >= 0 else { throw CXError(message: "Invalid load-test CPU counters.") }
        let frontCPU = Double(frontAfter.cpu - frontBefore.cpu) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        let workerCPU = Double(workerAfter.cpu - workerBefore.cpu) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        return ["name": name, "wallSeconds": elapsed, "frontendCPUSeconds": frontCPU, "workerCPUSeconds": workerCPU,
                "workerChildCPUSeconds": childCPU, "totalCPUPercent": (frontCPU + workerCPU + childCPU) / elapsed * 100,
                "frontendCPUPercent": frontCPU / elapsed * 100, "workerCPUPercent": workerCPU / elapsed * 100,
                "frontendRSSBytes": frontAfter.rss, "workerRSSBytes": workerAfter.rss,
                "rasterizedFrames": frames.count, "offscreenRasterMs": distribution(frames)]
    }

    private static func childCPU(_ client: RuntimeClient) async throws -> Double {
        try await client.perform("loadStats")["childCPUSeconds"] as? Double ?? 0
    }

    private static func milliseconds(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    private static func distribution(_ values: [Double]) -> JSON {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return ["samples": 0] }
        func percentile(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)] }
        return ["samples": sorted.count, "p50": percentile(0.5), "p95": percentile(0.95), "max": sorted.last!]
    }

    private final class LoadBackend: RuntimeBackend {
        let backend: SessionBackend
        let connection: LoadConnection
        var onChange: ((JSON) -> Void)? { get { backend.onChange } set { backend.onChange = newValue } }
        init(backend: SessionBackend, connection: LoadConnection) { self.backend = backend; self.connection = connection }
        func snapshot() -> JSON { backend.snapshot() }
        func perform(action: String, params: JSON) async throws -> JSON {
            if action == "loadStats" {
                var usage = rusage()
                guard getrusage(RUSAGE_CHILDREN, &usage) == 0 else { throw CXError(message: "Cannot sample worker child CPU.") }
                return ["childCPUSeconds": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000]
            }
            return try await backend.perform(action: action, params: params)
        }
        func close() { backend.close() }
    }

    private final class LoadConnection: Connection {
        var event: (JSON) -> Void = { _ in }
        private let threadID = "load-" + UUID().uuidString
        private var stream: Task<Void, Never>?
        func start(command: [String]?) async throws {}
        func request(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON {
            switch method {
            case "thread/start", "thread/resume": return ["thread": ["id": threadID], "model": "load-fixture"]
            case "thread/list", "thread/turns/list", "model/list": return ["data": []]
            case "turn/start", "turn/steer":
                let turn = UUID().uuidString, item = UUID().uuidString
                event(["method": "turn/started", "params": ["threadId": threadID, "turn": ["id": turn]]])
                stream = Task { [weak self] in
                    guard let self else { return }
                    for index in 0..<300 {
                        do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                        event(["method": "item/agentMessage/delta", "params": ["threadId": threadID, "itemId": item, "delta": "load-token-\(index) "]])
                    }
                    event(["method": "turn/completed", "params": ["threadId": threadID, "turn": ["id": turn, "status": "completed"]]])
                    stream = nil
                }
                return ["turn": ["id": turn]]
            case "turn/interrupt": stream?.cancel(); stream = nil; event(["method": "turn/completed", "params": ["threadId": threadID, "turn": ["status": "interrupted"]]]); return [:]
            default: return [:]
            }
        }
        func respond(_ id: Any, _ result: JSON) throws {}
        func reject(_ id: Any, method: String) throws {}
        func close() { stream?.cancel(); stream = nil; event = { _ in } }
    }
}
