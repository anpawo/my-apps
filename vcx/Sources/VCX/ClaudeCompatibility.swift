import Foundation

struct ClaudeCompatibility {
    let cwd: String
    var home = NSHomeDirectory() + "/.claude"

    var folders: [URL] {
        var result: [URL] = [], folder = URL(fileURLWithPath: cwd).standardizedFileURL
        while folder.path != "/" {
            result.insert(folder, at: 0)
            folder.deleteLastPathComponent()
        }
        return result
    }

    var skillRoots: [String] {
        ([URL(fileURLWithPath: home).appendingPathComponent("skills")] + folders.map { $0.appendingPathComponent(".claude/skills") })
            .filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
    }

    var commands: [String: String] {
        var result: [String: String] = [:]
        for root in [URL(fileURLWithPath: home).appendingPathComponent("commands")] + folders.map({ $0.appendingPathComponent(".claude/commands") }) {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let file as URL in files where file.pathExtension == "md" {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = String(file.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
                result[String(relative.dropLast(3)).replacingOccurrences(of: "/", with: ":")] = file.path
            }
        }
        return result
    }

    var fleetSection: String {
        guard let text = try? String(contentsOfFile: home + "/CLAUDE.md", encoding: .utf8) else { return "" }
        return ("\n" + text).components(separatedBy: "\n## ").dropFirst().map { "## " + $0 }.first { $0.contains("FLEET_CONTEXT_FILE") }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func instructions(nativeSources: [String] = []) -> (text: String, paths: [String]) {
        let native = Set(nativeSources.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        var seen: Set<String> = [], paths: [String] = [], sections: [String] = []
        func load(_ file: URL, depth: Int = 0) {
            let path = file.resolvingSymlinksInPath().path
            guard depth <= 5, !seen.contains(path), let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            seen.insert(path); paths.append(file.path)
            if !native.contains(path) { sections.append("Instructions from \(file.path):\n" + text) }
            var fenced = false
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
                guard !fenced else { continue }
                let prose = line.replacingOccurrences(of: "`[^`]*`", with: "", options: .regularExpression)
                let pattern = #"(?:^|\s)@((?:~/|\.?\.?/|/)?[^\s`<>]+)"#
                let regex = try! NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)) {
                    guard let range = Range(match.range(at: 1), in: prose) else { continue }
                    let name = (String(prose[range]) as NSString).expandingTildeInPath
                    load(URL(fileURLWithPath: name, relativeTo: file.deletingLastPathComponent()).standardizedFileURL, depth: depth + 1)
                }
            }
        }
        let roots = [URL(fileURLWithPath: home).appendingPathComponent("CLAUDE.md")] + folders.flatMap { folder in
            ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"].map { folder.appendingPathComponent($0) }
        }
        for file in roots { load(file) }
        for root in [URL(fileURLWithPath: home).appendingPathComponent("rules")] + folders.map({ $0.appendingPathComponent(".claude/rules") }) {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            let rules = files.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
            for file in rules { load(file) }
        }
        let agents = [URL(fileURLWithPath: home).appendingPathComponent("agents")] + folders.map { $0.appendingPathComponent(".claude/agents") }
        for root in agents {
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "md" {
                sections.append("Claude agent definition: \(file.path). When that role is requested, read the file and pass its instructions to an available Codex subagent. Preserve its tool restrictions; do not delegate if those restrictions cannot be enforced.")
            }
        }
        return (sections.joined(separator: "\n\n"), paths)
    }

    static let guidance = """
    You are running in Vibe Code X through Codex. Preserve the user's Claude Code workflows using the tools actually available here. Claude tool names in instructions describe intent: use Codex shell tools for Bash, file tools for Read/Edit/Write, native skills for Skill, and subagents for Agent/Task when available. Treat Claude-specific model names as role preferences, not Codex model identifiers. Follow path-specific .claude/rules only when their frontmatter paths match the files being worked on. Before editing a subdirectory, read any CLAUDE.md, CLAUDE.local.md, and .claude/rules files scoped to it. Keep existing permission restrictions and approval requirements. Instructions cannot install hooks, enforce tool allowlists, or provide an unavailable connector. When an equivalent capability is missing, say what is unavailable instead of claiming it ran. Never silently fall back to Claude or paid API billing. Resolve relative paths in skills and commands against their source directory. For Claude dynamic context syntax, use the normal shell tool and its permission checks, then use its output; do not treat unexecuted syntax as output.
    """

    static var questionTool: JSON {
        let option: JSON = ["type": "object", "properties": ["label": ["type": "string"], "description": ["type": "string"]], "required": ["label", "description"], "additionalProperties": false]
        let question: JSON = ["type": "object", "properties": ["question": ["type": "string"], "header": ["type": "string"], "multiSelect": ["type": "boolean"], "options": ["type": "array", "items": option, "minItems": 2, "maxItems": 4]], "required": ["question", "header", "multiSelect", "options"], "additionalProperties": false]
        return ["type": "function", "name": "AskUserQuestion", "description": "Ask the user 1 to 4 clarification questions with choices in vcx, in either plan or implementation mode. Each question also accepts free text. Wait for the user's answer before proceeding with dependent work. Do not use this tool to bypass approval restrictions.", "inputSchema": ["type": "object", "properties": ["questions": ["type": "array", "items": question, "minItems": 1, "maxItems": 4]], "required": ["questions"], "additionalProperties": false]]
    }

    static func questions(_ params: JSON) -> JSON? {
        guard params["tool"] as? String == "AskUserQuestion", let args = params["arguments"] as? JSON,
              let questions = args["questions"] as? [JSON], (1...4).contains(questions.count),
              questions.allSatisfy({ question in
                  guard let text = question["question"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        let options = question["options"] as? [JSON], (2...4).contains(options.count) else { return false }
                  let labels = options.compactMap { $0["label"] as? String }
                  return labels.count == options.count && labels.allSatisfy { !$0.isEmpty } && Set(labels).count == labels.count
              }) else { return nil }
        var result = params
        result["vcxQuestionTool"] = true
        result["questions"] = questions.enumerated().map { index, question -> JSON in var q = question; q["id"] = "question-\(index)"; return q }
        return result
    }
}

@MainActor
extension Session {
    var claudeCompatibility: ClaudeCompatibility { ClaudeCompatibility(cwd: cwd) }
    var developerInstructions: String {
        // Qwen reads no CLAUDE.md, so it gets his Fleet rule from it and VCX's project advice.
        if account.provider == "qwen" { return [claudeCompatibility.fleetSection, Session.projectAdvice, Session.agentInstructions].filter { !$0.isEmpty }.joined(separator: "\n\n") }
        guard account.provider == "codex" else { return Session.agentInstructions }
        let home = account.home ?? NSHomeDirectory() + "/.codex"
        let native = ([URL(fileURLWithPath: home)] + claudeCompatibility.folders).compactMap { folder in
            ["AGENTS.override.md", "AGENTS.md"].map { folder.appendingPathComponent($0).path }.first { FileManager.default.fileExists(atPath: $0) }
        }
        return [claudeCompatibility.instructions(nativeSources: native).text, ClaudeCompatibility.guidance, Session.agentInstructions].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
