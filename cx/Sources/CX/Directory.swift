import Foundation

func shellDirectory(_ item: JSON, current: String, initial: String) -> String? {
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
    } else {
        guard current == initial else { return nil }
        target = base
    }
    return workingDirectory(target, within: initial)
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
