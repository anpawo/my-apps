import Foundation

/// Once a day Claude reads what was learned since its last read and takes the mistakes out: a
/// typo he left, which then counts as his word (epitehc); a fix he let stand but did not mean
/// (eip made épi, put right by hand later); a ⌫ that took back a fix that was right. Each change
/// and its reason go to review.log beside learned.json; reviewed.json keeps what was read.
enum Review {
    static let model = "opus"
    static let every: TimeInterval = 24 * 3600

    struct Seen: Codable {
        var at = Date.distantPast
        var words: Set<String> = []
        var fixes: Set<String> = []
        var refused: Set<String> = []
    }
    struct Word: Codable { let word: String; let why: String }
    struct Pair: Codable {
        let typed: String, fixed: String, why: String
        var key: String { typed + "\t" + fixed }
    }
    struct Verdict: Codable { var forget: [Word]; var reject: [Pair]; var unrefuse: [Pair] }
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// What has not been read yet, and every refusal, for context.
    struct Batch {
        var words: [String: Int], fixes: [String: Int], refused: [String: Int], allRefused: [String]
        var isEmpty: Bool { words.isEmpty && fixes.isEmpty && refused.isEmpty }

        init(_ mine: Mine, _ seen: Seen) {
            words = mine.counts.filter { !seen.words.contains($0.key) }
            fixes = mine.fixes.filter { !seen.fixes.contains($0.key) }
            refused = mine.rejected.filter { !seen.refused.contains($0.key) }
            allRefused = mine.rejected.keys.sorted()
        }
    }

    /// Words per call: Claude skims a long list (31/10: one read of 3,181 words named typos from a
    /// to g, then a handful).
    static let chunk = 300

    private static let prompt = """
    You review what autocorrect, a macOS app, learned from Marius's typing. He is a French Epitech student \
    who also works in finance; he types French and English, often mixed in one sentence, on a U.S. keyboard \
    that makes him leave accents out. He uses tech and school jargon (EIP, intra, recon), names, \
    abbreviations and slang (mdr, bcp, smth). The app fixes the word just typed when space or Return \
    follows. The JSON at the end is part of what it learned since the last review:

    - "words": each word he typed and kept, and how many times. A word here is never fixed as a typo \
    again and wins among close spellings. Read every one. A mistake here is a typo he left (epitehc for \
    epitech, two words run together), or a word the app put in place of his that he put right later by \
    hand, so it still counts as his: a word that is the "fixed" side of a fix in "all_refused" and that \
    he would seldom mean (épi, an ear of wheat, when he refused eip → épi) came from that fix.
    - "fixes": fixes the app made that he did not take back right away (typed → fixed, times). He may \
    have put a wrong one right by hand later.
    - "refused": fixes he took back with ⌫ right after; the app never makes them again. A ⌫ can also be \
    him going to put the typo right himself, not knowing the app already had.
    - "all_refused": every fix he ever took back, for context only: unrefuse names pairs from "refused" alone.

    Return:
    - forget: words from "words" that are mistakes. Keep real words of any language, names, jargon, \
    acronyms, abbreviations, slang, code identifiers.
    - reject: fixes from "fixes" that were wrong: the typed word is what he meant (eip → épi).
    - unrefuse: refusals from "refused" whose typed side is a word in neither French nor English and \
    whose fixed side is the only word he can have meant (runing → running, completement → complètement). \
    Not region → région: region is English, and the app weighs each sentence's language. Not when the \
    typed side may be a name or a brand (a first name typed in lower case), when the fix is not what he meant \
    (imporntat → importât: he meant important), or when he may have meant another word (sreen: seen or \
    screen).
    List only what to change: a word to keep gets no entry. Each with a short reason in English. When \
    unsure, leave it out: a word left costs little, a word taken out can be fixed wrongly again.
    """

    private static let schema: String = {
        let word: [String: Any] = ["type": "object", "required": ["word", "why"],
                                   "properties": ["word": ["type": "string"], "why": ["type": "string"]]]
        let pair: [String: Any] = ["type": "object", "required": ["typed", "fixed", "why"],
                                   "properties": ["typed": ["type": "string"], "fixed": ["type": "string"], "why": ["type": "string"]]]
        let object: [String: Any] = ["type": "object", "required": ["forget", "reject", "unrefuse"], "properties": [
            "forget": ["type": "array", "items": word],
            "reject": ["type": "array", "items": pair],
            "unrefuse": ["type": "array", "items": pair],
        ]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }()

    /// Blocks while Claude reads: off the main thread. The pairs go with the first chunk of words.
    static func ask(_ batch: Batch) throws -> Verdict {
        let words = batch.words.sorted { $0.key < $1.key }
        var verdict = Verdict(forget: [], reject: [], unrefuse: [])
        for start in stride(from: 0, to: max(words.count, 1), by: chunk) {
            var part = batch
            part.words = Dictionary(uniqueKeysWithValues: words[start..<min(start + chunk, words.count)].map { ($0.key, $0.value) })
            if start > 0 { part.fixes = [:]; part.refused = [:] }
            // Each call names only what it was given to read, not what it saw as context.
            let v = try askOnce(part)
            verdict.forget += v.forget.filter { part.words[$0.word] != nil }
            verdict.reject += v.reject.filter { part.fixes[$0.key] != nil }
            verdict.unrefuse += v.unrefuse.filter { part.refused[$0.key] != nil }
        }
        return verdict
    }

    private static func askOnce(_ batch: Batch) throws -> Verdict {
        let pairs = { (d: [String: Int]) in
            d.sorted { $0.key < $1.key }.map { kv -> [String: Any] in
                let p = kv.key.components(separatedBy: "\t")
                return ["typed": p[0], "fixed": p.count > 1 ? p[1] : "", "times": kv.value]
            }
        }
        let input: [String: Any] = ["words": batch.words, "fixes": pairs(batch.fixes), "refused": pairs(batch.refused),
                                    "all_refused": batch.allRefused.map { $0.replacingOccurrences(of: "\t", with: " → ") }]
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/claude")
        process.arguments = ["-p", prompt + "\n\n" + String(decoding: data, as: UTF8.self),
                             "--model", model, "--output-format", "json", "--json-schema", schema,
                             // Text in, verdict out: no tool, no setting, no MCP server, no transcript.
                             "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
                             "--tools", "", "--no-session-persistence"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // An open stdin costs 3 s: `claude -p` waits for piped input first.
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 900) { if process.isRunning { process.terminate() } }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        struct Envelope: Decodable { let is_error: Bool?; let result: String?; let structured_output: Verdict? }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: stdout) else {
            throw Failure(description: "claude exited \(process.terminationStatus) without an answer")
        }
        guard envelope.is_error != true, let verdict = envelope.structured_output else {
            throw Failure(description: String((envelope.result ?? "no verdict").prefix(200)))
        }
        return verdict
    }

    /// Only what was sent can be changed, once; returns what it changed, in words. The rules
    /// Claude broke on 31/10 hold here in code: a lexicon word is forgotten only as the fixed side
    /// of a refusal (épi), and a refusal is undone only when what he typed is no word (dont stays).
    static func apply(_ verdict: Verdict, _ batch: Batch, to words: Words, seen: inout Seen) -> [String] {
        var once = Set<String>()
        let fixedSides = Set(words.mine.rejected.keys.compactMap { $0.components(separatedBy: "\t").last })
        let forget = verdict.forget.filter {
            batch.words[$0.word] != nil && (!words.isWord($0.word) || fixedSides.contains($0.word)) && once.insert($0.word).inserted
        }
        let reject = verdict.reject.filter { batch.fixes[$0.key] != nil && once.insert("fix\t" + $0.key).inserted }
        let unrefuse = verdict.unrefuse.filter {
            batch.refused[$0.key] != nil && !words.isWord($0.typed) && once.insert("refused\t" + $0.key).inserted
        }
        words.amend(forget: forget.map(\.word), reject: reject.map(\.key), unreject: unrefuse.map(\.key))
        seen.at = Date()
        // A word taken out is read again if he keeps typing it.
        seen.words.formUnion(batch.words.keys)
        seen.words.subtract(forget.map(\.word))
        seen.words.formUnion(reject.map(\.typed))
        seen.fixes.formUnion(batch.fixes.keys)
        seen.refused.formUnion(batch.refused.keys)
        seen.refused.formUnion(reject.map(\.key))
        return forget.map { "forget \($0.word): \($0.why)" }
            + reject.map { "reject \($0.typed) → \($0.fixed): \($0.why)" }
            + unrefuse.map { "unrefuse \($0.typed) → \($0.fixed): \($0.why)" }
    }

    // MARK: - In the app

    private static var running = false

    static func schedule(_ words: Words, in folder: URL) {
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in run(words, in: folder) }
        // Not in the first minutes after login, with everything else starting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { run(words, in: folder) }
    }

    private static func run(_ words: Words, in folder: URL) {
        var seen = load(folder)
        guard !running, Date().timeIntervalSince(seen.at) >= every else { return }
        let batch = Batch(words.mine, seen)
        if batch.isEmpty { return }
        running = true
        DispatchQueue.global().async {
            let result = Result { try ask(batch) }
            DispatchQueue.main.async {
                running = false
                switch result {
                case .success(let verdict):
                    let lines = apply(verdict, batch, to: words, seen: &seen)
                    words.save()
                    write(seen, folder)
                    log(["read \(batch.words.count) words, \(batch.fixes.count) fixes, \(batch.refused.count) refusals; changed \(lines.count)"] + lines, folder)
                case .failure(let error):
                    // seen.at stays: the next hour tries again.
                    log(["failed: \(error)"], folder)
                }
            }
        }
    }

    // MARK: - Files, his alone: they hold the words he types

    private static func load(_ folder: URL) -> Seen {
        (try? Data(contentsOf: folder.appendingPathComponent("reviewed.json"))).flatMap { try? JSONDecoder().decode(Seen.self, from: $0) } ?? Seen()
    }

    private static func write(_ seen: Seen, _ folder: URL) {
        let file = folder.appendingPathComponent("reviewed.json")
        guard let data = try? JSONEncoder().encode(seen), (try? data.write(to: file, options: [.atomic])) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func log(_ lines: [String], _ folder: URL) {
        let file = folder.appendingPathComponent("review.log")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = format.string(from: Date())
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(lines.map { "\(stamp)  \($0)\n" }.joined().utf8))
        try? handle.close()
    }

    // MARK: - `autocorrect --review`

    /// What a review would change now; nothing is written. Counts only unless `--show`: the
    /// lines hold the words he types.
    static func dryRun(_ words: Words, in folder: URL, show: Bool) -> Int32 {
        var seen = load(folder)
        let batch = Batch(words.mine, seen)
        print("not read yet: \(batch.words.count) words, \(batch.fixes.count) fixes, \(batch.refused.count) refusals")
        if batch.isEmpty { return 0 }
        do {
            let verdict = try ask(batch)
            let lines = apply(verdict, batch, to: words, seen: &seen)
            print("would change \(lines.count): forget \(verdict.forget.count), reject \(verdict.reject.count), unrefuse \(verdict.unrefuse.count)")
            if show { lines.forEach { print($0) } }
            return 0
        } catch {
            print("failed: \(error)")
            return 1
        }
    }
}
