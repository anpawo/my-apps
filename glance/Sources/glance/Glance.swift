import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class Glance: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var question: String
        var withScreen: Bool
        var withSound = false
        var answer = ""
        var error: String?
        var done = false
    }

    static let width: CGFloat = 640
    /// Room around the box for its shadow. The panel is cut to the box, so the clear part covers only this band of the
    /// app behind: the panel stays up while he works there.
    static let margin: CGFloat = 24

    @Published var draft = ""
    @Published var turns: [Turn] = []
    /// A screenshot is waiting to go with the next question.
    @Published var seesScreen = false
    /// Listening to the computer since then.
    @Published var listening: Date?
    /// What was heard waits to go with the next question.
    @Published var hears = false
    @Published var note: String?
    @Published var copied = false
    /// The conversation's height before it scrolls.
    @Published var room: CGFloat = 600
    private var shot: Task<Data?, Never>?
    private var listener: Listener?
    /// Put in words from the moment listening stops, not from ↵.
    private var heard: Task<String, Never>?
    private var app: String?
    private var before: NSRunningApplication?
    private var conversation: Conversation?
    private var panel: GlancePanel?
    private var top = CGPoint.zero

    var answering: Bool { turns.last.map { !$0.done } ?? false }

    /// ⌘⌥G. Hidden: a new conversation on the screen as it is. Up: put away, wherever the focus is.
    func summon() {
        if let panel, panel.isVisible { return hide() }
        (draft, turns, note) = ("", [], nil)
        capture()
        let conversation = Conversation { [weak self] in self?.receive($0) }
        conversation.start()
        self.conversation = conversation
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let area = NSScreen.underMouse.visibleFrame
        room = (area.height * 0.7).rounded()
        top = CGPoint(x: area.midX, y: area.maxY - 8 + Self.margin)
        place(height: 48)
        // It takes the focus, his pick (27/10/2026): the app behind goes inactive, and gets it back on ⎋.
        before = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        // Only when glance still has it: a click in another app since then chose where the focus goes.
        if NSApp.isActive { before?.activate(options: []) }
        before = nil
        conversation?.stop()
        conversation = nil
        shot?.cancel()
        (shot, seesScreen) = (nil, false)
        if let listener { Task { _ = await listener.stop() } }
        (listener, listening, heard, hears) = (nil, nil, nil, false)
    }

    /// ⌘R. The computer's sound from now on goes with the next question; ⌘R again stops listening, so does ↵.
    func listen() {
        if listening != nil { return stopListening() }
        guard CGPreflightScreenCaptureAccess() else {
            note = "glance cannot hear the computer: turn it on in System Settings → Privacy & Security → Screen & System Audio Recording."
            return
        }
        let listener = Listener()
        (self.listener, listening, heard, hears, note) = (listener, Date(), nil, false, nil)
        Task {
            do { try await listener.start() } catch {
                guard self.listener === listener else { return }
                (self.listener, listening, note) = (nil, nil, "No sound: \(error.localizedDescription)")
            }
        }
    }

    private func stopListening() {
        guard let listener, let since = listening else { return }
        let length = Date().timeIntervalSince(since)
        (self.listener, listening, hears) = (nil, nil, true)
        heard = Task { await Sound.words(await listener.stop(), length: length) }
    }

    private func capture() {
        app = NSWorkspace.shared.frontmostApplication?.localizedName
        guard CGPreflightScreenCaptureAccess() else {
            note = "glance cannot see the screen: turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then ⌘⌥G twice. Questions still work."
            // Asks once; after that it is a no-op, so the pane is opened instead.
            if !CGRequestScreenCaptureAccess() {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }
        shot?.cancel()
        seesScreen = true
        shot = Task {
            do { return try await Screen.shot() } catch {
                if !Task.isCancelled { (note, seesScreen) = ("No screenshot: \(error.localizedDescription)", false) }
                return nil
            }
        }
    }

    /// ↵. Nothing typed is a question too, "help with what is on the screen" (or what was heard), as long as there is
    /// one to send.
    func send() {
        guard !answering, let conversation else { return }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if listening != nil { stopListening() }
        guard !typed.isEmpty || shot != nil || heard != nil else { return }
        let pending = shot, sound = heard, app = self.app
        (shot, seesScreen, heard, hears, draft, note) = (nil, false, nil, false, "", nil)
        turns.append(Turn(question: typed, withScreen: pending != nil, withSound: sound != nil))
        let index = turns.count - 1
        Task {
            let image = await pending?.value
            if image == nil { turns[index].withScreen = false }
            conversation.send(Conversation.question(typed, app: image == nil ? nil : app, heard: await sound?.value), image: image)
        }
    }

    func receive(_ event: Conversation.Event) {
        guard let i = turns.indices.last, !turns[i].done else {
            if case .failed(let why) = event { note = why }
            return
        }
        switch event {
        case .text(let t): turns[i].answer += t
        case .done(let whole):
            if turns[i].answer.isEmpty { turns[i].answer = whole }
            turns[i].done = true
        case .failed(let why): (turns[i].error, turns[i].done) = (why, true)
        }
    }

    /// ⌘C: what is selected in an answer; with nothing selected, the code block of the last answer (where the
    /// prompt puts text to send), or the whole answer.
    func copy() {
        let board = NSPasteboard.general, before = board.changeCount
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        guard board.changeCount == before, let last = turns.last(where: { !$0.answer.isEmpty }) else { return }
        board.clearContents()
        board.setString(Markdown.code(in: last.answer) ?? last.answer, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.copied = false }
    }

    /// Every key comes here before any view. There is no text field: in a panel that never activates the app there
    /// would be one to focus, and a field that missed its focus would leave the typing nowhere (opener's reason).
    func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Escape: hide()
        case kVK_Return, kVK_ANSI_KeypadEnter: send()
        case kVK_Delete where flags.contains(.command): draft = ""
        case kVK_Delete where flags.contains(.option): draft = Self.dropWord(draft)
        case kVK_Delete: draft = String(draft.dropLast())
        case kVK_ANSI_V where flags.contains(.command): draft += NSPasteboard.general.string(forType: .string) ?? ""
        case kVK_ANSI_C where flags.contains(.command): copy()
        case kVK_ANSI_R where flags.contains(.command): listen()
        default:
            // Arrows and function keys come as characters of the private-use area.
            guard flags.intersection([.command, .control]).isEmpty, let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
            else { return false }
            draft += text
        }
        return true
    }

    static func dropWord(_ s: String) -> String {
        let trimmed = s.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return String(trimmed[..<(trimmed.lastIndex(where: \.isWhitespace).map { trimmed.index(after: $0) } ?? trimmed.startIndex)])
    }

    /// The box's top stays where it opened; the panel grows down as the answer comes in.
    func place(height: CGFloat) {
        guard let panel else { return }
        let size = NSSize(width: Self.width + 2 * Self.margin, height: height + 2 * Self.margin)
        panel.setFrame(NSRect(x: top.x - size.width / 2, y: top.y - size.height, width: size.width, height: size.height), display: true)
    }

    /// Non-activating: after a click in the app behind, a click on it takes the keys without taking that app away
    /// (⌘⌥G is what takes the focus). On every Space and over
    /// full-screen apps, and out of screen shares (the window server honours that for most capture tools, not all).
    private func makePanel() -> GlancePanel {
        let panel = GlancePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onKey = { [weak self] in self?.key($0) ?? false }
        let host = NSHostingView(rootView: GlanceView(glance: self))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

final class GlancePanel: NSPanel {
    var onKey: (NSEvent) -> Bool = { _ in false }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey(event) { return }
        super.sendEvent(event)
    }
}

enum Markdown {
    enum Block: Equatable {
        case text(String)
        case code(String)
    }

    /// Fenced code apart from the prose around it. A fence still open (the answer streaming in) is code so far.
    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = [], lines: [Substring] = [], fenced = false
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !body.trimmingCharacters(in: .whitespaces).isEmpty { out.append(fenced ? .code(body) : .text(body)) }
            lines = []
        }
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                fenced.toggle()
            } else {
                lines.append(line)
            }
        }
        flush()
        return out
    }

    static func code(in s: String) -> String? {
        blocks(s).lazy.compactMap { if case .code(let c) = $0 { c } else { nil } }.first
    }

    /// Bold, italics, inline code and links; list marks as bullets. The blocks are `blocks`' work.
    static func inline(_ s: String) -> AttributedString {
        let text = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let indent = line.prefix(while: { $0 == " " })
            let rest = line.dropFirst(indent.count)
            return rest.hasPrefix("- ") || rest.hasPrefix("* ") ? indent + "• " + rest.dropFirst(2) : String(line)
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct GlanceView: View {
    @ObservedObject var glance: Glance
    /// Off offscreen: ImageRenderer draws a ScrollView as nothing.
    var scrolls = true
    @State private var height: CGFloat = 0
    @Environment(\.renderBehind) private var renderBehind

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if !glance.turns.isEmpty || glance.note != nil {
                Divider()
                if scrolls {
                    ScrollViewReader { proxy in
                        ScrollView { thread }
                            .frame(height: min(height, glance.room))
                            .onChange(of: glance.turns.count) { proxy.scrollTo(glance.turns.last?.id, anchor: .top) }
                    }
                } else {
                    thread
                }
            }
        }
        .frame(width: Glance.width)
        // Light text whatever the system's mode: it sits on a light glass. The text alone: a light material hides the
        // backdrop the glass blurs, and the panel turns clear.
        .environment(\.colorScheme, .light)
        // The watch list's card: its glass, a white rim inside a dark one.
        .background(Glass.tint)
        .background(alignment: .topLeading) {
            if let renderBehind { Image(nsImage: renderBehind) } else { GlassView(radius: 14) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.4), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Glass.ink.opacity(0.1), lineWidth: 1).padding(-1))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { glance.place(height: $0) }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .padding(Glance.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var field: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: glance.listening != nil || glance.hears ? "waveform" : glance.seesScreen ? "camera.viewfinder" : "sparkles")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(glance.listening != nil ? Color.red : glance.hears || glance.seesScreen ? Color.accentColor : .secondary)
            // A caret that does not blink: a blink would redraw the panel twice a second for nothing.
            (Text(glance.draft) + Text("|").foregroundColor(.accentColor)
                + Text(glance.draft.isEmpty ? placeholder : "")
                .foregroundColor(Color.secondary.opacity(0.6)))
                .font(.system(size: 17))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let since = glance.listening {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Sound.clock(context.date.timeIntervalSince(since)))
                }
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.red)
            } else {
                Text(glance.copied ? "Copied" : glance.answering ? "…" : "↵")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var placeholder: String {
        if glance.listening != nil { return " Listening to the computer, ↵ to ask" }
        if glance.hears { return " Ask about what was heard" }
        return glance.turns.isEmpty ? " Ask about your screen" : " Ask a follow-up"
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let note = glance.note { Text(note).font(.system(size: 13)).foregroundStyle(.orange) }
            ForEach(glance.turns) { turn in
                TurnView(turn: turn).id(turn.id)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
    }
}

struct TurnView: View {
    let turn: Glance.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if turn.withScreen { Image(systemName: "camera.viewfinder") }
                if turn.withSound { Image(systemName: "waveform") }
                Text(turn.question.isEmpty ? (turn.withSound ? "What was heard" : "What's on screen") : turn.question)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            if let error = turn.error {
                Text(error).font(.system(size: 14)).foregroundStyle(.red)
            } else if turn.answer.isEmpty {
                Text("Looking…").font(.system(size: 14)).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(Markdown.blocks(turn.answer).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let s):
                        Text(Markdown.inline(s)).font(.system(size: 14)).lineSpacing(2)
                    case .code(let s):
                        Text(s)
                            .font(.system(size: 12.5, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // The watch list's rows: a whiter glass, readable over a dark window too.
                            .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Glass.line, lineWidth: 1))
                    }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
