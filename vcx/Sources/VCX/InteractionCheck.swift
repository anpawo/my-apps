import AppKit
import SwiftUI

@MainActor
enum InteractionCheck {
    private static let historyTurns = 16
    private static let framesPerSecond = 60.0
    private static let animationFrames = 75
    private static let settleSeconds = 0.3
    private static let frameBudgetMilliseconds = 1000 / framesPerSecond
    private static let maximumWorkMilliseconds = frameBudgetMilliseconds * 2
    private static let keyIntervalSeconds = 0.04
    private static let streamIntervalSeconds = 0.08
    private static let skillCount = 200
    private static var typingCPU: [Double] = []

    static func run(directory: String) -> Bool {
        let folder = URL(fileURLWithPath: directory)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = fixture(folder)
        typingCPU = []
        let sending = SendAnimation()
        let host = NSHostingView(rootView: CXView(session: session, sending: sending))
        host.sizingOptions = []; host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(x: 0, y: 0, width: 1120, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date() + settleSeconds)
        guard let field = editor(host) else { fatalError("Composer missing from interaction fixture") }
        var streamed = "A response is streaming while the composer is used."
        let stream = Timer.scheduledTimer(withTimeInterval: streamIntervalSeconds, repeats: true) { _ in
            MainActor.assumeIsolated {
                streamed += " More response text."
                session.show(["id": "streaming-answer", "type": "agentMessage", "text": streamed])
                session.revision += 1
            }
        }
        defer { stream.invalidate() }
        let typing = type(into: field, host: host)
        let send = send(field: field, session: session, sending: sending, host: host)
        let finished = sending.flight == nil
        stream.invalidate()
        sidebarCountsFollowCatalogChanges(folder: folder, field: field)
        let report: JSON = ["typing": summary(typing), "typing_cpu": summary(typingCPU), "send": summary(send.times), "flight_observed": send.observed, "send_finished": finished,
                            "limits": "Unshown AppKit view; desktop compositor and real runtime traffic are excluded."]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: folder.appendingPathComponent("interaction.json"))
        print(String(decoding: data, as: UTF8.self))
        Render.motion(directory: directory, name: "wrapped", text: "Keep the exact text from the composer as this longer message lifts into the conversation, changes size, and settles into its final bubble without jumping between lines.", history: true)
        Render.motion(directory: directory, name: "tall", text: (1...20).map { "Line \($0) of a pasted text block." }.joined(separator: "\n"), history: true)
        return (typing.max() ?? 0) < maximumWorkMilliseconds && (send.times.max() ?? 0) < maximumWorkMilliseconds * 2 && send.observed && finished
    }

    private static func fixture(_ folder: URL) -> Session {
        let session = Session(cwd: "/Users/example/projects/atlas", stateDirectory: folder.appendingPathComponent("state"))
        session.ready = true; session.status = "Ready"
        session.skills = (0..<skillCount).map { "example-skill-\($0)" }
        session.providerCommands = session.skills.map { ChatCommand(name: "/" + $0, detail: "A synthetic skill used to measure sidebar refresh cost.", source: "Claude", insert: "/" + $0) }
        for turn in 0..<historyTurns {
            session.show(["id": "question-\(turn)", "type": "userMessage", "content": [["type": "text", "text": "Review the latest change."]]])
            session.show(["id": "answer-\(turn)", "type": "agentMessage", "text": String(repeating: "A paragraph with **formatted text** and `code` for the transcript.\n\n", count: 12)])
        }
        session.revision += 1
        return session
    }

    private static func sidebarCountsFollowCatalogChanges(folder: URL, field: ComposerText) {
        let session = Session(cwd: "/Users/example/projects/atlas", stateDirectory: folder.appendingPathComponent("counts"))
        session.skills = ["first", "first"]; session.mcp = ["tool", "tool"]
        session.instructions = ["AGENTS.md", "AGENTS.md"]; session.recalledRules = ["First rule", "Second rule"]
        session.hooks = ["Before · first", "Before · second", "After · third"]
        for title in ["Skills", "MCP", "Instructions", "RAG", "Hooks"] {
            precondition(session.capabilityCount(title) == 2, "Sidebar counts retain duplicate entries and group hooks")
            precondition(session.capabilityCount(title) == session.capabilityItems(title).count, "Sidebar counts match the entries the popup displays")
        }
        let baseline = session.capabilityCount("Commands")
        let command = ChatCommand(name: "/fixture-command", detail: "First description", source: "Claude", insert: "/fixture-command")
        session.providerCommands = [command, command]
        precondition(session.capabilityCount("Commands") == baseline, "Skills stay out of the builtin command count")
        session.builtinCommands = ["fixture-command"]
        precondition(session.capabilityCount("Commands") == baseline + 1, "Reloaded builtins update the badge without counting duplicate names")
        session.providerCommands[0].detail = "Updated description"
        precondition(session.capabilityItems("Commands").first(where: { $0.name == "fixture-command" })?.detail == "Updated description", "Reloaded command descriptions reach the popup")
        field.setDraft(NSAttributedString(string: "/help"))
        precondition(field.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil, "Recognized slash commands remain highlighted")
        field.setDraft(NSAttributedString(string: "help"))
        precondition(field.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil, "Removing the slash clears command highlighting")
    }

    private static func editor(_ view: NSView) -> ComposerText? {
        (view as? ComposerText) ?? view.subviews.lazy.compactMap(editor).first
    }

    private static func type(into field: ComposerText, host: NSView) -> [Double] {
        var times: [Double] = []
        let start = Date()
        for (index, character) in "Typing a normal message should feel immediate.".enumerated() {
            let deadline = start + Double(index) * keyIntervalSeconds
            RunLoop.main.run(until: deadline)
            let thread = mach_thread_self()
            let cpu = FreezeTrace.cpuTime(thread)
            field.insertText(String(character), replacementRange: field.selectedRange())
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            times.append(Date().timeIntervalSince(deadline) * 1000)
            typingCPU.append((FreezeTrace.cpuTime(thread) - cpu) * 1000)
            mach_port_deallocate(mach_task_self_, thread)
        }
        return times
    }

    private static func send(field: ComposerText, session: Session, sending: SendAnimation, host: NSView) -> (times: [Double], observed: Bool) {
        var previous = CACurrentMediaTime()
        let text = field.string
        field.willSubmit(text, [], field.sendSnapshot())
        session.editDraft(NSAttributedString(string: ""))
        session.show(["id": "sent-message", "type": "userMessage", "content": [["type": "text", "text": text]]])
        session.revision += 1
        var times: [Double] = []
        var observed = false
        let start = Date()
        for frame in 0..<animationFrames {
            RunLoop.main.run(until: start + Double(frame) / framesPerSecond)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let after = CACurrentMediaTime()
            times.append((after - previous) * 1000); previous = after
            observed = observed || sending.flight != nil
        }
        return (times, observed)
    }

    private static func summary(_ values: [Double]) -> JSON {
        let sorted = values.sorted()
        return ["samples": sorted.count, "median_ms": sorted[sorted.count / 2], "p95_ms": sorted[sorted.count * 95 / 100],
                "max_ms": sorted.last ?? 0, "over_frame_budget": sorted.filter { $0 > frameBudgetMilliseconds }.count]
    }
}
