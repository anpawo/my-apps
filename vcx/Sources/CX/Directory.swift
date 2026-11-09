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

/// The folder under ~/self a window's first prompt is about, nil for none or several: Haiku
/// picks it from the self-map's table. Agents left in / cd'd late or never, so Fleet showed /
/// and the project's CLAUDE.md missed the start (asked 2026-11-07).
func routeProject(_ prompt: String, account: Account?) async -> String? {
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
    // Measured on 42 of his first prompts that later cd'd: 22 to 26 right, 1 to 2 wrong folder, the rest none (median 3 s).
    let question = """
    Pick the project folder under ~/self that this request is about. It is the first message of a new chat window, so it rarely names its folder: judge from what it talks about.
    Reply with the folder's path relative to ~/self and nothing else (e.g. s14, my-apps/vcx, epitech), or none.
    Reply none when the request is general (a question, an errand, mail, money, papers, the Mac itself), spans several folders, or when you are unsure: a wrong folder is worse than none.
    The chat window is VCX (my-apps/vcx). Fleet (my-apps/fleet) is the separate board that shows every session as a card, in groups, beside his mail, todos and crons: a request about those cards, groups or that board is my-apps/fleet.
    Folders, one per row:
    \(rows)
    Apps inside my-apps, each its own folder: \(apps)
    His skills, whose descriptions say which work belongs where:
    \(skills)
    <request>\(prompt.prefix(4000))</request>
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
    let data = await Task.detached { let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return data }.value
    timeout.cancel()
    let answer = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`'\"/.")))
    guard !answer.isEmpty, answer.lowercased() != "none", !answer.contains("..") else { return nil }
    return workingDirectory(root + "/" + answer.replacingOccurrences(of: "~/self/", with: ""), within: root)
}
