import Foundation

// Marius's ERRORS files hold his agents' past mistakes; Qwen loads none of them, and Claude and Codex
// get ERRORS.tools.md lines only once a matching tool call runs. Each prompt carries the few lines
// that share its words, ranked by BM25: Apple's sentence embeddings ranked them no better than chance.
// ponytail: lexical BM25 over a few hundred lines re-read per prompt; embeddings if a French prompt needs to reach English rules.
enum ErrorsRecall {
    static let marker = "VCX note, not part of the request:"
    static let home = ProcessInfo.processInfo.environment["VCX_ERRORS_HOME"] ?? NSHomeDirectory()

    static func files(cwd: String) -> [String] {
        var found = [home + "/.claude/ERRORS.md", home + "/.claude/ERRORS.tools.md"]
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
        while directory.hasPrefix(home + "/") {
            found += [directory + "/ERRORS.md", directory + "/ERRORS.tools.md"]
            directory = (directory as NSString).deletingLastPathComponent
        }
        return found
    }

    static func rules(cwd: String) -> [(text: String, words: [String])] {
        files(cwd: cwd).flatMap { path in
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.hasPrefix("- ") }.map { (String($0.dropFirst(2)), words(String($0))) }
        }
    }

    static let stop: Set<String> = ["a", "an", "the", "of", "to", "in", "on", "and", "or", "is", "are", "be", "it", "its", "for", "with", "by", "from", "at", "as", "that", "this", "not", "never", "no", "his", "him", "he", "my", "me", "what", "when", "one"]

    // Six letters stand in for a stemmer: scroll and scrolling, commit and committed meet.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.filter { $0.count > 1 && !stop.contains(String($0)) }.map { String($0.prefix(6)) }
    }

    static func recall(_ prompt: String, cwd: String, limit: Int = 4, minimum: Double = 6) -> [String] {
        let rules = rules(cwd: cwd), query = Set(words(prompt))
        guard !rules.isEmpty, !query.isEmpty else { return [] }
        let counts = rules.map { Dictionary($0.words.map { ($0, 1.0) }, uniquingKeysWith: +) }
        let n = Double(rules.count), average = Double(rules.map(\.words.count).reduce(0, +)) / n
        var frequency: [String: Double] = [:]
        for count in counts { for word in count.keys { frequency[word, default: 0] += 1 } }
        let scored = zip(rules, counts).map { rule, count -> (Double, String) in
            let length = Double(rule.words.count)
            let score = query.reduce(0.0) { total, word in
                guard let f = count[word], let df = frequency[word] else { return total }
                return total + log(1 + (n - df + 0.5) / (df + 0.5)) * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * length / average))
            }
            return (score, rule.text)
        }
        return scored.filter { $0.0 >= minimum }.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    // The heading a line sits under says what it is for ("Shell and quoting"); cached because the sidebar counts on every render.
    @MainActor private static var sections: [String: String] = [:]
    @MainActor static func section(of rule: String, cwd: String) -> String? {
        if let known = sections[rule] { return known.isEmpty ? nil : known }
        var found = ""
        search: for path in files(cwd: cwd) {
            var heading = ""
            for line in ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n") {
                if line.hasPrefix("## ") { heading = String(line.dropFirst(3)) }
                else if line == "- " + rule { found = heading; break search }
            }
        }
        sections[rule] = found
        return found.isEmpty ? nil : found
    }

    static func note(_ lines: [String]) -> String {
        lines.isEmpty ? "" : marker + " past mistakes from Marius's ERRORS files that may apply to it.\n" + lines.map { "- " + $0 }.joined(separator: "\n")
    }

    static func lines(_ text: String) -> [String] {
        guard let range = text.range(of: marker) else { return [] }
        return text[range.upperBound...].split(separator: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
    }

    // The note rides at the end of a prompt; a conversation read back from its provider shows the prompt without it.
    static func strip(_ text: String) -> String {
        guard let range = text.range(of: marker) else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
