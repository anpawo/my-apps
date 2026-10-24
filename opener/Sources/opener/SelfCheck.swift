import AppKit
import Carbon.HIToolbox

/// `opener --selftest`: the ranking and the keys, on made-up apps. Runs headless, before every install.
@MainActor
enum SelfCheck {
    static func run() -> Int {
        var failures = 0
        func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            if got == want { print("  ok    \(what)") } else {
                print("  FAIL  \(what)\n        want \(want)\n        got  \(got)")
                failures += 1
            }
        }

        let names = ["Firefox", "FaceTime", "Finder", "Visual Studio Code", "Terminal", "Activity Monitor",
                     "System Settings", "Élève"]
        let apps = names.map { AppEntry(path: "/x/\($0).app", name: $0) }
        func top(_ query: String, _ uses: [String: Int] = [:]) -> [String] {
            Rank.matches(query, in: apps, uses: uses).map(\.name)
        }
        expect(top("fi"), ["Finder", "Firefox", "FaceTime"], "the start of the name, the shorter first, then letters in order")
        expect(top("fi", ["/x/Firefox.app": 3]).first, "Firefox", "the one opened most often first")
        expect(top("vsc").first, "Visual Studio Code", "initials")
        expect(top("mon").first, "Activity Monitor", "the start of a word")
        expect(top("ff"), ["Firefox"], "letters in order")
        expect(top("ELEVE"), ["Élève"], "neither accents nor case count")
        expect(top("zzz"), [], "no match, no row")
        expect(top("  "), [], "nothing typed, nothing shown")

        _ = NSApplication.shared
        let opener = Opener()
        opener.apps = apps
        @discardableResult
        func press(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
            return opener.key(event)
        }
        press(kVK_ANSI_T, "t")
        press(kVK_ANSI_E, "e")
        expect(opener.query, "te", "letters type")
        expect(opener.results.first?.name, "Terminal", "and the list follows")
        press(kVK_DownArrow, "\u{F701}")
        expect(opener.index, 1, "↓ moves down")
        press(kVK_UpArrow, "\u{F700}")
        press(kVK_UpArrow, "\u{F700}")
        expect(opener.index, opener.results.count - 1, "↑ from the top wraps to the bottom")
        press(kVK_Delete, "\u{7F}")
        expect(opener.query, "t", "⌫ takes a letter")
        press(kVK_Delete, "\u{7F}", .command)
        expect(opener.query, "", "⌘⌫ takes them all")
        expect(press(kVK_ANSI_Q, "q", .command), false, "a ⌘ chord is not typed")
        expect(press(kVK_F5, "\u{F708}"), false, "nor a function key")
        expect(Catalog.apps().contains { $0.name == "Finder" }, true, "Finder is listed")
        return failures
    }
}
