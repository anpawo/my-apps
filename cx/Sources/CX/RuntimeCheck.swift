import AppKit
import Darwin

@MainActor
enum RuntimeCheck {
    static func run() async throws -> Int {
        let directory = URL(fileURLWithPath: "/tmp/vcx-runtime-check-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let resource = Bundle.main.resourceURL
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests")
        func fixture(_ name: String) throws -> URL {
            for root in [resource, sources] {
                if let path = root?.appendingPathComponent(name), FileManager.default.fileExists(atPath: path.path) { return path }
            }
            throw CXError(message: "Runtime continuity fixture is missing: " + name)
        }
        let peer = try fixture("runtime_peer.py"), probe = try fixture("runtime_probe.py")
        let command = directory.appendingPathComponent("command.json")
        try JSONSerialization.data(withJSONObject: ["/usr/bin/python3", peer.path, directory.path]).write(to: command, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: command.path)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("attachment.png"))
        guard mkfifo(directory.appendingPathComponent("release-tool").path, 0o600) == 0 else { throw CXError(message: "Cannot create runtime continuity fixture gate.") }

        let worker = Process(), client = Process(), output = Pipe()
        worker.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        worker.arguments = ["--runtime-worker", directory.appendingPathComponent("worker.sock").path, "--runtime-test", "--runtime-fixture-command", command.path]
        var environment = ProcessInfo.processInfo.environment
        environment["VCX_RUNTIME_HOME"] = directory.appendingPathComponent("runtime").path
        environment["VCX_CONFIG_HOME"] = directory.appendingPathComponent("config").path
        worker.environment = environment
        worker.standardInput = FileHandle.nullDevice
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        try worker.run()
        defer {
            for process in [client, worker] where process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                let force = DispatchWorkItem { kill(pid, SIGKILL) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: force)
                process.waitUntilExit()
                force.cancel()
            }
        }

        client.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        client.arguments = [probe.path, directory.appendingPathComponent("worker.sock").path, directory.path]
        client.standardInput = FileHandle.nullDevice
        client.standardOutput = output
        client.standardError = FileHandle.nullDevice
        try client.run()
        let timeout = DispatchWorkItem {
            if client.isRunning { client.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: timeout)
        defer { timeout.cancel() }
        let result = await Task.detached {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            client.waitUntilExit()
            return (client.terminationStatus, data)
        }.value
        let report = (try? JSONSerialization.jsonObject(with: result.1)) as? JSON
        guard result.0 == 0, let count = report?["checks"] as? Int, count > 0 else {
            throw CXError(message: "Runtime continuity failed: " + (report?["error"] as? String ?? "probe exited without a result"))
        }
        let sessionData = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        guard let sessionID = ((try JSONSerialization.jsonObject(with: sessionData)) as? JSON)?["sessionId"] as? String else { throw CXError(message: "Runtime continuity session identity is missing.") }
        let session = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("frontend"))
        let frontend = RuntimeClient(session: session, cwd: directory.path, resumeRuntimeID: sessionID, socketPath: directory.appendingPathComponent("worker.sock").path)
        defer { frontend.close(); session.close() }
        var total = count
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CXError(message: "Runtime client continuity failed: " + message) }
            total += 1
        }
        try await frontend.connect(resume: nil)
        try check(session.threadID == "runtime-fixture-thread" && !session.busy, "snapshot did not restore completed thread")
        try check(session.draftGeneration == 1 && draftContent(session.draft).count == 2, "snapshot did not restore the text and image draft")
        let rows = session.rows, items = session.rows.flatMap(\.items), revision = session.revision
        try await frontend.checkpoint(draft: [["text": "newer fixture draft"]], generation: 2)
        for _ in 0..<100 where session.draftGeneration < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(session.draftGeneration == 2 && session.draft.string == "newer fixture draft" && session.revision > revision, "ordered checkpoint update did not reach projection")
        try await frontend.checkpoint(draft: [["text": "older fixture draft"]], generation: 1)
        try check(session.draftGeneration == 2 && session.draft.string == "newer fixture draft", "older checkpoint replaced newer draft")
        try check(zip(rows, session.rows).allSatisfy { $0 === $1 } && rows.count == session.rows.count, "checkpoint replaced row objects")
        try check(zip(items, session.rows.flatMap(\.items)).allSatisfy { $0 === $1 } && items.count == session.rows.flatMap(\.items).count, "checkpoint replaced item objects")
        let fleetDirectory = directory.appendingPathComponent("fleet-check")
        let fleetFirst = Session(cwd: directory.path, stateDirectory: fleetDirectory)
        let fleetSecond = Session(cwd: directory.path, stateDirectory: fleetDirectory)
        let firstPresence = FleetPresence(session: fleetFirst), secondPresence = FleetPresence(session: fleetSecond)
        defer { firstPresence.close(); secondPresence.close(); fleetFirst.close(); fleetSecond.close() }
        let fleetFile = fleetDirectory.appendingPathComponent("fleet/\(getpid()).json")
        func fleetRecords() throws -> [JSON] {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: fleetFile)) as? JSON
            return value?["sessions"] as? [JSON] ?? []
        }
        let records = try fleetRecords()
        try check(records.count == 2 && Set(records.compactMap { $0["sessionId"] as? String }).count == 2, "Fleet did not retain two distinct session records")
        firstPresence.close()
        try check(try fleetRecords().count == 1, "closing one Fleet session removed its sibling")
        secondPresence.close()
        try check(!FileManager.default.fileExists(atPath: fleetFile.path), "closing the last Fleet session left a stale process record")
        let previousHome = ProcessInfo.processInfo.environment["VCX_RUNTIME_HOME"]
        setenv("VCX_RUNTIME_HOME", directory.appendingPathComponent("tickets").path, 1)
        defer {
            if let previousHome { setenv("VCX_RUNTIME_HOME", previousHome, 1) }
            else { unsetenv("VCX_RUNTIME_HOME") }
        }
        func reject(_ message: String, _ action: () throws -> Void) throws {
            var rejected = false
            do { try action() } catch { rejected = true }
            try check(rejected, message)
        }
        let ticket = try RuntimeUpdate.writeTicket(["windows": [], "fixture": true], suffix: ".restore.json")
        var info = stat()
        try check(lstat(ticket.path, &info) == 0 && info.st_uid == getuid() && info.st_mode & 0o777 == 0o600, "handoff ticket is not private and owned")
        try check((try RuntimeUpdate.readTicket(ticket.path, suffix: ".restore.json"))["fixture"] as? Bool == true, "valid handoff ticket did not round trip")
        try reject("handoff accepted the wrong ticket type") { _ = try RuntimeUpdate.readTicket(ticket.path, suffix: ".open.json") }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ticket.path)
        try reject("handoff accepted public permissions") { _ = try RuntimeUpdate.readTicket(ticket.path, suffix: ".restore.json") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ticket.path)
        let link = ticket.deletingLastPathComponent().appendingPathComponent("link.restore.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ticket)
        try reject("handoff accepted a symlink") { _ = try RuntimeUpdate.readTicket(link.path, suffix: ".restore.json") }
        let outside = directory.appendingPathComponent("outside.restore.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        try reject("handoff accepted a file outside its private folder") { _ = try RuntimeUpdate.readTicket(outside.path, suffix: ".restore.json") }
        try Data("{".utf8).write(to: ticket)
        try reject("handoff accepted corrupt JSON") { _ = try RuntimeUpdate.readTicket(ticket.path, suffix: ".restore.json") }
        try Data(repeating: 32, count: 1_048_577).write(to: ticket)
        try reject("handoff accepted an oversized file") { _ = try RuntimeUpdate.readTicket(ticket.path, suffix: ".restore.json") }
        try reject("handoff wrote an oversized payload") { _ = try RuntimeUpdate.writeTicket(["text": String(repeating: "x", count: 1_048_576)], suffix: ".restore.json") }
        try await Task.sleep(nanoseconds: 300_000_000)
        func cpuTicks() throws -> UInt64 {
            var task = proc_taskinfo()
            guard proc_pidinfo(worker.processIdentifier, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size) else { throw CXError(message: "Cannot sample runtime worker CPU time.") }
            return task.pti_total_user + task.pti_total_system
        }
        let beforeCPU = try cpuTicks(), beforeWall = DispatchTime.now().uptimeNanoseconds
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let afterWall = DispatchTime.now().uptimeNanoseconds, afterCPU = try cpuTicks()
        var timebase = mach_timebase_info_data_t()
        try check(mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom > 0 && afterCPU >= beforeCPU, "idle CPU counters were invalid")
        let cpuNanoseconds = Double(afterCPU - beforeCPU) * Double(timebase.numer) / Double(timebase.denom)
        let elapsedNanoseconds = Double(afterWall - beforeWall)
        print(String(format: "Idle worker sample: %.3f ms CPU / %.3f s wall (%.3f%% of one core)", cpuNanoseconds / 1_000_000, elapsedNanoseconds / 1_000_000_000, cpuNanoseconds / elapsedNanoseconds * 100))
        print("\(total) runtime continuity checks passed")
        return total
    }
}
