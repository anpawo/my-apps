import AppKit
import SwiftUI

@MainActor
enum BugCheck {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vcx-bugs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var failures: [String] = [], count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            print("\(condition ? "PASS" : "FAIL"): \(message)")
            if !condition { failures.append(message) }
        }
        func settle() async { try? await Task.sleep(nanoseconds: 700_000_000) }
        func editor(_ session: Session) -> (ComposerText, Composer.Coordinator) {
            let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 600, height: 150))
            storage.addLayoutManager(manager); manager.addTextContainer(container)
            let field = ComposerText(frame: NSRect(x: 0, y: 0, width: 600, height: 150), textContainer: container)
            field.heldStorage = storage; field.session = session
            let coordinator = Composer.Coordinator(session)
            field.delegate = coordinator
            return (field, coordinator)
        }
        let account = Settings.shared.value.accounts.first { $0.provider == "codex" }!
        let preferences = Settings.shared.value
        defer { Settings.shared.value = preferences; Settings.shared.save() }
        Settings.shared.value.provider = "codex"; Settings.shared.save()
        let backendSession = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("backend"))
        let connection = FixtureConnection(account); connection.hold = true
        backendSession.connectionFactory = { _, _ in connection }
        try await backendSession.activate(account, resume: nil, keepRows: false)
        let backend = SessionBackend(session: backendSession)
        let frontend = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("frontend"))
        backend.onChange = { frontend.applyRuntimePatch($0) }
        frontend.applyRuntimeSnapshot(backend.snapshot())
        defer { backend.close(); frontend.close() }
        let (field, coordinator) = editor(frontend)
        defer { withExtendedLifetime(coordinator) {} }
        @discardableResult func capture(_ name: String) throws -> Data {
            let background = field.drawsBackground
            field.drawsBackground = true; field.backgroundColor = .white
            defer { field.drawsBackground = background }
            guard let bitmap = field.bitmapImageRepForCachingDisplay(in: field.bounds) else { throw CXError(message: "Cannot render composer fixture.") }
            field.cacheDisplay(in: field.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CXError(message: "Cannot encode composer fixture.") }
            if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"] {
                let folder = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent(name + ".png"))
            }
            return png
        }
        check(!field.isAutomaticQuoteSubstitutionEnabled && !field.isAutomaticDashSubstitutionEnabled && !field.isAutomaticTextReplacementEnabled, "composer preserves literal punctuation")
        do {
            let (lone, _) = editor(frontend); lone.delegate = nil
            lone.putImage("/fixture.png")
            lone.layoutManager!.ensureLayout(for: lone.textContainer!)
            let first = lone.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: lone.textContainer!)
            lone.insertText("x", replacementRange: NSRange(location: 0, length: 0))
            lone.layoutManager!.ensureLayout(for: lone.textContainer!)
            let second = lone.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 1, length: 1), in: lone.textContainer!)
            print("Chip first: \(first), after text: \(second)")
            check(abs(second.width - first.width - 6) < 0.5, "a chip that opens the message has no left margin")
        }
        field.putImage("/fixture.png")
        field.layoutManager!.ensureLayout(for: field.textContainer!)
        let before = field.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: field.textContainer!)
        let beforeImage = try capture("before-space")
        field.insertText(" ", replacementRange: field.selectedRange())
        field.layoutManager!.ensureLayout(for: field.textContainer!)
        let after = field.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: field.textContainer!)
        let afterImage = try capture("after-space")
        var attachments = 0
        field.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: field.textStorage!.length)) { value, _, _ in if value is ImageChip { attachments += 1 } }
        print("Image geometry: \(before) -> \(after); attachments: \(attachments)")
        check(beforeImage == afterImage && attachments == 1 && field.message().1.count == 1, "Space preserves pasted image pixels and attachment count")
        field.insertText("text", replacementRange: field.selectedRange())
        field.layoutManager!.ensureLayout(for: field.textContainer!)
        try capture("with-text")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("line one\nline two", forType: .string)
        field.paste(from: board)
        try capture("with-paste")
        let pasted = field.textStorage!.attribute(.attachment, at: field.selectedRange().location - 1, effectiveRange: nil) as? PasteChip
        check(pasted?.number == 1 && field.message().0.hasSuffix("textline one\nline two") && draftContent(frontend.draft).last?["type"] as? String == "paste", "pasted text shows as [Paste #1] and still sends its text")
        check(runtimeDraft(draftContent(frontend.draft)).attribute(.attachment, at: frontend.draft.length - 1, effectiveRange: nil) is PasteChip, "a restored draft keeps its paste chip")
        check(coordinator.textView(field, doCommandBy: #selector(NSResponder.insertTab(_:))) && field.string.hasSuffix("line one\nline two"), "Tab right after a paste expands it to text")
        field.paste(from: board); field.insertText(" ", replacementRange: field.selectedRange())
        check(!coordinator.textView(field, doCommandBy: #selector(NSResponder.insertTab(_:))) && field.textStorage!.attribute(.attachment, at: field.string.utf16.count - 2, effectiveRange: nil) is PasteChip, "Tab after typing leaves the paste collapsed")
        field.deleteBackward(nil)
        check(coordinator.textView(field, doCommandBy: #selector(NSResponder.insertTab(_:))) && field.string.hasSuffix("line two") && field.textStorage!.attribute(.attachment, at: field.string.utf16.count - 1, effectiveRange: nil) == nil, "Tab after deleting back to a paste expands it")
        field.paste(from: board); field.insertText(" ", replacementRange: field.selectedRange())
        let oldWorkerEcho = plainDraftContent(draftContent(frontend.draft))
        frontend.applyRuntimeDraft(["draft": oldWorkerEcho, "draftGeneration": frontend.draftGeneration])
        check(oldWorkerEcho.count == 2 && !oldWorkerEcho.contains { $0["type"] as? String == "paste" } && frontend.draft.attribute(.attachment, at: frontend.draft.length - 2, effectiveRange: nil) is PasteChip, "a runtime worker that echoes the paste as text keeps the chip")
        frontend.applyRuntimeDraft(["draft": [JSON](), "draftGeneration": frontend.draftGeneration])
        check(frontend.draft.length == 0, "a runtime that clears the draft still clears it")
        let presence = FleetPresence(session: frontend)
        defer { presence.close() }
        let presenceFile = frontend.stateDirectory.appendingPathComponent("fleet/\(getpid()).json")
        func state() throws -> String? { (try JSONSerialization.jsonObject(with: Data(contentsOf: presenceFile)) as? JSON)?["state"] as? String }
        check(try state() == "fresh", "Fleet reports a session without a prompt as new")
        field.setDraft(NSAttributedString(string: "fixture prompt")); field.didChangeText()
        let host = NSHostingView(rootView: Composer(session: frontend))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 150); host.layoutSubtreeIfNeeded()
        await settle()
        _ = try await backend.perform(action: "send", params: ["text": "fixture prompt", "images": [String](), "draft": draftContent(frontend.draft), "generation": frontend.draftGeneration])
        await settle(); host.layoutSubtreeIfNeeded()
        check(frontend.draft.length == 0 && RuntimeUpdate.composer(in: host)?.string.isEmpty == true, "sending clears the visible runtime composer")
        frontend.editDraft(runtimeDraft([["text": "with image"], ["path": "/fixture.png"]]))
        _ = try await backend.perform(action: "send", params: ["text": "with image", "images": ["/fixture.png"], "draft": draftContent(frontend.draft), "generation": frontend.draftGeneration])
        await settle(); host.layoutSubtreeIfNeeded()
        check(frontend.draft.length == 0 && RuntimeUpdate.composer(in: host)?.string.isEmpty == true, "sending an image clears the visible runtime composer")
        check(try state() == "working", "Fleet reports a running runtime session as working")
        do {
            let (backField, backCoordinator) = editor(backendSession)
            defer { withExtendedLifetime(backCoordinator) {} }
            func prompts() -> [String] { backendSession.rows.filter { $0.kind == "user" }.compactMap { ($0.items.first?.data["content"] as? [JSON])?.first?["text"] as? String } }
            func sentTexts() -> [String] { connection.sent.compactMap { ($0["input"] as? [JSON])?.first?["text"] as? String } }
            func queueLast(read: Bool = false) -> String {
                let id = connection.sent.last?["clientUserMessageId"] as? String ?? ""
                if !read { connection.unread.insert(id) }
                connection.event(["method": "cx/userQueue", "params": ["id": id, "queued": !read]])
                return id
            }
            func key(_ selector: Selector) async -> Bool { let handled = backCoordinator.textView(backField, doCommandBy: selector); await settle(); return handled }
            backendSession.editDraft(NSAttributedString(string: ""))
            await backendSession.send(text: "first version", images: [])
            let first = queueLast()
            await settle()
            let mirrored = frontend.rows.flatMap(\.items).first { $0.id == first }
            check(mirrored?.data["queued"] as? Bool == true, "the window shows a prompt the agent has not read yet")
            if let mirrored {
                let bubble = NSHostingView(rootView: UserBubble(item: mirrored, session: frontend).environmentObject(SendAnimation()).environment(\.colorScheme, .light).frame(width: 560).padding(12).background(Color.white))
                bubble.frame = NSRect(origin: .zero, size: bubble.fittingSize); bubble.layoutSubtreeIfNeeded()
                if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"], let bitmap = bubble.bitmapImageRepForCachingDisplay(in: bubble.bounds) {
                    bubble.cacheDisplay(in: bubble.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent("unread-prompt.png"))
                }
            }
            check(await key(#selector(NSResponder.moveUp(_:))) && backendSession.draft.string == "first version" && !prompts().contains("first version") && connection.unread.isEmpty,
                  "up arrow withdraws an unread prompt into the composer")
            check(await key(#selector(NSResponder.cancelOperation(_:))) && backendSession.draft.length == 0 && prompts().last == "first version" && sentTexts().last == "first version" && backendSession.busy,
                  "Escape sends the withdrawn prompt back unchanged without stopping the agent")
            let sentBefore = connection.sent.count
            _ = queueLast()
            check(await key(#selector(NSResponder.moveUp(_:))) && backendSession.draft.string == "first version", "up arrow withdraws the prompt again")
            backendSession.editDraft(NSAttributedString(string: "edited version"))
            await backendSession.send(text: "edited version", images: [])
            check(sentTexts().suffix(connection.sent.count - sentBefore) == ["edited version"] && prompts().suffix(2) == ["with image", "edited version"],
                  "Enter sends the edited prompt in place of the withdrawn one, which the agent never receives")
            _ = queueLast(read: true)
            let readMark = backendSession.rows.last { $0.kind == "user" }?.items.first?.data["queued"]
            let copied = await key(#selector(NSResponder.moveUp(_:)))
            check(readMark == nil && copied && backendSession.draft.string == "edited version" && prompts().last == "edited version",
                  "up arrow on a prompt the agent has read only copies it")
            backendSession.editDraft(NSAttributedString(string: ""))
            await backendSession.send(text: "raced", images: [])
            let raced = queueLast()
            connection.unread.remove(raced)
            let late = try await backend.perform(action: "unsend", params: ["id": raced])
            check(late["cancelled"] as? Bool == false && prompts().last == "raced", "a prompt the agent took in before the withdrawal stays sent")
            backendSession.editDraft(NSAttributedString(string: ""))
        }
        do {
            let asking = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("tall-question"))
            asking.ready = true; asking.status = "Ready"
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1470, height: 895), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 780, height: 560)
            window.contentView = CXView.host(asking)
            defer { window.close() }
            let before = window.frame.height
            let question = "Which part should keep the editor's font when a word is highlighted as a command: the gray chip's box, the tint that appears while typing, or the purple word in the transcript? Pick the one you meant."
            asking.permissions = [Permission(rpcID: "tall", method: "item/tool/requestUserInput", params: ["questions": [["id": "font", "header": "What changes", "question": question, "options": [["label": "The gray chip's box", "description": "Keep the chip's text in the composer's font."]]]]])]
            await settle(); window.contentView?.layoutSubtreeIfNeeded()
            if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"], let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent("tall-question.png"))
            }
            print("Window with a \(question.count)-character question: \(Int(before)) pt tall before, \(Int(window.frame.height)) after")
            check(window.frame.height == before, "a long question keeps the window its size, composer on screen")
        }
        do {
            let asking = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("pinned-question"))
            asking.ready = true; asking.status = "Ready"
            let lines = (1...20).map { "Line \($0) of a question long enough to need more than the two lines a pinned question keeps on screen, and to wrap where the bubble's width ends." }.joined(separator: "\n")
            asking.show(["id": "pinned-question", "type": "userMessage", "content": [["type": "text", "text": lines], ["type": "localImage", "path": "/fixture-one.png"], ["type": "localImage", "path": "/fixture-two.png"]]])
            asking.show(["id": "pinned-answer", "type": "agentMessage", "provider": "Claude", "text": (1...60).map { "- Answer line \($0), long enough to reach the left edge beside the pinned question." }.joined(separator: "\n")])
            if let item = asking.rows.first?.items.first {
                func height(_ collapsible: Bool) -> CGFloat { NSHostingView(rootView: UserBubble(item: item, session: asking, collapsible: collapsible).environmentObject(SendAnimation()).frame(width: 900)).fittingSize.height }
                let pinned = height(true), full = height(false)
                print("Question with twenty lines and two pictures:\(Int(pinned)) pt pinned, \(Int(full)) pt hovered")
                check(pinned < 160 && full > pinned + 40, "a pinned question keeps two lines and one row of pictures until hovered")
                // Sampled at 60 fps, the opening bubble grows through several heights and never shrinks back.
                let hover = HoverProbe.State()
                let host = NSHostingView(rootView: HoverProbe(state: hover, item: item, session: asking).environmentObject(SendAnimation()).frame(width: 900).padding(30).frame(maxHeight: .infinity, alignment: .top).background(Color.white))
                host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 960, height: 1200)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.close() }
                host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                var halfway: NSBitmapImageRep?
                func tinted() -> Int {
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let x = Int(922 * CGFloat(bitmap.pixelsWide) / host.bounds.width)
                    let rows = (0..<bitmap.pixelsHigh).filter { y in bitmap.colorAt(x: x, y: y).map { $0.blueComponent - $0.greenComponent > 0.02 } ?? false }.count
                    if halfway == nil, rows > 400, rows < 560 { halfway = bitmap }
                    return rows
                }
                var heights = [tinted()]
                let start = Date()
                withAnimation(UserBubble.opening(reduceMotion: false)) { hover.open = true }
                for frame in 1...30 { RunLoop.main.run(until: start.addingTimeInterval(Double(frame) / 60)); heights.append(tinted()) }
                print("Bubble opening, tinted rows per frame: " + heights.map(String.init).joined(separator: " "))
                if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"], let png = halfway?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: destination).appendingPathComponent("bubble-opening.png"))
                }
                check(Set(heights).count >= 6 && zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 } && heights.last! > heights[0],
                      "hovering opens a pinned question in one smooth motion")
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1176, height: 803), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = CXView.host(asking)
            defer { window.close() }
            await settle(); window.contentView?.layoutSubtreeIfNeeded()
            if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"] {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent("pinned-question.png"))
                }
                // Scrolled to the answer's end, the question's tint shows in the transcript's top 120 pt only if it is pinned.
                let x = Int(1100 * CGFloat(bitmap.pixelsWide) / content.bounds.width), top = Int(120 * CGFloat(bitmap.pixelsHigh) / content.bounds.height)
                let tinted = (0..<top).filter { y in bitmap.colorAt(x: x, y: y).map { $0.blueComponent - $0.greenComponent > 0.02 } ?? false }.count
                check(tinted > 10, "a question taller than half the transcript stays pinned above its answer")
            }
        }
        do {
            let source = SessionBackend(session: Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("scroll-source")))
            defer { source.close() }
            for n in 1...30 {
                source.session.show(["id": "scroll-q\(n)", "type": "userMessage", "content": [["type": "text", "text": "Question \(n)"]]])
                source.session.show(["id": "scroll-a\(n)", "type": "agentMessage", "provider": "Claude", "text": (1...6).map { "Answer \(n), paragraph \($0), long enough to wrap where the chat column ends on a window this wide." }.joined(separator: "\n\n")])
            }
            let snapshot = source.snapshot()
            // The order createWindow follows when an update or a recovery reopens a window.
            func reopen(_ name: String, _ state: JSON) async -> (Session, NSWindow) {
                let session = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent(name))
                session.ready = true; session.status = "Ready"
                RuntimeUpdate.adopt(state, session: session)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1176, height: 803), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = CXView.host(session)
                await settle(); window.contentView?.layoutSubtreeIfNeeded()
                // connect applies the snapshot in a task of its own and restores once it resumes.
                await Task { session.applyRuntimeSnapshot(snapshot) }.value
                RuntimeUpdate.restore(state, window: window, session: session)
                await settle(); window.contentView?.layoutSubtreeIfNeeded()
                await settle(); window.contentView?.layoutSubtreeIfNeeded()
                return (session, window)
            }
            func image(_ window: NSWindow, _ name: String) -> NSBitmapImageRep? {
                guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"] { try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png")) }
                return bitmap
            }
            let (old, oldWindow) = await reopen("scroll-old", [:])
            defer { oldWindow.close(); old.close() }
            if let scroll = RuntimeUpdate.scrollView(in: oldWindow.contentView) {
                // Up from the end a screen at a time, as a hand scrolls, so the rows passed are measured.
                var y = scroll.contentView.bounds.origin.y
                while y > 1500 {
                    y = max(1500, y - 300)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05)); oldWindow.contentView?.layoutSubtreeIfNeeded()
                }
            }
            old.follow.attached = false
            await settle(); oldWindow.contentView?.layoutSubtreeIfNeeded()
            // Through JSON as the handoff ticket carries it: a raw CGFloat does not cast to Double.
            let state = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: RuntimeUpdate.state(window: oldWindow, session: old))) as? JSON ?? [:]
            let (new, newWindow) = await reopen("scroll-new", state)
            defer { newWindow.close(); new.close() }
            let before = state["scrollY"] as? Double ?? 0, after = Double(RuntimeUpdate.scrollView(in: newWindow.contentView)?.contentView.bounds.origin.y ?? 0)
            var differing = 0, total = 0
            if let a = image(oldWindow, "scroll-before-update"), let b = image(newWindow, "scroll-after-update"), let pa = a.bitmapData, let pb = b.bitmapData, a.bytesPerRow * a.pixelsHigh == b.bytesPerRow * b.pixelsHigh {
                total = a.bytesPerRow * a.pixelsHigh
                for index in 0..<total where pa[index] != pb[index] { differing += 1 }
            }
            let saved = state["anchorTop"] as? Double, shown = (state["anchor"] as? String).flatMap { UUID(uuidString: $0) }.flatMap { new.exchangeTops[$0] }.map(Double.init)
            print("Window scrolled to \(Int(before)) pt before an update, \(Int(after)) pt after; the exchange at the top edge sat at \(saved.map { String(format: "%.2f", $0) } ?? "none") pt, now \(shown.map { String(format: "%.2f", $0) } ?? "none") pt; \(total == 0 ? 100 : differing * 100 / total)% of the picture differs")
            check(before > 0 && !new.follow.attached && saved != nil && shown != nil && abs(shown! - saved!) < 1 && total > 0 && differing * 20 < total, "a window reopened by an update shows what it showed before")
        }
        backendSession.event(["method": "turn/completed", "params": ["turn": ["id": connection.pendingTurn, "status": "interrupted"]]])
        await settle(); await settle()
        check(frontend.rows.contains { $0.kind == "notice" && $0.items.contains { $0.text.localizedCaseInsensitiveContains("interrupted") } }, "interruption stays visible in the transcript")
        check(try state() == "waiting", "Fleet marks an interrupted session as needing attention")
        let savedID = backendSession.currentConversationID
        let savedFile = backendSession.nativeDirectory.appendingPathComponent(String(savedID.dropFirst(7)) + ".json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: savedFile)) as? JSON
        check(saved?["needsAttention"] as? Bool == true, "interruption attention is saved on disk")
        check(await backendSession.switchThread(savedID), "interrupted conversation can be reopened")
        check(backendSession.needsAttention && backendSession.rows.contains { $0.kind == "notice" && $0.items.contains { $0.text.contains("interrupted") } }, "reopening preserves interruption and attention")
        backendSession.legacyCommandPaths = [:]
        backendSession.skillPaths["sm"] = "/fixture/SKILL.md"
        backendSession.providerCommands = [ChatCommand(name: "/sm", detail: "Summarize", source: "Codex", insert: "/codex:sm ")]
        await backendSession.command("/sm")
        let visible = backendSession.rows.last { $0.kind == "user" }?.items.first?.data["content"] as? [JSON]
        check(visible?.first?["text"] as? String == "/sm", "slash skill retains the text the user submitted")
        let wire = connection.sent.last?["input"] as? [JSON]
        check(wire?.contains { $0["type"] as? String == "skill" && $0["name"] as? String == "sm" } == true, "Codex still receives the native skill")
        check(!backendSession.needsAttention, "a new accepted prompt clears interruption attention")
        await backendSession.stop(source: "Escape")
        await settle(); await settle()
        check(backendSession.rows.last?.items.first?.text.contains("Escape") == true, "the stop source stays visible after completion")
        check(backendSession.rows.filter { $0.items.contains { $0.text.contains("Escape") } }.count == 1, "one stop shows one notice")
        check(!backendSession.needsAttention && backendSession.status == "Stopped" && (try state()) == "ready", "Fleet shows a session the user stopped with Escape as ready")
        await backendSession.send(text: "close fixture", images: [])
        _ = try await backend.perform(action: "close", params: [:])
        check(!backendSession.busy && backendSession.needsAttention && backendSession.rows.last?.items.first?.text.contains("Close Session") == true, "closing records why active work stopped")
        let recovered = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("recovered"))
        recovered.applyInterruptedRecovery(["interrupted": false])
        check(!recovered.needsAttention, "recovering an idle runtime does not report interrupted work")
        recovered.applyInterruptedRecovery(["interrupted": true])
        check(recovered.needsAttention, "recovering active work requests attention")
        recovered.close()
        do {
            let fixture = Bundle.main.url(forResource: "native_peer", withExtension: "py")?.path
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/native_peer.py").path
            let claude = ClaudeConnection(account: Account(id: "bug-claude", name: "Fixture", provider: "claude"), cwd: directory.path)
            defer { claude.close() }
            var queued: [String: Bool] = [:], answer = "", done = false
            claude.event = { message in
                let p = message["params"] as? JSON ?? [:]
                if message["method"] as? String == "cx/userQueue", let id = p["id"] as? String { queued[id] = p["queued"] as? Bool }
                if message["method"] as? String == "item/completed", let item = p["item"] as? JSON { answer = item["text"] as? String ?? answer }
                if message["method"] as? String == "turn/completed" { done = true }
            }
            try await claude.start(command: ["python3", fixture, "claude"])
            let turn = ((try await claude.request("turn/start", ["input": [["type": "text", "text": "WAIT"]]]))["turn"] as? JSON)?["id"] as? String ?? ""
            func steer(_ text: String, _ id: String) async throws { _ = try await claude.request("turn/steer", ["expectedTurnId": turn, "clientUserMessageId": id, "input": [["type": "text", "text": text]]]) }
            try await steer("first version", "unsent")
            for _ in 0..<200 where queued["unsent"] == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            check(queued["unsent"] == true, "Claude reports a prompt sent during its turn as not read yet")
            let withdrawn = try await claude.request("cx/unsend", ["id": "unsent"])
            try await steer("edited version", "edited")
            try await steer("READ", "read")
            for _ in 0..<200 where !done { try await Task.sleep(nanoseconds: 10_000_000) }
            check(withdrawn["cancelled"] as? Bool == true && answer == "Read: edited version, READ", "a prompt withdrawn before Claude reads it never reaches Claude")
            check(queued["edited"] == false, "Claude reports a prompt its turn took in as read")
            let late = try await claude.request("cx/unsend", ["id": "edited"])
            check(late["cancelled"] as? Bool == false, "a prompt Claude has read cannot be withdrawn")
        } catch { check(false, "Claude withdrawal: " + error.localizedDescription) }
        print("\(count - failures.count)/\(count) reported-bug checks passed")
        if !failures.isEmpty { throw CXError(message: "Reported-bug checks failed: " + failures.joined(separator: "; ")) }
    }
}

// Stands in for the pointer: hovering only flips a state inside an animation.
struct HoverProbe: View {
    final class State: ObservableObject { @Published var open = false }
    @ObservedObject var state: State
    let item: Item
    let session: Session
    var body: some View { UserBubble(item: item, session: session, collapsible: !state.open) }
}
