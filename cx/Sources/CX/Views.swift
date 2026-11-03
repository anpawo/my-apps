import SwiftUI
import AppKit

let accent = Color(red: 0.65, green: 0.44, blue: 1)
let userGradient = LinearGradient(colors: [Color(red: 0.93, green: 0.23, blue: 0.51), Color(red: 0.55, green: 0.3, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)

struct RoundButton: View {
    let icon: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34).background(.white.opacity(0.07), in: Circle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct CXView: View {
    @ObservedObject var session: Session
    @State private var sidebar = true
    @State private var settings = false
    @State private var userScrolling = false
    var body: some View {
        HStack(spacing: 0) {
            if sidebar { history.frame(width: 230); Rectangle().fill(.white.opacity(0.07)).frame(width: 1) }
            VStack(spacing: 0) {
                header
                Divider().overlay(.white.opacity(0.05))
                transcript
                composer
            }
        }
        .foregroundStyle(.white.opacity(0.92))
        .background(Color(red: 0.035, green: 0.035, blue: 0.045))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $settings) { SettingsView(session: session).frame(width: 620, height: 640) }
        .overlay { if let permission = session.permissions.first { PermissionView(session: session, request: permission).id(permission.id) } }
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
            else if session.busy { Task { await session.stop() } }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Text("vcx").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(userGradient)
                Text("VIBE CODE X").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.4))
                Spacer()
            }.padding(.top, 12)
            Button { Task { await session.switchThread(nil) } } label: {
                Label("New conversation", systemImage: "square.and.pencil").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
            }.buttonStyle(.plain).disabled(session.busy || session.changing).keyboardShortcut("n", modifiers: .command)
            HStack {
                Text("CONVERSATIONS").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.35))
                Spacer()
                Button { Task { await session.refreshCatalog() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh conversations")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(session.recent) { thread in
                        Button { Task { await session.switchThread(thread.id) } } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "bubble.left").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                                Text(thread.title.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(10).background(.white.opacity(thread.id == session.currentConversationID || thread.id == session.threadID ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(session.disabled)
                    }
                    if session.recent.isEmpty { Text("Your conversations appear here.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.3)).padding(.top, 4) }
                }
            }
            Spacer(minLength: 0)
            Button { settings = true } label: { Label("Settings", systemImage: "slider.horizontal.3").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)) }.buttonStyle(.plain).keyboardShortcut(",", modifiers: .command)
            HStack(spacing: 6) { Circle().fill(accent).frame(width: 5, height: 5); Text("Claude · Codex · Qwen").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3)) }
        }.padding(18).background(Color.white.opacity(0.025))
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundButton(icon: "sidebar.left", label: "Toggle sidebar") { sidebar.toggle() }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.folder).font(.system(size: 16, weight: .semibold))
                Text(session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.35)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            if !session.ready { Button("Reconnect") { Task { await session.reconnect() } }.font(.system(size: 12)) }
            Menu {
                ForEach(session.models, id: \.self) { model in Button(model) { Task { await session.changeModel(model) } } }
            } label: { HStack(spacing: 6) { Text(session.model); Image(systemName: "chevron.down").font(.system(size: 9)) }.font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6)) }
                .menuStyle(.borderlessButton).fixedSize().disabled(session.disabled)
            Button { session.details.toggle() } label: { Image(systemName: session.details ? "list.bullet.rectangle.fill" : "list.bullet.rectangle").foregroundStyle(session.details ? accent : .white.opacity(0.45)) }.buttonStyle(.plain).help("Show or collapse actions")
            RoundButton(icon: "gearshape", label: "Settings") { settings = true }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if session.rows.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: "sparkle").font(.system(size: 32, weight: .light)).foregroundStyle(accent)
                                Text("A clear space to build.").font(.system(size: 28, weight: .semibold))
                                Text("Your code, your agents, one conversation.").font(.system(size: 14)).foregroundStyle(.white.opacity(0.4))
                            }.frame(maxWidth: .infinity).padding(.vertical, 100)
                        }
                        ForEach(session.rows) { row in ConversationRow(row: row, session: session, details: session.details).equatable().id(row.id) }
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
            HStack(spacing: 7) {
                Circle().fill(session.busy ? accent : session.ready ? .green.opacity(0.7) : .orange).frame(width: 5, height: 5)
                Text(session.permissions.isEmpty ? session.status : "Your answer is needed").font(.system(size: 11)).lineLimit(1).foregroundStyle(.white.opacity(0.45))
                Spacer()
                if !session.context.isEmpty { Text(session.context).font(.system(size: 11)).foregroundStyle(.white.opacity(0.3)) }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button { attach() } label: { Image(systemName: "plus").font(.system(size: 18)).foregroundStyle(.white.opacity(0.5)).frame(width: 24, height: 26) }.buttonStyle(.plain).help("Attach images")
                Composer(session: session).frame(height: session.editorHeight)
                if session.busy { RoundButton(icon: "stop.fill", label: "Stop generation (Escape)") { Task { await session.stop() } } }
                Button { session.submitDraft() } label: { Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).frame(width: 34, height: 34).background(userGradient, in: Circle()) }.buttonStyle(.plain).disabled(!session.ready || session.changing).help(session.busy ? "Send guidance" : "Send message (Return)")
            }.padding(14).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.09), lineWidth: 1))
            HStack {
                Text("Return to send · Shift+Return for a new line").font(.system(size: 10)).foregroundStyle(.white.opacity(0.25))
                Spacer()
                Text(session.usage).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }
        }.frame(maxWidth: 850).frame(maxWidth: .infinity).padding(.horizontal, 32).padding(.bottom, 20).padding(.top, 8)
    }
    private func attach() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        panel.begin { result in
            guard result == .OK else { return }
            let draft = NSMutableAttributedString(attributedString: session.draft)
            for (n, url) in panel.urls.enumerated() { draft.append(NSAttributedString(attachment: ImageChip(path: url.path, number: n + 1))) }
            session.draft = draft; session.draftRevision += 1
        }
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
                        HStack {
                            Text(block.language.isEmpty ? "Code" : block.language).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)); Spacer()
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy code")
                        }.padding(10).background(.white.opacity(0.025))
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
    var questions: [JSON] { request.params["questions"] as? [JSON] ?? [] }
    var input: Bool { request.method == "item/tool/requestUserInput" }
    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
            VStack(alignment: .leading, spacing: 20) {
                Label(input ? "Your answer is needed" : "Permission requested", systemImage: input ? "questionmark.bubble" : "hand.raised").font(.system(size: 20, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if input {
                            ForEach(Array(questions.enumerated()), id: \.offset) { n, question in
                                let id = question["id"] as? String ?? "\(n)"
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(question["question"] as? String ?? "Question").font(.system(size: 14, weight: .medium))
                                    ForEach(Array((question["options"] as? [JSON] ?? []).enumerated()), id: \.offset) { _, option in
                                        let label = option["label"] as? String ?? "Option"
                                        Button { answers[id] = label } label: {
                                            HStack(alignment: .top) {
                                                Image(systemName: answers[id] == label ? "checkmark.circle.fill" : "circle").foregroundStyle(accent)
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
                    Button("Cancel") { session.answer(request, result: input ? ["answers": [:]] : ["decision": "cancel"]) }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if input {
                        Button("Send answer") {
                            session.answer(request, result: ["answers": answers.mapValues { ["answers": [$0]] }])
                        }.buttonStyle(.borderedProminent).tint(accent).disabled(questions.enumerated().contains { n, q in (answers[q["id"] as? String ?? "\(n)"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    } else {
                        Button("Decline") { session.answer(request, result: ["decision": "decline"]) }
                        Button("Allow") { session.answer(request, result: ["decision": "accept"]) }.buttonStyle(.borderedProminent).tint(accent)
                            .disabled(request.method == "item/fileChange/requestApproval" && (request.params["changes"] as? [JSON] ?? []).isEmpty)
                    }
                }
            }.padding(26).frame(width: 540).frame(maxHeight: 560).background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.1)))
        }
    }
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
                                            Text(rich(cell)).font(.system(size: 13, weight: n == 0 ? .semibold : .regular)).frame(maxWidth: 280, alignment: .leading).textSelection(.enabled)
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
