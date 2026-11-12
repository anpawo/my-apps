import SwiftUI
import AppKit

let accent = Color(red: 0.43, green: 0.23, blue: 0.75)
let readyColor = Color(red: 0.1, green: 0.45, blue: 0.18)
let pendingColor = Color(red: 0.87, green: 0.42, blue: 0)
let agentPink = Color(red: 0.92, green: 0.22, blue: 0.56)
let userGradient = LinearGradient(colors: [Color(red: 0.93, green: 0.23, blue: 0.51), Color(red: 0.55, green: 0.3, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)

struct ConversationSection: Identifiable {
    let id: UUID
    var question: Row?
    var rows: [Row] = []
}

// A message from another session starts a turn like a prompt does, so it heads its own section.
func headsSection(_ row: Row) -> Bool { row.kind == "user" || (row.kind == "peer" && row.items.first?.data["direction"] as? String == "received") }

func conversationSections(_ rows: [Row]) -> [ConversationSection] {
    var sections: [ConversationSection] = []
    for row in rows {
        if headsSection(row) {
            sections.append(ConversationSection(id: row.id, question: row))
        } else {
            if sections.isEmpty { sections.append(ConversationSection(id: row.id)) }
            sections[sections.count - 1].rows.append(row)
        }
    }
    return sections
}

// The last message (the latest thought while working, the answer once done) stays visible; the rest folds into one block.
func sectionParts(_ rows: [Row]) -> (trail: [Row], last: Row?, notices: [Row]) {
    var work = rows.filter { !["notice", "peer"].contains($0.kind) }
    let last = work.lastIndex(where: { $0.kind == "assistant" }).map { work.remove(at: $0) }
    return (work, last, rows.filter { ["notice", "peer"].contains($0.kind) })
}

struct RoundButton: View {
    let icon: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 17.5, weight: .medium)).frame(width: 34, height: 34).background(.black.opacity(0.07), in: Circle()).raised(Circle()) }
            .buttonStyle(.reactive(Circle())).help(label).accessibilityLabel(label)
    }
}

extension View {
    // A white base carries the shadow: under a translucent tint, a plain .shadow would be as faint as the tint.
    func raised(_ shape: some Shape) -> some View { background(.white.shadow(.drop(color: .black.opacity(0.22), radius: 3, y: 2)), in: shape) }
}

// Hover tints a button inside its own shape; a press tints it darker and pulls its edges in by a few points whatever its width.
struct Reactive: ButtonStyle {
    var shape = AnyShape(RoundedRectangle(cornerRadius: 8))
    var outset: CGFloat = 0
    func makeBody(configuration: Configuration) -> some View { configuration.label.modifier(HoverPress(shape: shape, outset: outset, pressed: configuration.isPressed)) }
}

extension ButtonStyle where Self == Reactive {
    static var reactive: Reactive { Reactive() }
    static func reactive(_ shape: some Shape, outset: CGFloat = 0) -> Reactive { Reactive(shape: AnyShape(shape), outset: outset) }
}

struct HoverPress: ViewModifier {
    var shape = AnyShape(RoundedRectangle(cornerRadius: 8))
    var outset: CGFloat = 0
    var pressed = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let shrink = pressed && enabled && !reduceMotion
        content
            .overlay(shape.fill(.black.opacity(!enabled ? 0 : pressed ? 0.1 : hovering ? 0.05 : 0)).padding(-outset).allowsHitTesting(false))
            .visualEffect { content, geometry in content.scaleEffect(shrink ? max(0.94, 1 - 6 / max(geometry.size.width, 1)) : 1) }
            .onHover { FreezeTrace.note("hover button"); hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

struct ImagePreview: View {
    let path: String
    let size: CGSize
    var dismiss: () -> Void
    @State private var copied = false
    @State private var reset: Task<Void, Never>?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = thumbnail(path, size: 1600) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .onTapGesture { copy() }
                        .help("Click to copy the image").accessibilityAddTraits(.isButton).accessibilityLabel("Copy image")
                        .overlay {
                            if copied {
                                Label("Copied", systemImage: "checkmark").font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: Capsule())
                                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            }
                        }.animation(.easeOut(duration: 0.25), value: copied)
                }
                else { Text("This image is no longer available.").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.padding(16)
            RoundButton(icon: "xmark", label: "Close image", action: dismiss).padding(10)
        }.frame(width: size.width * 2 / 3, height: size.height * 2 / 3)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.2), radius: 28, y: 12)
            .accessibilityAddTraits(.isModal)
    }
    private func copy() {
        guard let image = NSImage(contentsOfFile: path) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
        copied = true; reset?.cancel()
        reset = Task { try? await Task.sleep(nanoseconds: 1_500_000_000); if !Task.isCancelled { copied = false } }
    }
}

struct HidesText: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// The question to keep at the transcript's top: the last one scrolled above the top edge, or, when it is no longer drawn,
// the one whose exchange crosses the edge. A question with no exchange under it scrolls away, as a header-only section did.
func pinnedQuestionID(questions: [UUID: CGFloat], exchanges: [UUID: CGFloat]) -> UUID? {
    if let above = questions.filter({ $0.value < 0 }).max(by: { $0.value < $1.value }) { return exchanges[above.key] != nil ? above.key : nil }
    return exchanges.filter { $0.value <= 0 && questions[$0.key] == nil }.max { $0.value < $1.value }?.key
}

struct MessageFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}

@MainActor
final class SendAnimation: ObservableObject {
    struct Flight {
        let item: Item
        let origin: CGRect
        var destination: CGRect
        let snapshot: ComposerSnapshot?
        var tall = false
        var collapsed = false
        var started = Date()
    }
    @Published var flight: Flight?
    @Published var frame = CGRect.zero
    @Published var blend: CGFloat = 0
    @Published private var pending: Pending?
    private var composer = CGRect.zero
    private var editor = CGRect.zero
    private(set) var transcript = CGRect.zero
    private var generation = 0
    private var moving = false
    private struct Pending {
        let content: [JSON]
        let previous: Set<String>
        let origin: CGRect
        let snapshot: ComposerSnapshot?
        let date = Date()
    }
    var hasPending: Bool { pending != nil }
    private var burst = 0
    private var queued: [String: CGRect]?

    /// On 2026-11-05 the frontend logged "MessageFrames tried to update multiple times per frame" and never left SwiftUI's
    /// flush again, so no click, key or new-window request was handled. Past a few updates in one run loop turn, the
    /// latest frames wait for the next turn, which ends such a loop. Not every update: one turn late, the sent message
    /// vanished for three frames before its flight.
    func receive(_ frames: [String: CGRect], rows: @escaping @MainActor () -> [Row], reduceMotion: Bool) {
        burst += 1
        if burst == 1 {
            DispatchQueue.main.async { [self] in
                burst = 0
                if let frames = queued { queued = nil; update(frames: frames, rows: rows(), reduceMotion: reduceMotion) }
            }
        }
        if burst <= 4 { update(frames: frames, rows: rows(), reduceMotion: reduceMotion) } else { queued = frames }
    }

    func prepare(text: String, images: [String], rows: [Row], snapshot: ComposerSnapshot? = nil) {
        let content: [JSON] = (text.isEmpty ? [] : [["type": "text", "text": text]]) + images.map { ["type": "localImage", "path": $0] }
        let origin = snapshot.map { $0.bounds.offsetBy(dx: editor.minX, dy: editor.minY).insetBy(dx: -16, dy: -16) } ?? composer
        pending = Pending(content: content, previous: Set(rows.flatMap(\.items).map(\.id)), origin: origin, snapshot: snapshot)
    }

    func hides(_ item: Item) -> Bool {
        if flight?.item.id == item.id { return true }
        guard let pending, Date().timeIntervalSince(pending.date) < 5 else { return false }
        return !pending.previous.contains(item.id) && NSArray(array: item.data["content"] as? [JSON] ?? []).isEqual(to: pending.content)
    }

    func update(frames: [String: CGRect], rows: [Row], reduceMotion: Bool) {
        if let frame = frames["composer"] { composer = frame }
        if let frame = frames["editor"] { editor = frame }
        if let frame = frames["transcript"] { transcript = frame }
        let viewport = transcript.isEmpty ? CGRect(x: 0, y: 0, width: composer.maxX, height: composer.minY) : transcript
        func target(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: 0, dy: min(0, viewport.maxY - 28 - rect.maxY)).intersection(viewport) }
        if let flight {
            // Retargeted on every frame, a flight never completes and republishes forever; both frontend freezes (11-05 16:03,
            // 11-06 12:17) began at a send, and the per-turn cap above did not stop the second. Past 1.5 s it lands where it is.
            if reduceMotion || Date().timeIntervalSince(flight.started) > 1.5 || !rows.contains(where: { $0.items.contains(where: { $0.id == flight.item.id }) }) {
                self.flight = nil; generation += 1; moving = false
            // Sub-point remeasures are ignored, so a frame that jitters between layout passes cannot keep republishing the flight.
            } else if let measured = frames[flight.item.id], case let destination = target(measured),
                      [destination.minX - flight.destination.minX, destination.minY - flight.destination.minY,
                       destination.width - flight.destination.width, destination.height - flight.destination.height].contains(where: { abs($0) >= 0.5 }) {
                self.flight?.destination = destination
                if moving { move(to: destination) }
            }
        }
        guard let pending else { return }
        guard !reduceMotion, Date().timeIntervalSince(pending.date) < 5, pending.origin.width > 0 else { self.pending = nil; return }
        guard let item = rows.filter({ $0.kind == "user" }).flatMap(\.items).first(where: {
            !pending.previous.contains($0.id) && NSArray(array: $0.data["content"] as? [JSON] ?? []).isEqual(to: pending.content)
        }), let measured = frames[item.id] else { return }
        let destination = target(measured)
        self.pending = nil
        guard !destination.isEmpty else { return }
        generation += 1; moving = false
        frame = pending.origin; blend = 0
        flight = Flight(item: item, origin: pending.origin, destination: destination, snapshot: pending.snapshot, tall: destination.height < measured.height, collapsed: frames["collapsed:" + item.id] != nil)
    }

    func launch() {
        guard let flight, !moving else { return }
        moving = true
        withAnimation(.easeOut(duration: 0.18)) { blend = 1 }
        move(to: flight.destination)
    }

    private func move(to destination: CGRect) {
        generation += 1
        let current = generation
        withAnimation(.spring(duration: 0.42, bounce: 0.08), completionCriteria: .removed) {
            frame = destination
        } completion: {
            guard self.generation == current else { return }
            self.flight = nil; self.moving = false
        }
    }
}

struct FlyingMessage: View {
    let flight: SendAnimation.Flight
    let frame: CGRect
    let blend: CGFloat
    private var fittedScale: CGFloat {
        let width = max(0.01, (frame.width - 32) / max(1, flight.destination.width - 32))
        return flight.tall ? min(1, width) : min(1, width, max(0.01, (frame.height - 32) / max(1, flight.destination.height - 32)))
    }
    var body: some View {
        // A message taller than the transcript shows its last lines, as the composer and the scrolled bubble do.
        let anchor: UnitPoint = flight.tall ? .bottomLeading : .topLeading, inset: CGFloat = flight.tall ? -16 : 16
        ZStack(alignment: flight.tall ? .bottomLeading : .topLeading) {
            if let snapshot = flight.snapshot {
                Image(nsImage: snapshot.image).resizable().frame(width: snapshot.image.size.width, height: snapshot.image.size.height)
                    .animation(.linear(duration: 0.06)) { $0.opacity(1 - blend) }.offset(x: 16, y: inset)
            }
            MessageContent(item: flight.item, collapsed: flight.collapsed).frame(width: max(1, flight.destination.width - 32), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).scaleEffect(fittedScale, anchor: anchor)
                .animation(.linear(duration: 0.06)) { $0.opacity(flight.snapshot == nil ? 1 : blend) }.offset(x: 16, y: inset)
        }.frame(width: frame.width, height: frame.height, alignment: flight.tall ? .bottomLeading : .topLeading)
            .background(accent.opacity(0.08 * blend), in: RoundedRectangle(cornerRadius: 17))
            .clipShape(RoundedRectangle(cornerRadius: 17))
            .offset(x: frame.minX, y: frame.minY)
    }
}

struct CXView: View {
    @ObservedObject var session: Session
    @ObservedObject private var settings = Settings.shared
    // Not observed here: the table publishes it on every scroll, for the pinned question alone.
    @State private var geometry = TranscriptGeometry()
    @State private var openCapability: String?
    @State private var copiedID = false
    @StateObject var sending = SendAnimation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 0) {
            sessionPanel.frame(width: 150)
            Rectangle().fill(.black.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                transcript
                    .overlay(alignment: .bottom) {
                        if session.commandQuery != nil {
                            GeometryReader { geometry in
                                CommandPalette(session: session, maxListHeight: max(40, min(250, geometry.size.height - 90)))
                                    .padding(.horizontal, 24).padding(.bottom, 8)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            }
                            .transition(reduceMotion ? .opacity : .offset(y: 70).combined(with: .opacity))
                        }
                    }
                    .clipped()
                    .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.24), value: session.commandQuery != nil)
                if let permission = session.permissions.first, permission.method != "item/tool/requestUserInput" {
                    PermissionView(session: session, request: permission).id(permission.id).frame(maxHeight: 240).padding(.horizontal, 24).padding(.bottom, 10)
                }
                if !settings.loginMessage.isEmpty { loginStatus }
                composer
                    .zIndex(1)
            }
            // The composer box grows with the question it opens, and resizes as each question replaces the last.
            .animation(.smooth(duration: reduceMotion ? 0.1 : 0.3), value: session.questionFlow.flatMap { $0.done ? nil : $0.step })
        }
        .fontDesign(.monospaced)
        .foregroundStyle(.black.opacity(0.92))
        .background(Color.white)
        .coordinateSpace(name: "conversation")
        .environmentObject(sending)
        .onPreferenceChange(MessageFrames.self) { frames in
            FreezeTrace.note("MessageFrames")
            if let transcript = frames["transcript"], transcript.height != session.viewportHeight { session.viewportHeight = transcript.height; FreezeTrace.shape(of: session) }
            sending.receive(frames, rows: { session.rows }, reduceMotion: reduceMotion)
        }
        .overlay(alignment: .topLeading) {
            if let flight = sending.flight {
                FlyingMessage(flight: flight, frame: sending.frame, blend: sending.blend)
                    .id(flight.item.id).onAppear { sending.launch() }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $session.showingSettings) {
            SettingsPopup(session: session).disabled(session.frontendReplacing)
        }
        .overlay {
            GeometryReader { geometry in
                ZStack {
                    if let path = session.preview {
                        Color.black.opacity(0.25).onTapGesture { session.preview = nil }.transition(.opacity)
                        ImagePreview(path: path, size: geometry.size) { session.preview = nil }
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(session.preview != nil)
                    .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.24), value: session.preview != nil)
            }
        }
        .disabled(session.frontendReplacing)
        .onChange(of: session.editorHeight) { FreezeTrace.shape(of: session) }
        .onExitCommand {
            guard !session.frontendReplacing else { return }
            if session.preview != nil { session.preview = nil }
            else if session.commandQuery != nil { session.dismissCommands() }
            else if session.busy { Task { await session.stop(source: "Escape") } }
        }
    }

    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { session.showingSettings = true } label: {
                HStack(spacing: 7) {
                    Text("SETTINGS").tracking(1.2)
                    Spacer()
                }.font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.75))
                    .padding(12).frame(maxWidth: .infinity)
                    .background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8)).raised(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.1)))
                    .contentShape(Rectangle())
            }.buttonStyle(.reactive).keyboardShortcut(",", modifiers: .command).padding(10)
            Divider().overlay(.black.opacity(0.04))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    capability("Hooks")
                    capability("Skills")
                    if !session.builtinCommands.isEmpty { capability("Commands") }
                    capability("MCP")
                    capability("Instructions")
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(.black.opacity(0.04))
            // The session's ID to hand another agent, which reads its transcript, instead of a screenshot.
            Button {
                guard let id = session.threadID else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string)
                withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.25)) { copiedID = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.25)) { copiedID = false } }
            } label: {
                HStack(spacing: 4) {
                    Text(copiedID ? "COPIED" : "SESSION ID").tracking(1.2).lineLimit(1).fixedSize().contentTransition(.opacity)
                    Spacer(minLength: 0)
                    Image(systemName: copiedID ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .bold)).contentTransition(.opacity)
                }.font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.75))
                    .padding(12).frame(maxWidth: .infinity)
                    .background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8)).raised(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.1)))
                    .contentShape(Rectangle())
            }.buttonStyle(.reactive).padding(10).help(session.threadID.map { "Copy " + $0 } ?? "No session yet").accessibilityLabel("Copy session ID")
        }.background(Color.black.opacity(0.025))
    }

    private func setting(_ title: String, value: String, command: String, color: Color, loading: Bool = false) -> some View {
        Button {
            if command == "/dir " {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.directoryURL = URL(fileURLWithPath: session.cwd, isDirectory: true)
                panel.begin { result in
                    if result == .OK, let url = panel.url { session.statusCommand("/dir " + url.path) }
                }
            } else if command.hasPrefix("https://"), let url = URL(string: command) { NSWorkspace.shared.open(url) }
            else { session.statusCommand(command) }
        } label: {
            HStack(spacing: 5) {
                if loading { ProgressView().controlSize(.mini) }
                Text(value).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(color).lineLimit(1).fixedSize()
            }
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5)).raised(RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
        }.buttonStyle(.reactive(RoundedRectangle(cornerRadius: 5))).help(command == "/repo" && !session.repositoryChanges.isEmpty ? session.repositoryChanges.joined(separator: "\n") : command).accessibilityLabel("\(title): \(value). \(command)")
    }

    private func capability(_ title: String) -> some View {
        Button { openCapability = title } label: {
                HStack(spacing: 7) {
                    Text(title == "Instructions" ? "MD Files" : title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2)
                    Spacer()
                    Text("\(session.capabilityItems(title).count)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                }.foregroundStyle(.black.opacity(0.75)).padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8)).raised(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.1)))
                    .contentShape(Rectangle())
            }.buttonStyle(.reactive).help("Browse " + title.lowercased())
            .popover(isPresented: Binding(get: { openCapability == title }, set: { if !$0 { openCapability = nil } }), arrowEdge: .trailing) {
                CapabilityPopup(session: session, title: title) { openCapability = nil }
            }
    }

    private var loginStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(settings.signingIn ? "Account sign-in" : "Account status", systemImage: "person.crop.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                Spacer()
                Button(settings.signingIn ? "Cancel" : "Dismiss") {
                    if settings.signingIn { settings.cancelSignIn() }
                    else { settings.loginMessage = "" }
                }.buttonStyle(.reactive(RoundedRectangle(cornerRadius: 5), outset: 4)).font(.system(size: 11)).foregroundStyle(.black.opacity(0.6))
            }
            ScrollView { Text(settings.loginMessage).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
        }.padding(14).background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 32).padding(.bottom, 8)
    }

    private var transcript: some View {
        ZStack(alignment: .bottom) {
            TranscriptTable(session: session, rows: session.rows, revision: session.revision, details: session.details, replacing: session.frontendReplacing,
                            sending: sending, geometry: geometry, reduceMotion: reduceMotion)
                .overlay(alignment: .top) { PinnedQuestion(session: session, geometry: geometry) }
            if !session.follow.attached {
                Button { session.landOnEnd?() } label: {
                    Label("Back to latest", systemImage: "arrow.down").font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 9).background(.ultraThinMaterial, in: Capsule()).raised(Capsule())
                }.buttonStyle(.reactive(Capsule())).padding(.bottom, 12)
            }
        }
        .background(GeometryReader { geometry in Color.clear.preference(key: MessageFrames.self, value: ["transcript": geometry.frame(in: .named("conversation"))]) })
    }

    private var composer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                let pending = !session.busy && !session.needsAttention && session.backgroundTasks > 0
                ActivityDot(busy: session.busy, pending: pending).frame(width: 12, height: 10).opacity(session.ready || session.busy ? 1 : 0.35).accessibilityLabel(session.activityLabel)
                Text(session.activityLabel).font(.system(size: 12)).foregroundStyle(session.busy ? accent : !session.ready ? .gray : pending ? pendingColor : readyColor)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 5).opacity(sending.flight == nil ? 1 : 0)
            if (!session.permissions.isEmpty && session.questionFlow == nil) || (!session.ready && !session.status.isEmpty) {
                Text(session.permissions.isEmpty ? session.status : "Your answer is needed").font(.system(size: 12)).lineLimit(1).foregroundStyle(.black.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 0) {
                if let flow = session.questionFlow, !flow.done {
                    QuestionPanel(session: session, flow: flow).padding(.bottom, 14)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                HStack(alignment: .bottom, spacing: 12) {
                Composer(session: session) { text, images, snapshot in
                    sending.prepare(text: text, images: images, rows: session.rows, snapshot: snapshot)
                }.frame(height: session.editorHeight)
                    .background(GeometryReader { geometry in Color.clear.preference(key: MessageFrames.self, value: ["editor": geometry.frame(in: .named("conversation"))]) })
                if session.busy { RoundButton(icon: "stop.fill", label: "Stop generation (Escape)") { Task { await session.stop(source: "Stop button") } } }
                Button { session.submitDraft() } label: { Image(systemName: "arrow.up").font(.system(size: 20, weight: .medium)).frame(width: 34, height: 34).foregroundStyle(.white).background(userGradient, in: Circle()).raised(Circle()) }.buttonStyle(.reactive(Circle())).disabled(!session.draft.string.hasPrefix("/") && (!session.ready || session.changing)).help(session.busy ? "Send guidance" : "Send message (Return)")
                }
            }.padding(14).background(.black.opacity(0.065), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.black.opacity(0.09), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .background(GeometryReader { geometry in Color.clear.preference(key: MessageFrames.self, value: ["composer": geometry.frame(in: .named("conversation"))]) })
            statusBar.padding(.leading, 10)
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 8)
    }

    var statusBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                identityStatus
                separator
                usageStatus
                separator
                repositoryStatus
                if !session.pullRequest.isEmpty {
                    separator.transition(.opacity)
                    setting("Pull request", value: session.pullRequest, command: session.pullRequestURL, color: Color(red: 0.42, green: 0.25, blue: 0.7))
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }.fixedSize().padding(8).animation(.easeOut(duration: 0.28), value: session.pullRequest.isEmpty)
        // The scroll view clips what it holds: the chips' shadows need room inside it, taken back outside.
        }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true).padding(-8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var identityStatus: some View {
        HStack(spacing: 8) {
            setting("Directory", value: session.directoryLabel, command: "/dir ", color: Color(red: 0.28, green: 0.36, blue: 0.7))
            separator
            setting("Model", value: session.modelStatusLabel, command: session.modelCommand, color: Color(red: 0.68, green: 0.18, blue: 0.45), loading: session.modelLoading)
            separator
            setting("Mode", value: session.activeMode == "bypass" ? "bypass" : "ask", command: "/perms ", color: Color(red: 0.75, green: 0.15, blue: 0.15))
        }
    }
    private var usageStatus: some View {
        HStack(spacing: 8) {
            setting("Tokens", value: session.contextLabel, command: "/tokens", color: Color(red: 0.13, green: 0.39, blue: 0.67))
            if session.account.provider != "qwen", session.usageLoading || !session.usage.isEmpty {
                separator
                quotaStatus
            }
        }
    }
    private var quotaStatus: some View {
        setting("Usage", value: session.usage.isEmpty ? (session.usageLoading ? "Loading…" : "Not reported") : session.usage, command: "/usage", color: session.usagePercent.map { Color(hue: (1 - min(100, max(0, $0)) / 100) / 3, saturation: 0.85, brightness: 0.45) } ?? .black.opacity(0.6), loading: session.usageLoading)
    }
    private var repositoryStatus: some View {
        setting("Repo", value: session.repositoryLabel, command: "/repo", color: session.repositoryStatus == "uncommitted" ? Color(red: 0.68, green: 0.18, blue: 0.38) : session.repositoryStatus == "unpushed" ? Color(red: 0.55, green: 0.36, blue: 0.08) : session.repositoryStatus == "up to date" ? readyColor : .black.opacity(0.6))
    }
    private var separator: some View { Text("|").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.black.opacity(0.25)) }
}

extension CXView {
    // The window alone sets its size: measured at zero width, a wrapped question gave a minimum height over 3,000 pt,
    // which grew the window past the bottom of the screen with the composer.
    static func host(_ session: Session) -> NSHostingView<CXView> {
        let host = NSHostingView(rootView: CXView(session: session))
        host.sizingOptions = []
        _ = TranscriptWheel.monitor
        return host
    }
}

// The pinned question is drawn above the transcript, not in it: the wheel over it found no scroll view and went nowhere.
// A wheel over the transcript's area that no scroll view takes goes to the transcript.
@MainActor enum TranscriptWheel {
    static func stray(in window: NSWindow, at point: NSPoint) -> NSScrollView? {
        guard let content = window.contentView, scrollView(at: point, in: content) == nil else { return nil }
        return transcript(under: point, in: content)
    }
    private static func scrollView(at point: NSPoint, in content: NSView) -> NSScrollView? {
        var hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let view = hit, !(view is NSScrollView) { hit = view.superview }
        return hit as? NSScrollView
    }
    // Walks the whole window: only for a wheel no scroll view takes, never for every event.
    private static func transcript(under point: NSPoint, in content: NSView) -> NSScrollView? {
        guard let transcript = RuntimeUpdate.scrollView(in: content), transcript.convert(transcript.bounds, to: nil).contains(point) else { return nil }
        return transcript
    }
    // A scroll view inside the transcript (a wide table, an open question) took every vertical wheel over it, even with nowhere to go.
    // Up or down where it cannot move, the wheel goes on to the transcript; a trackpad gesture goes whole to the view its first move picks.
    static func passes(_ event: NSEvent, over inner: NSScrollView) -> Bool { passes(event.scrollingDeltaX, event.scrollingDeltaY, over: inner) }
    static func passes(_ dx: CGFloat, _ dy: CGFloat, over inner: NSScrollView) -> Bool {
        guard let document = inner.documentView else { return false }
        let seen = inner.documentVisibleRect, whole = document.bounds
        // A swipe's first point often leans sideways: over a table with nothing to scroll sideways it latched the swipe there.
        guard abs(dy) > abs(dx) else { return whole.width <= seen.width + 0.5 }
        let top = document.isFlipped ? seen.minY <= whole.minY + 0.5 : seen.maxY >= whole.maxY - 0.5
        let bottom = document.isFlipped ? seen.maxY >= whole.maxY - 0.5 : seen.minY <= whole.minY + 0.5
        return dy > 0 ? top : bottom
    }
    private(set) static var chained: Bool?
    private(set) static var held: [NSEvent] = []
    private static var travel = CGSize.zero
    static let monitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
        MainActor.assumeIsolated { route(event, in: event.window, at: event.locationInWindow) }
    }
    static func route(_ event: NSEvent, in window: NSWindow?, at point: NSPoint) -> NSEvent? {
            guard let window, let content = window.contentView else { return event }
            var hit = scrollView(at: point, in: content)
            var outer = hit?.superview
            while let view = outer, !(view is TranscriptScrollView) { outer = view.superview }
            // A swipe begun off any table stays with the transcript when a table slides under the pointer.
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) { chained = outer is TranscriptScrollView ? nil : true; travel = .zero; held = [] }
            if let inner = hit, let outer = outer as? TranscriptScrollView {
                let chain: Bool
                if event.phase.isEmpty && event.momentumPhase.isEmpty { chain = passes(event, over: inner) }
                else {
                    if chained == nil {
                        travel.width += event.scrollingDeltaX; travel.height += event.scrollingDeltaY
                        let moved = abs(travel.width) + abs(travel.height)
                        if moved >= 4 || event.phase.contains(.ended) || event.phase.contains(.cancelled) || !event.momentumPhase.isEmpty {
                            chained = moved > 0 && passes(travel.width, travel.height, over: inner)
                        }
                    }
                    guard let decided = chained else { held.append(event); return nil }
                    chain = decided
                }
                let replay = held; held = []
                if chain { hit = nil; replay.forEach(outer.scrollWheel) } else { replay.forEach(inner.scrollWheel) }
            } else if !held.isEmpty {
                // An undecided swipe left the table: what it held goes where it went, never into a later swipe.
                if chained == nil { chained = true }
                let replay = held; held = []
                if let receiver = hit ?? transcript(under: point, in: content) { replay.forEach(receiver.scrollWheel) }
            }
            let target = hit ?? transcript(under: point, in: content)
            // A wheel that moves the transcript leaves its end; read once the event has scrolled it.
            var owner: NSView? = target
            while let view = owner, !(view is TranscriptScrollView) { owner = view.superview }
            if let owner = owner as? TranscriptScrollView {
                owner.controller?.willScroll()
                DispatchQueue.main.async { owner.controller?.userScrolled() }
            }
            guard hit == nil, let target else { return event }
            target.scrollWheel(with: event)
            return nil
    }
}

struct ActivityDot: NSViewRepresentable {
    let busy: Bool
    var pending = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ActivityDotView { ActivityDotView() }
    func updateNSView(_ view: ActivityDotView, context: Context) { view.update(busy: busy, pending: pending, reduceMotion: reduceMotion) }
}

final class ActivityDotView: NSView {
    private let dot = CALayer()
    private var busy = false
    private var reduceMotion = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        dot.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        dot.cornerRadius = 3
        layer?.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window { NotificationCenter.default.addObserver(self, selector: #selector(updateMotion), name: NSWindow.didChangeOcclusionStateNotification, object: window) }
        updateMotion()
    }
    override func viewDidHide() { super.viewDidHide(); updateMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }

    func update(busy: Bool, pending: Bool = false, reduceMotion: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.backgroundColor = NSColor(busy ? accent : pending ? pendingColor : readyColor).cgColor
        CATransaction.commit()
        self.busy = busy || pending; self.reduceMotion = reduceMotion
        updateMotion()
    }
    @objc private func updateMotion() {
        setMoving(!reduceMotion && !isHiddenOrHasHiddenAncestor && window?.occlusionState.contains(.visible) == true)
    }
    func setMoving(_ moving: Bool) {
        guard moving && busy && !reduceMotion else { dot.removeAnimation(forKey: "drift"); return }
        guard dot.animation(forKey: "drift") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -3; animation.toValue = 3
        animation.duration = 0.6; animation.autoreverses = true; animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(animation, forKey: "drift")
    }
}

enum SettingsTab: String, CaseIterable { case session = "Session", accounts = "Accounts", qwen = "Qwen", background = "Background" }

struct SettingsPopup: View {
    @ObservedObject var session: Session
    @ObservedObject private var settings = Settings.shared
    @State var tab = SettingsTab.session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func task(_ title: String, _ state: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(state).font(.system(size: 11)).foregroundStyle(accent).multilineTextAlignment(.trailing)
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.black.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.12)) }
    }
    @ViewBuilder private var background: some View {
        let routing = ["/", NSHomeDirectory()].contains(session.cwd) && !session.rows.contains { $0.kind == "user" }
        let fallbacks = session.available.filter { $0.id != session.account.id }.map(\.name)
        Text("Work VCX starts without a prompt from you. Each one spends tokens on the account named.").font(.system(size: 11)).foregroundStyle(.black.opacity(0.6))
        task("Agent background tasks", session.backgroundTasks == 0 ? "None running" : "\(session.backgroundTasks) running",
             "Commands and subagents the agent left running keep spending \(session.account.name)'s tokens after its reply; when one finishes, Claude starts a turn by itself.")
        task("Project routing", routing ? "Armed in this window" : "Done for this window",
             "The first prompt of a window opened in / or ~ goes to Claude Haiku on \(session.routeAccount?.name ?? "no Claude account"), with the ~/self folder map and the skill list, to pick its project. It runs while you type and again on Enter if the prompt grew by more than a quarter.")
        task("Rate limit retries", "\(session.rateLimitRetries.count) at most",
             "A turn stopped by a rate limit (not the plan's usage limit) is resent as \"Keep going\" on the same account after " + session.rateLimitRetries.map { "\(Int($0)) s" }.joined(separator: ", ") + ".")
        task("Network resume", "3 at most",
             "A turn a dropped connection killed is resent as \"Keep going\" once the internet answers again.")
        task("Usage limit fallback", fallbacks.isEmpty ? "No fallback" : fallbacks.joined(separator: ", "),
             "When an account reaches its usage limit mid-turn, the next enabled account takes the last prompt, with up to 48 KB of the recent conversation.")
        task("Resume recovery", "When needed",
             "When Claude cannot resume a saved conversation, a new one starts and gets the pending prompt with up to 48 KB of recent messages.")
    }
    private func setting(_ title: String, _ value: String, _ command: String) -> some View {
        Button {
            session.showingSettings = false
            session.showCommands(command)
        } label: {
            HStack(alignment: .top) {
                Text(title).foregroundStyle(.black.opacity(0.55))
                Spacer()
                Text(value).multilineTextAlignment(.trailing)
            }.font(.system(size: 12)).padding(.vertical, 8).frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.reactive(RoundedRectangle(cornerRadius: 8), outset: 6))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 16, weight: .semibold))
                Spacer()
                RoundButton(icon: "xmark", label: "Close settings") { session.showingSettings = false }
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            Picker("Settings section", selection: $tab.animation(reduceMotion ? nil : .easeOut(duration: 0.25))) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    switch tab {
                    case .session:
                    setting("Provider", session.providerLabel, "/model ")
                    setting("Model", session.modelLabel, session.modelCommand)
                    if let effort = session.effectiveEffort { setting("Effort", effort, session.modelCommand + session.model + " ") }
                    setting("Permissions", session.mode, "/perms ")
                    setting("Working directory", session.cwd, "/dir ")
                    case .accounts:
                    ForEach(settings.value.accounts) { account in
                        setting(account.name, account.provider.capitalized + (account.enabled ? " · enabled" : " · disabled"), "/account ")
                        if let home = account.home { setting("Profile", home, "/profile " + account.provider + " ") }
                        if let reset = settings.value.limits[account.id], reset > Date().timeIntervalSince1970 {
                            setting("Available after", Date(timeIntervalSince1970: reset).formatted(), "/usage")
                        }
                    }
                    setting("Add account", "Claude or Codex", "/login ")
                    setting("Import profile", "Existing account folder", "/profile ")
                    case .qwen:
                    setting("Endpoint", settings.value.qwenURL, "/qwen url ")
                    setting("Proxy", settings.value.qwenProxy.isEmpty ? "None" : settings.value.qwenProxy, "/qwen proxy ")
                    setting("Model", settings.value.qwenModel, "/qwen model ")
                    case .background:
                    background
                    }
                }.padding(20).id(tab).transition(.opacity)
            }
        }.frame(width: 480, height: 520).background(Color(white: 0.98)).preferredColorScheme(.light)
            .onExitCommand { session.showingSettings = false }
            // claude.ai connectors connect after the session starts, so the counts read at connection miss them.
            .task { await session.refreshCapabilities() }
    }
}

struct CapabilityPopup: View {
    @ObservedObject var session: Session
    let title: String
    var dismiss: () -> Void = {}
    @State private var query = ""
    @FocusState private var searching: Bool
    private var matches: [CapabilityItem] { capabilityMatches(session.capabilityItems(title), query: query) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                RoundButton(icon: "xmark", label: "Close " + title.lowercased(), action: dismiss)
            }.padding(14)
            TextField("Search " + title.lowercased(), text: $query).textFieldStyle(.plain).focused($searching)
                .padding(10).background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(matches) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.system(size: 12, weight: .medium))
                            if title == "Hooks" {
                                ForEach(Array(item.detail.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, detail in
                                    let parts = detail.components(separatedBy: " · ")
                                    HStack {
                                        Text(parts[0]).lineLimit(1)
                                        Spacer(minLength: 8)
                                        if parts.contains("disabled") { Text("disabled") }
                                    }.font(.system(size: 11)).foregroundStyle(.black.opacity(0.6)).help(detail).accessibilityLabel(detail)
                                }
                            } else {
                                Text(item.detail).font(.system(size: 11)).foregroundStyle(.black.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.12))
                            }
                    }
                    if matches.isEmpty {
                        Text(query.isEmpty ? "None reported" : "No matches").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(16)
            }
        }.frame(width: 380, height: 440).background(Color(white: 0.98)).preferredColorScheme(.light)
            .onAppear { searching = true }.onExitCommand(perform: dismiss)
    }
}

struct CommandPalette: View {
    @ObservedObject var session: Session
    var maxListHeight: CGFloat = 250
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "command").foregroundStyle(accent)
                Text("Commands").font(.system(size: 12, weight: .semibold))
                Text("\(session.commandOptions.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.black.opacity(0.6))
                Spacer()
                Text("esc").font(.system(size: 10, design: .monospaced)).foregroundStyle(.black.opacity(0.6))
            }.padding(.horizontal, 14).padding(.vertical, 12)
            Divider().overlay(.black.opacity(0.03))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(session.commandOptions.enumerated()), id: \.element.id) { index, command in
                            Button { session.chooseCommand(command) } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(command.name).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                                        Text(command.detail).font(.system(size: 11)).foregroundStyle(.black.opacity(0.6)).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text(command.source).font(.system(size: 9, weight: .medium)).foregroundStyle(accent.opacity(0.9)).padding(.horizontal, 7).padding(.vertical, 4).background(accent.opacity(0.1), in: Capsule())
                                }.padding(.horizontal, 10).padding(.vertical, 9).background(index == session.commandSelection ? accent.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                            }.buttonStyle(.reactive).id(command.id)
                        }
                        if session.commandOptions.isEmpty {
                            Text("No matching commands").font(.system(size: 12)).foregroundStyle(.black.opacity(0.6)).frame(maxWidth: .infinity).padding(.vertical, 25)
                        }
                    }.padding(6)
                }
                .onChange(of: session.commandSelection) { _, index in
                    if session.commandOptions.indices.contains(index) { proxy.scrollTo(session.commandOptions[index].id, anchor: .center) }
                }
                .onChange(of: session.commandQuery, initial: true) { _, _ in
                    if session.commandOptions.indices.contains(session.commandSelection) { proxy.scrollTo(session.commandOptions[session.commandSelection].id, anchor: .center) }
                }
            }.frame(height: min(max(CGFloat(session.commandOptions.count) * 51 + 12, 65), maxListHeight))
            Divider().overlay(.black.opacity(0.03))
            HStack {
                Text("↑ ↓ navigate"); Text("Return select"); Text("Tab complete")
                Spacer(minLength: 0)
            }.font(.system(size: 9)).foregroundStyle(.black.opacity(0.6)).padding(.horizontal, 14).padding(.vertical, 9)
        }.background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.22)))
            .shadow(color: .black.opacity(0.12), radius: 22, y: 8)
            .accessibilityLabel("Command suggestions")
    }
}

struct ConversationRow: View, Equatable {
    @ObservedObject var row: Row
    let session: Session
    var collapsible = false
    var pinnedIn: CGSize?
    var lifted = false
    static func == (left: Self, right: Self) -> Bool { left.row.id == right.row.id && left.pinnedIn == right.pinnedIn && left.lifted == right.lifted }
    var body: some View {
        if let item = row.items.first {
            if row.kind == "user" { UserBubble(item: item, session: session, collapsible: collapsible, pinnedIn: pinnedIn, lifted: lifted) }
            else if row.kind == "notice" { NoticeLine(item: item) }
            else if row.kind == "peer" { PeerLine(item: item).background(Color.white) }
            else { AssistantBubble(item: item).environment(\.codeEdits, session.codeEdits) }
        }
    }
}

struct NoticeLine: View {
    @ObservedObject var item: Item
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(item.text, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.black.opacity(0.6)).textSelection(.enabled)
            // Selectable Text ignores link clicks, so the log path is its own text view.
            if let link = item.data["link"] as? String {
                let path = { var text = AttributedString(link.replacingOccurrences(of: NSHomeDirectory(), with: "~", options: .anchored)); text.link = URL(fileURLWithPath: link); return text }()
                LinkText(text: path, weight: .regular, lineSpacing: 0).padding(.leading, 20)
            }
        }
    }
}

struct PeerLine: View {
    @ObservedObject var item: Item
    var body: some View {
        let first = item.text.split(separator: "\n").first.map(String.init) ?? ""
        Button { focusPeer(item.data) } label: {
            Label(item.title + (first.isEmpty ? "" : " · " + first), systemImage: item.data["direction"] as? String == "sent" ? "arrow.up.right" : "arrow.down.left")
                .lineLimit(1).truncationMode(.tail)
                .font(.system(size: 12)).foregroundStyle(.black.opacity(item.failed ? 0.3 : 0.45))
        }.buttonStyle(.reactive(RoundedRectangle(cornerRadius: 5), outset: 4)).help(item.text)
    }
}

struct WorkBlock: View {
    let rows: [Row]
    let details: Bool
    // Brings the shut block back into view: shut while scrolled inside it, it left the view past the transcript's new end, blank.
    var reveal: () -> Void = {}
    // Maps a y in its row to the transcript's viewport.
    var viewportTop: (CGFloat) -> CGFloat = { $0 }
    @State private var hovering = false
    @State private var pinned = false
    @State private var local: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func animate(_ change: () -> Void) { withAnimation(reduceMotion ? nil : .smooth(duration: 0.28), change) }
    var body: some View {
        let actions = rows.filter { $0.kind == "activity" }.flatMap(\.items).count, notes = rows.filter { $0.kind == "assistant" }.count, sent = rows.filter { $0.kind == "peer" }.count
        let open = hovering || pinned || details
        VStack(alignment: .leading, spacing: 0) {
            Button { animate { if pinned { pinned = false; hovering = false } else { pinned = true } } } label: {
                HStack(spacing: 12) {
                    // The tinted segment is the hover target that opens the block.
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 44).frame(maxHeight: .infinity).background(accent.opacity(open ? 0.16 : 0.09))
                        .onHover { inside in FreezeTrace.note("work block edge hover"); if inside, !hovering { animate { hovering = true } } }
                    Text([actions == 0 ? nil : "\(actions) \(actions == 1 ? "action" : "actions")", notes == 0 ? nil : "\(notes) \(notes == 1 ? "note" : "notes")", sent == 0 ? nil : "\(sent) \(sent == 1 ? "message" : "messages") sent"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }.frame(height: 40).foregroundStyle(.black.opacity(0.6)).contentShape(Rectangle())
            }.buttonStyle(.reactive(Rectangle())).help(pinned ? "Collapse" : "Keep open (hovering the tinted edge opens it)")
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        if row.kind == "activity" { ForEach(row.items) { ActionView(item: $0) } }
                        else if row.kind == "peer", let item = row.items.first { PeerLine(item: item) }
                        else if let item = row.items.first { WorkNote(item: item) }
                    }
                }.padding(14).transition(.opacity)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("conversation")).minY } action: { FreezeTrace.note("work block top"); local = $0 }
            .onHover { inside in
                FreezeTrace.note("work block hover")
                guard !inside, hovering else { return }
                let top = viewportTop(local)
                // Scrolled inside it, the transcript rises to its header first, then it shuts: shut at once under that offset, the view went blank until the scroll caught up.
                if top < 0, !pinned, !details, !reduceMotion {
                    withAnimation(.smooth(duration: 0.3)) { reveal() }
                    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in MainActor.assumeIsolated { animate { hovering = false } } }
                } else { animate { hovering = false; if top < 0, !pinned, !details { reveal() } } }
            }
    }
}

struct WorkNote: View {
    @ObservedObject var item: Item
    var body: some View { MarkdownBody(text: item.text).opacity(0.6) }
}

struct ActionView: View {
    @ObservedObject var item: Item
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let command = item.data["command"] as? String ?? ""
        // The header carries the card's padding so its hover tint fills the card's top, not a box inside it.
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { open.toggle() } } label: {
                HStack {
                    Image(systemName: item.failed ? "exclamationmark.circle" : "chevron.right").rotationEffect(.degrees(open && !item.failed ? 90 : 0)); Text(item.title).lineLimit(1)
                    Spacer(minLength: 8)
                    // Qwen's steps: a live counter while one runs, its duration once done.
                    if let start = item.data["stepStartedAt"] as? Double, item.data["status"] as? String == "inProgress" {
                        TimelineView(.periodic(from: .now, by: 1)) { context in Text(Duration.seconds(max(0, Int(context.date.timeIntervalSince1970 - start))).formatted(.time(pattern: .minuteSecond))).monospacedDigit().opacity(0.6) }
                    } else if let seconds = item.data["seconds"] as? Int {
                        Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))).monospacedDigit().opacity(0.6)
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 9).padding(.bottom, open ? 8 : 9).contentShape(Rectangle())
            }.buttonStyle(.reactive(Rectangle())).font(.system(size: 12, design: .monospaced)).foregroundStyle(item.failed ? Color(red: 0.65, green: 0.32, blue: 0.04) : .black.opacity(0.65))
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if !command.isEmpty, command != item.title { Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.black.opacity(0.75)).textSelection(.enabled) }
                    if !item.output.isEmpty { Text(item.output).font(.system(size: 11, design: .monospaced)).foregroundStyle(.black.opacity(0.6)).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 9).transition(.opacity)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct UserBubble: View {
    @ObservedObject var item: Item
    let session: Session
    var collapsible = false
    // Drawn above the transcript as its current question: the transcript's size, since no scroll view holds it.
    var pinnedIn: CGSize?
    var lifted = false
    @State private var hovering = false
    @State private var stuck = false
    @State private var hides = false
    @State private var size = CGSize.zero
    @EnvironmentObject private var sending: SendAnimation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static func opening(reduceMotion: Bool) -> Animation { .smooth(duration: reduceMotion ? 0.1 : 0.3) }
    var body: some View {
        let unread = item.data["queued"] as? Bool == true, collapsed = collapsible && !hovering, edge = collapsible && hides
        let message = AgentMessages.parse(((item.data["content"] as? [JSON]) ?? []).compactMap { $0["text"] as? String }.joined())
        // Pinned, the question never scrolls with the transcript: open and taller than most of it, it scrolls on its own or its end stays out of reach.
        let cap = (pinnedIn?.height ?? (session.viewportHeight > 0 ? session.viewportHeight : .infinity)) * 0.6, scrolls = collapsible && hovering && size.height > cap
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 5) {
                let content = VStack(alignment: .leading, spacing: 6) {
                    if let message { AgentMessageContent(message: message, collapsed: collapsed) }
                    else { MessageContent(item: item, collapsed: collapsed) { session.preview = $0 } }
                }
                // Only the arrow opens it: the pointer crossing the text to read the answer under it leaves it shut.
                // A question of fifteen lines or less shows whole, with no arrow; open, the arrow is gone until the pointer leaves.
                // The arrow is an overlay on a reserved row, not a row of its own coming and going in the stack.
                .padding(.bottom, edge && !hovering ? 6 + CollapsibleText.line : 0)
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(message == nil ? accent : agentPink)
                        .frame(width: 28, height: CollapsibleText.line, alignment: .leading)
                        .contentShape(Rectangle())
                        .onHover { inside in FreezeTrace.note("question arrow hover " + item.id); if inside, !hovering { withAnimation(Self.opening(reduceMotion: reduceMotion)) { hovering = true } } }
                        .opacity(edge && !hovering ? 1 : 0).allowsHitTesting(edge && !hovering)
                }
                .padding(16)
                Group {
                    // At the width it had unscrolled, the text wraps as it did and keeps the height that made it scroll.
                    if scrolls { ScrollView { content }.frame(width: size.width, height: cap) }
                    else { content.onGeometryChange(for: CGSize.self) { $0.size } action: { new in FreezeTrace.note("question size " + item.id); withAnimation(Self.opening(reduceMotion: reduceMotion)) { size = new } } }
                }
                    // Open, the text shows whole and reports nothing hidden: the edge stays until the pointer leaves.
                    .onPreferenceChange(HidesText.self) { FreezeTrace.note("question hides " + item.id); if !hovering { hides = $0 } }
                    // A send flight lands on this frame, which leaves the edge out.
                    .background(GeometryReader { geometry in
                        let frame = geometry.frame(in: .named("conversation"))
                        Color.clear.preference(key: MessageFrames.self, value: pinnedIn != nil ? [:] : collapsed ? [item.id: frame, "collapsed:" + item.id: .zero] : [item.id: frame])
                    })
                    .clipShape(RoundedRectangle(cornerRadius: 17))
                    .background(message == nil ? accent.opacity(0.08) : agentPink.opacity(0.2), in: RoundedRectangle(cornerRadius: 17))
                    // Pinned, only the bubble hides what scrolls under it, and its shadow sets it above the transcript once it sticks to the top.
                    .background { RoundedRectangle(cornerRadius: 17).fill(.white).shadow(color: .black.opacity(stuck ? 0.22 : 0), radius: 12, y: 4) }
                    .onAppear { if pinnedIn != nil { stuck = lifted } }
                    .onChange(of: lifted) { _, now in stuck = now }
                    .animation(.easeOut(duration: 0.2), value: stuck)
                    // Not onHover: opening into its own scroll view over the transcript's table, it reported the pointer gone while it stayed.
                    .onContinuousHover { phase in FreezeTrace.note("question hover " + item.id); if case .ended = phase, hovering { withAnimation(Self.opening(reduceMotion: reduceMotion)) { hovering = false } } }
                    .opacity(sending.hides(item) ? 0 : unread ? 0.5 : 1)
                if unread { Text("Not read yet · ↑ to edit").font(.system(size: 11)).foregroundStyle(.black.opacity(0.45)).padding(.trailing, 6) }
            }.column(pinnedIn.map { $0.width * 0.85 })
        }
    }
}

extension View {
    // 85 % of the scroll view's width; above the scroll view, its width is passed in.
    @ViewBuilder func column(_ width: CGFloat?) -> some View {
        if let width { frame(width: width, alignment: .trailing) }
        else { containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.85 } }
    }
}

// Another window's agent wrote it: who, as a tag fitted to its name, then the text.
struct AgentMessageContent: View {
    let message: AgentMessages.Message
    var collapsed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("from \(message.provider)-\(message.name)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(agentPink)
                .padding(.horizontal, 8).padding(.vertical, 4).background(agentPink.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            CollapsibleText(text: message.body, collapsed: collapsed)
        }
    }
}

// Collapsed, SwiftUI's own truncation fills line 1 with words of line 2, which jump back down on hover:
// it shows the first line as the open text wraps it, then "…", and keeps the open text's width.
struct CollapsibleText: View {
    let text: String
    let collapsed: Bool
    @State private var open: CGSize
    // The new pinned view starts with the size already measured in the transcript.
    // shortcut: shared text at different widths remeasures next frame; key by width if those views need independent initial sizes.
    private static var measured: [String: CGSize] = [:]
    init(text: String, collapsed: Bool) { self.text = text; self.collapsed = collapsed; _open = State(initialValue: Self.measured[text] ?? .zero) }
    static let size: CGFloat = 12
    static let line = NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: size, weight: .regular))
    var body: some View {
        ZStack(alignment: .topLeading) {
            // ponytail: width from the first 10,000 characters; measured whole, a 520,000-character paste held the window 45 s.
            // A wider line past them widens the bubble only once opened.
            Text(text.prefix(10_000)).font(.system(size: Self.size, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { FreezeTrace.note("text open size"); open = $0; if Self.measured.count > 500 { Self.measured = [:] }; Self.measured[text] = $0 }
                .hidden().frame(height: 0, alignment: .top)
            // Up to fifteen lines, it stays whole.
            let shown = collapsed && open.width > 0 && open.height > Self.line * 15.5 ? firstLine(text, width: open.width) : text
            Text(shown).font(.system(size: Self.size, design: .monospaced)).textSelection(.enabled)
                .lineLimit(collapsed && (open.width == 0 || shown != text) ? 1 : nil).fixedSize(horizontal: false, vertical: true)
                .preference(key: HidesText.self, value: shown != text)
                .clipped() // opening, the lines appear as the bubble grows instead of under the pictures that follow
        }
    }
}

func firstLine(_ text: String, width: CGFloat) -> String {
    let font = NSFont.monospacedSystemFont(ofSize: CollapsibleText.size, weight: .regular)
    func lineEnds(_ s: String) -> [Int] {
        let setter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        var ends = [Int](), length = (s as NSString).length
        while ends.count < 2, (ends.last ?? 0) < length { ends.append((ends.last ?? 0) + CTTypesetterSuggestLineBreak(setter, ends.last ?? 0, Double(width))) }
        return ends
    }
    let ends = lineEnds(text), ns = text as NSString
    guard ends.count > 1 else { return text }
    var end = ends[0]
    func trim() { while end > 0, CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(ns.character(at: end - 1)) ?? "x") { end -= 1 } }
    trim()
    // No room left for "…": the line ends at the break before, where the ellipsis pushed its last piece of word.
    while end > 0, case let shorter = lineEnds(ns.substring(to: end) + "…"), shorter.count > 1 {
        end = shorter[0] < end ? shorter[0] : ns.rangeOfComposedCharacterSequence(at: end - 1).location
        trim()
    }
    return ns.substring(to: end) + "…"
}

// Pictures pasted together share a row.
func pieceRuns(_ pieces: [JSON]) -> [[JSON]] {
    pieces.reduce(into: [[JSON]]()) { runs, piece in
        if piece["type"] as? String != "text", let last = runs.last?.last, last["type"] as? String != "text" { runs[runs.count - 1].append(piece) }
        else { runs.append([piece]) }
    }
}

struct MessageContent: View {
    @ObservedObject var item: Item
    // A pinned question keeps one line until hovered, so it covers little of the answer under it.
    var collapsed = false
    var preview: (String) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(pieceRuns(item.data["content"] as? [JSON] ?? []).enumerated()), id: \.offset) { n, run in
                if run.count == 1, run[0]["type"] as? String == "text", let text = run[0]["text"] as? String {
                    CollapsibleText(text: text, collapsed: collapsed)
                } else { PictureRow(pieces: run, preview: preview) }
            }
        }
    }
}

struct PictureRow: View {
    let pieces: [JSON]
    var preview: (String) -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { cards }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) { cards }
        }
    }
    private var cards: some View {
        ForEach(Array(pieces.enumerated()), id: \.offset) { n, piece in
            if let path = piece["path"] as? String ?? piece["url"] as? String { PictureView(path: path) { preview(path) } }
            else { Label("Image \(n + 1)", systemImage: "photo").font(.system(size: 12)) }
        }
    }
}

struct PictureView: View {
    let path: String
    var action: () -> Void
    @State private var image: NSImage?
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let image { Image(nsImage: image).resizable().scaledToFill().frame(width: 64, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 7)) }
                else { Image(systemName: "photo").frame(width: 64, height: 52).background(.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 7)) }
                VStack(alignment: .leading, spacing: 4) { Text("Image").font(.system(size: 12, weight: .semibold)); Text("Click to preview").font(.system(size: 10)).opacity(0.6) }
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).opacity(0.5)
            }.padding(8).background(.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.reactive(RoundedRectangle(cornerRadius: 11))).task(id: path) { image = await Task.detached { thumbnail(path) }.value }
    }
}

struct AssistantBubble: View {
    @ObservedObject var item: Item
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) { Image(systemName: "sparkle").foregroundStyle(accent); Text(item.data["provider"] as? String ?? "Codex").foregroundStyle(.black.opacity(0.6)) }.font(.system(size: 11, weight: .medium))
            MarkdownBody(text: item.text.isEmpty ? "…" : item.text)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlock: Identifiable {
    let id: Int
    let text: String
    let code: Bool
    let language: String
    let markdown: Bool
}

// CommonMark fences: a block closes only on a bare run of its own character at least as long as its opener, so a ```` block holds ``` ones.
func markdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = [], lines: [String] = [], code = false, language = "", fence = ""
    func append() {
        // A ```` fence exists only to hold nested fences: its content is a Markdown document, shown formatted.
        if !lines.isEmpty { blocks.append(MarkdownBlock(id: blocks.count, text: lines.joined(separator: "\n"), code: code, language: language, markdown: code && (["md", "markdown"].contains(language.lowercased()) || fence.count > 3))); lines.removeAll() }
    }
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix { $0 == trimmed.first && ($0 == "`" || $0 == "~") }
        if code ? run.first == fence.first && run.count >= fence.count && run.count == trimmed.count : run.count >= 3 {
            append()
            if code { code = false; fence = ""; language = "" }
            else { code = true; fence = String(run); language = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces) }
        } else { lines.append(line) }
    }
    append(); return blocks
}

struct MarkdownBody: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(markdownBlocks(text)) { block in
                if block.code {
                    CodeBlock(block: block)
                } else {
                    ProseView(text: block.text)
                }
            }
        }
    }
}

private struct CodeEditsKey: EnvironmentKey { static let defaultValue: CodeEdits? = nil }
extension EnvironmentValues { var codeEdits: CodeEdits? { get { self[CodeEditsKey.self] } set { self[CodeEditsKey.self] = newValue } } }

struct CodeBlock: View {
    let block: MarkdownBlock
    @Environment(\.codeEdits) private var edits
    @State private var copied = false
    @State private var reset: Task<Void, Never>?
    @State private var edited: String?
    @State private var draft = ""
    @State var editing = false
    @FocusState private var focused: Bool
    var body: some View {
        let code = edited ?? block.text, mono = Font.system(size: 12, design: .monospaced)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                copied = true; reset?.cancel()
                reset = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { copied = false } }
            } label: {
                HStack {
                    Text((block.language.isEmpty ? block.markdown ? "Markdown" : "Code" : block.language) + (edited == nil ? "" : " · edited")).font(.system(size: 10)).foregroundStyle(.black.opacity(0.6)); Spacer()
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: copied ? 19 : 13, weight: copied ? .light : .regular)).frame(height: 18)
                }.padding(10).background(.black.opacity(0.025)).contentShape(Rectangle())
            }.buttonStyle(.reactive(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))).help(copied ? "Copied" : "Copy code").accessibilityLabel(copied ? "Copied" : "Copy code")
            .overlay(alignment: .trailing) {
                if edits != nil, !block.markdown {
                    Button { editing.toggle() } label: {
                        Image(systemName: editing ? "checkmark.circle" : "pencil").font(.system(size: 13)).frame(width: 24, height: 18).contentShape(Rectangle())
                    }.buttonStyle(.reactive(RoundedRectangle(cornerRadius: 5), outset: 4)).padding(.trailing, 40)
                    .help(editing ? "Done editing" : "Edit: copy takes your version, and your next message sends it").accessibilityLabel(editing ? "Done editing" : "Edit code")
                }
            }
            if block.markdown { MarkdownBody(text: block.text).padding(14) }
            else if editing {
                // The hidden copy sizes the editor to its text, so it never scrolls inside the transcript; 5 pt is NSTextView's line padding.
                Text(code + " ").font(mono).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 5).hidden()
                .overlay {
                    // Bound to its own state: a Binding(get:set:) here made every keystroke reset the text and send the caret to the end.
                    TextEditor(text: $draft)
                        .font(mono).scrollContentBackground(.hidden).scrollDisabled(true).focused($focused)
                        .onKeyPress(.escape) { editing = false; return .handled }
                }.padding(.vertical, 14).padding(.horizontal, 9)
                .onAppear { draft = code; DispatchQueue.main.async { focused = true } }
                .onChange(of: draft) { _, now in edited = now == block.text ? nil : now; edits?.set(block.text, now) }
                .onChange(of: focused) { _, now in if !now { editing = false } }
            }
            else { Text(code).font(mono).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
        }.background(.black.opacity(editing ? 0.02 : 0.045), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(editing ? accent.opacity(0.4) : .black.opacity(0.06)))
        .animation(.easeOut(duration: 0.25), value: editing)
        .onAppear { edited = edits?.text[block.text] }
        .onHover { inside in FreezeTrace.note("code block hover"); if !inside, copied { reset?.cancel(); copied = false } }
    }
}

struct PermissionView: View {
    @ObservedObject var session: Session
    let request: Permission
    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Label("Permission requested", systemImage: "hand.raised").font(.system(size: 14, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(request.params["reason"] as? String ?? "Review this action before allowing it.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(request.params["command"] as? String ?? (request.params["changes"] as? [JSON] ?? []).map { ($0["path"] as? String ?? "") + "\n" + ($0["diff"] as? String ?? "") }.joined(separator: "\n")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Cancel") { session.answer(request, result: ["decision": "cancel"]) }.modifier(HoverPress(shape: AnyShape(RoundedRectangle(cornerRadius: 5))))
                    Spacer()
                    Button("Decline") { session.answer(request, result: ["decision": "decline"]) }.modifier(HoverPress(shape: AnyShape(RoundedRectangle(cornerRadius: 5))))
                    Button("Allow") { session.answer(request, result: ["decision": "accept"]) }.buttonStyle(.borderedProminent).tint(accent).modifier(HoverPress(shape: AnyShape(RoundedRectangle(cornerRadius: 5))))
                        .disabled(request.method == "item/fileChange/requestApproval" && (request.params["changes"] as? [JSON] ?? []).isEmpty)
                }
            }.padding(16).frame(maxWidth: 750).background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.1)))
    }
}

// The pending question, inside the composer box: each option carries the number that picks it.
struct QuestionPanel: View {
    @ObservedObject var session: Session
    let flow: QuestionFlow
    @State private var secret = ""
    @FocusState private var secretFocused: Bool
    var body: some View {
        let question = flow.current, picked = flow.selections[flow.id, default: []]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble").foregroundStyle(accent)
                Text(([flow.questions.count > 1 ? "Question \(flow.step + 1) of \(flow.questions.count)" : "Your answer is needed", question["header"] as? String].compactMap { $0 }).joined(separator: " · "))
                Spacer()
                Button("Cancel") { session.answer(flow.request, result: ["answers": [:]]) }.buttonStyle(.reactive(RoundedRectangle(cornerRadius: 5), outset: 4)).help("Answer nothing and let the agent continue")
            }.font(.system(size: 11, weight: .semibold)).foregroundStyle(.black.opacity(0.6))
            Text(question["question"] as? String ?? "Question").font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            let options = VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(flow.options.enumerated()), id: \.offset) { index, option in
                    let label = option["label"] as? String ?? "Option", selected = picked.contains(label)
                    Button { _ = session.chooseOption(index + 1) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)").font(.system(size: 11, weight: .bold)).frame(width: 20, height: 20)
                                .foregroundStyle(selected ? .white : accent).background(selected ? accent : accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(label).font(.system(size: 12, weight: .medium))
                                if let detail = option["description"] as? String, !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.black.opacity(0.6)) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8)).raised(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                    }.buttonStyle(.reactive)
                }
            }
            ScrollView { options.padding(8) }.frame(maxHeight: 276).fixedSize(horizontal: false, vertical: true).padding(-8)
            if question["isSecret"] as? Bool == true {
                SecureField("Your answer (hidden), then Return", text: $secret).focused($secretFocused).onAppear { secretFocused = true }.onSubmit { session.answerQuestion(secret); secret = "" }
            } else if flow.multiple {
                Text("Numbers toggle choices · Return confirms").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5))
            }
        }.id(flow.step).transition(.opacity)
    }
}

func questionAnswers(_ questions: [JSON], text: [String: String], selections: [String: Set<String>]) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for (index, question) in questions.enumerated() {
        let id = question["id"] as? String ?? "\(index)"
        var values = question["multiSelect"] as? Bool == true ? (question["options"] as? [JSON] ?? []).compactMap { $0["label"] as? String }.filter { selections[id, default: []].contains($0) } : []
        if let answer = text[id], !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append(answer) }
        if !values.isEmpty { result[id] = values }
    }
    return result
}

// Each ⟶ / ✓ line is its own block, in the order short answer, details, done, next.
func answerParagraphs(_ text: String) -> [String] {
    var parts: [String] = []
    for paragraph in text.components(separatedBy: "\n\n") {
        var plain: [String] = []
        func close() {
            // The blank line after a closing fence would otherwise hide the heading that follows it.
            if !plain.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(plain.joined(separator: "\n").trimmingCharacters(in: .newlines)) }
            plain = []
        }
        let lines = paragraph.components(separatedBy: "\n")
        for (n, line) in lines.enumerated() {
            if line.hasPrefix("⟶ ") || line.hasPrefix("✓ Done:") { close(); parts.append(line) }
            else {
                // A table right under a line of text, with no blank line between, is still its own block.
                if n + 1 < lines.count, line.contains("|"), tableRule(lines[n + 1]) { close() }
                plain.append(line)
            }
        }
        close()
    }
    func rank(_ part: String) -> Int { part.hasPrefix("✓ Done:") ? 2 : part.hasPrefix("⟶ Next:") ? 3 : part.hasPrefix("⟶ ") ? 0 : 1 }
    return parts.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
}

struct ProseView: View {
    let text: String
    private var paragraphs: [String] { answerParagraphs(text) }
    private func rich(_ text: String) -> AttributedString { (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text) }
    // Selectable SwiftUI Text becomes an NSTextField on macOS, which ignores clicks on its links.
    @ViewBuilder private func prose(_ text: String, weight: Font.Weight = .regular, lineSpacing: CGFloat = 0) -> some View {
        let value = rich(text)
        if value.runs.contains(where: { $0.link != nil }) { LinkText(text: value, weight: weight, lineSpacing: lineSpacing) }
        else { Text(value).font(.system(size: 12, weight: weight, design: .monospaced)).lineSpacing(lineSpacing).textSelection(.enabled) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                let lines = paragraph.components(separatedBy: "\n")
                if lines.count >= 2, tableRule(lines[1]) {
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 10) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { n, line in
                                if n != 1 {
                                    GridRow {
                                        ForEach(Array(tableCells(line).enumerated()), id: \.offset) { _, cell in
                                            prose(cell, weight: n == 0 ? .semibold : .regular).frame(width: 280, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }.padding(14)
                    }.background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                } else if paragraph.hasPrefix("#") {
                    let title = paragraph.drop(while: { $0 == "#" || $0 == " " })
                    prose(String(title), weight: .semibold)
                } else if paragraph.hasPrefix("⟶ ") || paragraph.hasPrefix("✓ Done:") {
                    prose(paragraph.replacingOccurrences(of: "⟶ Next:", with: "+ Next:").replacingOccurrences(of: "⟶ ", with: "").trimmingCharacters(in: .whitespacesAndNewlines), weight: .medium, lineSpacing: 5).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading).background(paragraph.hasPrefix("✓") ? Color(red: 1, green: 225 / 255, blue: 195 / 255) : paragraph.hasPrefix("⟶ Next:") ? Color(red: 214 / 255, green: 230 / 255, blue: 1) : Color(red: 214 / 255, green: 245 / 255, blue: 214 / 255), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    prose(paragraph, lineSpacing: 6).tint(accent).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct LinkText: NSViewRepresentable {
    let text: AttributedString
    let weight: Font.Weight
    let lineSpacing: CGFloat
    static var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    // NSTextView's own fallback opens nothing: a click on a file link reached no LaunchServices call.
    final class Coordinator: NSObject, NSTextViewDelegate {
        // Measured once per width: layout asks every row again on each pass, a new layout manager each time.
        var sizes: [CGFloat: CGSize] = [:]
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            return LinkText.open(url)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.isEditable = false; view.drawsBackground = false; view.isVerticallyResizable = false
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.linkTextAttributes = [.foregroundColor: NSColor(accent), .cursor: NSCursor.pointingHand]
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        let base: NSFont.Weight = weight == .semibold ? .semibold : weight == .medium ? .medium : .regular
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = lineSpacing
        let string = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = NSFont.monospacedSystemFont(ofSize: 12, weight: intent.contains(.stronglyEmphasized) ? .bold : base)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            string.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        if view.textStorage?.isEqual(to: string) != true { view.textStorage?.setAttributedString(string); context.coordinator.sizes = [:] }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        if let size = context.coordinator.sizes[width ?? .infinity] { return size }
        let storage = NSTextStorage(attributedString: view.textStorage ?? NSAttributedString()), manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size, size = CGSize(width: width ?? ceil(used.width), height: ceil(used.height))
        if context.coordinator.sizes.count > 8 { context.coordinator.sizes = [:] }
        context.coordinator.sizes[width ?? .infinity] = size
        return size
    }
}

func tableRule(_ line: String) -> Bool { line.contains("|") && line.replacingOccurrences(of: #"[\s:|\-]"#, with: "", options: .regularExpression).isEmpty }

func tableCells(_ line: String) -> [String] {
    var text = line.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("|") { text.removeFirst() }
    if text.hasSuffix("|") { text.removeLast() }
    return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}

