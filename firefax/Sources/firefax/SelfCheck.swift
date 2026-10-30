import Foundation

// `firefax --selftest`: the spec parser, the value rules, matching, the pollers, the rails and the
// report, all against FakeAX with an injected clock, keychain and files. No real AX, window, time or
// keychain is touched. Runs before every install (build.sh). The mutation ritual in the README is
// run by hand against these fixtures.

enum SelfCheck {
    static func run() -> Int {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            if got == want { print("  ok    \(what)") }
            else { print("  FAIL  \(what)\n        want \(want)\n        got  \(got)"); failures += 1 }
        }
        func near(_ got: Double, _ want: Double, _ tol: Double, _ what: String) {
            if abs(got - want) <= tol { print("  ok    \(what)") }
            else { print("  FAIL  \(what)\n        want \(want) ± \(tol)\n        got  \(got)"); failures += 1 }
        }

        let iban = "FR7630006000011234567890189"
        let secrets = FakeSecrets(values: ["iban": iban, "sentinel": "ZZSENTINELREF"])

        func engine(human: Bool = false, dry: Bool = false, finals: [String] = [], navSeed: [String: Int] = [:]) -> Engine {
            let clock = FakeClock()
            var e = Engine(clock: clock, store: secrets, files: FakeFiles(values: [:]), nav: FakeNav(clock, seed: navSeed))
            e.human = human; e.dryRun = dry; e.finals = finals
            return e
        }
        func fill(_ tree: String, _ spec: String, human: Bool = false, dry: Bool = false, finals: [String] = [], navSeed: [String: Int] = [:]) -> (Int32, [String], [String: FakeNode]) {
            let (page, tagged) = Fixture.load(tree)
            let e = engine(human: human, dry: dry, finals: finals, navSeed: navSeed)
            let parsed = try! SpecParser.parse(Data(spec.utf8))
            let (code, lines) = e.fill(parsed, page)
            return (code, lines, tagged)
        }

        // ---- value shape rules ----
        expect(Shape.refused(iban) != nil, true, "an IBAN literal is refused")
        expect(Shape.isIBAN(iban), true, "the published example IBAN passes mod-97")
        expect(Shape.refused("FR7630006000011234567890188") == nil, true, "a wrong IBAN check digit is not an IBAN")
        expect(Shape.refused("73282932") == nil, true, "a short number is allowed")
        expect(Shape.refused("18") == nil, true, "a house number is allowed")
        expect(Shape.refused("1234567890123") != nil, true, "13 digits (NIR / numéro fiscal) refused")
        expect(Shape.refused("123456789012345") != nil, true, "15 digits refused")
        expect(Shape.refused("732829320") != nil, true, "a Luhn-valid SIREN (9 digits) refused")
        expect(Shape.refused("732829329") == nil, true, "a 9-digit number failing Luhn is allowed")
        expect(Shape.refused("73282932000074") != nil, true, "a Luhn-valid SIRET (14 digits) refused")
        expect(Shape.refused("4111111111111111") != nil, true, "a Luhn-valid 16-digit card refused")
        expect(Shape.luhn("4111111111111111"), true, "Luhn recognises a valid card")

        // ---- spec parser ----
        func parseFails(_ json: String, _ what: String) {
            do { _ = try SpecParser.parse(Data(json.utf8)); print("  FAIL  \(what) (did not throw)"); failures += 1 }
            catch { print("  ok    \(what)") }
        }
        parseFails(#"{"page":"h/","steps":[{"label":"x","lable":"y","set":"v"}]}"#, "an unknown key is rejected")
        parseFails(#"{"page":"h/","steps":[{"label":"x","set":"a","check":true}]}"#, "two actions in one step rejected")
        parseFails(#"{"page":"h/","steps":[{"set":"a"}]}"#, "a step with no locator rejected")
        parseFails(#"{"page":"h/","steps":[{"label":"x"}]}"#, "a step with no action rejected")
        parseFails(#"{"page":"h/","steps":[{"label":"x","set":{"ref":"a","file":"b"}}]}"#, "a two-key value object rejected")
        parseFails(#"{"page":"h/","steps":[{"label":"x","select":"a","type":"q"}]}"#, "type with a non-pick action rejected")

        // ---- human cadence bounds ----
        let gaps = Cadence.gaps(4000, seed: 12345)
        expect(gaps.min()! >= 60, true, "no gap below the 60 ms floor")
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        near(mean, 239, 45, "mean gap near Dhakal's 239 ms")

        // ---- the address page: name, pick via keys, pick via ax with a dependent field, set, press ----
        let (codeA, linesA, taggedA) = fill(addressTree, addressSpec)
        expect(codeA, 0, "the address page fills, exit 0")
        expect(linesA.contains { $0.contains("1  ok") }, true, "step 1 (name) ok")
        expect(linesA.contains { $0.contains("via keys") }, true, "a pick fell back to a key when AX raised no list")
        expect(linesA.contains { $0.contains("via ax") }, true, "a pick opened its list on the AX write alone")
        expect(taggedA["commune"]!.enabledFlag, true, "the commune field was enabled after the department pick")
        expect(taggedA["nom"]!.storedValue, "NOM PRENOM", "the name landed in the field")
        expect(linesA.contains { $0.contains("5  ok") && $0.contains("press") }, true, "the Suivant press is ok")
        expect(linesA.contains { $0.contains("NOM PRENOM") }, false, "no field value appears in the report")

        // ---- lagging readback: the set still verifies by polling ----
        let (codeL, linesL, _) = fill(oneFieldTree(lag: 2, maxlength: nil, drop: false), oneSetSpec("hello"))
        expect(codeL, 0, "a lagging readback still verifies")
        expect(linesL.contains { $0.contains("verified") && !$0.contains("unverified") }, true, "the set reads back as verified")

        // ---- dropped write: reported failed, never silently ok ----
        let (codeD, _, _) = fill(oneFieldTree(lag: 0, maxlength: nil, drop: true), oneSetSpec("hello"))
        expect(codeD, 1, "a dropped write is a failure, exit 1")

        // ---- maxlength cut on a plain set: failed with a length ----
        let (codeM, linesM, _) = fill(oneFieldTree(lag: 0, maxlength: 4, drop: false), oneSetSpec("ABCDEFG"))
        expect(codeM, 1, "a maxlength cut on a plain set is a failure")
        expect(linesM.contains { $0.contains("len 4 of 7") }, true, "the cut is reported as len 4 of 7")

        // ---- split an IBAN across adjacent boxes, static prefix dropped ----
        let (codeS, linesS, taggedS) = fill(ibanTree, ibanSpec)
        let digits = String(iban.dropFirst(2))
        expect(codeS, 0, "the IBAN splits across the boxes, exit 0")
        expect(taggedS["b0"]!.storedValue, "7630", "box 0 holds the check digits, not the country code")
        let joined = (0..<7).map { taggedS["b\($0)"]!.storedValue }.joined()
        expect(joined, digits, "the boxes together hold the whole IBAN after FR")
        expect(linesS.contains { $0.contains("verified") && !$0.contains("unverified") }, true, "the split verifies")

        // ---- ambiguous label vs an explicit nth ----
        let (codeAmb, linesAmb, _) = fill(twoNomTree, #"{"page":"h/f","steps":[{"label":"Nom","set":"X"}]}"#)
        expect(codeAmb, 1, "an ambiguous label fails")
        expect(linesAmb.contains { $0.contains("ambiguous") && $0.contains("2 matches") }, true, "it says ambiguous with the count")
        let (codeNth, _, _) = fill(twoNomTree, #"{"page":"h/f","steps":[{"label":"Nom","nth":2,"set":"X"}]}"#)
        expect(codeNth, 0, "an explicit nth resolves the tie")

        // ---- password field refused ----
        let (codePw, linesPw, _) = fill(passwordTree, #"{"page":"h/f","steps":[{"id":"pw","set":"x"}]}"#)
        expect(codePw, 4, "a secure field is refused, exit 4")
        expect(linesPw.contains { $0.contains("refused") }, true, "the password step is refused")

        // ---- challenge page and session expiry ----
        let (codeCh, _, _) = fill(challengeTree, #"{"page":"h/f","steps":[{"id":"x","set":"v"}]}"#)
        expect(codeCh, 5, "a challenge page exits 5")
        let (codeEx, _, _) = fill(expiredTree, #"{"page":"h/f","steps":[{"id":"x","set":"v"}]}"#)
        expect(codeEx, 3, "session expirée exits 3")

        // ---- redirect mid-run ----
        let (codeRd, linesRd, _) = fill(redirectTree, #"{"page":"h/f","steps":[{"id":"r1","set":"hello"},{"id":"r2","set":"x"}]}"#)
        expect(codeRd, 3, "a redirect mid-run exits 3")
        expect(linesRd.contains { $0.contains("1  ok") }, true, "the step before the redirect stayed ok")

        // ---- press allowlist and --final ----
        let (codePv, _, _) = fill(validerTree, #"{"page":"h/f","steps":[{"label":"Valider","press":true}]}"#)
        expect(codePv, 4, "a committing button without --final is refused")
        let (codePf, _, _) = fill(validerTree, #"{"page":"h/f","steps":[{"label":"Valider","press":true}]}"#, finals: ["Valider"])
        expect(codePf, 0, "--final 'Valider' allows it")

        // ---- a press must be last, at most one ----
        let (codeOrder, _, _) = fill(addressTree, #"{"page":"example.test/form","steps":[{"label":"Suivant","press":true},{"id":"numero","set":"1"}]}"#)
        expect(codeOrder, 2, "a press that is not the last step is a bad spec")

        // ---- navigation cap ----
        let (codeCap, _, _) = fill(validerTree, #"{"page":"h/f","steps":[{"label":"Suivant","press":true}]}"#, navSeed: ["h": 20])
        expect(codeCap, 4, "the 20/h navigation cap refuses the press")

        // ---- dry-run writes nothing ----
        let (codeDry, linesDry, taggedDry) = fill(oneFieldTree(lag: 0, maxlength: nil, drop: false), oneSetSpec("hello"), dry: true)
        expect(codeDry, 0, "dry-run resolves and exits 0")
        expect(taggedDry["f"]!.storedValue, "", "dry-run wrote nothing to the field")
        expect(linesDry.contains { $0.contains("dry") }, true, "dry-run marks the step")
        let (codeDryRef, _, _) = fill(oneFieldTree(lag: 0, maxlength: nil, drop: false), #"{"page":"h/f","steps":[{"id":"f","set":"FR7630006000011234567890189"}]}"#, dry: true)
        expect(codeDryRef, 4, "dry-run still refuses a shaped literal before any live run")

        // ---- sentinel leak: neither a literal nor a ref value appears anywhere in the output ----
        let (_, linesSen, _) = fill(twoFieldTree, #"{"page":"h/f","steps":[{"id":"a","set":"ZZSENTINELLIT"},{"id":"b","set":{"ref":"sentinel"}}]}"#)
        let blob = linesSen.joined(separator: "\n")
        expect(blob.contains("ZZSENTINEL"), false, "no sentinel value (literal or ref) leaks into the report")

        // ---- scan lists controls, never values ----
        let (page, _) = Fixture.load(addressTree)
        let (scanCode, scanLines) = engine().scan(page)
        expect(scanCode, 0, "scan exits 0")
        expect(scanLines.first!.contains("controls 5"), true, "scan counts the five controls")
        expect(scanLines.joined().contains("Suivant"), true, "scan shows the button locator")

        // ---- report option allowlist keeps postal codes, hides other digit tokens ----
        expect(Report.allowlist("RUE DE L EXEMPLE 75001 PARIS"), "RUE DE L EXEMPLE 75001 PARIS", "a 5-digit postal code is kept")
        expect(Report.allowlist("LOT 123456"), "LOT <6>", "a 6-digit token becomes its length")
        expect(Report.allowlist("SIRET 732 829 320 00074"), "SIRET <14>", "grouped digits join before the length")

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) checks failed")
        return failures
    }

    // ---- fixtures ----

    static func oneFieldTree(lag: Int, maxlength: Int?, drop: Bool) -> String {
        """
        {"host":"h","path":"/f","root":{"role":"AXWebArea","url":"https://h/f","children":[
          {"role":"AXTextField","id":"f","tag":"f","readbackLag":\(lag),\(maxlength.map { "\"maxlength\":\($0)," } ?? "")"dropWrite":\(drop)}
        ]}}
        """
    }
    static func oneSetSpec(_ v: String) -> String { #"{"page":"h/f","steps":[{"id":"f","set":"\#(v)"}]}"# }

    static let twoFieldTree = """
    {"host":"h","path":"/f","root":{"role":"AXWebArea","url":"https://h/f","children":[
      {"role":"AXTextField","id":"a","tag":"a"},
      {"role":"AXTextField","id":"b","tag":"b"}
    ]}}
    """

    static let twoNomTree = """
    {"host":"h","path":"/f","root":{"role":"AXWebArea","url":"https://h/f","children":[
      {"role":"AXTextField","title":"Nom"},
      {"role":"AXTextField","title":"Nom"}
    ]}}
    """

    static let passwordTree = """
    {"host":"h","path":"/f","root":{"role":"AXWebArea","url":"https://h/f","children":[
      {"role":"AXTextField","id":"pw","title":"Mot de passe","subrole":"AXSecureTextField"}
    ]}}
    """

    static let challengeTree = """
    {"host":"h","path":"/f","root":{"role":"AXWebArea","url":"https://h/f","children":[
      {"role":"AXTextField","id":"x"},
      {"role":"AXWebArea","url":"https://challenges.cloudflare.com/turnstile"}
    ]}}
    """

    static let expiredTree = """
    {"host":"h","path":"/f","root":{"role":"AXWebArea","url":"https://h/f","children":[
      {"role":"AXStaticText","value":"Votre session a expiré, session expirée"},
      {"role":"AXTextField","id":"x"}
    ]}}
    """

    static let redirectTree = """
    {"host":"h","path":"/f","root":{"role":"AXWebArea","url":"https://h/f","children":[
      {"role":"AXTextField","id":"r1","tag":"r1","navigate":true},
      {"role":"AXTextField","id":"r2","tag":"r2"}
    ]},
    "alt":{"role":"AXWebArea","url":"https://h/next","children":[{"role":"AXTextField","id":"r2"}]}}
    """

    static let validerTree = """
    {"host":"h","path":"/f","root":{"role":"AXWebArea","url":"https://h/f","children":[
      {"role":"AXButton","title":"Valider"},
      {"role":"AXButton","title":"Suivant"}
    ]}}
    """

    static let ibanTree: String = {
        let boxes = (0..<7).map { "{\"role\":\"AXTextField\",\"id\":\"iban\($0)\",\"tag\":\"b\($0)\",\"maxlength\":4}" }.joined(separator: ",\n      ")
        return """
        {"host":"h","path":"/f","root":{"role":"AXWebArea","url":"https://h/f","children":[
          {"role":"AXStaticText","value":"IBAN"},
          \(boxes)
        ]}}
        """
    }()
    static let ibanSpec = #"{"page":"h/f","steps":[{"id":"iban0","split":{"ref":"iban"},"prefix":"FR"}]}"#

    static let addressTree = """
    {"host":"example.test","path":"/form","root":{"role":"AXWebArea","url":"https://example.test/form","children":[
      {"role":"AXStaticText","value":"Nom du titulaire"},
      {"role":"AXTextField","id":"nom","tag":"nom"},
      {"role":"AXStaticText","value":"Département"},
      {"role":"AXComboBox","id":"dept","tag":"dept","revealKey":"listDept","children":[
        {"role":"AXList","id":"listDept","hidden":true,"lateChildren":2,"children":[
          {"role":"AXStaticText","value":"01 - AIN","fills":"dept"},
          {"role":"AXStaticText","value":"75 - PARIS","fills":"dept"}
        ]}
      ]},
      {"role":"AXStaticText","value":"Commune"},
      {"role":"AXComboBox","id":"commune","tag":"commune","enabled":false,"enabledAfterPick":true,"revealSet":"listCommune","children":[
        {"role":"AXList","id":"listCommune","hidden":true,"children":[
          {"role":"AXStaticText","value":"PARIS 1ER","fills":"commune"}
        ]}
      ]},
      {"role":"AXStaticText","value":"Numéro"},
      {"role":"AXTextField","id":"numero","tag":"numero"},
      {"role":"AXButton","title":"Suivant"}
    ]}}
    """
    static let addressSpec = """
    {"page":"example.test/form","steps":[
      {"label":"Nom du titulaire","set":"NOM PRENOM"},
      {"id":"dept","type":"75","pick":"75 - PARIS"},
      {"id":"commune","type":"paris","pick":"PARIS 1ER"},
      {"id":"numero","set":"18"},
      {"label":"Suivant","press":true}
    ]}
    """
}
