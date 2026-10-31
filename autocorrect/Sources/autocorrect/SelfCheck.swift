import Foundation

/// `autocorrect --selftest`: the choices and the keys, on the real lexicon with nothing learned.
/// Runs headless, before every install.
enum SelfCheck {
    static func run(_ file: URL) -> Int {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            if got == want { print("  ok    \(what)") } else {
                print("  FAIL  \(what)\n        want \(want)\n        got  \(got)")
                failures += 1
            }
        }
        let words = Words(file: file, learned: nil)
        expect(words.count > 200_000, true, "the lexicon loads (\(words.count) words)")
        func fix(_ text: String) -> String { var t = Typist(words); return t.fix(text) }

        for (typed, want, what) in [
            ("ca va tres bien", "ça va très bien", "accents a French word cannot go without"),
            ("je suis deja la", "je suis déjà la", "la/là, ou/où, a/à: both are words, left as typed"),
            ("ou est le probleme", "ou est le problème", ""),
            ("a la maison", "a la maison", ""),
            ("cest pas grave", "c'est pas grave", "apostrophes"),
            ("jai faim", "j'ai faim", ""),
            ("quil vienne", "qu'il vienne", ""),
            ("j'etais la", "j'étais la", "an elision typed with its apostrophe: only its word"),
            ("aujourdhui", "aujourd'hui", ""),
            ("peutetre", "peut-être", "hyphens"),
            ("peut-etre", "peut-être", ""),
            ("le francais", "le français", "cedilla"),
            ("mon coeur", "mon cœur", "œ"),
            ("Deja", "Déjà", "case kept"),
            ("DEJA", "DEJA", "a capital inside the word: an acronym or a name"),
            ("GitHub macOS", "GitHub macOS", ""),
            ("d’un", "d’un", "his apostrophe, curly or not"),
            ("l’etat", "l’état", ""),
            ("chat scan width", "chat scan width", "a real word is never made into another one"),
            ("popup mo-recon", "popup mo-recon", "nor are hyphens added in English or dropped"),
            ("vasy", "vas-y", "but they are added in French"),
            ("dautre", "d'autre", "an elision before a typo"),
            ("screenshots", "screenshots", "a plural is not a typo"),
            ("verifie ca", "verifie ça", "vérifie or vérifié: too close to call, left as typed"),
            ("i dont know", "I don't know", "English after English: dont is don't"),
            ("la maison dont je parle", "la maison dont je parle", "French after French: dont stays"),
            ("im tired", "I'm tired", ""),
            ("teh cat", "the cat", "a typo, one letter off"),
            ("c'est vraiemtn cool", "c'est vraiment cool", "two swaps"),
            ("because of teh becuase", "because of the because", ""),
            ("le role", "le rôle", "rôle in French"),
            ("the role", "the role", "role in English"),
            ("smth like that", "smth like that", "an abbreviation without vowels"),
            ("Basile est la", "Basile est la", "a name is not a typo"),
            ("it's fine", "it's fine", "an English contraction"),
            ("github.com/tres ok", "github.com/tres ok", "not after a / (a link)"),
            ("messervices.etudiant.gouv.fr ok", "messervices.etudiant.gouv.fr ok", "nor in a domain"),
            ("e.g. tres", "e.g. très", ""),
            ("il est tres bien. (tres)", "il est très bien. (très)", "punctuation around the word"),
            ("une côte", "une côte", "a word he typed with its accents stays"),
            ("tres2 ok", "tres2 ok", "not with a digit"),
        ] {
            expect(fix(typed), want, what.isEmpty ? typed : "\(what): \(typed)")
        }

        var t = Typist(words)
        t.clean = true
        for c in "deja" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .edit(delete: 3, type: "éjà", thenKey: true), "space fixes the word, erasing from the first letter that changes")
        expect(t.handle(.backspace), .edit(delete: 4, type: "eja ", thenKey: false), "⌫ right after puts back what was typed")
        for c in "deja" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .pass, "and the same word is then left alone")
        _ = t.handle(.reset)
        for c in "tres" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .pass, "a word begun after an arrow is never fixed")
        for c in "tres" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .edit(delete: 2, type: "ès", thenKey: true), "the next one is")
        _ = t.handle(.focus)
        for c in "probleme" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .edit(delete: 3, type: "ème", thenKey: true), "one begun after a click, in another app or after a paste is")
        _ = t.handle(.char("x"))
        expect(t.handle(.backspace), .pass, "⌫ after another key is a plain ⌫")
        for c in " ca" { _ = t.handle(.char(c)) }
        expect(t.handle(.char("\r")), .edit(delete: 2, type: "ça", thenKey: true), "Return fixes too")
        expect(t.handle(.backspace), .pass, "but a ⌫ after Return does not take it back")
        for c in " apres." { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .edit(delete: 3, type: "ès.", thenKey: true), "punctuation after the word is typed again")
        expect(t.handle(.backspace), .edit(delete: 4, type: "es. ", thenKey: false), "and taken back with it")
        for c in " tr" { _ = t.handle(.char(c)) }
        _ = t.handle(.backspace)
        for c in "res" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .edit(delete: 2, type: "ès", thenKey: true), "⌫ inside a word follows it")

        expect(words.correct("eip", fr: 0.5), "épi", "a word the lexicon lacks scores 0 itself")
        words.reject("eip", "épi")
        expect(words.correct("eip", fr: 0.5), nil, "yet one ⌫ is enough to stop that fix")

        words.keep("tema", "team")
        for word in ["team", "epitehc", "dont"] { words.learn(word) }
        words.reject("dont", "don't")
        var seen = Review.Seen()
        let batch = Review.Batch(words.mine, seen)
        let verdict = Review.Verdict(forget: [.init(word: "epitehc", why: ""), .init(word: "epitehc", why: ""), .init(word: "the", why: "")],
                                     reject: [.init(typed: "tema", fixed: "team", why: "")],
                                     unrefuse: [.init(typed: "dont", fixed: "don't", why: "")])
        expect(Review.apply(verdict, batch, to: words, seen: &seen).count, 2, "the review applies its verdict, once, and only")
        expect(words.mine.counts["the"] != nil && words.mine.rejected["dont\tdon't"] != nil, true, "where the lexicon agrees")
        expect(words.correct("tema", fr: 0.5), nil, "a fix it rejects is never made again")
        expect([words.mine.counts["team"], words.mine.counts["epitehc"]], [nil, nil], "nor counted as his word, and a word it forgets is gone")
        expect(Review.Batch(words.mine, seen).isEmpty, true, "and what it read is not sent again")

        expect(words.correct("enfusion", fr: 0.5), "effusion", "a word the lexicon lacks may be fixed as a typo")
        expect(words.seed(["enfusion": 40, "tres": 40, "the": 40, "dautre": 40, "j'aimerais": 40]), 1,
               "a seed takes his own words, not a lexicon word nor one missing its accents or apostrophe")
        expect([words.correct("enfusion", fr: 0.5), words.correct("tres", fr: 0.95), words.correct("dautre", fr: 0.95)], [nil, "très", "d'autre"],
               "and then leaves them, while tres and dautre are still fixed")
        return failures
    }
}
