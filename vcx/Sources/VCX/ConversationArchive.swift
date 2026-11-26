import Foundation

enum ConversationArchive {
    struct Resolution {
        let id: String
        var source: NativeSource?
    }
    private static var script: URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("conversation_archive.py")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("conversation_archive.py")
    }

    static func call(_ action: String, state: URL, values: JSON = [:]) throws -> JSON {
        var request = values
        request["action"] = action; request["state"] = state.path
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let result = try JSONSerialization.jsonObject(with: data) as? JSON,
              result["ok"] as? Bool == true else { throw VCXError(message: "Could not archive or restore the conversation. Existing history has been retained.") }
        return result
    }

    static func records(state: URL) async throws -> [JSON] {
        try await Task.detached { try call("list", state: state)["records"] as? [JSON] ?? [] }.value
    }

    static func record(_ id: String, state: URL) async throws -> JSON? {
        try await Task.detached { try call("read", state: state, values: ["id": id])["record"] as? JSON }.value
    }

    static func resolve(_ id: String, state: URL) async throws -> Resolution? {
        let result = try await Task.detached { try call("resolve", state: state, values: ["id": id]) }.value
        guard let canonical = result["id"] as? String else { return nil }
        return Resolution(id: canonical, source: (result["source"] as? JSON).flatMap(NativeSource.init))
    }

    static func restore(_ id: String, state: URL, preserveDraft: Bool = false) async throws {
        _ = try await Task.detached { try call("restore", state: state, values: ["id": id, "preserveDraft": preserveDraft]) }.value
    }

    static func sourceFiles(_ sources: [NativeSource], state: URL) async throws -> [String] {
        try await Task.detached { try call("sourceFiles", state: state, values: ["sources": sources.map(\.json)])["paths"] as? [String] ?? [] }.value
    }

    static func archive(path: URL, state: URL, sources: [NativeSource], owned: [NativeSource], clientVersions: [String: String], childExited: Bool, fixtureRoot: String? = nil) async throws {
        var values: JSON = ["recordPath": path.path, "nativeSources": sources.map(\.json), "ownedSources": owned.map(\.json), "pruneProviders": ["claude", "codex", "agy", "qwen"]]
        values["clientVersions"] = clientVersions
        values["childExited"] = childExited
        values["syntheticFixtureRoot"] = fixtureRoot
        _ = try await Task.detached { try call("archive", state: state, values: values) }.value
    }
}
