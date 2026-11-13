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
            ("j'ai verifie ca", "j'ai vérifié ça", "unless the word before settles it"),
            ("il verifie ca", "il vérifie ça", ""),
            ("je vais a Paris", "je vais à Paris", "à after vais"),
            ("il a faim", "il a faim", "a after il"),
            ("mais ou est le probleme", "mais où est le problème", ""),
            ("le marche est ferme", "le marché est fermé", ""),
            ("je marche", "je marche", ""),
            ("je vais. a la maison", "je vais. a la maison", "punctuation cuts the context"),
            ("i dont know", "I don't know", "English after English: dont is don't"),
            ("la maison dont je parle", "la maison dont je parle", "French after French: dont stays"),
            ("im tired", "I'm tired", ""),
            ("teh cat", "the cat", "a typo, one letter off"),
            ("wnat wiat", "wnat wiat", "a swap against a likelier word a far key away: too close to call, not what"),
            ("aveen theya", "aveen they", "never into a rare word he does not type (aven), nor a junk accent (theyâ)"),
            ("dand la maison", "dans la maison", "no elision before an English word: not d'and"),
            ("tils", "t-ils", "t' never before a pronoun"),
            ("blojob", "blojob", "never into a rude word"),
            ("what isthe plan", "what is the plan", "a space missed, put back"),
            ("i think ofthe kids", "I think of the kids", "even one the subtitles spell (ofthe)"),
            ("the worktree is clean", "the worktree is clean", "not into two words seldom said together"),
            ("c'est vraiemtn cool", "c'est vraiment cool", "two swaps"),
            ("it should dispaear", "it should disappear", "a swap and a missed double letter"),
            ("for thew height", "for the height", "a word too rare to count, though macOS knows it"),
            ("i shoul go", "I should go", "a d left off is a typo, not another form"),
            ("because of teh becuase", "because of the because", ""),
            ("le role", "le rôle", "rôle in French"),
            ("the role", "the role", "role in English"),
            ("smth like that", "smth like that", "an abbreviation without vowels"),
            ("Basile est la", "Basile est la", "a name is not a typo"),
            ("it's fine", "it's fine", "an English contraction"),
            ("github.com/tres ok", "github.com/tres ok", "not after a / (a link)"),
            ("messervices.etudiant.gouv.fr ok", "messervices.etudiant.gouv.fr ok", "nor in a domain"),
            ("e.g. tres", "e.g. très", ""),
            ("etudiant.gouv.fr tres, ok", "etudiant.gouv.fr très, ok", "a word the period fixed is put back in a link"),
            ("il est tres bien. (tres)", "il est très bien. (très)", "punctuation around the word"),
            ("une côte", "une côte", "a word he typed with its accents stays"),
            ("tres2 ok", "tres2 ok", "not with a digit"),
            ("une infor mation", "une information", "a space fallen inside a word, taken out"),
            ("il et parti", "il est parti", "a real word wrong by the words on both sides"),
            ("their is a cat", "there is a cat", ""),
            ("ils son partis", "ils sont partis", ""),
            ("des enfant jouent", "des enfants jouent", "a noun takes the number its determiner sets"),
            ("une courte et évidente phrase", "une courte et évidente phrase", "et stays where it fits"),
            ("ses récits et ses demandes", "ses récits et ses demandes", "ses is never made ces"),
        ] {
            expect(fix(typed), want, what.isEmpty ? typed : "\(what): \(typed)")
        }

        expect([Words.slip("wnat", "want"), Words.slip("wnat", "what"), Words.slip("wiat", "what")], [0.03, 0.01, 0.002],
               "a swap, then a key next to the right one, then a far one")

        var t = Typist(words)
        t.clean = true
        for c in "deja" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .edit(delete: 3, type: "éjà", thenKey: true), "space fixes the word, erasing from the first letter that changes")
        expect(t.handle(.backspace), .edit(delete: 4, type: "eja ", thenKey: false), "⌫ right after puts back what was typed")
        for c in "deja" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .pass, "and the same word is then left alone")
        for c in "il et parti" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .edit(delete: 7, type: "st parti", thenKey: true), "the word before is put right once the next one ends")
        expect(t.handle(.backspace), .edit(delete: 9, type: "t parti ", thenKey: false), "and ⌫ puts both back")
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
        for c in " apres" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(".")), .edit(delete: 2, type: "ès", thenKey: true), "a period fixes the word at once, as a space does")
        expect(t.handle(.backspace), .edit(delete: 3, type: "es.", thenKey: false), "and ⌫ takes it back with the period")
        for c in " tres" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(",")), .edit(delete: 2, type: "ès", thenKey: true), "so does a comma")
        expect(t.handle(.char(" ")), .pass, "and the space after it fixes nothing more")
        for c in "tres" { _ = t.handle(.char(c)) }
        _ = t.handle(.char("."))
        expect(t.handle(.char("c")), .edit(delete: 3, type: "es.", thenKey: true), "a letter after that period puts the word back: a link")
        for c in "om tres!" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .edit(delete: 3, type: "ès!", thenKey: true), "other punctuation after the word is typed again on space")
        for c in " tr" { _ = t.handle(.char(c)) }
        _ = t.handle(.backspace)
        for c in "res" { _ = t.handle(.char(c)) }
        expect(t.handle(.char(" ")), .edit(delete: 2, type: "ès", thenKey: true), "⌫ inside a word follows it")

        expect(words.correct("eip", fr: 0.5), "épi", "a word the lexicon lacks scores 0 itself")
        words.reject("eip", "épi")
        expect(words.correct("eip", fr: 0.5), nil, "yet one ⌫ is enough to stop that fix")
        words.reject("eip", "épi", at: Date() - Words.refusalHold - 60)
        expect(words.correct("eip", fr: 0.5), "épi", "for ten minutes only")
        words.reject("eip", "épi")
        let past = Date() - Words.refusalHold - 60
        words.reject("quil", "qu'il", at: past)
        expect(words.correct("quil", fr: 0.5), "qu'il", "a sure fix outlives a stray ⌫")
        for _ in 0..<20 { words.reject("quil", "qu'il", at: past) }
        expect(words.correct("quil", fr: 0.5), nil, "but each refusal weighs it a little less")

        for _ in 0..<200 { words.learn("ca") }
        expect([words.mine.counts["ca"] == nil ? "" : "counted", fix("ca va")], ["", "ça va"],
               "a word missing its marks, kept unfixed, never counts as his: ca stays fixed")
        words.keep("tema", "team")
        for word in ["team", "epitehc", "dont", "house"] { words.learn(word) }
        words.reject("dont", "don't")
        var seen = Review.Seen()
        let batch = Review.Batch(words.mine, seen)
        let verdict = Review.Verdict(forget: [.init(word: "epitehc", why: ""), .init(word: "epitehc", why: ""), .init(word: "house", why: "")],
                                     reject: [.init(typed: "tema", fixed: "team", why: "")],
                                     unrefuse: [.init(typed: "dont", fixed: "don't", why: "")])
        expect(Review.apply(verdict, batch, to: words, seen: &seen).count, 2, "the review applies its verdict, once, and only")
        expect(words.mine.counts["house"] != nil && words.mine.rejected["dont\tdon't"] != nil, true, "where the lexicon agrees")
        expect(words.correct("tema", fr: 0.5), nil, "a fix it rejects is held off too")
        expect([words.mine.counts["team"], words.mine.counts["epitehc"]], [nil, nil], "nor counted as his word, and a word it forgets is gone")
        expect(Review.Batch(words.mine, seen).isEmpty, true, "and what it read is not sent again")

        expect(words.correct("enfusion", fr: 0.5), "en fusion", "a word the lexicon lacks may be fixed")
        expect(words.seed(["enfusion": 40, "tres": 40, "the": 40, "dautre": 40, "j'aimerais": 40]), 1,
               "a seed takes his own words, not a lexicon word nor one missing its accents or apostrophe")
        expect([words.correct("enfusion", fr: 0.5), words.correct("tres", fr: 0.95), words.correct("dautre", fr: 0.95)], [nil, "très", "d'autre"],
               "and then leaves them, while tres and dautre are still fixed")

        var long = Typist(words)
        long.clean = true
        for c in String(repeating: "abcd", count: 16) { _ = long.handle(.char(c)) }
        expect(long.word.count <= 30, true, "long tokens keep the keyboard buffer bounded")
        expect(long.handle(.char(" ")), .pass, "a long token is left untouched")
        for c in "tres" { _ = long.handle(.char(c)) }
        expect(long.handle(.char(" ")), .edit(delete: 2, type: "ès", thenKey: true), "correction resumes after a long token")
        for c in "word" + String(repeating: ".", count: 1000) { _ = long.handle(.char(c)) }
        expect(long.tail.count <= 30, true, "punctuation cannot grow the keyboard buffer without a limit")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let seed = folder.appendingPathComponent("seed.tsv")
            let text = (0..<100).map { "qza\(Character(UnicodeScalar(97 + $0 / 26)!))\(Character(UnicodeScalar(97 + $0 % 26)!))\t1" }.joined(separator: "\n")
            try text.write(to: seed, atomically: true, encoding: .utf8)
            let imported = Words(file: file, learned: folder.appendingPathComponent("learned.json"))
            var finished = false, yielded = false
            Review.takeSeed(imported, folder) { finished = true }
            expect(finished, false, "seed import returns before doing its spellchecks")
            DispatchQueue.main.async {
                yielded = !finished
                try? "enfusion\t1\n".write(to: seed, atomically: true, encoding: .utf8)
            }
            let deadline = Date(timeIntervalSinceNow: 10)
            while !finished && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
            expect(finished && yielded, true, "seed import yields to input handling before it finishes")
            expect(imported.mine.counts.count > 0, true, "batched seed import still learns its words")
            expect((try? String(contentsOf: seed, encoding: .utf8)), "enfusion\t1\n", "a new seed arriving during import is preserved")
            let restored = Words(file: file, learned: folder.appendingPathComponent("learned.json"))
            expect(restored.mine.counts, imported.mine.counts, "batched seed import saves what it learned")
            finished = false
            Review.takeSeed(imported, folder) { finished = true }
            while !finished && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
            expect(finished && imported.mine.counts["enfusion"] == 1, true, "the next import takes the new seed")
            expect(FileManager.default.fileExists(atPath: seed.path), false, "completed seed import removes its input")
        } catch {
            expect(false, true, "seed fixture: \(error)")
        }
        return failures
    }

    static func benchmark(_ file: URL) -> Int {
        let words = Words(file: file, learned: nil)
        var failures = 0
        for (label, text) in [("known", "hello"), ("accent", "tres"), ("typo", "becuase"),
                              ("two_swaps", "vraiemtn"), ("identifier", "dependencyresolver"),
                              ("long_token", String(repeating: "abcd", count: 16))] {
            var times: [Double] = []
            for _ in 0..<30 {
                var typist = Typist(words)
                typist.clean = true
                for c in text { _ = typist.handle(.char(c)) }
                let start = ProcessInfo.processInfo.systemUptime
                _ = typist.handle(.char(" "))
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            times.sort()
            let maximum = times.last!
            let row: [String: Any] = ["case": label, "samples": times.count, "median_ms": times[times.count / 2],
                                      "p95_ms": times[Int(Double(times.count - 1) * 0.95)], "max_ms": maximum, "budget_ms": 16]
            print(String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            if maximum > 16 { failures += 1 }
        }
        return failures
    }
}
