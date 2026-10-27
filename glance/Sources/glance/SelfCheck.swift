import AppKit
import Carbon.HIToolbox
import SwiftUI

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

        let wav = Sound.wav([0, 1, -1, 2])
        func u32(_ at: Int) -> Int { Int(wav[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
        expect([wav.count, u32(4), u32(24), u32(40)], [52, 44, 16_000, 8], "the WAV header gives its sizes and 16 kHz")
        expect(stride(from: 44, to: 52, by: 2).map { i in wav[i..<i + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) } },
               [0, 32767, -32767, 32767], "samples are 16-bit, clipped")

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
        let backdrop = shown?.layer?.sublayers?.flatMap { $0.sublayers ?? [] }.first { !$0.isHidden }
        expect(backdrop.map { ($0.filters ?? []).compactMap { ($0 as? NSObject)?.value(forKey: "name") as? String } },
               ["sdrNormalize", "cssBlur", "colorMatrix"], "the panel's glass blurs what is behind it")

        print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
        return failures
    }
}
