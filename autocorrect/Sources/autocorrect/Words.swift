import AppKit

/// What he types himself: how often each word, how often he took a correction back, and how
/// often he let one stand (what the daily review reads for the wrong ones).
struct Mine: Codable {
    var counts: [String: Int] = [:]
    var rejected: [String: Int] = [:]
    var fixes: [String: Int] = [:]
    /// When each fix was last taken back (seconds since 1970): it is held off ten minutes from then.
    var refusedAt: [String: Double] = [:]

    init() {}
    // A file from before `fixes` lacks the key, and the synthesized decoder would refuse it whole.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counts = try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        rejected = try c.decodeIfPresent([String: Int].self, forKey: .rejected) ?? [:]
        fixes = try c.decodeIfPresent([String: Int].self, forKey: .fixes) ?? [:]
        refusedAt = try c.decodeIfPresent([String: Double].self, forKey: .refusedAt) ?? [:]
    }
}

/// The French and English lexicon, and the choice of a spelling for a typed word.
///
/// A spelling's score is how likely the word is (French and English frequencies, weighed by
/// the language of the sentence so far, plus his own use) times how likely he typed it that way
/// when he meant it: as is 1, without its accents or apostrophe 0.7 (the U.S. layout has no
/// accent keys), two letters swapped 0.03, a key next to the right one 0.01, a farther slip 0.002
/// (`slip`). Between spellings of one word (a/à, ou/où, vérifie/vérifié),
/// how likely each is is read after the word before it too (je vais à, il a). The best
/// spelling replaces the typed one only when it scores five times higher, and three times higher
/// than the next best. A word of his own (typed and kept) is never fixed, but is not a spelling
/// to fix others into: his typos are too.
final class Words {
    private struct Entry { var fr: Float; var en: Float }
    private var entries: [String: Entry] = [:]
    /// Spelling the lexicon gives a lower-case key, when it is not lower case ("I", "I'm").
    private var capital: [String: String] = [:]
    /// Every known word, under its accent-, apostrophe- and hyphen-free form.
    private var byBase: [String: [String]] = [:]
    /// P(word | the word before), keyed by `pairKey` (pairs.tsv: a million and more, so not by
    /// string). A pair it lacks was seen fewer than ten times: 0, in each language.
    private var pairs: [Int: Entry] = [:]
    /// For each word before, the share of what follows it that `pairs` holds: what is left is
    /// shared by every other word, as often as it is said (`context`).
    private var mass: [String: Entry] = [:]
    private(set) var mine = Mine()
    private let learned: URL?
    private var dirty = false
    private var spelling: [String: (known: Bool, until: TimeInterval)] = [:]

    static let maxLength = 30
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
        // Read as bytes, a line at a time: split into strings first, the app sat at 197 MB, not 133.
        let pairData = (try? Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent("pairs.tsv"))) ?? Data()
        pairs.reserveCapacity(pairData.count / 22)
        pairData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var cols: [Range<Int>] = [], start = 0
            for i in 0..<bytes.count where bytes[i] == 9 || bytes[i] == 10 {
                cols.append(start..<i)
                start = i + 1
                guard bytes[i] == 10 else { continue }
                defer { cols.removeAll(keepingCapacity: true) }
                let field = { (r: Range<Int>) in String(decoding: UnsafeRawBufferPointer(rebasing: bytes[r]), as: UTF8.self) }
                guard cols.count == 4, let fr = Float(field(cols[2])), let en = Float(field(cols[3])) else { continue }
                let prev = field(cols[0])
                pairs[Self.pairKey(prev, field(cols[1]))] = Entry(fr: fr, en: en)
                mass[prev, default: Entry(fr: 0, en: 0)].fr += fr
                mass[prev, default: Entry(fr: 0, en: 0)].en += en
            }
        }
        if let learned, let data = try? Data(contentsOf: learned), let saved = try? JSONDecoder().decode(Mine.self, from: data) {
            mine = saved
            let kept = mine.counts.filter { counted($0.key) }
            if kept.count != mine.counts.count { mine.counts = kept; dirty = true }
        }
    }

    /// Whether `key` may count as his word: not a spelling missing the marks of another (ca, tres,
    /// dont). Each one it let through would weigh against the fix until it stopped for good.
    private func counted(_ key: String) -> Bool { Self.fold(key) != key || (byBase[key] ?? []).allSatisfy { $0 == key } }

    var count: Int { entries.count }

    /// Said often enough not to be a typo the subtitles made too: the bar of `rare` in `correct`.
    func isWord(_ word: String) -> Bool { max(entries[word]?.fr ?? 0, entries[word]?.en ?? 0) >= 2e-7 }

    static func fold(_ word: String) -> String {
        var out = word.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "æ", with: "ae")
        out.removeAll { $0 == "'" || $0 == "’" || $0 == "-" }
        return out
    }

    // High: after a frequent word the pair counts are reliable, and after a rare one every
    // spelling is scaled alike (no pairs), which changes no choice.
    static let contextWeight = 0.95

    private func prior(_ key: String, fr: Double, after prev: String? = nil) -> Double {
        let e = entries[key]
        let alone = fr * Double(e?.fr ?? 0) + (1 - fr) * Double(e?.en ?? 0) + Double(mine.counts[key] ?? 0) * 1e-6
        guard let prev else { return alone }
        let p = pairs[Self.pairKey(prev, key)], w = Self.contextWeight
        return (1 - w) * alone + w * (fr * Double(p?.fr ?? 0) + (1 - fr) * Double(p?.en ?? 0))
    }

    static func pairKey(_ prev: String, _ word: String) -> Int {
        var h = Hasher()
        h.combine(prev)
        h.combine(word)
        return h.finalize()
    }

    /// How likely `key` is right after `prev`, any word against any other (a typo's readings):
    /// the share pairs.tsv gives it, or, for a pair seen too seldom to be in it, its share of
    /// what is left after `prev` (the endpoint is not ruled out because subtitles lack it).
    private func context(_ key: String, fr: Double, after prev: String?) -> Double {
        guard let prev, let m = mass[prev] else { return prior(key, fr: fr) }
        let e = entries[key], p = pairs[Self.pairKey(prev, key)]
        let f = (p?.fr ?? 0) > 0 ? Double(p!.fr) : (1 - Double(m.fr)) * Double(e?.fr ?? 0)
        let n = (p?.en ?? 0) > 0 ? Double(p!.en) : (1 - Double(m.en)) * Double(e?.en ?? 0)
        return fr * f + (1 - fr) * n + Double(mine.counts[key] ?? 0) * 1e-6
    }

    /// The spelling to put in place of `typed`, or nil to leave it. `fr`: how French the
    /// sentence is so far, 0 to 1; `prev`: the word right before, lower case, if nothing
    /// (punctuation, a sentence end) came between.
    func correct(_ typed: String, fr: Double, after prev: String? = nil) -> String? {
        guard typed.utf8.count <= Self.maxLength * 4, typed.count <= Self.maxLength,
              let last = typed.last, last.isLetter, !typed.contains(where: \.isNumber),
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
            return refused(lower + "\t" + fixed.lowercased()) ? nil : fixed
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
        // Only spellings of the typed word are weighed by context: pairs.tsv has no others, and a
        // word it lacks would lose to one it has.
        var inContext: Set<String> = []
        func consider(_ key: String, _ score: Double) {
            // Taken back: held off ten minutes, then a little weaker for each time it was.
            let pair = lower + "\t" + key
            guard !refused(pair), frenchAccents(key) else { return }
            let weaker = score * pow(Self.refusalWeight, Double(mine.rejected[pair] ?? 0))
            scores[key] = max(scores[key] ?? 0, weaker)
        }
        for key in byBase[base] ?? [] where key != lower {
            // An apostrophe, a hyphen or an accent he typed stays (pop-up is not popup, nor mesuré
            // mesure), and a hyphen he did not type is added in French only (vas-y, not plug-in).
            let m = marks(key)
            guard m.0 >= typedMarks.0, m.1 >= typedMarks.1, m.2 >= typedMarks.2 else { continue }
            if m.1 > typedMarks.1, (entries[key]?.fr ?? 0) <= (entries[key]?.en ?? 0) { continue }
            consider(key, prior(key, fr: fr, after: prev) * (Self.stripped(lower, of: key) ? 0.7 : 0.1))
            inContext.insert(key)
        }
        if rare, typedMarks.0 + typedMarks.1 == 0 {
            // l'homme, d'arriver: an elision the lexicon has no entry for, made of a French word
            // (not dirs into d'irs). c' only comes before être and en, which the lexicon has.
            for prefix in Self.elisions where prefix != "c" && base.count > prefix.count && base.hasPrefix(prefix) {
                let rest = String(base.dropFirst(prefix.count))
                guard rest.count >= 3, let first = rest.first, "aeiouyh".contains(first) else { continue }
                // Not before a word English says far more (d'and, d'hâve), nor t' before a pronoun: a-t-il.
                for key in byBase[rest] ?? [] where Self.stripped(lower, of: prefix + "'" + key) && known(key, in: ["fr"])
                    && (entries[rest]?.en ?? 0) <= 50 * (entries[key]?.fr ?? 0) && !(prefix == "t" && ["il", "ils", "elle", "elles", "on"].contains(key)) {
                    consider(prefix + "'" + key, 0.05 * fr * Double(entries[key]?.fr ?? 0) * 0.7)
                }
            }
        }
        // A typo, but not in a name (capital), an abbreviation (no vowel: mdr, bcp, smth), a word
        // missing its accents (genere: génère or généré, not genre) nor a word macOS knows
        // (plugin, hotkey, tutoriels). Three letters have too many neighbours: only two swapped
        // ones (teh) count there. Two swaps (vraiemtn), or one with a letter meant twice (dispaear),
        // when one slip finds nothing, from five letters on: a swap with another slip turns
        // distnoted into distorted, pyright upright.
        var bar = 5.0, typo = false
        if rare, scores.isEmpty, typedMarks.1 == 0, chars.count >= 3, chars[0].isLowercase,
           base.contains(where: { "aeiouy".contains($0) }), entries[lower] != nil || !known(lower) {
            // One macOS knows that the lexicon has, too rare to count, gives way only to a far
            // likelier word: thew to the, not unset to upset nor deriving to driving.
            if known(lower) { bar = 1000 }
            typo = true
            for second in [false, true] where scores.isEmpty {
                if second && chars.count < 5 { break }
                let edits = second
                    ? Set(Self.edits(base, swapsOnly: true).flatMap { Self.edits($0, swapsOnly: true) }).union(Self.swapsDoubled(base))
                    : Self.edits(base, swapsOnly: chars.count < 4)
                for edit in edits {
                    for key in byBase[edit] ?? [] where !key.contains("-") && !Self.inflected(base, Self.fold(key))
                        && !Self.rude.contains(key) && known(key)
                        // A rare word only if he types it himself: not aven, clade, letup.
                        && (mine.counts[key] != nil || max(entries[key]?.fr ?? 0, entries[key]?.en ?? 0) >= 3e-7) {
                        consider(key, context(key, fr: fr, after: prev) * (second ? 0.0001 : Self.slip(base, edit)))
                    }
                }
            }
        }
        // A space missed: isthe is "is the", when the two are said together often enough to be in
        // pairs.tsv (worktree is not work tree). Even when the subtitles have it (ofthe), as long
        // as macOS does not.
        if typedMarks.0 + typedMarks.1 == 0, chars.count >= 4, chars[0].isLowercase, mine.counts[lower] == nil,
           byBase[base].map({ $0 == [lower] }) ?? true, !known(lower) {
            typo = true
            for cut in 2...(chars.count - 2) {
                let a = String(lower.prefix(cut)), b = String(lower.dropFirst(cut))
                guard let p = pairs[Self.pairKey(a, b)] else { continue }
                consider(a + " " + b, context(a, fr: fr, after: prev) * (fr * Double(p.fr) + (1 - fr) * Double(p.en)) * 0.1)
            }
        }

        // The best spelling must beat the one typed five times over, and the next best three
        // times: vérifie and vérifié are as likely for "verifie", so neither is picked.
        let ranked = scores.sorted { $0.value > $1.value }
        var chosen = lower
        if let best = ranked.first, best.value > 0,
           best.value >= bar * (typo ? context(lower, fr: fr, after: prev) : prior(lower, fr: fr, after: inContext.contains(best.key) ? prev : nil)),
           ranked.count < 2 || best.value >= 3 * ranked[1].value {
            chosen = best.key
        }
        var spelled = Self.cased(chosen.split(separator: " ").map { capital[String($0)] ?? String($0) }.joined(separator: " "), like: typed)
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
    /// apprenants), or a daemon (launchd, systemd), not a typo of it. But a d left off is a typo
    /// (shoul, coul: should, could).
    static func inflected(_ typed: String, _ key: String) -> Bool {
        let (long, short) = typed.count > key.count ? (typed, key) : (key, typed)
        return long.count == short.count + 1 && long.hasPrefix(short) && "sxed".contains(long.last!)
            && !(long == key && long.last == "d")
    }

    /// Whether the macOS spell checker takes `word` in one of `languages`. It knows far more
    /// technical words than film subtitles do, and his own additions to it.
    private func known(_ word: String, in languages: [String] = ["en", "fr"]) -> Bool {
        let key = languages.joined(separator: ",") + "\t" + word
        let now = Date.timeIntervalSinceReferenceDate
        if let saved = spelling[key], saved.until > now { return saved.known }
        let result = languages.contains { language in
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        if spelling.count >= 2048 { spelling.removeAll(keepingCapacity: true) }
        // Expire results so edits to the macOS user dictionary take effect without a restart.
        spelling[key] = (result, now + 60)
        return result
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

    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map(Array.init)

    /// Whether two keys touch on a U.S. keyboard, or are the same key.
    static func near(_ a: Character, _ b: Character) -> Bool {
        guard let r = rows.firstIndex(where: { $0.contains(a) }), let i = rows[r].firstIndex(of: a),
              let s = rows.firstIndex(where: { $0.contains(b) }), let j = rows[s].firstIndex(of: b) else { return false }
        if r == s { return abs(i - j) <= 1 }
        // Each row sits half a key right of the one above: a is under q and w.
        if s == r + 1 { return j == i || j == i - 1 }
        if s == r - 1 { return j == i || j == i + 1 }
        return false
    }

    /// How likely `typed` is a one-slip typo of `meant`: a swap most of all, then a key next to
    /// the right one, a letter left out or one struck twice; a far key least (wnat is not made what).
    static func slip(_ typed: String, _ meant: String) -> Double {
        let t = Array(typed), m = Array(meant)
        if t.count == m.count {
            let diff = t.indices.filter { t[$0] != m[$0] }
            if diff.count == 2, diff[1] == diff[0] + 1 { return 0.03 }
            if diff.count == 1 { return near(t[diff[0]], m[diff[0]]) ? 0.01 : 0.002 }
            return 0.002
        }
        if t.count + 1 == m.count { return 0.01 }
        // A letter too many: struck with its neighbour, or twice.
        guard let i = t.indices.first(where: { $0 >= m.count || t[$0] != m[$0] }) else { return 0.002 }
        return (i > 0 && near(t[i], t[i - 1])) || (i + 1 < t.count && near(t[i], t[i + 1])) ? 0.01 : 0.002
    }

    /// Never a fix into one of these as a typo: he typed them as is or not at all.
    static let rude: Set<String> = ["blowjob", "tits", "dick", "cock", "pussy", "fuck", "shit", "bitch", "cunt",
                                    "bite", "chatte", "pute", "salope", "connard", "conne", "enculé", "putain", "merde"]

    /// Accents only French has (English has none), on a word the macOS French dictionary takes:
    /// not theyâ nor ïun, which the subtitles spelled.
    private func frenchAccents(_ key: String) -> Bool {
        let marked = key.filter { !$0.isASCII && $0 != "’" }
        guard !marked.isEmpty else { return true }
        guard marked.allSatisfy({ "àâäçéèêëîïôöùûüÿœæ".contains($0) }) else { return false }
        let word = key.split(separator: "'").last.map(String.init) ?? key
        return word.allSatisfy(\.isASCII) || known(word, in: ["fr"]) || known(word.capitalized, in: ["fr"])
    }

    /// Two letters swapped, one of which was also meant twice (dispaear: disappear), keeping
    /// the first letter. A doubling elsewhere in the word turns attrs into arts, tailnet taillent.
    static func swapsDoubled(_ word: String) -> Set<String> {
        let w = Array(word)
        var out = Set<String>()
        for i in 1..<max(1, w.count - 1) {
            var s = w
            s.swapAt(i, i + 1)
            out.insert(String(s[...i] + s[i...]))
            out.insert(String(s[...(i + 1)] + s[(i + 1)...]))
        }
        return out
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
        guard (2...Self.maxLength).contains(key.count), counted(key) else { return }
        mine.counts[key, default: 0] += 1
        dirty = true
    }

    static let refusalHold: TimeInterval = 10 * 60
    static let refusalWeight = 0.7

    private func refused(_ key: String) -> Bool {
        guard let at = mine.refusedAt[key] else { return false }
        return Date().timeIntervalSince1970 - at < Self.refusalHold
    }

    func reject(_ typed: String, _ fixed: String, at date: Date = Date()) {
        let key = typed.lowercased() + "\t" + fixed.lowercased()
        mine.rejected[key, default: 0] += 1
        mine.refusedAt[key] = date.timeIntervalSince1970
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
            guard (2...Self.maxLength).contains(key.count), !key.contains("'"), !key.contains("’"), !isWord(key),
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
        for key in unreject { mine.rejected[key] = nil; mine.refusedAt[key] = nil }
        for key in reject {
            let pair = key.components(separatedBy: "\t")
            guard pair.count == 2 else { continue }
            // Each time the fix stood it was counted as his word: it was not, the typed one was.
            if let n = mine.fixes.removeValue(forKey: key), let c = mine.counts[pair[1]] {
                mine.counts[pair[1]] = c > n ? c - n : nil
            }
            mine.rejected[key, default: 0] += 1
            mine.refusedAt[key] = Date().timeIntervalSince1970
            if counted(pair[0]) { mine.counts[pair[0], default: 0] += 1 }
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
