/// What each keystroke does to the text in front of him: it follows the word being typed, fixes
/// it when a space, a Return, a period or a comma ends it (with any punctuation typed after it:
/// "tres!" too), and takes the fix back on a ⌫ right after. A letter right after that punctuation
/// makes it a link or an abbreviation (etudiant.gouv.fr, e.g), left alone: a fix the period or
/// comma made is put back.
///
/// It sees keys, not the text field. So a word is only fixed when this process saw it start:
/// after a space, a Return, a click, a switch to another app or a shortcut (a paste, ⌘⌫). After
/// an arrow, or a ⌫ past the start of the word, the caret may be in the middle of a word it never
/// saw, and that word is left alone up to the next space.
///
/// It also keeps the line as it reads since the last click or Return, and where the caret is in
/// it, through ← and →: a word he goes back to and changes by hand is a fix that was wrong, or a
/// typo it left (`Words.revise`).
struct Typist {
    enum Key: Equatable {
        case char(Character), backspace, reset, left, right
        /// A click, another app or a shortcut: the caret is at the start of a word far more often
        /// than inside one.
        case focus
    }
    enum Act: Equatable {
        case pass
        /// Hold the key, erase `delete` characters, type `type`, then let the key through or not.
        case edit(delete: Int, type: String, thenKey: Bool)
    }

    static let ends: Set<Character> = [" ", "\r", "\n"]
    static let after: Set<Character> = [".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "»", "\"", "”"]
    static let before: Set<Character> = ["(", "[", "{", "«", "\"", "“"]
    static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "\r", "\n"]

    let words: Words
    var word: [Character] = []
    /// Punctuation typed after the word.
    var tail: [Character] = []
    /// The word began where this process saw a break.
    var clean = false
    var fr = 0.5
    /// The word before, as it stands, when only spaces follow it.
    var prev: String?
    private var undo: (delete: Int, type: String, typed: String, fixed: String)?
    /// The last key was a period or a comma that fixed the word before it.
    private var early = false
    /// The last word, counted as his once the next key shows he kept it, with what he had typed
    /// when it was a fix.
    private var kept: (word: String, typed: String?)?
    /// The word before, as typed and as it reads, while the next one follows a single space: the
    /// two may be one word (infor mation) or a pair to put right (their is).
    private var pending: Pending?
    typealias Pending = (typed: String, shown: String, prev: String?, kept: (word: String, typed: String?))

    /// The text typed since the last click, shortcut or Return, as it reads, and the caret in it;
    /// nil once the caret left it.
    private var line: [Character]? = []
    private var caret = 0
    /// The line as it was when he began to change it in the middle.
    private var revising: [Character]?
    /// The fixes made on this line: fixed, lower case → typed.
    private var fixedOnLine: [String: String] = [:]

    init(_ words: Words) { self.words = words }

    mutating func handle(_ key: Key) -> Act {
        switch key {
        case .focus, .reset: settle()
        case .char(let c) where !Self.inWord(c): settle()
        default: break
        }
        let act = step(key)
        follow(key, act)
        return act
    }

    static func inWord(_ c: Character) -> Bool { c.isLetter || c == "'" || c == "’" || c == "-" }

    /// Keeps `line` and `caret` as the key and what this did with it leave them.
    private mutating func follow(_ key: Key, _ act: Act) {
        let newLine = key == .char("\r") || key == .char("\n")
        guard var text = line, key != .focus, key != .reset, !newLine, text.count < 4000 else {
            line = []; caret = 0; revising = nil; fixedOnLine = [:]
            return
        }
        var at = caret
        switch key {
        case .left, .right:
            // Past either end: text it never saw.
            guard key == .left ? at > 0 : at < text.count else { line = nil; revising = nil; return }
            caret += key == .left ? -1 : 1
            if let old = revising, let c = Self.changed(old, text), !(c.at.lowerBound...c.at.upperBound).contains(caret) { settle() }
            return
        default: break
        }
        if at < text.count, revising == nil { revising = text }
        switch act {
        case .pass:
            if case .char(let c) = key { text.insert(c, at: at); at += 1 } else if at > 0 { at -= 1; text.remove(at: at) } else {
                line = nil; revising = nil
                return
            }
        case let .edit(delete, type, thenKey):
            guard at >= delete else { line = nil; revising = nil; return }
            text.removeSubrange(at - delete..<at)
            at -= delete
            text.insert(contentsOf: type, at: at)
            at += type.count
            if thenKey, case .char(let c) = key { text.insert(c, at: at); at += 1 }
            if case .char = key, let k = kept, let typed = k.typed { fixedOnLine[k.word.lowercased()] = typed }
        }
        line = text; caret = at
    }

    /// He is done changing a word in the middle: tell `words` what it was and what he made it.
    private mutating func settle() {
        defer { revising = nil }
        guard let old = revising, let new = line, let c = Self.changed(old, new) else { return }
        words.revise(c.old, c.new, typed: fixedOnLine[c.old.lowercased()])
    }

    /// The one word changed between `old` and `new`, and where it now stands; nil when more than a
    /// word changed, or the word was still being typed (nothing after it).
    static func changed(_ old: [Character], _ new: [Character]) -> (old: String, new: String, at: Range<Int>)? {
        var p = 0, s = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        while s < old.count - p, s < new.count - p, old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        guard old != new else { return nil }
        func word(_ t: [Character], _ hi: Int) -> Range<Int> {
            var a = p, b = hi
            while a > 0, inWord(t[a - 1]) { a -= 1 }
            while b < t.count, inWord(t[b]) { b += 1 }
            return a..<b
        }
        let o = word(old, old.count - s), n = word(new, new.count - s)
        guard !o.isEmpty, !n.isEmpty, o.upperBound < old.count, old[o].allSatisfy(inWord), new[n].allSatisfy(inWord) else { return nil }
        return (String(old[o]), String(new[n]), n)
    }

    private mutating func step(_ key: Key) -> Act {
        let last = undo, wasEarly = early, before = pending
        undo = nil; early = false; pending = nil
        if wasEarly, let u = last, case .char(let c) = key, !Self.ends.contains(c), !Self.after.contains(c) {
            kept = nil
            word = []; tail = []; clean = false; prev = nil
            return .edit(delete: u.delete, type: u.type, thenKey: true)
        }
        if case .backspace = key {} else if let k = kept {
            // A space it put back (isthe: is the) makes two words of his.
            for word in k.word.split(separator: " ") { words.learn(String(word)) }
            if let typed = k.typed { words.keep(typed, k.word) }
            kept = nil
        }
        switch key {
        case .reset, .focus, .left, .right:
            word = []; tail = []; clean = key == .focus; fr = 0.5; prev = nil
            return .pass
        case .backspace:
            if let u = last {
                word = []; tail = []; clean = false; prev = nil
                // A period or comma he takes off: the fix it made stays.
                if wasEarly { return .pass }
                words.reject(u.typed, u.fixed)
                kept = (u.typed, nil)
                return .edit(delete: u.delete, type: u.type, thenKey: false)
            }
            kept = nil
            if !tail.isEmpty { tail.removeLast() } else if !word.isEmpty { word.removeLast() } else { clean = false; prev = nil }
            return .pass
        case .char(let c):
            if tail.isEmpty, c.isLetter || (!word.isEmpty && (c == "'" || c == "’" || c == "-")) {
                guard word.count < Words.maxLength else {
                    word = []; clean = false
                    return .pass
                }
                word.append(c)
                pending = before
                return .pass
            }
            if tail.isEmpty, clean, !word.isEmpty, c == "." || c == "," {
                let typed = String(word)
                word = []; tail = [c]
                let act = end(typed, "", key: c, after: before)
                early = undo != nil
                return act
            }
            if word.isEmpty, Self.before.contains(c) || Self.after.contains(c) {
                prev = nil
                return .pass
            }
            if Self.after.contains(c) {
                guard tail.count < Words.maxLength else {
                    word = []; tail = []; clean = false
                    return .pass
                }
                tail.append(c)
                pending = before
                return .pass
            }
            guard Self.ends.contains(c) else {
                // A digit, @, /, _, or a letter after a dot: not prose (a link, an address).
                word = []; tail = []; clean = false; prev = nil
                return .pass
            }
            let typed = String(word), punctuation = String(tail)
            let eligible = clean && !word.isEmpty
            let ended = tail.contains(where: Self.sentenceEnds.contains) || Self.sentenceEnds.contains(c)
            word = []; tail = []; clean = true
            guard eligible else {
                if !typed.isEmpty || ended { prev = nil }
                return .pass
            }
            return end(typed, punctuation, key: c, after: before)
        }
    }

    /// Fixes `typed`, which `punctuation` and then `c` follow, and the word `before` it with it.
    private mutating func end(_ typed: String, _ punctuation: String, key c: Character,
                              after before: Pending?) -> Act {
        let ended = punctuation.contains(where: Self.sentenceEnds.contains) || Self.sentenceEnds.contains(c)
        // What is erased (`shown`) and what a ⌫ puts back (`typed`): the word before too, when the fix spans it.
        let ahead = prev
        var fixed = words.correct(typed, fr: fr, after: prev) ?? typed, shown = typed, typed = typed
        if let before {
            var both: String?
            if let joined = words.join(before.typed, typed) {
                both = joined
                typed = before.typed + " " + typed
            } else if let (a, b) = words.agree(before.shown, fixed, fr: fr, after: before.prev) {
                if a == before.shown { fixed = b } else { both = a + " " + b; typed = before.shown + " " + typed }
            }
            if let both {
                words.unlearn(before.kept.word, typed: before.kept.typed)
                fixed = both
                shown = before.shown + " " + shown
            }
        }
        fr = ended ? 0.5 : fixed.split(separator: " ").reduce(fr) { words.nextFr($0, after: String($1)) }
        prev = ended || !punctuation.isEmpty || !Self.ends.contains(c) ? nil
            : fixed.split(separator: " ").last.map { $0.lowercased().replacingOccurrences(of: "’", with: "'") }
        kept = (fixed, fixed == typed ? nil : typed)
        if punctuation.isEmpty, c == " ", !shown.contains(" ") { pending = (typed, fixed, ahead, kept!) }
        guard fixed != shown else { return .pass }
        let same = zip(zip(shown, typed), fixed).prefix { $0.0 == $1 && $0.1 == $1 }.count
        let shownTail = String(shown.dropFirst(same)) + punctuation, fixedTail = String(fixed.dropFirst(same)) + punctuation
        // After Return the message may be gone (sent): a ⌫ there is not about the word.
        // The ⌫ takes the space (or period) too: the word is back with the caret after it, so a space
        // he types next is not a second one.
        if c != "\r", c != "\n" { undo = (fixedTail.count + 1, String(typed.dropFirst(same)) + punctuation + (c == " " ? "" : String(c)), typed, fixed) }
        return .edit(delete: shownTail.count, type: fixedTail, thenKey: true)
    }

    /// `text` as it reads once typed through this, a line at a time.
    mutating func fix(_ text: String) -> String {
        var out: [Character] = []
        clean = true
        for c in text + "\n" {
            switch handle(.char(c)) {
            case .pass: out.append(c)
            case let .edit(delete, type, thenKey):
                out.removeLast(delete)
                out += type
                if thenKey { out.append(c) }
            }
        }
        return String(out.dropLast())
    }
}
