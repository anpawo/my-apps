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
struct Typist {
    enum Key: Equatable {
        case char(Character), backspace, reset
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

    init(_ words: Words) { self.words = words }

    mutating func handle(_ key: Key) -> Act {
        let last = undo, wasEarly = early
        undo = nil; early = false
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
        case .reset, .focus:
            word = []; tail = []; clean = key == .focus; fr = 0.5; prev = nil
            return .pass
        case .backspace:
            if let u = last {
                words.reject(u.typed, u.fixed)
                kept = (u.typed, nil)
                word = []; tail = []; clean = true; prev = nil
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
                return .pass
            }
            if tail.isEmpty, clean, !word.isEmpty, c == "." || c == "," {
                let typed = String(word)
                word = []; tail = [c]
                let act = end(typed, "", key: c)
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
            return end(typed, punctuation, key: c)
        }
    }

    /// Fixes `typed`, which `punctuation` and then `c` follow.
    private mutating func end(_ typed: String, _ punctuation: String, key c: Character) -> Act {
        let ended = punctuation.contains(where: Self.sentenceEnds.contains) || Self.sentenceEnds.contains(c)
        let fixed = words.correct(typed, fr: fr, after: prev) ?? typed
        fr = ended ? 0.5 : fixed.split(separator: " ").reduce(fr) { words.nextFr($0, after: String($1)) }
        prev = ended || !punctuation.isEmpty || !Self.ends.contains(c) ? nil
            : fixed.split(separator: " ").last.map { $0.lowercased().replacingOccurrences(of: "’", with: "'") }
        kept = (fixed, fixed == typed ? nil : typed)
        guard fixed != typed else { return .pass }
        let same = zip(typed, fixed).prefix { $0 == $1 }.count
        let typedTail = String(typed.dropFirst(same)) + punctuation, fixedTail = String(fixed.dropFirst(same)) + punctuation
        // After Return the message may be gone (sent): a ⌫ there is not about the word.
        if c != "\r", c != "\n" { undo = (fixedTail.count + 1, typedTail + String(c), typed, fixed) }
        return .edit(delete: typedTail.count, type: fixedTail, thenKey: true)
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
