import AppKit
import SwiftUI

/// `vcx --render-demo <dir>`: the README's GIF as frames, and `list.txt`, ffmpeg's concat list of how long each one
/// stays. One made-up session, drawn offscreen: nothing goes on screen and no agent runs. `docs/make-demo.sh` makes the GIF.
@MainActor
enum Demo {
    final class Key: ObservableObject { @Published var shown: String? }

    struct Stage: View {
        let session: Session
        let sending: SendAnimation
        @ObservedObject var key: Key
        var body: some View {
            CXView(session: session, sending: sending)
                .overlay(alignment: .bottomLeading) {
                    if let shown = key.shown {
                        Text(shown).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                            .frame(minWidth: 60, minHeight: 60).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.78)))
                            .padding(28)
                    }
                }
        }
    }

    static func run(directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = Session(cwd: "/Users/example/projects/atlas", stateDirectory: dir.appendingPathComponent("state"))
        // A connection that takes the question's answer, so the question closes as it does in the app.
        session.rpc = FixtureConnection(session.account)
        session.ready = true; session.status = "Ready"; session.model = "claude-opus-5-5"; session.providerLabel = "Claude"; session.effort = "high"
        session.contextUsed = 120000; session.contextLimit = 1000000
        session.usage = "18% usage - reset 2h50m - 32% wk"; session.usageLoading = false; session.usagePercent = 32
        session.activeMode = "bypass"; session.repository = "atlas"; session.branch = "main"; session.repositoryDirectory = "atlas"; session.repositoryStatus = "up to date"
        session.hooks = [hookSummary(["command": "python3 /hooks/context.py"], event: "SessionStart"), hookSummary(["command": "python3 /hooks/command-check.py", "trustStatus": "trusted"], event: "PreToolUse", matcher: "Bash")]
        session.skills = ["ui-tweak", "swift-macos", "diagnosing-bugs", "writing-style"]
        session.mcp = ["GitHub · connected · Browse repositories, issues, and pull requests."]
        session.instructions = ["AGENTS.md", "CLAUDE.md"]

        let key = Key(), sending = SendAnimation()
        let host = NSHostingView(rootView: Stage(session: session, sending: sending, key: key))
        host.appearance = NSAppearance(named: .aqua)
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // An animation's frame lasts until the next one is taken: it runs on the real clock, so the GIF plays it at its
        // speed however slow a capture is. A step (a key, a hold) gets its own duration.
        var shots: [(name: String, at: Date, lasts: Double?)] = []
        func capture(_ lasts: Double? = nil) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Demo capture failed") }
            host.cacheDisplay(in: host.bounds, to: rep)
            let name = String(format: "%03d.png", shots.count)
            try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
            shots.append((name, Date(), lasts))
        }
        func play(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            repeat { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 30)); capture() } while Date() < end
        }
        func hold(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); capture(seconds) }
        func type(_ text: String) {
            for end in stride(from: 2, through: text.count + 1, by: 2) {
                session.draft = NSAttributedString(string: String(text.prefix(end)), attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])
                session.draftRevision += 1
                hold(0.06)
            }
        }
        func press(_ shown: String, _ action: () -> Void) {
            key.shown = shown; play(0.25); action()
        }
        var actions = 0
        func action(_ command: String, _ seconds: Double = 0.5) {
            actions += 1
            let item: JSON = ["id": "demo-action-\(actions)", "type": "commandExecution", "command": command, "status": "completed", "exitCode": 0]
            session.event(["method": "item/started", "params": ["item": item]])
            play(seconds)
            session.event(["method": "item/completed", "params": ["item": item]])
        }
        func note(_ text: String) {
            actions += 1
            session.show(["id": "demo-note-\(actions)", "type": "agentMessage", "text": text]); play(0.6)
        }

        hold(1.2)
        let prompt = "The first option button has a weird size. Make it match the others."
        type(prompt)
        hold(0.5)
        press("↵") {
            func editor(_ view: NSView) -> ComposerText? { (view as? ComposerText) ?? view.subviews.lazy.compactMap(editor).first }
            guard let field = editor(host), let snapshot = field.sendSnapshot() else { fatalError("Composer not found") }
            field.willSubmit(prompt, [], snapshot)
            session.draft = NSAttributedString(string: ""); session.draftRevision += 1
            session.show(["id": "demo-question", "type": "userMessage", "content": [["type": "text", "text": prompt]]])
            session.busy = true; session.revision += 1
        }
        play(1.0); key.shown = nil
        play(0.8)
        action("Read\n" + pretty(["file_path": "/Users/example/projects/atlas/Sources/ControlCenter.swift"]))
        action("grep -n 'Button(' Sources/*.swift")
        note("The first button has a fixed 44 pt height; the others take the shared style.")
        action("Read\n" + pretty(["file_path": "/Users/example/projects/atlas/Sources/Theme.swift"]))
        session.permissions = [Permission(rpcID: "demo-ask", method: "item/tool/requestUserInput", params: ["questions": [
            ["id": "style", "header": "Button", "question": "Should the first button take the shared style, or keep a fixed height that matches today?", "options": [
                ["label": "Shared style (Recommended)", "description": "Same size as the others, and it follows the theme."],
                ["label": "Fixed 36 pt", "description": "Matches today, drifts when the theme changes."]]]]])]
        play(2.6)
        press("1") { _ = session.chooseOption(1) }
        play(0.6); key.shown = nil
        action("Edit\n" + pretty(["file_path": "/Users/example/projects/atlas/Sources/ControlCenter.swift", "old_string": ".frame(height: 44)", "new_string": ""]))
        action("swift build", 0.9)
        action("swift test --filter ControlCenterTests", 0.9)
        session.show(["id": "demo-answer", "type": "agentMessage", "text": "⟶ The first option button now has the same size as the others.\n\nDetails:\n- `ControlCenter.swift:88`: it used a fixed 44 pt height.\n- It now takes the shared button style; build and tests pass.\n\n✓ Done: the buttons match, you can close this session.\n\n⟶ Next: open the settings window and compare the buttons."])
        session.busy = false; session.revision += 1
        play(0.6)
        hold(3.0)
        press("/") { session.showCommands("/", preserveDraft: false) }
        play(0.5); key.shown = nil
        hold(1.4)
        for end in 2..."/model ".count { session.showCommands(String("/model ".prefix(end)), preserveDraft: false); hold(0.09) }
        play(0.3)
        hold(2.4)
        press("esc") { session.dismissCommands(); session.draft = NSAttributedString(string: ""); session.draftRevision += 1 }
        play(0.5); key.shown = nil
        hold(1.5)

        var list = ""
        for (index, shot) in shots.enumerated() {
            let lasts = shot.lasts ?? (index + 1 < shots.count ? shots[index + 1].at.timeIntervalSince(shot.at) : 1.5)
            list += "file '\(shot.name)'\nduration \(String(format: "%.3f", lasts))\n"
        }
        // The concat demuxer drops the last frame's duration unless the frame comes again.
        list += "file '\(shots.last!.name)'\n"
        try! list.write(to: dir.appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
        print("wrote \(shots.count) frames and list.txt to \(dir.path)")
    }
}
