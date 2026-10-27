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
        /// What was heard, as the live text showed it.
        var transcript: String?
        var answer = ""
        var error: String?
        var done = false
    }

    static let width: CGFloat = 512
    /// Room around the box for its outer rim, drawn just outside it. No shadow: a soft one needs a clear band around the
    /// box, and its edge showed where the band ended (27/10/2026); the watch list has none either.
    static let margin: CGFloat = 1
    /// From the box to the top and right edges of the screen.
    static let gap: CGFloat = 8

    @Published var draft = ""
    @Published var turns: [Turn] = []
    /// A screenshot is waiting to go with the next question.
    @Published var seesScreen = false
    /// Listening to the computer since then.
    @Published var listening: Date?
    /// What was heard waits to go with the next question.
    @Published var hears = false
    /// The words heard so far, live.
    @Published var live = ""
    /// Out of screenshots, screen shares and recordings; his switch, the eye in the panel. Glance's own shot leaves the
    /// panel out either way, by its filter.
    @Published var hidden = UserDefaults.standard.bool(forKey: "hidden") {
        didSet {
            UserDefaults.standard.set(hidden, forKey: "hidden")
            panel?.sharingType = hidden ? .none : .readOnly
        }
    }
    @Published var note: String?
    @Published var copied = false
    /// The box's size: the screen's shape.
    @Published var size = CGSize(width: width, height: width * 10 / 16)
    private var shot: Task<Data?, Never>?
    private var listener: Listener?
    private var transcript: Transcript?
    private var starting: Task<Void, Error>?
    /// The last words, settled from the moment listening stops, not from ↵.
    private var heard: Task<String, Never>?
    private var heardFor: TimeInterval = 0
    private var app: String?
    private var before: NSRunningApplication?
    private var conversation: Conversation?
    private var panel: GlancePanel?
    /// The corner it opens in, top right at first: ⌃ and an arrow move it, and it stays there (his pick, 27/10/2026).
    private var left = UserDefaults.standard.bool(forKey: "left")
    private var bottom = UserDefaults.standard.bool(forKey: "bottom")
    private var mouse: [Any] = []
    /// Where the mouse holds the panel while ⌃ is down over it.
    private var grab: CGPoint?

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
        let screen = NSScreen.underMouse, frame = Self.frame(screen: screen.frame, visible: screen.visibleFrame, left: left, bottom: bottom)
        size = frame.insetBy(dx: Self.margin, dy: Self.margin).size
        panel.setFrame(frame, display: true)
        followMouse()
        // It takes the focus, his pick (27/10/2026): the app behind goes inactive, and gets it back on ⎋.
        before = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        mouse.forEach(NSEvent.removeMonitor)
        (mouse, grab) = ([], nil)
        // Only when glance still has it: a click in another app since then chose where the focus goes.
        if NSApp.isActive { before?.activate(options: []) }
        before = nil
        conversation?.stop()
        conversation = nil
        shot?.cancel()
        (shot, seesScreen) = (nil, false)
        if listening != nil { stopListening() }
        (transcript, heard, hears, live) = (nil, nil, false, "")
    }

    /// ⌘R or the Listen button. The computer's sound from now on, in words as it plays, goes with the next question;
    /// again stops listening, so does ↵.
    func listen() {
        if listening != nil { return stopListening() }
        guard CGPreflightScreenCaptureAccess() else {
            note = "glance cannot hear the computer: turn it on in System Settings → Privacy & Security → Screen & System Audio Recording."
            return
        }
        let transcript = Transcript()
        transcript.onChange = { [weak self, weak transcript] text in
            if let self, self.transcript === transcript { self.live = text }
        }
        let listener = Listener(hear: transcript.feed)
        let starting = Task {
            try await transcript.start()
            try await listener.start()
        }
        (self.listener, self.transcript, self.starting) = (listener, transcript, starting)
        (listening, heard, hears, note, live) = (Date(), nil, false, nil, "")
        Task {
            do { try await starting.value } catch {
                guard self.listener === listener else { return }
                (self.listener, self.transcript, listening, note) = (nil, nil, nil, "No sound: \(error.localizedDescription)")
            }
        }
    }

    private func stopListening() {
        guard let listener, let transcript, let since = listening else { return }
        let starting = self.starting
        (heardFor, self.listener, self.starting, listening, hears) = (Date().timeIntervalSince(since), nil, nil, nil, true)
        heard = Task {
            _ = try? await starting?.value
            await listener.stop()
            return await transcript.finish()
        }
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
        let pending = shot, sound = heard, length = heardFor, app = self.app
        turns.append(Turn(question: typed, withScreen: pending != nil, withSound: sound != nil, transcript: sound == nil ? nil : live))
        (shot, seesScreen, heard, hears, draft, note, transcript, live) = (nil, false, nil, false, "", nil, nil, "")
        let index = turns.count - 1
        Task {
            let image = await pending?.value
            if image == nil { turns[index].withScreen = false }
            let words = await sound?.value
            if let words { turns[index].transcript = words }
            conversation.send(Conversation.question(typed, app: image == nil ? nil : app, heard: words.map { Sound.words($0, length: length) }),
                              image: image)
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
        case kVK_LeftArrow where flags.contains(.control): move(left: true)
        case kVK_RightArrow where flags.contains(.control): move(left: false)
        case kVK_UpArrow where flags.contains(.control): move(bottom: false)
        case kVK_DownArrow where flags.contains(.control): move(bottom: true)
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

    /// The panel: a box of the screen's shape in a corner, under the menu bar at the top (his pick, 27/10/2026).
    static func frame(screen: CGRect, visible: CGRect, left: Bool = false, bottom: Bool = false) -> CGRect {
        let size = CGSize(width: width, height: (width * screen.height / screen.width).rounded())
        return CGRect(x: left ? visible.minX + gap : visible.maxX - gap - size.width,
                      y: bottom ? visible.minY + gap : visible.maxY - gap - size.height, width: size.width, height: size.height)
            .insetBy(dx: -margin, dy: -margin)
    }

    /// ⌃ and an arrow: to that side of its screen, the other side as it stands, after a drag too.
    private func move(left: Bool? = nil, bottom: Bool? = nil) {
        guard let panel, let screen = panel.screen else { return }
        let visible = screen.visibleFrame
        self.left = left ?? (panel.frame.midX < visible.midX)
        self.bottom = bottom ?? (panel.frame.midY < visible.midY)
        UserDefaults.standard.set(self.left, forKey: "left")
        UserDefaults.standard.set(self.bottom, forKey: "bottom")
        let frame = Self.frame(screen: screen.frame, visible: visible, left: self.left, bottom: self.bottom)
        size = frame.insetBy(dx: Self.margin, dy: Self.margin).size
        panel.animator().setFrame(frame, display: true)
    }

    /// ⌃ over the panel: it follows the mouse until ⌃ is let go. A mouse move carries the keys held, and watching mouse
    /// moves needs no permission, where watching keys from outside needs Accessibility. Global for when another app has
    /// the keys, local for when glance has them.
    private func followMouse() {
        guard mouse.isEmpty else { return }
        let follow: (NSEvent) -> Void = { [weak self] event in MainActor.assumeIsolated { self?.follow(event) } }
        mouse = [NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: follow) as Any,
                 NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { follow($0); return $0 } as Any]
    }

    private func follow(_ event: NSEvent) {
        guard let panel, event.modifierFlags.contains(.control) else { grab = nil; return }
        let at = NSEvent.mouseLocation
        if grab == nil, panel.frame.contains(at) { grab = CGPoint(x: at.x - panel.frame.minX, y: at.y - panel.frame.minY) }
        if let grab { panel.setFrameOrigin(CGPoint(x: at.x - grab.x, y: at.y - grab.y)) }
    }

    /// Non-activating: after a click in the app behind, a click on it takes the keys without taking that app away
    /// (⌘⌥G is what takes the focus). On every Space and over full-screen apps.
    private func makePanel() -> GlancePanel {
        let panel = GlancePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.sharingType = hidden ? .none : .readOnly
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onKey = { [weak self] in self?.key($0) ?? false }
        let host = Host(rootView: GlanceView(glance: self))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

/// A click on a button works even while another app has the focus, not only once the panel has it.
final class Host<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    @Environment(\.renderBehind) private var renderBehind

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if !glance.turns.isEmpty || glance.note != nil || glance.listening != nil || glance.hears {
                Divider()
                if scrolls {
                    ScrollViewReader { proxy in
                        ScrollView { thread }
                            .onChange(of: glance.turns.count) { proxy.scrollTo(glance.turns.last?.id, anchor: .top) }
                            .onChange(of: glance.live) { proxy.scrollTo("live", anchor: .bottom) }
                    }
                } else {
                    thread
                }
            }
        }
        .frame(width: glance.size.width, height: glance.size.height, alignment: .top)
        // Light text whatever the system's mode: it sits on a light glass. The text alone: a light material hides the
        // backdrop the glass blurs, and the panel turns clear.
        .environment(\.colorScheme, .light)
        // The watch list's card: its glass, a white rim inside a dark one. Under the white of its rows: the glass alone
        // is the watch list's to the unit, measured on his screen at the same place (27/10/2026), but the watch list is
        // mostly rows at white 0.6 and stands on a dark veil, where glance stands on a white window: it looked grey.
        .background(.white.opacity(0.6))
        .background(Glass.tint)
        .background(alignment: .topLeading) {
            if let renderBehind { Image(nsImage: renderBehind) } else { GlassView(radius: 14) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.4), lineWidth: 1))
        // The dark rim darker than Watcher's 0.1: its card stands on a veil, black at 0.3, that sets its white rim off;
        // glance stands on the screen as it is, a white window often, where the white rim alone does not show.
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Glass.ink.opacity(0.4), lineWidth: 1).padding(-1))
        .padding(Glance.margin)
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
            HStack(spacing: 8) {
                Button { glance.listen() } label: {
                    if let since = glance.listening {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Label(Sound.clock(context.date.timeIntervalSince(since)), systemImage: "stop.fill")
                        }
                        .monospacedDigit()
                    } else {
                        Label("Listen", systemImage: "waveform")
                    }
                }
                .buttonStyle(Pill(on: glance.listening != nil))
                .help(glance.listening != nil ? "Stop listening (⌘R)" : "Listen to the computer's sound and write it out live (⌘R)")
                Button { glance.hidden.toggle() } label: {
                    Label(glance.hidden ? "Hidden" : "Seen", systemImage: glance.hidden ? "eye.slash" : "eye")
                }
                .buttonStyle(Pill(on: false))
                .help(glance.hidden ? "Left out of screenshots and screen shares: click to let them see it"
                                    : "Seen by screenshots and screen shares: click to leave it out")
                Text(glance.copied ? "Copied" : glance.answering ? "…" : "↵")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            // The buttons whole, the question wraps instead: at 416 pt they were cut to "Lis…".
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var placeholder: String {
        if glance.listening != nil { return " Listening to the computer, ↵ to ask about it" }
        if glance.hears { return " Ask about what was heard" }
        return glance.turns.isEmpty ? " Ask about your screen" : " Ask a follow-up"
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let note = glance.note { Text(note).font(.system(size: 13)).foregroundStyle(.orange) }
            ForEach(glance.turns) { turn in
                TurnView(turn: turn).id(turn.id)
            }
            if glance.listening != nil || glance.hears {
                VStack(alignment: .leading, spacing: 8) {
                    Label(glance.listening != nil ? "Listening" : "Heard, ↵ to ask about it", systemImage: "waveform")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(glance.listening != nil ? Color.red : .secondary)
                    Text(glance.live.isEmpty ? "Nothing said yet." : glance.live)
                        .font(.system(size: 14))
                        .foregroundStyle(glance.live.isEmpty ? .tertiary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id("live")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // Its end: the question is mostly about the last thing said.
            if let transcript = turn.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

/// The panel's buttons: the watch list's rows, a whiter glass with a grey rim; red while it runs.
struct Pill: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(on ? Color.white : Glass.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(on ? Color.red : .white.opacity(configuration.isPressed ? 0.85 : 0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : Glass.line, lineWidth: 1))
    }
}
