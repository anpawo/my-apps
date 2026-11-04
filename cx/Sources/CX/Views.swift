import SwiftUI
import AppKit

let accent = Color(red: 0.65, green: 0.44, blue: 1)
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

struct RoundButton: View {
    let icon: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 17.5, weight: .medium)).frame(width: 34, height: 34).background(.white.opacity(0.07), in: Circle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct CXView: View {
    @ObservedObject var session: Session
    @ObservedObject private var settings = Settings.shared
    @State private var userScrolling = false
    @State private var openCapability: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 0) {
            sessionPanel.frame(width: 205)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                transcript
                    .overlay(alignment: .bottom) {
                        if session.commandQuery != nil {
                            GeometryReader { geometry in
                                CommandPalette(session: session, maxListHeight: max(40, min(250, geometry.size.height - 90)))
                                    .frame(maxWidth: 850).padding(.horizontal, 24).padding(.bottom, 8)
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
        .foregroundStyle(.white.opacity(0.92))
        .background(Color(red: 0.035, green: 0.035, blue: 0.045))
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                await session.refreshUsage()
                await session.refreshRepository()
            }
        }
        .sheet(isPresented: $session.showingSettings) {
            SettingsPopup(session: session)
        }
        .overlay {
            if let path = session.preview {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.94)
                    if let image = thumbnail(path, size: 1600) { Image(nsImage: image).resizable().scaledToFit().padding(50) }
                    else { Text("This image is no longer available.").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    RoundButton(icon: "xmark", label: "Close image") { session.preview = nil }.padding(20)
                }.onTapGesture { session.preview = nil }
            }
        }
        .onExitCommand {
            if session.preview != nil { session.preview = nil }
            else if session.commandQuery != nil { session.dismissCommands() }
            else if session.busy { Task { await session.stop() } }
        }
    }

    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { session.showingSettings = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape").foregroundStyle(accent.opacity(0.7)).frame(width: 18)
                    Text("SETTINGS").tracking(1.2)
                    Spacer()
                    Image(systemName: "chevron.right")
                }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    .padding(20).frame(maxWidth: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).keyboardShortcut(",", modifiers: .command)
            Divider().overlay(.white.opacity(0.04))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    capability("Hooks", icon: "arrow.turn.down.right")
                    capability("Skills", icon: "sparkle")
                    capability("MCP", icon: "link")
                    capability("Instructions", icon: "doc.text")
                }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Color.white.opacity(0.025))
    }

    private func setting(_ title: String, value: String, command: String, color: Color) -> some View {
        Button {
            if command == "/dir " {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.directoryURL = URL(fileURLWithPath: session.cwd, isDirectory: true)
                panel.begin { result in
                    if result == .OK, let url = panel.url { session.statusCommand("/dir " + url.path) }
                }
            } else { session.statusCommand(command) }
        } label: {
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(color).lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(command).accessibilityLabel("\(title): \(value). \(command)")
    }

    private func capability(_ title: String, icon: String) -> some View {
        Button { openCapability = title } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon).font(.system(size: 13.75)).foregroundStyle(accent.opacity(0.7)).frame(width: 18)
                    Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.2)
                    Spacer()
                    Text("\(session.capabilityItems(title).count)").font(.system(size: 10, design: .monospaced))
                    Image(systemName: "chevron.right").font(.system(size: 10))
                }.foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 20).padding(.vertical, 14)
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
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
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            ScrollView { Text(settings.loginMessage).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
        }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 32).padding(.bottom, 8)
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
                                Text("Your code, your agents, one conversation.").font(.system(size: 14)).foregroundStyle(.white.opacity(0.4))
                            }.frame(maxWidth: .infinity).padding(.vertical, 100)
                        }
                        ForEach(conversationSections(session.rows)) { section in
                            Section {
                                ForEach(section.rows) { row in ConversationRow(row: row, session: session, details: session.details).equatable().id(row.id) }
                            } header: {
                                if let question = section.question {
                                    ConversationRow(row: question, session: session, details: session.details).equatable()
                                        .background(Color(red: 0.035, green: 0.035, blue: 0.045))
                                        .id(question.id)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: 850).frame(maxWidth: .infinity).padding(.horizontal, 32).padding(.vertical, 28)
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
                    DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                if !session.follow.attached {
                    Button { session.follow.attached = true; proxy.scrollTo("bottom", anchor: .bottom) } label: {
                        Label("Back to latest", systemImage: "arrow.down").font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 9).background(.ultraThinMaterial, in: Capsule())
                    }.buttonStyle(.plain).padding(.bottom, 12)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ActivityDot(busy: session.busy, action: session.performingAction)
                Text(session.busy ? "Thinking" : "Reading").font(.system(size: 11)).foregroundStyle(session.performingAction ? accent : .green)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 5)
            if !session.permissions.isEmpty || (!session.ready && !session.status.isEmpty) {
                Text(session.permissions.isEmpty ? session.status : "Your answer is needed").font(.system(size: 11)).lineLimit(1).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 12) {
                Composer(session: session).frame(height: session.editorHeight)
                if session.busy { RoundButton(icon: "stop.fill", label: "Stop generation (Escape)") { Task { await session.stop() } } }
                Button { session.submitDraft() } label: { Image(systemName: "arrow.up").font(.system(size: 20, weight: .medium)).frame(width: 34, height: 34).background(userGradient, in: Circle()) }.buttonStyle(.plain).disabled(!session.draft.string.hasPrefix("/") && (!session.ready || session.changing)).help(session.busy ? "Send guidance" : "Send message (Return)")
            }.padding(14).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.09), lineWidth: 1))
            statusBar.padding(.leading, 10)
        }.frame(maxWidth: 850).frame(maxWidth: .infinity).padding(.horizontal, 32).padding(.bottom, 20).padding(.top, 8)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) { identityStatus; ScrollView(.horizontal) { identityStatus } }
            ViewThatFits(in: .horizontal) { usageStatus; ScrollView(.horizontal) { usageStatus } }
            ViewThatFits(in: .horizontal) { quotaStatus; ScrollView(.horizontal) { quotaStatus } }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var identityStatus: some View {
        HStack(spacing: 8) {
            setting("Directory", value: session.directoryLabel, command: "/dir ", color: Color(red: 0.55, green: 0.64, blue: 1))
            separator
            setting("Model", value: session.modelStatusLabel, command: session.modelCommand, color: Color(red: 1, green: 0.47, blue: 0.78))
            separator
            setting("Mode", value: session.activeMode == "bypass" ? "bypass" : "ask", command: "/mode ", color: .red)
        }
    }
    private var usageStatus: some View {
        HStack(spacing: 8) {
            setting("Tokens", value: session.contextLabel, command: "/tokens", color: Color(red: 0.36, green: 0.66, blue: 1))
            separator
            repositoryStatus
        }
    }
    private var quotaStatus: some View {
        setting("Usage", value: session.usage.isEmpty ? "Not reported" : session.usage, command: "/usage", color: session.usagePercent.map { Color(hue: (1 - min(100, max(0, $0)) / 100) / 3, saturation: 0.8, brightness: 0.9) } ?? .white.opacity(0.45))
    }
    private var repositoryStatus: some View {
        setting("Repo", value: session.repositoryLabel, command: "/repo", color: session.repositoryStatus == "uncommitted" ? Color(red: 215/255, green: 95/255, blue: 135/255) : session.repositoryStatus == "unpushed" ? Color(red: 215/255, green: 175/255, blue: 95/255) : session.repositoryStatus == "up to date" ? Color(red: 95/255, green: 175/255, blue: 95/255) : .white.opacity(0.45))
    }
    private var separator: some View { Text("|").font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.25)) }
}

struct ActivityDot: View {
    let busy: Bool
    let action: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !busy || action || reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 5
            Circle().fill(action ? accent : .green)
                .frame(width: 6, height: 6)
                .offset(x: busy && !action && !reduceMotion ? CGFloat(sin(phase)) * 3 : 0)
        }.frame(width: 12, height: 10)
            .accessibilityLabel(action ? "Performing action" : busy ? "Thinking" : "Idle")
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
                Text(title).foregroundStyle(.white.opacity(0.55))
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
        }.frame(width: 480, height: 520).background(Color(red: 0.06, green: 0.055, blue: 0.075)).preferredColorScheme(.dark)
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
                .padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(matches) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.system(size: 12, weight: .medium))
                            Text(item.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    if matches.isEmpty {
                        Text(query.isEmpty ? "None reported" : "No matches").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(16)
            }
        }.frame(width: 380, height: 440).background(Color(red: 0.06, green: 0.055, blue: 0.075)).preferredColorScheme(.dark)
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
                Text("\(session.commandOptions.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
                Spacer()
                Text("esc").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
            }.padding(.horizontal, 14).padding(.vertical, 12)
            Divider().overlay(.white.opacity(0.03))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(session.commandOptions.enumerated()), id: \.element.id) { index, command in
                            Button { session.chooseCommand(command) } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(command.name).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                                        Text(command.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text(command.source).font(.system(size: 9, weight: .medium)).foregroundStyle(accent.opacity(0.9)).padding(.horizontal, 7).padding(.vertical, 4).background(accent.opacity(0.1), in: Capsule())
                                }.padding(.horizontal, 10).padding(.vertical, 9).background(index == session.commandSelection ? accent.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(command.id)
                        }
                        if session.commandOptions.isEmpty {
                            Text("No matching commands").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity).padding(.vertical, 25)
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
            Divider().overlay(.white.opacity(0.03))
            HStack {
                Text("↑ ↓ navigate"); Text("Return select"); Text("Tab complete")
                Spacer(minLength: 0)
            }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.3)).padding(.horizontal, 14).padding(.vertical, 9)
        }.background(Color(red: 0.075, green: 0.068, blue: 0.095), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.22)))
            .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
            .accessibilityLabel("Command suggestions")
    }
}

struct ConversationRow: View, Equatable {
    @ObservedObject var row: Row
    let session: Session
    let details: Bool
    static func == (left: Self, right: Self) -> Bool { left.row.id == right.row.id && left.details == right.details }
    @State private var expanded = false
    var body: some View {
        Group {
            if row.kind == "activity" {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) { ForEach(row.items) { ActionView(item: $0) } }.padding(.top, 12)
                } label: { ActivityLabel(items: row.items) }
                    .tint(.white.opacity(0.35)).padding(14).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: details) { _, value in expanded = value }.onAppear { expanded = details }
            } else if let item = row.items.first {
                if row.kind == "user" { UserBubble(item: item, session: session) }
                else if row.kind == "notice" { Label(item.text, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).textSelection(.enabled) }
                else { AssistantBubble(item: item) }
            }
        }
    }
}

struct ActivityLabel: View {
    let items: [Item]
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 11))
            Text("\(items.count) \(items.count == 1 ? "action" : "actions")").font(.system(size: 12, weight: .medium))
        }.foregroundStyle(.white.opacity(0.4))
    }
}

struct ActionView: View {
    @ObservedObject var item: Item
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: item.failed ? "exclamationmark.circle" : "chevron.right"); Text(item.title).lineLimit(3) }.font(.system(size: 12, design: .monospaced)).foregroundStyle(item.failed ? .orange.opacity(0.8) : .white.opacity(0.65))
            if !item.output.isEmpty { Text(item.output).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct UserBubble: View {
    @ObservedObject var item: Item
    let session: Session
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array((item.data["content"] as? [JSON] ?? []).enumerated()), id: \.offset) { n, piece in
                    if piece["type"] as? String == "text", let text = piece["text"] as? String { Text(text).font(.system(size: 15)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    else if let path = piece["path"] as? String ?? piece["url"] as? String { PictureView(path: path) { session.preview = path } }
                    else { Label("Image \(n + 1)", systemImage: "photo").font(.system(size: 12)) }
                }
            }.padding(16).background(userGradient, in: RoundedRectangle(cornerRadius: 17))
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
                else { Image(systemName: "photo").frame(width: 64, height: 52).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7)) }
                VStack(alignment: .leading, spacing: 4) { Text("Image").font(.system(size: 12, weight: .semibold)); Text("Click to preview").font(.system(size: 10)).opacity(0.6) }
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).opacity(0.5)
            }.padding(8).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).task(id: path) { image = await Task.detached { thumbnail(path) }.value }
    }
}

struct AssistantBubble: View {
    @ObservedObject var item: Item
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) { Image(systemName: "sparkle").foregroundStyle(accent); Text(item.data["provider"] as? String ?? "Codex").foregroundStyle(.white.opacity(0.4)) }.font(.system(size: 11, weight: .medium))
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
                                Text(block.language.isEmpty ? "Code" : block.language).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)); Spacer()
                                Image(systemName: "doc.on.doc")
                            }.padding(10).background(.white.opacity(0.025)).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Copy code").accessibilityLabel("Copy code")
                        ScrollView(.horizontal) { Text(block.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(14) }
                    }.background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.06)))
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
                                            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
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
            }.padding(16).frame(maxWidth: 750).background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.1)))
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

struct ProseView: View {
    let text: String
    private var paragraphs: [String] { text.components(separatedBy: "\n\n").filter { !$0.isEmpty } }
    private func rich(_ text: String) -> AttributedString { (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text) }
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
                                            Text(rich(cell)).font(.system(size: 13, weight: n == 0 ? .semibold : .regular)).frame(width: 280, alignment: .leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }.padding(14)
                    }.background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                } else if paragraph.hasPrefix("#") {
                    let title = paragraph.drop(while: { $0 == "#" || $0 == " " })
                    Text(rich(String(title))).font(.system(size: paragraph.hasPrefix("###") ? 16 : 20, weight: .semibold)).textSelection(.enabled)
                } else if paragraph.hasPrefix("⟶ ") || paragraph.hasPrefix("✓ Done:") {
                    Text(rich(paragraph.replacingOccurrences(of: "⟶ ", with: ""))).font(.system(size: 14, weight: .medium)).lineSpacing(5).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background((paragraph.hasPrefix("✓") ? Color.orange : paragraph.contains("Next:") ? Color.blue : Color.green).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(rich(paragraph)).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled).tint(accent).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

func tableCells(_ line: String) -> [String] {
    var text = line.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("|") { text.removeFirst() }
    if text.hasSuffix("|") { text.removeLast() }
    return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}
