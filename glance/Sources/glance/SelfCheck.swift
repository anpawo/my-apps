import AppKit
import Carbon.HIToolbox
import SwiftUI
import CoreMedia
import Speech

/// `glance --selftest`: what goes to `claude` and what comes back, the keys, the Markdown, the image size. Runs
/// headless, with no `claude` and no screen, before every install. `--ask` is the check of the path to Claude itself.
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
        func line(_ s: String) -> Data { Data(s.utf8) }

        typealias E = Conversation.Event
        expect(Conversation.event(line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"len"}}}"#)),
               E.text("len"), "a text delta is text")
        expect(Conversation.event(line(#"{"type":"stream_event","event":{"type":"content_block_start","index":0}}"#)), nil, "other stream events are nothing")
        expect(Conversation.event(line(#"{"type":"result","subtype":"success","is_error":false,"result":"All of it"}"#)),
               E.done("All of it"), "a result ends the turn with the whole answer")
        expect(Conversation.event(line(#"{"type":"result","subtype":"success","is_error":true,"result":"Claude usage limit reached"}"#)),
               E.failed("Claude usage limit reached"), "an error result says why")
        expect(Conversation.event(line(#"{"type":"system","subtype":"init"}"#)), nil, "the init line is nothing")
        expect(Conversation.event(line("not json")), nil, "a stray line is nothing")

        let sent = try? JSONSerialization.jsonObject(with: Conversation.message("hi", image: Data([1, 2, 3]))) as? [String: Any]
        let content = (sent?["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        expect(content.map { $0["type"] as? String ?? "" }, ["image", "text"], "the screenshot goes before the words")
        expect((content.first?["source"] as? [String: String])?["data"], "AQID", "the screenshot as base64")
        expect(Conversation.question("", app: "Safari"), "In front: Safari.\n\n(Nothing typed: help with what is on the screen.)",
               "nothing typed asks for help with the screen, naming the app")
        expect(Conversation.question("why?", app: nil), "why?", "a follow-up without a screen is the words alone")
        expect(Conversation.question("", app: "Zoom", heard: "Sound from the computer, 0:12, transcribed:\nAny questions?"),
               "In front: Zoom.\n\nSound from the computer, 0:12, transcribed:\nAny questions?\n\n(Nothing typed: help with what was heard.)",
               "nothing typed after listening asks for help with what was heard, after the app")
        expect(Sound.clock(75.9), "1:15", "a length reads as minutes and seconds")

        expect(Sound.words("", length: 3), "Sound from the computer, 0:03: no speech in it.", "nothing said says so")
        typealias H = Transcript.Heard
        // The measured confidences (27/10/2026): the right language 0.94, the wrong one 0.18 on French, 0.73 on English.
        expect(Transcript.merge([H(language: "en_US", start: 0, end: 3.2, text: "Situ a pure regardé", confidence: 0.18),
                                 H(language: "fr_FR", start: 0, end: 3, text: "Si tu as pu regarder", confidence: 0.94),
                                 H(language: "fr_FR", start: 4.1, end: 6, text: "S the question", confidence: 0.73),
                                 H(language: "en_US", start: 4, end: 5, text: "So the", confidence: 0.94),
                                 H(language: "en_US", start: 5, end: 6.2, text: "question", confidence: 0.94),
                                 H(language: "fr_FR", start: 7, end: 8, text: "Merci.", confidence: 0.5)]),
               ["Si tu as pu regarder", "So the", "question", "Merci."],
               "each stretch heard is said in the language surer of it, in order")
        // A French clip then an English one with no pause, as the recognizers settled them (27/10/2026).
        expect(Transcript.merge([H(language: "en_US", start: 3.00, end: 8.34, text: "Bonjour, je vous les savoir.", confidence: 0.26),
                                 H(language: "en_US", start: 8.34, end: 13.02, text: "Il fautre quon le signe.", confidence: 0.07),
                                 H(language: "en_US", start: 13.02, end: 20.12, text: "So the question is", confidence: 0.89),
                                 H(language: "fr_FR", start: 2.22, end: 13.50, text: "Bonjour, je voulais savoir, les fonds.", confidence: 0.95),
                                 H(language: "fr_FR", start: 13.50, end: 20.04, text: "what time complexity", confidence: 0.80)]),
               ["Bonjour, je voulais savoir, les fonds.", "So the question is"], "French then English with no pause: each sentence in its own")
        var said = AttributedString("Les fonds.") + AttributedString(" So the question")
        func at(_ a: Double, _ b: Double) -> CMTimeRange { CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 1000), end: CMTime(seconds: b, preferredTimescale: 1000)) }
        said[said.range(of: "Les fonds.")!].audioTimeRange = at(10, 14.3)
        said[said.range(of: " So the question")!].audioTimeRange = at(14.4, 16)
        said.transcriptionConfidence = 0.5
        expect(Transcript.sentences(said, language: "fr_FR", within: at(10, 16)),
               [H(language: "fr_FR", start: 10, end: 14.3, text: "Les fonds.", confidence: 0.5),
                H(language: "fr_FR", start: 14.4, end: 16, text: "So the question", confidence: 0.5)],
               "a result is cut at its sentence ends, each with its time")
        expect(Transcript.sentences(AttributedString("Les fonds. So the") .settingAttributes(AttributeContainer().audioTimeRange(at(10, 27))),
                                    language: "fr_FR", within: at(10, 27)).map { [$0.text, String($0.start), String($0.end)] },
               [["Les fonds.", "10.0", "20.0"], ["So the", "20.0", "27.0"]], "words still being heard, one piece, share its time by length")
        let french = "Bonjour, je voulais savoir si tu as pu regarder le contrat que je t'ai envoyé hier"
        expect([Transcript.reads(french, as: "fr_FR") > 0.5, Transcript.reads(french, as: "en_US") < 0.5], [true, true],
               "words still being heard are judged by the language they read as")
        // Live, a French clip run into an English one (27/10/2026): nothing settled yet, the English take one piece from 0.
        expect(Transcript.shown(finals: [], pending: [[H(language: "fr_FR", start: 0, end: 14.47, text: "Bonjour, les fonds.", confidence: 1),
                                                        H(language: "fr_FR", start: 14.47, end: 19.38, text: "question, what the", confidence: 0)],
                                                       [H(language: "en_US", start: 0, end: 19.38, text: "Bonjour v cont So the question is", confidence: 1)]]),
               "Bonjour, les fonds. question, what the", "the sentence being said never replaces a whole one shown")
        expect(Transcript.shown(finals: [H(language: "en_US", start: 0, end: 5, text: "So the question is.", confidence: 0.94)],
                                pending: [[H(language: "en_US", start: 5, end: 8, text: "what is", confidence: 1)],
                                          [H(language: "fr_FR", start: 5.2, end: 8, text: "what is", confidence: 0)]]),
               "So the question is. what is", "the sentence being said comes from the language it reads as")

        let retina = Screen.fit(2940, 1912)
        expect([retina.width, retina.height], [1920, 1249], "a Retina screen comes down to 1920 on its long edge")
        let small = Screen.fit(1280, 800)
        expect([small.width, small.height], [1280, 800], "a smaller one stays as it is")
        let jpeg = Screen.jpeg(NSImage(size: NSSize(width: 3000, height: 1000), flipped: false) { r in
            NSColor.white.setFill(); r.fill(); return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let back = NSBitmapImageRep(data: jpeg)
        expect([back?.pixelsWide ?? 0, back?.pixelsHigh ?? 0], [1920, 640], "the JPEG sent has the size it was fitted to")

        typealias B = Markdown.Block
        expect(Markdown.blocks("Fix:\n\n```python\nx = 1\n```\n\nThen run it."), [B.text("Fix:"), .code("x = 1"), .text("Then run it.")],
               "fenced code apart from the prose")
        expect(Markdown.blocks("Fix:\n```\ny = 2"), [B.text("Fix:"), .code("y = 2")], "a fence still streaming is code so far")
        expect(Markdown.blocks(""), [], "nothing is no block")
        expect(Markdown.code(in: "Send this:\n```\nSalut, je regarde ça.\n```"), "Salut, je regarde ça.", "⌘C takes the code block")
        expect(String(Markdown.inline("- one\n  * two").characters), "• one\n  • two", "list marks become bullets")
        expect(String(Markdown.inline("a **b** `c`").characters), "a b c", "inline marks are styles, not characters")

        let glance = Glance()
        func press(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> Bool {
            glance.key(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!)
        }
        for c in "pourquoi ça" { _ = press(kVK_ANSI_A, String(c)) }
        expect(glance.draft, "pourquoi ça", "letters, accents and spaces type")
        _ = press(kVK_ANSI_E, "é", .option)
        expect(glance.draft, "pourquoi çaé", "⌥E types é (his layout)")
        _ = press(kVK_Delete, "\u{7F}")
        expect(glance.draft, "pourquoi ça", "⌫ takes a letter")
        _ = press(kVK_Delete, "\u{7F}", .option)
        expect(glance.draft, "pourquoi ", "⌥⌫ takes a word")
        _ = press(kVK_Delete, "\u{7F}", .command)
        expect(glance.draft, "", "⌘⌫ takes them all")
        expect(press(kVK_ANSI_Q, "q", .command), false, "other ⌘ chords are not typed")
        expect(press(kVK_LeftArrow, "\u{F702}"), false, "arrows are not typed")
        expect(Glance.dropWord("fix it  "), "fix ", "⌥⌫ over trailing spaces")

        glance.turns = [Glance.Turn(question: "", withScreen: true)]
        glance.receive(.text("`trades` "))
        glance.receive(.text("is empty."))
        expect(glance.turns[0].answer, "`trades` is empty.", "the answer streams in")
        expect(glance.answering, true, "and it is still answering")
        glance.receive(.done("`trades` is empty."))
        expect(glance.answering, false, "a result ends it")
        glance.turns.append(Glance.Turn(question: "and?", withScreen: false))
        glance.receive(.failed("claude stopped before answering"))
        expect(glance.turns[1].error, "claude stopped before answering", "a failure shows under its question")
        glance.receive(.failed("claude is not installed"))
        expect(glance.note, "claude is not installed", "one with no question waiting shows as a note")

        // In a window never shown, dark as his Mac is: the glass keeps the backdrop it blurs. A render cannot tell, it
        // draws the glass from a picture; the light text once turned the material light, which names its layer otherwise.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: GlanceView(glance: glance, scrolls: false))
        window.displayIfNeeded()
        func glass(_ v: NSView) -> Glass? { (v as? Glass) ?? v.subviews.lazy.compactMap(glass).first }
        let shown = glass(window.contentView!)
        // Unshown, the material builds its layers only when asked to draw.
        shown?.display()
        let layers = shown?.layer?.sublayers?.flatMap { $0.sublayers ?? [] } ?? []
        // A material with no backdrop layer leaves nothing to check (the release's runner, a VM, found no visible one).
        if layers.contains(where: { $0.name?.lowercased() == "backdrop" }) {
            expect(layers.first { !$0.isHidden }.map { ($0.filters ?? []).compactMap { ($0 as? NSObject)?.value(forKey: "name") as? String } },
                   ["sdrNormalize", "cssBlur", "colorMatrix"], "the panel's glass blurs what is behind it")
        } else {
            print("  skip  the panel's glass: this Mac's material has no backdrop (\(layers.compactMap(\.name)))")
        }

        print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
        return failures
    }
}
