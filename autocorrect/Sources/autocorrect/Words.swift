import AppKit

/// What he types himself: how often each word, how often he took a correction back, and how
/// often he let one stand (what the daily review reads for the wrong ones).
struct Mine: Codable {
    var counts: [String: Int] = [:]
    var rejected: [String: Int] = [:]
    var fixes: [String: Int] = [:]

    init() {}
    // A file from before `fixes` lacks the key, and the synthesized decoder would refuse it whole.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counts = try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        rejected = try c.decodeIfPresent([String: Int].self, forKey: .rejected) ?? [:]
        fixes = try c.decodeIfPresent([String: Int].self, forKey: .fixes) ?? [:]
    }
}

/// The French and English lexicon, and the choice of a spelling for a typed word.
///
/// A spelling's score is how likely the word is (French and English frequencies, weighed by
/// the language of the sentence so far, plus his own use) times how likely he typed it that way
/// when he meant it: as is 1, without its accents or apostrophe 0.7 (the U.S. layout has no
/// accent keys), one letter off 0.01. The best spelling replaces the typed one only when it
/// scores five times higher, and three times higher than the next best. A word of his own
/// (typed and kept) is never fixed, but is not a spelling to fix others into: his typos are too.
final class Words {
    private struct Entry { var fr: Float; var en: Float }
    private var entries: [String: Entry] = [:]
    /// Spelling the lexicon gives a lower-case key, when it is not lower case ("I", "I'm").
    private var capital: [String: String] = [:]
    /// Every known word, under its accent-, apostrophe- and hyphen-free form.
    private var byBase: [String: [String]] = [:]
    private(set) var mine = Mine()
    private let learned: URL?
    private var dirty = false

    static let elisions = ["c", "j", "l", "d", "n", "m", "t", "s", "qu", "jusqu", "lorsqu", "puisqu", "quelqu", "presqu"]

    init(file: URL, learned: URL?) {
        self.learned = learned
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count == 3, let fr = Float(cols[1]), let en = Float(cols[2]) else { continue }
            let word = String(cols[0]), key = word.lowercased()
            if key != word { capital[key] = word }
            entries[key] = Entry(fr: fr / 1e6, en: en / 1e6)
            byBase[Self.fold(key), default: []].append(key)
        }
        if let learned, let data = try? Data(contentsOf: learned), let saved = try? JSONDecoder().decode(Mine.self, from: data) {
            mine = saved
        }
    }

    var count: Int { entries.count }

    /// Said often enough not to be a typo the subtitles made too: the bar of `rare` in `correct`.
    func isWord(_ word: String) -> Bool { max(entries[word]?.fr ?? 0, entries[word]?.en ?? 0) >= 2e-7 }

    static func fold(_ word: String) -> String {
        var out = word.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "æ", with: "ae")
        out.removeAll { $0 == "'" || $0 == "’" || $0 == "-" }
        return out
    }

    private func prior(_ key: String, fr: Double) -> Double {
        let e = entries[key]
        return fr * Double(e?.fr ?? 0) + (1 - fr) * Double(e?.en ?? 0) + Double(mine.counts[key] ?? 0) * 1e-6
    }

    /// The spelling to put in place of `typed`, or nil to leave it. `fr`: how French the
    /// sentence is so far, 0 to 1.
    func correct(_ typed: String, fr: Double) -> String? {
        guard let last = typed.last, last.isLetter, !typed.contains(where: \.isNumber),
              // A capital inside the word: a name or an acronym (GitHub, macOS, NEPH).
              !typed.dropFirst().contains(where: \.isUppercase),
              // An accent French has not: another language (já, aí).
              typed.lowercased().allSatisfy({ $0.isASCII || "àâäçéèêëîïôöùûüÿœæ’".contains($0) }) else { return nil }
        let lower = typed.lowercased().replacingOccurrences(of: "’", with: "'")
        let chars = Array(typed)
        if entries[lower] == nil, let cut = chars.firstIndex(where: { $0 == "'" || $0 == "’" }) {
            // Typed with its apostrophe: an elision has only its word to fix (j'etais), and an
            // English contraction the lexicon lacks (it's, we'll) is left alone.
            guard Self.elisions.contains(String(chars[..<cut]).lowercased()), cut + 1 < chars.count,
                  let rest = correct(String(chars[(cut + 1)...]), fr: fr) else { return nil }
            let fixed = String(chars[...cut]) + rest
            return mine.rejected[lower + "\t" + fixed.lowercased()] == nil ? fixed : nil
        }

        let base = Self.fold(lower)
        let marks = { (w: String) in
            (w.filter { $0 == "'" }.count, w.filter { $0 == "-" }.count, w.filter { !$0.isASCII }.count)
        }
        let typedMarks = marks(lower)
        // He typed its accents himself: côte, crées are what he meant, not côté, créés.
        if typedMarks.2 > 0, entries[lower] != nil { return nil }
        // Only a word no dictionary knows, or barely (a typo the subtitles made too: becuase),
        // gets fixed into a different word; a real one (chat, scan, width) is left alone.
        let rare = max(entries[lower]?.fr ?? 0, entries[lower]?.en ?? 0) < 2e-7 && mine.counts[lower] == nil
        var scores: [String: Double] = [:]
        func consider(_ key: String, _ score: Double) {
            // Taken back once is never made again: a penalty did nothing for a word the lexicon
            // lacks, whose own score is 0 (eip was made épi again after two ⌫).
            guard mine.rejected[lower + "\t" + key] == nil else { return }
            scores[key] = max(scores[key] ?? 0, score)
        }
        for key in byBase[base] ?? [] where key != lower {
            // An apostrophe, a hyphen or an accent he typed stays (pop-up is not popup, nor mesuré
            // mesure), and a hyphen he did not type is added in French only (vas-y, not plug-in).
            let m = marks(key)
            guard m.0 >= typedMarks.0, m.1 >= typedMarks.1, m.2 >= typedMarks.2 else { continue }
            if m.1 > typedMarks.1, (entries[key]?.fr ?? 0) <= (entries[key]?.en ?? 0) { continue }
            consider(key, prior(key, fr: fr) * (Self.stripped(lower, of: key) ? 0.7 : 0.1))
        }
        if rare, typedMarks.0 + typedMarks.1 == 0 {
            // l'homme, d'arriver: an elision the lexicon has no entry for, made of a French word
            // (not dirs into d'irs). c' only comes before être and en, which the lexicon has.
            for prefix in Self.elisions where prefix != "c" && base.count > prefix.count && base.hasPrefix(prefix) {
                let rest = String(base.dropFirst(prefix.count))
                guard rest.count >= 3, let first = rest.first, "aeiouyh".contains(first) else { continue }
                for key in byBase[rest] ?? [] where Self.stripped(lower, of: prefix + "'" + key) && Self.known(key, in: ["fr"]) {
                    consider(prefix + "'" + key, 0.05 * fr * Double(entries[key]?.fr ?? 0) * 0.7)
                }
            }
        }
        // A typo, but not in a name (capital), an abbreviation (no vowel: mdr, bcp, smth), a word
        // missing its accents (genere: génère or généré, not genre) nor a word macOS knows
        // (plugin, hotkey, tutoriels). Three letters have too many neighbours: only two swapped
        // ones (teh) count there. Two swaps when one slip finds nothing (vraiemtn), from five
        // letters on: a swap with another slip turns distnoted into distorted, pyright upright.
        if rare, scores.isEmpty, typedMarks.1 == 0, chars.count >= 3, chars[0].isLowercase,
           base.contains(where: { "aeiouy".contains($0) }), !Self.known(lower) {
            let first = Array(Self.edits(base, swapsOnly: chars.count < 4))
            let second = chars.count < 5 ? [] : Self.edits(base, swapsOnly: true).flatMap { Self.edits($0, swapsOnly: true) }
            for (edits, channel) in [(first, 0.01), (second, 0.0001)] where scores.isEmpty {
                for edit in edits {
                    for key in byBase[edit] ?? [] where !key.contains("-") && !Self.inflected(base, Self.fold(key)) && Self.known(key) {
                        consider(key, prior(key, fr: fr) * channel)
                    }
                }
            }
        }

        // The best spelling must beat the one typed five times over, and the next best three
        // times: vérifie and vérifié are as likely for "verifie", so neither is picked.
        let ranked = scores.sorted { $0.value > $1.value }
        var chosen = lower
        if let best = ranked.first, best.value > 0, best.value >= 5 * prior(lower, fr: fr),
           ranked.count < 2 || best.value >= 3 * ranked[1].value {
            chosen = best.key
        }
        var spelled = Self.cased(capital[chosen] ?? chosen, like: typed)
        if typed.contains("’") { spelled = spelled.replacingOccurrences(of: "'", with: "’") }
        return spelled == typed ? nil : spelled
    }

    /// `word` in the case he typed (Deja → Déjà), and a word the lexicon spells with a capital
    /// keeps it (i → I).
    static func cased(_ word: String, like typed: String) -> String {
        if let first = typed.first, first.isUppercase { return word.prefix(1).uppercased() + word.dropFirst() }
        return word
    }

    /// One more or one fewer s, x, e or d at the end: another form of the same word (screenshots,
    /// apprenants), or a daemon (launchd, systemd), not a typo of it.
    static func inflected(_ a: String, _ b: String) -> Bool {
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        return long.count == short.count + 1 && long.hasPrefix(short) && "sxed".contains(long.last!)
    }

    /// Whether the macOS spell checker takes `word` in one of `languages`. It knows far more
    /// technical words than film subtitles do, and his own additions to it.
    static func known(_ word: String, in languages: [String] = ["en", "fr"]) -> Bool {
        languages.contains { language in
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    /// Whether `typed` is `key` with some of its accents, apostrophes and hyphens left out
    /// (deja, dejà, peut-etre for peut-être; coeur for cœur), both lower case.
    static func stripped(_ typed: String, of key: String) -> Bool {
        let t = Array(typed), k = Array(key.replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "æ", with: "ae"))
        let bare = { (c: Character) in String(c).folding(options: .diacriticInsensitive, locale: nil) }
        var i = 0, j = 0
        while j < k.count {
            if i < t.count, t[i] == k[j] || (bare(t[i]) == String(t[i]) && bare(k[j]) == String(t[i])) {
                i += 1; j += 1
            } else if k[j] == "'" || k[j] == "-" {
                j += 1
            } else {
                return false
            }
        }
        return i == t.count
    }

    /// Every string one deletion, swap, change or insertion of a letter away (or only swaps),
    /// keeping the first letter: a typo is seldom there, but for two swapped ones (hte).
    static func edits(_ word: String, swapsOnly: Bool = false) -> Set<String> {
        let w = Array(word), letters = Array("abcdefghijklmnopqrstuvwxyz")
        var out = Set<String>()
        for i in 0...w.count {
            let head = w[..<i], tail = w[i...]
            if tail.count > 1 { out.insert(String(head + [tail[i + 1], tail[i]] + tail.dropFirst(2))) }
            if swapsOnly { continue }
            if !tail.isEmpty { out.insert(String(head + tail.dropFirst())) }
            for c in letters {
                if !tail.isEmpty, c != tail[i] { out.insert(String(head + [c] + tail.dropFirst())) }
                out.insert(String(head + [c] + tail))
            }
        }
        out.remove(word)
        let swapped = w.count > 1 ? String([w[1], w[0]] + w.dropFirst(2)) : word
        return out.filter { $0.first == w.first || $0 == swapped }
    }

    /// How French the sentence is once `word` is added to it. Kept within 5–95 %: one borrowed
    /// word should not settle it.
    func nextFr(_ fr: Double, after word: String) -> Double {
        guard let e = entries[word.lowercased()] else { return fr }
        let f = fr * (Double(e.fr) + 1e-7), n = (1 - fr) * (Double(e.en) + 1e-7)
        return min(0.95, max(0.05, f / (f + n)))
    }

    func learn(_ word: String) {
        let key = word.lowercased()
        guard (2...30).contains(key.count) else { return }
        mine.counts[key, default: 0] += 1
        dirty = true
    }

    func reject(_ typed: String, _ fixed: String) {
        mine.rejected[typed.lowercased() + "\t" + fixed.lowercased(), default: 0] += 1
        dirty = true
    }

    /// Words from his own messages (`seed.tsv`), counted as his so they are never fixed as typos.
    /// Not a lexicon word (nothing to gain, and a big count would tilt close spellings) nor a word
    /// with its marks left out (tres, dont, dautre: putting those back is the app's job, and a
    /// counted word is no longer `rare`, which the elisions need). Returns how many it took.
    func seed(_ counts: [String: Int]) -> Int {
        var taken = 0
        for (word, n) in counts {
            let key = word.lowercased(), n = min(n, 5)
            guard (2...30).contains(key.count), !key.contains("'"), !key.contains("’"), !isWord(key),
                  (byBase[Self.fold(key)] ?? []).allSatisfy({ $0 == key }),
                  [0.05, 0.5, 0.95].allSatisfy({ correct(key, fr: $0).map { Self.fold($0) != Self.fold(key) } ?? true }),
                  (mine.counts[key] ?? 0) < n else { continue }
            mine.counts[key] = n
            taken += 1
        }
        if taken > 0 { dirty = true }
        return taken
    }

    func keep(_ typed: String, _ fixed: String) {
        mine.fixes[typed.lowercased() + "\t" + fixed.lowercased(), default: 0] += 1
        dirty = true
    }

    /// The daily review's verdicts. `reject` and `unreject` hold "typed\tfixed" keys.
    func amend(forget: [String], reject: [String], unreject: [String]) {
        for word in forget { mine.counts[word] = nil }
        for key in unreject { mine.rejected[key] = nil }
        for key in reject {
            let pair = key.components(separatedBy: "\t")
            guard pair.count == 2 else { continue }
            // Each time the fix stood it was counted as his word: it was not, the typed one was.
            if let n = mine.fixes.removeValue(forKey: key), let c = mine.counts[pair[1]] {
                mine.counts[pair[1]] = c > n ? c - n : nil
            }
            mine.rejected[key, default: 0] += 1
            mine.counts[pair[0], default: 0] += 1
        }
        dirty = true
    }

    func save() {
        guard dirty, let learned, let data = try? JSONEncoder().encode(mine) else { return }
        try? FileManager.default.createDirectory(at: learned.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Every word he types: readable by him alone.
        if (try? data.write(to: learned, options: [.atomic])) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: learned.path)
            dirty = false
        }
    }
}
