import CryptoKit
import Darwin
import Foundation

struct NativeSource {
    let provider: String
    let home: String
    let threadID: String
    var path: String?
    var pendingCreation: Bool
    var managed: Bool
    var clientVersion: String?
    var accountID: String?

    init(provider: String, home: String, threadID: String, path: String? = nil, pendingCreation: Bool = false, managed: Bool = false) {
        self.provider = provider
        self.home = (try? canonicalArchiveRoot(URL(fileURLWithPath: home)))?.path ?? home
        let raw = threadID.split(separator: ":").last.map(String.init) ?? threadID
        self.threadID = UUID(uuidString: raw)?.uuidString.lowercased() ?? raw
        self.path = path
        self.pendingCreation = pendingCreation
        self.managed = managed
    }

    init?(_ value: JSON) {
        guard let provider = value["provider"] as? String, let home = value["home"] as? String,
              let thread = value["threadId"] as? String else { return nil }
        self.init(provider: provider, home: home, threadID: thread, path: value["nativeHistoryPath"] as? String, pendingCreation: value["pendingCreation"] as? Bool ?? false, managed: value["managed"] as? Bool ?? false)
        clientVersion = value["clientVersion"] as? String
        accountID = value["accountId"] as? String
    }

    var key: String { SHA256.hash(data: Data((provider + "\0" + home + "\0" + threadID).utf8)).map { String(format: "%02x", $0) }.joined() }
    var json: JSON {
        var value: JSON = ["provider": provider, "home": home, "threadId": threadID, "pendingCreation": pendingCreation, "managed": managed]
        value["nativeHistoryPath"] = path
        value["clientVersion"] = clientVersion
        value["accountId"] = accountID
        return value
    }
}

func nativeClientVersion(_ provider: String, environment: [String: String]) async -> String? {
    await Task.detached {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [provider, "--version"]; process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let versionTimeout: TimeInterval = 5, maximumVersionBytes = 4096
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + versionTimeout, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0, !data.isEmpty, data.count <= maximumVersionBytes else { return nil }
        guard let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return nil }
        return version
    }.value
}

final class NativeThreadLease {
    let source: NativeSource
    let descriptor: Int32
    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["VCX_NATIVE_LOCK_HOME"] ?? NSHomeDirectory() + "/.local/state/cx/native-locks", isDirectory: true)
    }

    init(_ source: NativeSource) throws {
        self.source = source
        guard try canonicalArchiveRoot(URL(fileURLWithPath: source.home)).path == source.home else { throw CXError(message: "Could not resolve the native conversation home.") }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(Self.directory.appendingPathComponent(source.key + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CXError(message: "Could not open the native conversation lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw CXError(message: "This native conversation is already open in another window. Use that window, or start a new conversation here.")
        }
        descriptor = fd
    }

    init(adopting source: NativeSource, descriptor: Int32) {
        self.source = source; self.descriptor = descriptor
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    var swapState: JSON { ["source": source.json, "descriptor": Int(descriptor)] }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
