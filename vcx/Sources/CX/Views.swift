import SwiftUI
import AppKit

let accent = Color(red: 0.43, green: 0.23, blue: 0.75)
let readyColor = Color(red: 0.1, green: 0.45, blue: 0.18)
let userGradient = LinearGradient(colors: [Color(red: 0.93, green: 0.23, blue: 0.51), Color(red: 0.55, green: 0.3, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)

struct ConversationSection: Identifiable {
    let id: UUID
    var question: Row?
    var rows: [Row] = []
}

func conversationSections(_ rows: [Row]) -> [ConversationSection] {
    var sections: [ConversationSection] = []
    for row in rows {
        if row.kind == "user" {
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
    var work = rows.filter { $0.kind != "notice" }
    let last = work.lastIndex(where: { $0.kind == "assistant" }).map { work.remove(at: $0) }
    return (work, last, rows.filter { $0.kind == "notice" })
}

struct RoundButton: View {
    let icon: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 17.5, weight: .medium)).frame(width: 34, height: 34).background(.black.opacity(0.07), in: Circle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct ImagePreview: View {
    let path: String
    let size: CGSize
    var dismiss: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = thumbnail(path, size: 1600) { Image(nsImage: image).resizable().scaledToFit() }
                else { Text("This image is no longer available.").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.padding(16)
            RoundButton(icon: "xmark", label: "Close image", action: dismiss).padding(10)
        }.frame(width: size.width * 2 / 3, height: size.height * 2 / 3)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.2), radius: 28, y: 12)
            .accessibilityAddTraits(.isModal)
    }
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
    }
    @Published var flight: Flight?
    @Published var frame = CGRect.zero
    @Published var blend: CGFloat = 0
    @Published private var pending: Pending?
    private var composer = CGRect.zero
    private var editor = CGRect.zero
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
        let viewport = frames["transcript"] ?? CGRect(x: 0, y: 0, width: composer.maxX, height: composer.minY)
        func target(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: 0, dy: min(0, viewport.maxY - 28 - rect.maxY)).intersection(viewport) }
        if let flight {
            if reduceMotion || !rows.contains(where: { $0.items.contains(where: { $0.id == flight.item.id }) }) {
                self.flight = nil; generation += 1; moving = false
            } else if let measured = frames[flight.item.id], target(measured) != flight.destination {
                let destination = target(measured)
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
        flight = Flight(item: item, origin: pending.origin, destination: destination, snapshot: pending.snapshot, tall: destination.height < measured.height)
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
            MessageContent(item: flight.item).frame(width: max(1, flight.destination.width - 32), alignment: .leading)
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
    @State private var userScrolling = false
    @State private var openCapability: String?
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
                if let permission = session.permissions.first {
                    PermissionView(session: session, request: permission).id(permission.id).frame(maxHeight: 240).padding(.horizontal, 24).padding(.bottom, 10)
                }
                if !settings.loginMessage.isEmpty { loginStatus }
                composer
                    .zIndex(1)
            }
        }
        .fontDesign(.monospaced)
        .foregroundStyle(.black.opacity(0.92))
        .background(Color.white)
        .coordinateSpace(name: "conversation")
        .environmentObject(sending)
        .onPreferenceChange(MessageFrames.self) { frames in
            sending.update(frames: frames, rows: session.rows, reduceMotion: reduceMotion)
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
                    .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.24), value: session.preview != nil)
            }
        }
        .disabled(session.frontendReplacing)
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
                    .background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.1)))
                    .contentShape(Rectangle()).padding(10)
            }.buttonStyle(.plain).keyboardShortcut(",", modifiers: .command)
            Divider().overlay(.black.opacity(0.04))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    capability("Hooks")
                    capability("Skills")
                    capability("MCP")
                    capability("Instructions")
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
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
            } else { session.statusCommand(command) }
        } label: {
            HStack(spacing: 5) {
                if loading { ProgressView().controlSize(.mini) }
                Text(value).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(color).lineLimit(1).fixedSize()
            }
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(command).accessibilityLabel("\(title): \(value). \(command)")
    }

    private func capability(_ title: String) -> some View {
        Button { openCapability = title } label: {
                HStack(spacing: 7) {
                    Text(title == "Instructions" ? "MD Files" : title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2)
                    Spacer()
                    Text("\(session.capabilityItems(title).count)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                }.foregroundStyle(.black.opacity(0.75)).padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.1)))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("Browse " + title.lowercased())
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
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.black.opacity(0.6))
            }
            ScrollView { Text(settings.loginMessage).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
        }.padding(14).background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 32).padding(.bottom, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                        if session.rows.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: "sparkle").font(.system(size: 40, weight: .light)).foregroundStyle(accent)
                                Text("A clear space to build.").font(.system(size: 28, weight: .semibold))
                                Text("Your code, your agents, one conversation.").font(.system(size: 14)).foregroundStyle(.black.opacity(0.6))
                            }.frame(maxWidth: .infinity).padding(.vertical, 100)
                        }
                        let sections = conversationSections(session.rows)
                        ForEach(sections) { section in
                            Section {
                                let parts = sectionParts(section.rows)
                                if !parts.trail.isEmpty { WorkBlock(rows: parts.trail, details: session.details).id("work-\(section.id)") }
                                if let last = parts.last { ConversationRow(row: last, session: session).equatable().id(last.id) }
                                ForEach(parts.notices) { row in ConversationRow(row: row, session: session).equatable().id(row.id) }
                            } header: {
                                if let question = section.question {
                                    ConversationRow(row: question, session: session).equatable()
                                        .background(Color.white)
                                        .padding(.bottom, section.rows.isEmpty && section.id != sections.last?.id ? -16 : 0)
                                        .id(question.id)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 28)
                }
                .onScrollPhaseChange { _, phase, context in
                    userScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
                    if userScrolling { session.follow.userScroll(distance: context.geometry.contentSize.height - context.geometry.contentOffset.y - context.geometry.containerSize.height) }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height)
                } action: { _, distance in if userScrolling { session.follow.userScroll(distance: distance) } }
                .onChange(of: session.revision) { _, _ in
                    guard session.follow.attached else { return }
                    let animate = !reduceMotion && (sending.hasPending || sending.flight != nil)
                    DispatchQueue.main.async {
                        if animate { withAnimation(.spring(duration: 0.42, bounce: 0.08)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                        else { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                if !session.follow.attached {
                    Button { session.follow.attached = true; proxy.scrollTo("bottom", anchor: .bottom) } label: {
                        Label("Back to latest", systemImage: "arrow.down").font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 9).background(.ultraThinMaterial, in: Capsule())
                    }.buttonStyle(.plain).padding(.bottom, 12)
                }
            }
        }
        .background(GeometryReader { geometry in Color.clear.preference(key: MessageFrames.self, value: ["transcript": geometry.frame(in: .named("conversation"))]) })
    }

    private var composer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ActivityDot(busy: session.busy).frame(width: 12, height: 10).accessibilityLabel(session.busy ? "Thinking" : "Ready")
                Text(session.busy ? "Thinking" : session.needsAttention ? session.status : "Ready").font(.system(size: 11)).foregroundStyle(session.busy ? accent : readyColor)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 5).opacity(sending.flight == nil ? 1 : 0)
            if !session.permissions.isEmpty || (!session.ready && !session.status.isEmpty) {
                Text(session.permissions.isEmpty ? session.status : "Your answer is needed").font(.system(size: 11)).lineLimit(1).foregroundStyle(.black.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 12) {
                Composer(session: session, hidingPlaceholder: sending.hasPending || sending.flight != nil) { text, images, snapshot in
                    sending.prepare(text: text, images: images, rows: session.rows, snapshot: snapshot)
                }.frame(height: session.editorHeight)
                    .background(GeometryReader { geometry in Color.clear.preference(key: MessageFrames.self, value: ["editor": geometry.frame(in: .named("conversation"))]) })
                if session.busy { RoundButton(icon: "stop.fill", label: "Stop generation (Escape)") { Task { await session.stop(source: "Stop button") } } }
                Button { session.submitDraft() } label: { Image(systemName: "arrow.up").font(.system(size: 20, weight: .medium)).frame(width: 34, height: 34).foregroundStyle(.white).background(userGradient, in: Circle()) }.buttonStyle(.plain).disabled(!session.draft.string.hasPrefix("/") && (!session.ready || session.changing)).help(session.busy ? "Send guidance" : "Send message (Return)")
            }.padding(14).background(.black.opacity(0.065), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.black.opacity(0.09), lineWidth: 1))
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
            }.fixedSize()
        }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var identityStatus: some View {
        HStack(spacing: 8) {
            setting("Directory", value: session.directoryLabel, command: "/dir ", color: Color(red: 0.28, green: 0.36, blue: 0.7))
            separator
            setting("Model", value: session.modelStatusLabel, command: session.modelCommand, color: Color(red: 0.68, green: 0.18, blue: 0.45))
            separator
            setting("Mode", value: session.activeMode == "bypass" ? "bypass" : "ask", command: "/mode ", color: Color(red: 0.75, green: 0.15, blue: 0.15))
        }
    }
    private var usageStatus: some View {
        HStack(spacing: 8) {
            setting("Tokens", value: session.contextLabel, command: "/tokens", color: Color(red: 0.13, green: 0.39, blue: 0.67))
            separator
            quotaStatus
        }
    }
    private var quotaStatus: some View {
        setting("Usage", value: session.usage.isEmpty ? (session.usageLoading ? "Loading…" : "Not reported") : session.usage, command: "/usage", color: session.usagePercent.map { Color(hue: (1 - min(100, max(0, $0)) / 100) / 3, saturation: 0.85, brightness: 0.45) } ?? .black.opacity(0.6), loading: session.usageLoading)
    }
    private var repositoryStatus: some View {
        setting("Repo", value: session.repositoryLabel, command: "/repo", color: session.repositoryStatus == "uncommitted" ? Color(red: 0.68, green: 0.18, blue: 0.38) : session.repositoryStatus == "unpushed" ? Color(red: 0.55, green: 0.36, blue: 0.08) : session.repositoryStatus == "up to date" ? readyColor : .black.opacity(0.6))
    }
    private var separator: some View { Text("|").font(.system(size: 13, design: .monospaced)).foregroundStyle(.black.opacity(0.25)) }
}

struct ActivityDot: NSViewRepresentable {
    let busy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ActivityDotView { ActivityDotView() }
    func updateNSView(_ view: ActivityDotView, context: Context) { view.update(busy: busy, reduceMotion: reduceMotion) }
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

    func update(busy: Bool, reduceMotion: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.backgroundColor = NSColor(busy ? accent : readyColor).cgColor
        CATransaction.commit()
        self.busy = busy; self.reduceMotion = reduceMotion
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

struct SettingsPopup: View {
    @ObservedObject var session: Session
    @ObservedObject private var settings = Settings.shared
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
        }.buttonStyle(.plain)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 16, weight: .semibold))
                Spacer()
                RoundButton(icon: "xmark", label: "Close settings") { session.showingSettings = false }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    setting("Provider", session.providerLabel, "/model ")
                    setting("Model", session.modelLabel, session.modelCommand)
                    if let effort = session.effectiveEffort { setting("Effort", effort, session.modelCommand + session.model + " ") }
                    setting("Permissions", session.mode, "/mode ")
                    setting("Working directory", session.cwd, "/dir ")
                    Divider().padding(.vertical, 8)
                    Text("Accounts").font(.system(size: 13, weight: .semibold))
                    ForEach(settings.value.accounts) { account in
                        setting(account.name, account.provider.capitalized + (account.enabled ? " · enabled" : " · disabled"), "/account ")
                        if let home = account.home { setting("Profile", home, "/profile " + account.provider + " ") }
                        if let reset = settings.value.limits[account.id], reset > Date().timeIntervalSince1970 {
                            setting("Available after", Date(timeIntervalSince1970: reset).formatted(), "/usage")
                        }
                    }
                    setting("Add account", "Claude or Codex", "/login ")
                    setting("Import profile", "Existing account folder", "/profile ")
                    Divider().padding(.vertical, 8)
                    Text("Qwen").font(.system(size: 13, weight: .semibold))
                    setting("Endpoint", settings.value.qwenURL, "/qwen url ")
                    setting("Proxy", settings.value.qwenProxy.isEmpty ? "None" : settings.value.qwenProxy, "/qwen proxy ")
                    setting("Text model", settings.value.qwenModel, "/qwen model ")
                    setting("Vision model", settings.value.qwenVisionModel, "/qwen vision ")
                }.padding(20)
            }
        }.frame(width: 480, height: 520).background(Color(white: 0.98)).preferredColorScheme(.light)
            .onExitCommand { session.showingSettings = false }
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
                            }.buttonStyle(.plain).id(command.id)
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
    static func == (left: Self, right: Self) -> Bool { left.row.id == right.row.id }
    var body: some View {
        if let item = row.items.first {
            if row.kind == "user" { UserBubble(item: item, session: session) }
            else if row.kind == "notice" { Label(item.text, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.black.opacity(0.6)).textSelection(.enabled) }
            else { AssistantBubble(item: item) }
        }
    }
}

struct WorkBlock: View {
    let rows: [Row]
    let details: Bool
    @State private var hovering = false
    @State private var pinned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func animate(_ change: () -> Void) { withAnimation(reduceMotion ? nil : .smooth(duration: 0.28), change) }
    var body: some View {
        let actions = rows.filter { $0.kind == "activity" }.flatMap(\.items).count, notes = rows.filter { $0.kind == "assistant" }.count
        let open = hovering || pinned || details
        VStack(alignment: .leading, spacing: 12) {
            Button { animate { if pinned { pinned = false; hovering = false } else { pinned = true } } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                    Text([actions == 0 ? nil : "\(actions) \(actions == 1 ? "action" : "actions")", notes == 0 ? nil : "\(notes) \(notes == 1 ? "note" : "notes")"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12, weight: .medium))
                }.foregroundStyle(.black.opacity(0.6)).contentShape(Rectangle())
            }.buttonStyle(.plain).help(pinned ? "Collapse" : "Keep open (hovering the left edge opens it)")
            if open {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        if row.kind == "activity" { ForEach(row.items) { ActionView(item: $0) } }
                        else if let item = row.items.first { WorkNote(item: item) }
                    }
                }.transition(.opacity)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): if point.x < 72, !hovering { animate { hovering = true } }
                case .ended: if hovering { animate { hovering = false } }
                }
            }
    }
}

struct WorkNote: View {
    @ObservedObject var item: Item
    var body: some View { MarkdownBody(text: item.text).opacity(0.6) }
}

struct ActionView: View {
    @ObservedObject var item: Item
    @State private var hovering = false
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: item.failed ? "exclamationmark.circle" : "chevron.right").rotationEffect(.degrees(open && !item.failed ? 90 : 0)); Text(item.title).lineLimit(3) }.font(.system(size: 12, design: .monospaced)).foregroundStyle(item.failed ? Color(red: 0.65, green: 0.32, blue: 0.04) : .black.opacity(0.65))
            if open, !item.output.isEmpty { Text(item.output).font(.system(size: 11, design: .monospaced)).foregroundStyle(.black.opacity(0.6)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).transition(.opacity) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)).clipShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
            .task(id: hovering) {
                // A short dwell keeps actions the pointer only crosses from opening and shifting the list.
                if hovering { try? await Task.sleep(for: .milliseconds(150)); if Task.isCancelled { return } }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { open = hovering }
            }
    }
}

struct UserBubble: View {
    @ObservedObject var item: Item
    let session: Session
    @EnvironmentObject private var sending: SendAnimation
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            MessageContent(item: item) { session.preview = $0 }
                .padding(16).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 17))
                .background(GeometryReader { geometry in Color.clear.preference(key: MessageFrames.self, value: [item.id: geometry.frame(in: .named("conversation"))]) })
                .opacity(sending.hides(item) ? 0 : 1)
        }
    }
}

struct MessageContent: View {
    @ObservedObject var item: Item
    var preview: (String) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((item.data["content"] as? [JSON] ?? []).enumerated()), id: \.offset) { n, piece in
                if piece["type"] as? String == "text", let text = piece["text"] as? String { Text(text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                else if let path = piece["path"] as? String ?? piece["url"] as? String { PictureView(path: path) { preview(path) } }
                else { Label("Image \(n + 1)", systemImage: "photo").font(.system(size: 12)) }
            }
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
        }.buttonStyle(.plain).task(id: path) { image = await Task.detached { thumbnail(path) }.value }
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
}

func markdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = [], lines: [String] = [], code = false, language = "", fence = ""
    func append() { if !lines.isEmpty { blocks.append(MarkdownBlock(id: blocks.count, text: lines.joined(separator: "\n"), code: code, language: language)); lines.removeAll() } }
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if (!code && (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"))) || (code && trimmed.hasPrefix(fence)) {
            append()
            if code { code = false; fence = ""; language = "" }
            else { code = true; fence = String(trimmed.prefix(3)); language = String(trimmed.dropFirst(3)) }
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
                    VStack(alignment: .leading, spacing: 0) {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.text, forType: .string) } label: {
                            HStack {
                                Text(block.language.isEmpty ? "Code" : block.language).font(.system(size: 10)).foregroundStyle(.black.opacity(0.6)); Spacer()
                                Image(systemName: "doc.on.doc")
                            }.padding(10).background(.black.opacity(0.025)).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Copy code").accessibilityLabel("Copy code")
                        ScrollView(.horizontal) { Text(block.text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).padding(14) }
                    }.background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.06)))
                } else {
                    ProseView(text: block.text)
                }
            }
        }
    }
}

struct PermissionView: View {
    @ObservedObject var session: Session
    let request: Permission
    @State private var answers: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    var questions: [JSON] { request.params["questions"] as? [JSON] ?? [] }
    var input: Bool { request.method == "item/tool/requestUserInput" }
    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Label(input ? "Your answer is needed" : "Permission requested", systemImage: input ? "questionmark.bubble" : "hand.raised").font(.system(size: 14, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if input {
                            ForEach(Array(questions.enumerated()), id: \.offset) { n, question in
                                let id = question["id"] as? String ?? "\(n)"
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(question["question"] as? String ?? "Question").font(.system(size: 14, weight: .medium))
                                    ForEach(Array((question["options"] as? [JSON] ?? []).enumerated()), id: \.offset) { _, option in
                                        let label = option["label"] as? String ?? "Option"
                                        let multiple = question["multiSelect"] as? Bool == true
                                        let selected = multiple ? selections[id, default: []].contains(label) : answers[id] == label
                                        Button {
                                            if multiple {
                                                if selections[id, default: []].contains(label) { selections[id]?.remove(label) }
                                                else { selections[id, default: []].insert(label) }
                                            } else { answers[id] = label }
                                        } label: {
                                            HStack(alignment: .top) {
                                                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(accent)
                                                VStack(alignment: .leading, spacing: 3) { Text(label); Text(option["description"] as? String ?? "").foregroundStyle(.secondary) }
                                            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                        }.buttonStyle(.plain)
                                    }
                                    if question["isSecret"] as? Bool == true { SecureField("Your answer", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })) }
                                    else { TextField("Your answer", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })) }
                                }
                            }
                        } else {
                            Text(request.params["reason"] as? String ?? "Review this action before allowing it.").font(.system(size: 13)).foregroundStyle(.secondary)
                            Text(request.params["command"] as? String ?? (request.params["changes"] as? [JSON] ?? []).map { ($0["path"] as? String ?? "") + "\n" + ($0["diff"] as? String ?? "") }.joined(separator: "\n")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Cancel") { session.answer(request, result: input ? ["answers": [:]] : ["decision": "cancel"]) }
                    Spacer()
                    if input {
                        Button("Send answer") {
                            session.answer(request, result: ["answers": questionAnswers(questions, text: answers, selections: selections).mapValues { ["answers": $0] }])
                        }.buttonStyle(.borderedProminent).tint(accent).disabled(questionAnswers(questions, text: answers, selections: selections).count != questions.count)
                    } else {
                        Button("Decline") { session.answer(request, result: ["decision": "decline"]) }
                        Button("Allow") { session.answer(request, result: ["decision": "accept"]) }.buttonStyle(.borderedProminent).tint(accent)
                            .disabled(request.method == "item/fileChange/requestApproval" && (request.params["changes"] as? [JSON] ?? []).isEmpty)
                    }
                }
            }.padding(16).frame(maxWidth: 750).background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.1)))
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
            if !plain.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(plain.joined(separator: "\n")) }
            plain = []
        }
        for line in paragraph.components(separatedBy: "\n") {
            if line.hasPrefix("⟶ ") || line.hasPrefix("✓ Done:") { close(); parts.append(line) } else { plain.append(line) }
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
        else { Text(value).font(.system(size: 13, weight: weight, design: .monospaced)).lineSpacing(lineSpacing).textSelection(.enabled) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                let lines = paragraph.components(separatedBy: "\n")
                if lines.count >= 2, lines[1].contains("|"), lines[1].replacingOccurrences(of: #"[\s:|\-]"#, with: "", options: .regularExpression).isEmpty {
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
                    prose(paragraph.replacingOccurrences(of: "⟶ ", with: "").trimmingCharacters(in: .whitespacesAndNewlines), weight: .medium, lineSpacing: 5).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading).background(paragraph.hasPrefix("✓") ? Color(red: 1, green: 225 / 255, blue: 195 / 255) : paragraph.contains("Next:") ? Color(red: 214 / 255, green: 230 / 255, blue: 1) : Color(red: 214 / 255, green: 245 / 255, blue: 214 / 255), in: RoundedRectangle(cornerRadius: 10))
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
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
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
            var font = NSFont.monospacedSystemFont(ofSize: 13, weight: intent.contains(.stronglyEmphasized) ? .bold : base)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            string.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        if view.textStorage?.isEqual(to: string) != true { view.textStorage?.setAttributedString(string) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let storage = NSTextStorage(attributedString: view.textStorage ?? NSAttributedString()), manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        return CGSize(width: width ?? ceil(used.width), height: ceil(used.height))
    }
}

func tableCells(_ line: String) -> [String] {
    var text = line.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("|") { text.removeFirst() }
    if text.hasSuffix("|") { text.removeLast() }
    return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}
