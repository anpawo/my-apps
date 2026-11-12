import Foundation

func shellDirectory(_ item: JSON, current: String, initial: String, added: [String] = addedDirectories()) -> String? {
    guard item["type"] as? String == "commandExecution", item["status"] as? String == "completed",
          (item["exitCode"] as? Int ?? 0) == 0 else { return nil }
    let base = item["cwd"] as? String ?? current
    guard base.hasPrefix("/") else { return nil }
    var words = literalShellWords(item["command"] as? String ?? "")
    if let shell = words, shell.count == 3, ["sh", "bash", "zsh"].contains(URL(fileURLWithPath: shell[0]).lastPathComponent),
       ["-c", "-lc", "-ic", "-ilc"].contains(shell[1]) { words = literalShellWords(shell[2]) }
    let target: String
    if let words, words.first == "cd", words.count == 2 || (words.count == 3 && words[1] == "--") {
        let path = words.last!
        guard path != "-", !path.hasPrefix("~") || path == "~" || path.hasPrefix("~/") else { return nil }
        target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                     relativeTo: URL(fileURLWithPath: base, isDirectory: true)).standardized.path
    } else { return nil }
    return ([initial] + added).lazy.compactMap { workingDirectory(target, within: $0) }.first
}

/// Claude Code keeps a cd that ends in one of these too (~/self): a session launched in
/// ai-research that cd'd to s14 kept ai-research in its bar while Fleet filed it under s14 (asked 2026-11-09).
func addedDirectories() -> [String] {
    guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/settings.json"),
          let settings = try? JSONSerialization.jsonObject(with: data) as? JSON else { return [] }
    return (settings["permissions"] as? JSON)?["additionalDirectories"] as? [String] ?? []
}

/// The project a turn edited files in: the git root (or the `.fleet` sub-folder) edited most, the latest on a tie.
/// nil when none, or when the session already stands in it. A session launched in m3-labs that worked in s14 stayed
/// under m3-labs in Fleet (asked 2026-11-10); reads and commands do not count, a cer session that read Fleet's code
/// to answer a question moved to my-apps (same day: "it shouldn't change that much the current focused dir").
func turnDirectory(_ commands: [String], current: String, initial: String, added: [String] = addedDirectories()) -> String? {
    var counts: [String: (count: Int, last: Int)] = [:], roots: [String: String?] = [:]
    for (n, path) in commands.compactMap(editedPath).enumerated() {
        let parent = (path as NSString).deletingLastPathComponent
        if roots[parent] == nil { roots[parent] = projectRoot(path) }
        guard let root = roots[parent] ?? nil, ([initial] + added).contains(where: { workingDirectory(root, within: $0) != nil })
        else { continue }
        counts[root] = ((counts[root]?.count ?? 0) + 1, n)
    }
    guard let best = counts.max(by: { ($0.value.count, $0.value.last) < ($1.value.count, $1.value.last) })?.key,
          current != best, !current.hasPrefix(best + "/") else { return nil }
    return best
}

/// The file of a Claude Edit/Write call, shown as its tool name over its JSON input (`Agents.swift`).
func editedPath(_ command: String) -> String? {
    let parts = command.split(separator: "\n", maxSplits: 1)
    guard parts.count == 2, ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(String(parts[0])),
          let input = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? JSON else { return nil }
    return (input["file_path"] ?? input["notebook_path"]) as? String
}

/// The nearest folder above path holding `.git`, or its `.fleet` sub-folder path is in (an empty `.fleet` names the root).
private func projectRoot(_ path: String) -> String? {
    let home = NSHomeDirectory(), files = FileManager.default
    var folder = URL(fileURLWithPath: path).standardized.path
    while folder != "/" && folder != home {
        if files.fileExists(atPath: folder + "/.git") {
            let subs = ((try? String(contentsOfFile: folder + "/.fleet", encoding: .utf8)) ?? "").split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return subs.map { folder + "/" + $0 }.first { path == $0 || path.hasPrefix($0 + "/") } ?? folder
        }
        folder = (folder as NSString).deletingLastPathComponent
    }
    return nil
}

func workingDirectory(_ target: String, within initial: String) -> String? {
    guard target.hasPrefix("/") else { return nil }
    let path = URL(fileURLWithPath: target).standardized.path
    guard initial == "/" || path == initial || path.hasPrefix(initial + "/") else { return nil }
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue ? path : nil
}

private func literalShellWords(_ command: String) -> [String]? {
    var words: [String] = [], word = "", quote: Character?, escaped = false, started = false
    for character in command {
        if escaped { word.append(character); escaped = false; continue }
        if quote == "'" {
            if character == "'" { quote = nil } else { word.append(character) }
        } else if character == "\\" { escaped = true; started = true }
        else if let delimiter = quote {
            if character == delimiter { quote = nil }
            else if character == "$" || character == "`" { return nil }
            else { word.append(character) }
        } else if character == "'" || character == "\"" { quote = character; started = true }
        else if character.isWhitespace {
            if started { words.append(word); word = ""; started = false }
        } else if ";&|()<>$`*?[]{}\n\r".contains(character) { return nil }
        else { word.append(character); started = true }
    }
    guard quote == nil, !escaped else { return nil }
    if started { words.append(word) }
    return words
}

/// The folder under ~/self a window's prompts are about, the first weighing most; nil for none or several: Haiku
/// picks it from the self-map's table. Agents left in / cd'd late or never, so Fleet showed /
/// and the project's CLAUDE.md missed the start (asked 2026-11-07).
func routeProject(_ prompts: [String], account: Account?) async -> String? {
    let root = NSHomeDirectory() + "/self"
    let map = (try? String(contentsOfFile: NSHomeDirectory() + "/.claude/skills/self-map/SKILL.md", encoding: .utf8)) ?? ""
    let rows = map.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Folder") }.joined(separator: "\n")
    let apps = ((try? String(contentsOfFile: root + "/my-apps/.fleet", encoding: .utf8)) ?? "")
        .split(whereSeparator: \.isNewline).map { "my-apps/" + $0 }.joined(separator: ", ")
    // Their descriptions carry the words a project's tasks come in ("recon", "Middle Office": s14).
    let skillsDir = NSHomeDirectory() + "/.claude/skills"
    let skills = ((try? FileManager.default.contentsOfDirectory(atPath: skillsDir)) ?? []).sorted().compactMap { name -> String? in
        guard let text = try? String(contentsOfFile: skillsDir + "/" + name + "/SKILL.md", encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let at = lines.firstIndex(where: { $0.hasPrefix("description:") }) else { return nil }
        var value = lines[at].dropFirst(12).trimmingCharacters(in: .whitespaces)
        // A folded block (`>-`, `|`) carries it on the indented lines under.
        if value.isEmpty || value.hasPrefix(">") || value.hasPrefix("|") {
            value = lines[(at + 1)...].prefix { $0.hasPrefix(" ") }.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        return name + ": " + value.prefix(160)
    }.joined(separator: "\n")
    let later = prompts.dropFirst().suffix(5).map { "\n<later>" + $0.prefix(1000) + "</later>" }.joined()
    // Measured on 42 of his first prompts that later cd'd: 22 to 26 right, 1 to 2 wrong folder, the rest none (median 3 s).
    let question = """
    Pick the project folder under ~/self that this chat is about. <request> is the first message of a new chat window and weighs most; <later> holds the messages that followed, if any. They rarely name their folder: judge from what they talk about.
    Reply with the folder's path relative to ~/self and nothing else (e.g. s14, my-apps/vcx, epitech), or none.
    Reply none when the request is general (a question, an errand, mail, money, papers, the Mac itself), spans several folders, or when you are unsure: a wrong folder is worse than none.
    The chat window is VCX (my-apps/vcx). Fleet (my-apps/fleet) is the separate board that shows every session as a card, in groups, beside his mail, todos and crons: a request about those cards, groups or that board is my-apps/fleet.
    Folders, one per row:
    \(rows)
    Apps inside my-apps, each its own folder: \(apps)
    His skills, whose descriptions say which work belongs where:
    \(skills)
    <request>\(prompts.first?.prefix(4000) ?? "")</request>\(later)
    """
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["claude", "-p", question, "--model", "haiku", "--setting-sources", "", "--strict-mcp-config",
                         "--disable-slash-commands", "--tools", "", "--no-session-persistence", "--output-format", "text"]
    var environment = agentEnvironment(account)
    // Fleet would take a claude carrying these for the window's own shell.
    environment.removeValue(forKey: "FLEET_SHELL"); environment.removeValue(forKey: "FLEET_CONTEXT_FILE")
    process.environment = environment
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let timeout = DispatchWorkItem { if process.isRunning { endProcess(process, signal: SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
    // No waitUntilExit: on 2026-11-10 it never returned for a Haiku already reaped, and the first prompt waited an hour unsent.
    let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
    timeout.cancel()
    let answer = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`'\"/.")))
    guard !answer.isEmpty, answer.lowercased() != "none", !answer.contains("..") else { return nil }
    return workingDirectory(root + "/" + answer.replacingOccurrences(of: "~/self/", with: ""), within: root)
}
