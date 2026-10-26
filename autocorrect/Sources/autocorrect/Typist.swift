/// What each keystroke does to the text in front of him: it follows the word being typed, fixes
/// it when a space or Return ends it (with any punctuation typed after it: "tres." too), and takes
/// the fix back on a ⌫ right after. A letter right after that punctuation makes it a link or an
/// abbreviation (etudiant.gouv.fr, e.g), left alone.
///
/// It sees keys, not the text field. So a word is only fixed when this process saw it start,
/// right after a space or Return: after a click, an arrow or a ⌘ shortcut the caret may be in
/// the middle of a word it never saw, and that word is left alone up to the next space.
struct Typist {
    enum Key { case char(Character), backspace, reset }
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
    private var undo: (delete: Int, type: String, typed: String, fixed: String)?
    /// The last word, counted as his once the next key shows he kept it.
    private var kept: String?

    init(_ words: Words) { self.words = words }

    mutating func handle(_ key: Key) -> Act {
        let last = undo
        undo = nil
        if case .backspace = key {} else if let w = kept { words.learn(w); kept = nil }
        switch key {
        case .reset:
            word = []; tail = []; clean = false; fr = 0.5
            return .pass
        case .backspace:
            if let u = last {
                words.reject(u.typed, u.fixed)
                kept = u.typed
                word = []; tail = []; clean = true
                return .edit(delete: u.delete, type: u.type, thenKey: false)
            }
            kept = nil
            if !tail.isEmpty { tail.removeLast() } else if !word.isEmpty { word.removeLast() } else { clean = false }
            return .pass
        case .char(let c):
            if tail.isEmpty, c.isLetter || (!word.isEmpty && (c == "'" || c == "’" || c == "-")) {
                word.append(c)
                return .pass
            }
            if word.isEmpty, Self.before.contains(c) || Self.after.contains(c) { return .pass }
            if Self.after.contains(c) {
                tail.append(c)
                return .pass
            }
            guard Self.ends.contains(c) else {
                // A digit, @, /, _, or a letter after a dot: not prose (a link, an address).
                word = []; tail = []; clean = false
                return .pass
            }
            let typed = String(word), punctuation = String(tail)
            let eligible = clean && !word.isEmpty
            let ended = tail.contains(where: Self.sentenceEnds.contains) || Self.sentenceEnds.contains(c)
            word = []; tail = []; clean = true
            guard eligible else { return .pass }
            let fixed = words.correct(typed, fr: fr) ?? typed
            fr = ended ? 0.5 : words.nextFr(fr, after: fixed)
            kept = fixed
            guard fixed != typed else { return .pass }
            let same = zip(typed, fixed).prefix { $0 == $1 }.count
            let typedTail = String(typed.dropFirst(same)) + punctuation, fixedTail = String(fixed.dropFirst(same)) + punctuation
            // After Return the message may be gone (sent): a ⌫ there is not about the word.
            if c != "\r", c != "\n" { undo = (fixedTail.count + 1, typedTail + String(c), typed, fixed) }
            return .edit(delete: typedTail.count, type: fixedTail, thenKey: true)
        }
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
