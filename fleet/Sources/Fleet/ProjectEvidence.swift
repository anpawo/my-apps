import Foundation

struct ProjectEvidence {
    struct Action: Codable, Equatable {
        var path: String
        var kind: String
    }

    private static let maximumActions = 64
    private static let maximumPromptCharacters = 8000
    private static let maximumPrompts = 8
    private var pending: [String: (String, [String: Any])] = [:]
    var prompt = ""
    var prompts: [String] = []
    var actions: [Action] = []

    mutating func userPrompt(_ text: String) {
        guard !text.hasPrefix("# AGENTS.md"), !text.hasPrefix("<environment_context>"),
              !text.hasPrefix("<task-notification>"), !text.hasPrefix("<system-reminder>") else { return }
        let task = text.components(separatedBy: "VCX note, not part of the request:")[0]
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        prompt = String(task.prefix(Self.maximumPromptCharacters))
        if prompts.last != prompt { prompts.append(prompt) }
        if prompts.count > Self.maximumPrompts { prompts.remove(at: 1) }
        actions = []
    }

    mutating func ingest(_ object: [String: Any]) {
        if object["isMeta"] as? Bool == true || object["isSidechain"] as? Bool == true ||
            object["isCompactSummary"] as? Bool == true || object["queueTranscriptOnly"] as? Bool == true { return }
        if let payload = object["payload"] as? [String: Any] {
            ingestCodex(payload)
            return
        }
        guard let message = object["message"] as? [String: Any] else { return }
        if let text = message["content"] as? String, object["type"] as? String == "user" {
            userPrompt(text)
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        if object["type"] as? String == "user" {
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { userPrompt(text) }
        }
        for block in blocks {
            if block["type"] as? String == "tool_use", let id = block["id"] as? String {
                pending[id] = (block["name"] as? String ?? "", block["input"] as? [String: Any] ?? [:])
            }
            if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
               let call = pending.removeValue(forKey: id), block["is_error"] as? Bool != true {
                completed(name: call.0, input: call.1)
            }
        }
    }

    private mutating func ingestCodex(_ payload: [String: Any]) {
        let type = payload["type"] as? String ?? ""
        if type == "message", payload["role"] as? String == "user" {
            let blocks = payload["content"] as? [[String: Any]] ?? []
            userPrompt(blocks.compactMap { $0["text"] as? String }.joined(separator: "\n"))
        } else if type == "function_call", let id = payload["call_id"] as? String,
                  let args = payload["arguments"] as? String,
                  let input = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any] {
            pending[id] = (payload["name"] as? String ?? "", input)
        } else if type == "custom_tool_call", let id = payload["call_id"] as? String,
                  let patch = payload["input"] as? String {
            pending[id] = (payload["name"] as? String ?? "", ["patch": patch])
        } else if ["function_call_output", "custom_tool_call_output"].contains(type), let id = payload["call_id"] as? String,
                  let call = pending.removeValue(forKey: id), let output = payload["output"] as? String {
            // A returned call can still be a running process or a failed command.
            let result = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
            let metadata = result?["metadata"] as? [String: Any]
            if (result?["exit_code"] as? Int ?? metadata?["exit_code"] as? Int) == 0 ||
                output.hasPrefix("Process exited with code 0\n") || output.hasPrefix("Wall time:") &&
                output.components(separatedBy: "\n").contains("Process exited with code 0") {
                completed(name: call.0, input: call.1)
            }
        }
    }

    mutating func nativeItem(_ item: [String: Any]) {
        guard item["status"] as? String == "completed" else { return }
        if item["type"] as? String == "fileChange" {
            for change in item["changes"] as? [[String: Any]] ?? [] {
                if let path = change["path"] as? String { append(path, kind: "edit") }
            }
        } else if item["type"] as? String == "commandExecution", (item["exitCode"] as? Int ?? 0) == 0,
                  let command = item["command"] as? String {
            let parts = command.split(separator: "\n", maxSplits: 1).map(String.init)
            if parts.count == 2, let input = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] {
                completed(name: parts[0], input: input)
            } else { completed(name: "shell", input: ["command": command]) }
        }
    }

    private mutating func completed(name: String, input: [String: Any]) {
        let name = name.components(separatedBy: ".").last ?? name
        if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name),
           let path = (input["file_path"] ?? input["notebook_path"]) as? String {
            append(path, kind: "edit")
        } else if name == "apply_patch", let patch = (input["patch"] ?? input["input"]) as? String {
            let prefixes = ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "]
            for line in patch.components(separatedBy: "\n") {
                if let prefix = prefixes.first(where: line.hasPrefix) { append(String(line.dropFirst(prefix.count)), kind: "edit") }
            }
        } else if ["Bash", "shell", "exec_command"].contains(name),
                  let command = (input["command"] ?? input["cmd"]) as? String,
                  let path = Self.directoryChange(command) { append(path, kind: "directory") }
    }

    private mutating func append(_ path: String, kind: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return }
        actions.append(Action(path: (expanded as NSString).standardizingPath, kind: kind))
        if actions.count > Self.maximumActions { actions.removeFirst() }
    }

    static func directoryChange(_ command: String) -> String? {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("cd "), !text.contains("\n") else { return nil }
        var path = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("-- ") { path = String(path.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        if let quote = path.first, ["\"", "'"].contains(quote), path.last == quote { path = String(path.dropFirst().dropLast()) }
        else if path.contains(where: \.isWhitespace) { return nil }
        guard !path.isEmpty, !path.contains(where: { ";&|()<>$`*?[]{}\\\"'".contains($0) }) else { return nil }
        return path
    }
}

final class NativeProjectEvidence {
    private var cache: [String: (Date, Int, ProjectEvidence)] = [:]

    func read(_ path: String, root: String, refreshing: Bool = true) -> ProjectEvidence? {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let allowed = URL(fileURLWithPath: root + "/native").resolvingSymlinksInPath().path
        guard canonical.hasPrefix(allowed + "/"), canonical.hasSuffix(".json") else { return nil }
        if !refreshing { return cache[canonical]?.2 }
        guard
              let attrs = try? FileManager.default.attributesOfItem(atPath: canonical),
              let stamp = attrs[.modificationDate] as? Date, let size = attrs[.size] as? Int else { return nil }
        if let hit = cache[canonical], hit.0 == stamp, hit.1 == size { return hit.2 }
        guard let data = FileManager.default.contents(atPath: canonical),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return cache[canonical]?.2 }
        var evidence = ProjectEvidence()
        for row in object["rows"] as? [[String: Any]] ?? [] {
            for item in row["items"] as? [[String: Any]] ?? [] {
                if row["kind"] as? String == "user" {
                    let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    evidence.userPrompt(text)
                } else if row["kind"] as? String == "activity" { evidence.nativeItem(item) }
            }
        }
        cache[canonical] = (stamp, size, evidence)
        return evidence
    }

    func retain(paths: Set<String>) { cache = cache.filter { paths.contains($0.key) } }
}
