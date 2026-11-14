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
        do {
            let sized = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("sized"))
            sized.draft = NSAttributedString(string: String(repeating: "wrap ", count: 30)); sized.draftRevision += 1
            let host = NSHostingView(rootView: Composer(session: sized))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 150); host.layoutSubtreeIfNeeded()
            await settle()
            let sizedField = RuntimeUpdate.composer(in: host)!, wrapped = sized.editorHeight
            sizedField.setFrameSize(NSSize(width: 2000, height: sizedField.frame.height))
            sizedField.setFrameSize(NSSize(width: 600, height: sizedField.frame.height))
            await settle()
            check(wrapped > 24 && sized.editorHeight == wrapped, "a wrapped draft keeps its height after two measures in one pass (\(wrapped) → \(sized.editorHeight))")
            sized.close()
        }
        let account = Settings.shared.value.accounts.first { $0.provider == "codex" }!
        let preferences = Settings.shared.value
        defer { Settings.shared.value = preferences; Settings.shared.save() }
        Settings.shared.value.provider = "codex"; Settings.shared.save()
        do {
            let sending = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("repeated-return"))
            let connection = FixtureConnection(account); connection.hold = true
            sending.connectionFactory = { _, _ in connection }
            try await sending.activate(account, resume: nil, keepRows: false)
            defer { sending.close() }
            let (field, coordinator) = editor(sending)
            defer { withExtendedLifetime(coordinator) {} }
            sending.editDraft(NSAttributedString(string: "Send this once")); field.setDraft(sending.draft)
            var animations = 0
            field.willSubmit = { _, _, _ in animations += 1 }
            for _ in 0..<2 { _ = coordinator.textView(field, doCommandBy: #selector(NSResponder.insertNewline(_:))) }
            await settle()
            check(connection.sent.count == 1 && sending.rows.filter { $0.kind == "user" }.count == 1 && animations == 1,
                  "two Returns before the send task starts submit one message and prepare one animation (sent \(connection.sent.count), animations \(animations))")
            field.submit()
            await settle()
            check(connection.sent.count == 1, "a stale editor cannot resubmit a consumed draft before the view refreshes")
            sending.editDraft(NSAttributedString(string: "Send this once")); field.setDraft(sending.draft)
            field.submit()
            await settle()
            check(connection.sent.count == 2, "a freshly typed identical message can still be sent")
            sending.editDraft(NSAttributedString(string: "First draft")); field.setDraft(sending.draft); field.submit()
            sending.editDraft(NSAttributedString(string: "Next draft")); field.setDraft(sending.draft); field.submit()
            await settle()
            check(connection.sent.count == 4 && sending.draft.length == 0, "a new draft can be submitted while an earlier draft is pending")
            connection.failSend = true
            sending.editDraft(runtimeDraft([["type": "text", "text": "Retry this"], ["type": "localImage", "path": "/fixture.png"]])); field.setDraft(sending.draft)
            field.submit()
            await settle()
            check(connection.sent.count == 5 && sending.draft.string.contains("Retry this") && draftContent(sending.draft).contains { $0["path"] as? String == "/fixture.png" },
                  "a failed send restores its text and attachment")
            connection.failSend = false; field.setDraft(sending.draft)
            field.submit()
            await settle()
            check(connection.sent.count == 6 && sending.draft.length == 0, "the restored draft can be retried without editing it")
            guard failures.isEmpty else { throw CXError(message: failures.joined(separator: "; ")) }
        }
        do {
            let claude = Settings.shared.value.accounts.first { $0.provider == "claude" }!
            let switching = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("provider-switch"))
            switching.providerChoice = "claude"
            var connections: [FixtureConnection] = []
            var failSwitch = false
            switching.connectionFactory = { account, _ in
                let connection = FixtureConnection(account)
                if !connections.isEmpty { connection.startDelay = 1_000_000_000 }
                connection.failStart = failSwitch
                connections.append(connection)
                return connection
            }
            try await switching.activate(claude, resume: nil, keepRows: false)
            let backend = SessionBackend(session: switching)
            let frontend = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("provider-switch-frontend"))
            backend.onChange = { frontend.applyRuntimePatch($0) }
            frontend.applyRuntimeSnapshot(backend.snapshot())
            let host = NSHostingView(rootView: Composer(session: frontend))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 150); host.layoutSubtreeIfNeeded()
            defer {
                backend.close(); frontend.close()
                Settings.shared.updateLimit(account: claude.id, reset: 0)
            }
            Settings.shared.updateLimit(account: claude.id, reset: Date().timeIntervalSince1970 + 3600)
            for provider in ["codex", "claude"] {
                if provider == "claude" { Settings.shared.updateLimit(account: claude.id, reset: Date().timeIntervalSince1970 - 1) }
                let prompt = "Continue with " + provider
                frontend.editDraft(NSAttributedString(string: prompt))
                let params: JSON = ["text": prompt, "images": [String](), "draft": draftContent(frontend.draft), "generation": frontend.draftGeneration]
                let send = Task { try await backend.perform(action: "send", params: params) }
                for _ in 0..<100 where !switching.changing { try? await Task.sleep(nanoseconds: 1_000_000) }
                let shown = { frontend.rows.last?.kind == "user" && (frontend.rows.last?.items.first?.data["content"] as? [JSON])?.first?["text"] as? String == prompt }
                let cleared = { frontend.draft.length == 0 && RuntimeUpdate.composer(in: host)?.string.isEmpty == true }
                // A fixed 150 ms wait failed under mac.vcx-update (a launchd daemon spawn) and passed from a shell: wait while connecting.
                let deadline = Date().addingTimeInterval(0.9)
                repeat { try? await Task.sleep(nanoseconds: 10_000_000); host.layoutSubtreeIfNeeded() } while switching.changing && !(shown() && cleared()) && Date() < deadline
                check(switching.changing, "\(provider) switch fixture waits on its connection")
                check(shown(), "\(provider) switch shows the submitted bubble before connecting")
                check(cleared(), "\(provider) switch clears the visible composer before connecting")
                if provider == "codex" { frontend.editDraft(NSAttributedString(string: "Next draft")) }
                _ = try await send.value
                await settle(); host.layoutSubtreeIfNeeded()
                let userIndex = frontend.rows.firstIndex { ($0.items.first?.data["content"] as? [JSON])?.first?["text"] as? String == prompt }
                let noticeIndex = frontend.rows.lastIndex { $0.kind == "notice" }
                check(switching.account.provider == provider && switching.preferredProvider == "claude", "\(provider) switch keeps Claude as the preferred provider")
                check(userIndex != nil && noticeIndex != nil && userIndex! < noticeIndex!, "\(provider) switch notice follows the submitted bubble")
                check(connections.last?.sent.count == 1 && frontend.rows.filter { ($0.items.first?.data["content"] as? [JSON])?.first?["text"] as? String == prompt }.count == 1,
                      "\(provider) switch sends once and keeps one bubble")
                check(frontend.draft.string == (provider == "codex" ? "Next draft" : ""), "\(provider) switch preserves new typing while connecting")
            }
            failSwitch = true
            Settings.shared.updateLimit(account: claude.id, reset: Date().timeIntervalSince1970 + 3600)
            frontend.editDraft(runtimeDraft([["type": "text", "text": "Keep failed switch"], ["type": "localImage", "path": "/fixture.png"]]))
            _ = try await backend.perform(action: "send", params: ["text": "Keep failed switch", "images": ["/fixture.png"], "draft": draftContent(frontend.draft), "generation": frontend.draftGeneration])
            check(!switching.busy && switching.ready && frontend.draft.string.contains("Keep failed switch") && draftContent(frontend.draft).contains { $0["path"] as? String == "/fixture.png" },
                  "a failed provider switch keeps its connection and restores the submitted text and attachment")
            check(!frontend.rows.contains { ($0.items.first?.data["content"] as? [JSON])?.first?["text"] as? String == "Keep failed switch" } && connections.last?.sent.isEmpty == true,
                  "a failed provider switch removes the unsent bubble")
        }
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
        board.clearContents(); board.setString("line one of the paste\nline two", forType: .string)
        field.paste(from: board)
        try capture("with-paste")
        let pasted = field.textStorage!.attribute(.attachment, at: field.selectedRange().location - 1, effectiveRange: nil) as? PasteChip
        check(pasted?.number == 1 && field.message().0.hasSuffix("textline one of the paste\nline two") && draftContent(frontend.draft).last?["type"] as? String == "paste", "pasted text shows as [Paste #1] and still sends its text")
        check(runtimeDraft(draftContent(frontend.draft)).attribute(.attachment, at: frontend.draft.length - 1, effectiveRange: nil) is PasteChip, "a restored draft keeps its paste chip")
        check(coordinator.textView(field, doCommandBy: #selector(NSResponder.insertTab(_:))) && field.string.hasSuffix("line one of the paste\nline two"), "Tab right after a paste expands it to text")
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
        board.clearContents(); board.setString("under twenty", forType: .string)
        field.paste(from: board)
        check(field.string.hasSuffix("under twenty") && field.textStorage!.attribute(.attachment, at: field.string.utf16.count - 1, effectiveRange: nil) == nil, "a paste under 20 characters goes in as text")
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
            let sentBeforeNow = connection.sent.count, noticesBefore = backendSession.rows.filter { $0.kind == "notice" }.count
            _ = try await backend.perform(action: "sendNow", params: [:])
            for _ in 0..<20 where connection.sent.count == sentBeforeNow { await settle() }
            let resumed = connection.sent.suffix(connection.sent.count - sentBeforeNow)
            check(resumed.count == 1 && (resumed.first?["input"] as? [JSON])?.isEmpty == true && backendSession.busy && prompts().last == "raced" && backendSession.rows.filter({ $0.kind == "notice" }).count == noticesBefore,
                  "Shift+Return interrupts Codex and a turn with no input reads the waiting prompt, without a stop notice")
            let afterNow = connection.sent.count
            _ = try await backend.perform(action: "sendNow", params: [:]); await settle()
            check(connection.sent.count == afterNow && backendSession.busy, "Shift+Return does nothing once the prompt is the running turn's own")
        }
        do {
            let ordered = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("unread-order"))
            ordered.ready = true; ordered.status = "Ready"
            func act(_ n: Int) { ordered.show(["id": "order-c\(n)", "type": "commandExecution", "command": "ls step-\(n)", "aggregatedOutput": "", "status": "completed"]) }
            ordered.show(["id": "order-q1", "type": "userMessage", "content": [["type": "text", "text": "average internship salary"]]])
            act(1); act(2)
            ordered.rows.append(Row("user", [Item(["id": "order-q2", "type": "userMessage", "content": [["type": "text", "text": "and the average salary after graduating"]], "sentAt": Date().timeIntervalSince1970])]))
            ordered.event(["method": "cx/userQueue", "params": ["id": "order-q2", "queued": true]])
            act(3); act(4); act(5)
            ordered.show(["id": "order-a1", "type": "agentMessage", "text": "Interns earn about this much."])
            print("Rows while the second prompt is unread: \(ordered.rows.map { "\($0.kind)(\($0.items.count))" }.joined(separator: " "))")
            check(ordered.rows.map(\.kind) == ["user", "activity", "assistant", "user"] && ordered.rows[1].items.count == 5,
                  "what the agent does before reading a queued prompt goes above it, its actions in the bar it was filling")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1176, height: 803), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = CXView.host(ordered)
            await settle(); window.contentView?.layoutSubtreeIfNeeded()
            if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"], let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent("unread-order.png"))
            }
            window.close()
            ordered.event(["method": "cx/userQueue", "params": ["id": "order-q2", "queued": false]])
            act(6)
            check(ordered.rows.map(\.kind) == ["user", "activity", "assistant", "user", "activity"] && ordered.rows[4].items.count == 1,
                  "once the agent reads the prompt, its next actions go under it")
            ordered.close()
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
            let lines = (1...20).map { "Line \($0) of a question long enough to need more than the one line a pinned question keeps on screen, and to wrap where the bubble's width ends." }.joined(separator: "\n")
            asking.show(["id": "pinned-question", "type": "userMessage", "content": [["type": "text", "text": lines], ["type": "localImage", "path": "/fixture-one.png"], ["type": "localImage", "path": "/fixture-two.png"]]])
            asking.show(["id": "pinned-answer", "type": "agentMessage", "provider": "Claude", "text": (1...60).map { "- Answer line \($0), long enough to reach the left edge beside the pinned question." }.joined(separator: "\n")])
            if let item = asking.rows.first?.items.first {
                func height(_ collapsible: Bool) -> CGFloat { NSHostingView(rootView: UserBubble(item: item, session: asking, collapsible: collapsible).environmentObject(SendAnimation()).frame(width: 900)).fittingSize.height }
                let pinned = height(true), full = height(false)
                print("Question with twenty lines and two pictures:\(Int(pinned)) pt pinned, \(Int(full)) pt hovered")
                check(pinned < 160 && full > pinned + 40, "a pinned question keeps one line and one row of pictures until hovered")
                let host = NSHostingView(rootView: UserBubble(item: item, session: asking, collapsible: true).environmentObject(SendAnimation()).frame(width: 900).padding(30).frame(maxHeight: .infinity, alignment: .top).background(Color.white))
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
                let left = tintStart(host, y: 60), arrow = arrowBox(host, left: left).map { NSPoint(x: $0.midX, y: $0.midY) } ?? .zero
                pointer(host, at: NSPoint(x: 5, y: 60), entering: true)
                pointer(host, at: NSPoint(x: left + 300, y: 60)); RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                let shut = tinted()
                // The opening bubble passes through a height between shut and open, takes a while to get there and never shrinks back.
                // A render of the whole view takes 100 to 250 ms, so the samples are timed rather than counted as 60 fps frames.
                var heights = [shut], times = [0.0]
                let start = Date()
                pointer(host, at: arrow)
                for frame in 1...30 { RunLoop.main.run(until: start.addingTimeInterval(Double(frame) / 60)); times.append(Date().timeIntervalSince(start)); heights.append(tinted()) }
                print("Bubble opening, tinted rows per frame: " + heights.map(String.init).joined(separator: " "))
                print("Sampled at ms: " + times.map { String(Int($0 * 1000)) }.joined(separator: " "))
                let opened = times[heights.firstIndex(of: heights.last!)!]
                if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"], let png = halfway?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: destination).appendingPathComponent("bubble-opening.png"))
                }
                check(heights.contains { $0 > shut && $0 < heights.last! } && opened >= 0.15 && zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 } && heights.last! > heights[0],
                      "hovering its arrow opens a pinned question in one smooth motion")
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                // A close starts 80 ms after the pointer leaves, then runs its 0.3 s spring.
                pointer(host, at: NSPoint(x: left + 300, y: 60)); pointer(host, at: NSPoint(x: 5, y: 60)); RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                let away = tinted()
                print("Pinned question from x \(Int(left)): \(heights[0]) tinted rows with the pointer on its text, \(heights.last!) on its arrow, \(away) away")
                // Column 922 crosses the bubble's rounded corners: the same shut bubble measures 272 or 274 rows from one render to the next.
                check(heights[0] < 300 && abs(away - heights[0]) <= 4, "the pointer on a pinned question's text leaves it shut, and leaving it closes it")
            }
            do {
                // Up to fifteen lines, a question shows whole pinned, with no arrow: as wide and as tall pinned as anywhere else.
                for (name, text) in [("one", "A question on one line"), ("fifteen", (1...15).map { "Line \($0) of a question that stays whole pinned" }.joined(separator: "\n"))] {
                let short = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("short-question-" + name))
                short.show(["id": "short-question-" + name, "type": "userMessage", "content": [["type": "text", "text": text]]])
                if let item = short.rows.first?.items.first {
                    func left(_ collapsible: Bool) -> (x: CGFloat, height: Int) {
                        let host = NSHostingView(rootView: UserBubble(item: item, session: short, collapsible: collapsible).environmentObject(SendAnimation()).frame(width: 900).padding(30).frame(maxHeight: .infinity, alignment: .top).background(Color.white))
                        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 960, height: 400)
                        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                        if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent("short-\(name)-\(collapsible ? "pinned" : "plain").png"))
                        }
                        let x = tintStart(host, y: 45)
                        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return (x, 0) }
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let column = Int((x + 20) * CGFloat(bitmap.pixelsWide) / host.bounds.width)
                        return (x, (0..<bitmap.pixelsHigh).filter { y in bitmap.colorAt(x: column, y: y).map { $0.blueComponent - $0.greenComponent > 0.02 } ?? false }.count)
                    }
                    let pinned = left(true), plain = left(false)
                    print("\(name.capitalized)-line question's bubble starts at x \(Int(pinned.x)) pinned, \(Int(plain.x)) unpinned; \(pinned.height) tinted rows pinned, \(plain.height) unpinned")
                    check(pinned.x > 0 && pinned.x == plain.x && abs(pinned.height - plain.height) <= 2, "a question on \(name) line(s) shows whole pinned, with no arrow")
                }
                }
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
                // The wheel over the pinned question goes to the transcript, as it did when the question was a header inside it.
                if let transcript = RuntimeUpdate.scrollView(in: content) {
                    let point = content.convert(NSPoint(x: 1100, y: 60), to: nil)
                    var hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
                    while let view = hit, !(view is NSScrollView) { hit = view.superview }
                    let target = hit ?? TranscriptWheel.stray(in: window, at: point)
                    print("Wheel over the pinned question goes to: " + (hit != nil ? "the scroll view under it" : target === transcript ? "the transcript, forwarded" : "nothing"))
                    check(target === transcript, "the wheel over a pinned question scrolls the transcript")
                } else { check(false, "the wheel over a pinned question: no transcript or event") }
                // In the transcript too, the pinned question's edge opens it: the open question's tint runs past the top 120 pt.
                let edge = tintStart(content, y: 20, from: 200)
                func rows(after wait: Double = 0.5) -> Int {
                    RunLoop.main.run(until: Date().addingTimeInterval(wait)); content.layoutSubtreeIfNeeded()
                    guard let shot = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return 0 }
                    content.cacheDisplay(in: content.bounds, to: shot)
                    return (0..<shot.pixelsHigh).filter { y in shot.colorAt(x: x, y: y).map { $0.blueComponent - $0.greenComponent > 0.02 } ?? false }.count
                }
                pointer(content, at: NSPoint(x: 1100, y: 20), entering: true)
                let shut = rows()
                let arrow = arrowBox(content, left: edge, below: 150).map { NSPoint(x: $0.midX, y: $0.midY) } ?? .zero
                pointer(content, at: arrow)
                // Taller than the transcript, it opens into a scroll view of its own: the switch happens mid-opening and must not jump.
                var opening = [shut]
                let start = Date()
                for frame in 1...20 { RunLoop.main.run(until: start.addingTimeInterval(Double(frame) / 60)); opening.append(rows(after: 0)) }
                let open = rows()
                print("Pinned question in the transcript from x \(Int(edge)): \(shut) tinted rows over its text, \(open) over its arrow")
                print("Opening in the transcript, tinted rows per sample: " + opening.map(String.init).joined(separator: " "))
                check(open > shut + 100, "in the transcript, hovering a pinned question's arrow opens it")
                check(opening.contains { $0 > shut + 20 && $0 < open - 20 } && zip(opening, opening.dropFirst()).allSatisfy { $0 <= $1 + 4 } && abs(opening.last! - open) <= 4,
                      "in the transcript, a question opening into its own scroll view grows in one smooth motion")
                // A hand resting on the mouse still sends moves: the question shut and reopened on each one, its main thread at 100 % (11-12).
                var held: [Int] = []
                for frame in 1...30 { pointer(content, at: arrow); RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60)); if frame % 6 == 0 { held.append(rows(after: 0)) } }
                print("Pointer moving on the open question's arrow, tinted rows per sample: " + held.map(String.init).joined(separator: " "))
                check(held.allSatisfy { abs($0 - open) <= 4 }, "a pointer moving where an open question's arrow was keeps it open")
                // Open and taller than the transcript, the pinned question had its end below the window: the wheel scrolled only the answer under it.
                func scrollViews(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews) }
                if let outer = RuntimeUpdate.scrollView(in: content), let inner = scrollViews(content).first(where: { $0 !== outer && outer.convert(outer.bounds, to: nil).contains($0.convert($0.bounds, to: nil)) }), let document = inner.documentView {
                    let box = inner.convert(inner.bounds, to: nil), visible = outer.convert(outer.bounds, to: nil)
                    let middle = NSPoint(x: box.midX, y: box.midY)
                    var hit = content.hitTest(content.superview?.convert(middle, from: nil) ?? middle)
                    while let view = hit, !(view is NSScrollView) { hit = view.superview }
                    document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.frame.height : 0))
                    content.layoutSubtreeIfNeeded()
                    let seen = inner.documentVisibleRect, end = document.isFlipped ? seen.maxY >= document.frame.height - 1 : seen.minY <= 1
                    print("Open pinned question: \(Int(box.height)) pt box in a \(Int(visible.height)) pt transcript, \(Int(document.frame.height)) pt of text")
                    if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"], let shot = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: shot)
                        try? shot.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent("pinned-question-end.png"))
                    }
                    check(visible.contains(box) && document.frame.height > box.height + 40 && hit === inner && end,
                          "an open pinned question taller than the transcript fits in it and the wheel over it scrolls it to its end")
                } else { check(false, "an open pinned question taller than the transcript scrolls on its own") }
            }
        }
        do {
            // A wide table's horizontal scroll view took every vertical wheel over it: the transcript stopped scrolling under the pointer.
            let tabled = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("table-wheel"))
            tabled.ready = true; tabled.status = "Ready"
            tabled.show(["id": "table-q", "type": "userMessage", "content": [["type": "text", "text": "compare"]]])
            tabled.show(["id": "table-a", "type": "agentMessage", "text": "Here:\n\n| A | B | C | D | E |\n|---|---|---|---|---|\n" + String(repeating: "| " + String(repeating: "a long cell ", count: 4) + " ", count: 5) + "|\n| six | seven | eight | nine | ten |"])
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1176, height: 803), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = CXView.host(tabled)
            defer { window.close() }
            await settle(); window.contentView?.layoutSubtreeIfNeeded()
            func scrollViews(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews) }
            func wheel(_ dy: Int32, _ dx: Int32 = 0) -> NSEvent? {
                CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0).flatMap(NSEvent.init(cgEvent:))
            }
            if let content = window.contentView, let outer = RuntimeUpdate.scrollView(in: content),
               let table = scrollViews(outer).first(where: { $0 !== outer && ($0.documentView?.frame.width ?? 0) > $0.frame.width + 1 }),
               let up = wheel(10), let down = wheel(-10), let side = wheel(0, -10) {
                print("Table scroll view \(Int(table.frame.width)) pt wide over \(Int(table.documentView?.frame.width ?? 0)) pt; wheel up/down/sideways passes on: \(TranscriptWheel.passes(up, over: table)) \(TranscriptWheel.passes(down, over: table)) \(TranscriptWheel.passes(side, over: table))")
                check(TranscriptWheel.passes(up, over: table) && TranscriptWheel.passes(down, over: table) && !TranscriptWheel.passes(side, over: table),
                      "a vertical wheel over a wide table scrolls the transcript, a sideways one the table")
            } else { check(false, "a vertical wheel over a wide table: no table scroll view in the transcript") }
        }
        for columns in [3, 5] {
            // The rule above held, yet a wheel sent over a table did not move the transcript.
            let tabled = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("table-route-\(columns)"))
            tabled.ready = true; tabled.status = "Ready"
            let head = "| " + (1...columns).map { "H\($0)" }.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: columns)
            // Columns fit their cells: the 5-column table is wide because its cells are long.
            let filler = columns == 5 ? " " + String(repeating: "wide ", count: 12) : ""
            let body = (1...12).map { r in "\n| " + (1...columns).map { "r\(r)c\($0)" + filler }.joined(separator: " | ") + " |" }.joined()
            for n in 0..<6 {
                tabled.show(["id": "q\(n)", "type": "userMessage", "content": [["type": "text", "text": "question \(n)"]]])
                tabled.show(["id": "a\(n)", "type": "agentMessage", "text": "Answer \(n):\n\n" + head + body + "\n\nAfter."])
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1176, height: 803), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = CXView.host(tabled)
            defer { window.close() }
            await settle(); window.contentView?.layoutSubtreeIfNeeded()
            func scrollViews(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews) }
            guard let content = window.contentView, let outer = RuntimeUpdate.scrollView(in: content),
                  let table = scrollViews(outer).filter({ $0 !== outer }).first(where: { t in
                      let r = t.convert(t.bounds, to: outer.contentView)
                      return outer.contentView.bounds.insetBy(dx: 0, dy: 40).contains(CGPoint(x: r.midX, y: r.midY))
                  }) else { check(false, "\(columns)-column table: none on screen"); continue }
            let frame = table.convert(table.bounds, to: nil)
            var point = NSPoint(x: frame.midX, y: frame.midY)
            func send(_ dy: Int32, _ dx: Int32 = 0, phase: CGScrollPhase? = nil) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
                if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
                guard let event = NSEvent(cgEvent: cg) else { return }
                if let passed = TranscriptWheel.route(event, in: window, at: point) { window.sendEvent(passed) }
                content.layoutSubtreeIfNeeded()
            }
            // Headless, a swipe moves no scroll view at all; what is checked is where the monitor sends it.
            func swipe(_ moves: [(Int32, Int32)]) -> Bool? {
                send(0, phase: .mayBegin); send(0, phase: .began)
                for (dy, dx) in moves { send(dy, dx, phase: .changed) }
                let went = TranscriptWheel.chained
                send(0, phase: .ended)
                return went
            }
            let start = outer.contentView.bounds.minY
            send(30)
            let wheel = outer.contentView.bounds.minY
            let up = swipe([(10, 0), (10, 0)]), leaning = swipe([(0, -2), (6, -1), (10, 0)]), sideways = swipe([(0, -10), (0, -10)])
            point = NSPoint(x: outer.convert(outer.bounds, to: nil).minX + 4, y: frame.midY)
            send(0, phase: .began)
            point = NSPoint(x: frame.midX, y: frame.midY)
            send(0, -10, phase: .changed)
            let slid = TranscriptWheel.chained
            send(0, phase: .ended)
            // Held under 4 pt over the table, a swipe that leaves it hands its events on; they never replay into the next swipe.
            send(0, phase: .began); send(1, phase: .changed)
            let heldOver = TranscriptWheel.held.count
            point = NSPoint(x: outer.convert(outer.bounds, to: nil).minX + 4, y: frame.midY)
            send(1, phase: .changed)
            let heldAfter = TranscriptWheel.held.count
            send(0, phase: .ended)
            point = NSPoint(x: frame.midX, y: frame.midY)
            send(0, phase: .began)
            let heldNext = TranscriptWheel.held.count
            send(0, phase: .ended)
            print("\(columns)-column table: \(heldOver) event(s) held over it, \(heldAfter) once the swipe left it, \(heldNext) at the next swipe")
            check(heldOver > 0 && heldAfter == 0 && heldNext <= 1, "a swipe leaving a \(columns)-column table undecided keeps no held events")
            let wide = columns == 5
            print("\(columns)-column table (\(Int(table.frame.width)) over \(Int(table.documentView?.frame.width ?? 0)) pt): transcript at \(Int(start)), \(Int(wheel)) after a mouse wheel up; swipe to the transcript: up \(String(describing: up)), leaning \(String(describing: leaning)), sideways \(String(describing: sideways)), begun beside it \(String(describing: slid))")
            check(wheel < start - 1 && up == true && leaning == true && sideways == !wide && slid == true,
                  "a wheel or a swipe over a \(columns)-column table scrolls the transcript, a sideways swipe \(wide ? "the table" : "too")")
        }
        do {
            // Opened by hover, scrolled into and left by the pointer, a tall work block shut under a scroll offset past the new end: the transcript went blank.
            let working = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("work-shut"))
            working.ready = true; working.status = "Ready"
            working.show(["id": "work-q", "type": "userMessage", "content": [["type": "text", "text": "list every step"]]])
            for n in 1...60 { working.show(["id": "work-c\(n)", "type": "commandExecution", "command": "ls step-\(n)", "aggregatedOutput": "", "status": "completed"]) }
            working.show(["id": "work-a", "type": "agentMessage", "text": "Done."])
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1176, height: 803), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = CXView.host(working)
            defer { window.close() }
            await settle()
            if let content = window.contentView {
                func shot(_ name: String) -> NSBitmapImageRep? {
                    content.layoutSubtreeIfNeeded()
                    guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"] { try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent("work-shut-\(name).png")) }
                    return bitmap
                }
                // The block's tinted edge, found on the render: the first tinted column left of the middle, on the row where it sits.
                func edge(_ bitmap: NSBitmapImageRep) -> (x: Int, y: Int)? {
                    for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide / 2 where bitmap.colorAt(x: x, y: y).map({ $0.blueComponent - $0.greenComponent > 0.02 }) == true { return (x, y) } }
                    return nil
                }
                // Inked rows of the transcript alone (right of the side bar, above the status line), in points.
                func inked(_ bitmap: NSBitmapImageRep) -> Int {
                    let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
                    return stride(from: 0, to: Int(640 * scale), by: Int(scale)).filter { y in stride(from: Int(170 * scale), to: Int(1150 * scale), by: 4).contains { x in bitmap.colorAt(x: x, y: y).map { $0.redComponent + $0.greenComponent + $0.blueComponent < 2.4 } ?? false } }.count
                }
                if let shut = shot("before"), let spot = edge(shut) {
                    let scale = CGFloat(shut.pixelsWide) / content.bounds.width
                    let at = NSPoint(x: CGFloat(spot.x) / scale + 20, y: CGFloat(spot.y) / scale + 20)
                    pointer(content, at: NSPoint(x: content.bounds.width - 5, y: at.y), entering: true)
                    pointer(content, at: at); RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                    func scrollViews(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews) }
                    if let outer = scrollViews(content).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }), let document = outer.documentView {
                        let tall = document.frame.height
                        // Scrolled to the middle of the open block, then the pointer leaves it sideways.
                        document.scroll(NSPoint(x: 0, y: document.isFlipped ? tall / 2 : tall / 2 - outer.contentSize.height))
                        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                        let open = shot("open")
                        pointer(content, at: NSPoint(x: content.bounds.width - 5, y: 400))
                        var frames: [Int] = []
                        let start = Date()
                        for frame in 1...24 { RunLoop.main.run(until: start.addingTimeInterval(Double(frame) / 30)); if let bitmap = shot([4, 10, 11].contains(frame) ? "moving-\(frame)" : "frame") { frames.append(inked(bitmap)) } }
                        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                        let after = shot("after")
                        print("Work block of 60 actions: document \(Int(tall)) pt open, \(Int(document.frame.height)) pt shut; inked rows open \(open.map(inked) ?? 0), while shutting " + frames.map(String.init).joined(separator: " ") + ", after \(after.map(inked) ?? 0)")
                        check(tall > document.frame.height + 600 && after.flatMap(edge) != nil && frames.allSatisfy { $0 > 10 },
                              "a work block left by the pointer while scrolled inside it shuts back into view, never on a blank transcript")
                    } else { check(false, "a work block left while scrolled inside it: no transcript scroll view") }
                } else { check(false, "a work block left while scrolled inside it: no tinted edge on the render") }
            }
        }
        do {
            // A word too long for what is left of line 1 opens line 2: SwiftUI's truncation pulled part of it up, then put it back on hover.
            // A path breaks after its slashes and hyphens, and "…" still has to fit after the last piece left on line 1.
            for (name, text) in [("word", "A pinned question keeps one line: 4f43b8a0b26746466d4cd6b1b84fdfd5d8b6c6d1725 and more words after it, so the text runs on to a third line, then a fourth and a fifth: past fifteen lines, a pinned question shuts to its first." + (1...12).map { "\nMore line \($0)." }.joined()),
                                 ("path", "A pinned question keeps one line, then an ellipsis: /Users/someone/projects/a-rather-long-folder-name/and-a-file.swift and more words after it, so the text runs on to a third line, then a fourth and a fifth: past fifteen lines, a pinned question shuts to its first." + (1...12).map { "\nMore line \($0)." }.joined())] {
                let asking = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("collapsed-" + name))
                asking.ready = true; asking.status = "Ready"
                asking.show(["id": "collapsed-" + name, "type": "userMessage", "content": [["type": "text", "text": text]]])
                guard let item = asking.rows.first?.items.first else { check(false, "collapsed \(name) fixture shows its question"); continue }
                let host = NSHostingView(rootView: UserBubble(item: item, session: asking, collapsible: true).environmentObject(SendAnimation()).environment(\.colorScheme, .light).frame(width: 560).padding(12).frame(maxHeight: .infinity, alignment: .top).background(Color.white))
                host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 584, height: 400)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.close() }
                var scale: CGFloat = 1, text = 0
                // Each text line as the first and last dark column of a band of dark rows; the arrow's colour is not dark.
                func lines(_ file: String) -> [(Int, Int)] {
                    host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.3)); host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return [] }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let data = bitmap.bitmapData else { return [] }
                    if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"] { try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent(file)) }
                    scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                    var bands = [(Int, Int)](), inBand = false
                    for y in 0..<bitmap.pixelsHigh {
                        let dark = (text..<bitmap.pixelsWide).filter { x in let p = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel; return Int(data[p]) + Int(data[p + 1]) + Int(data[p + 2]) < 360 && abs(Int(data[p]) - Int(data[p + 2])) < 50 }
                        if let first = dark.first, let last = dark.last {
                            if inBand, let band = bands.popLast() { bands.append((min(band.0, first), max(band.1, last))) } else { bands.append((first, last)) }
                            inBand = true
                        } else { inBand = false }
                    }
                    return bands
                }
                host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                let left = tintStart(host, y: 30)
                text = Int((left + 16) * CGFloat(host.bitmapImageRepForCachingDisplay(in: host.bounds)?.pixelsWide ?? 0) / host.bounds.width)
                let collapsed = lines("collapsed-\(name).png")
                func arrow() -> CGRect? { arrowBox(host, left: left) }
                let shutArrow = arrow()
                print("Collapsed \(name) question: arrow at \(shutArrow.map { "x \(Int($0.minX - left)), y \(Int($0.minY))" } ?? "none")")
                check(shutArrow.map { abs($0.minX - left - 16) <= 3 && $0.minY > 12 + 16 + CollapsibleText.line } == true, "a collapsed question's arrow (\(name)) sits under line 1, at the text's left")
                pointer(host, at: NSPoint(x: 5, y: 30), entering: true); pointer(host, at: NSPoint(x: left + 20, y: 12 + 16 + CollapsibleText.line * 1.5 + 6))
                let open = lines("collapsed-\(name)-open.png")
                print("Collapsed \(name) question, ink columns per line: \(collapsed), open: \(open)")
                check(arrow() == nil, "an open question (\(name)) hides its arrow")
                pointer(host, at: NSPoint(x: 5, y: 30)); RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                check(arrow() != nil, "a question (\(name)) shows its arrow again once the pointer leaves")
                if name == "word" { check(open.count >= 3 && open[1].1 - open[0].1 > Int(100 * scale), "fixture: the open question wraps its long word to line 2 and leaves line 1 short") }
                // Line 1 gains at most the "…", and may lose its last piece of word to it, never more.
                check(collapsed.count == 1 && open.count >= 2 && abs(collapsed[0].0 - open[0].0) <= 1
                      && collapsed[0].1 - open[0].1 < Int(12 * scale) && open[0].1 - collapsed[0].1 < Int(80 * scale), "a collapsed question (\(name)) shows line 1 as it wraps open, then …: no word moves on hover")
            }
        }
        do {
            // An agent message's arrow sat beside its "from …" tag instead of on the body's first line.
            let asking = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("collapsed-agent"))
            asking.show(["id": "collapsed-agent", "type": "userMessage", "content": [["type": "text", "text": "claude from [Fix pinned scroll]: \"Heads-up from another window: its body runs well past one line, so the pinned bubble shuts it to its first line and shows an edge to open it. Fifteen lines would stay whole, so this one goes on." + (1...16).map { "\nMore line \($0)." }.joined() + "\""]]])
            if let item = asking.rows.first?.items.first {
                let host = NSHostingView(rootView: UserBubble(item: item, session: asking, collapsible: true).environmentObject(SendAnimation()).environment(\.colorScheme, .light).frame(width: 560).padding(12).frame(maxHeight: .infinity, alignment: .top).background(Color.white))
                host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 584, height: 200)
                host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.3)); host.layoutSubtreeIfNeeded()
                let left = tintStart(host, y: 30)
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"] { try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent("collapsed-agent.png")) }
                    let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                    func column(_ x: CGFloat) -> Int { Int((left + x) * scale) }
                    func dark(_ x: Int, _ y: Int) -> Bool { bitmap.colorAt(x: x, y: y).map { $0.redComponent + $0.greenComponent + $0.blueComponent < 1.4 } ?? false }
                    // Middle of a run of rows, in points.
                    func middle(_ rows: [Int]) -> CGFloat { rows.isEmpty ? -100 : CGFloat(rows.first! + rows.last!) / 2 / scale }
                    let text = (0..<bitmap.pixelsHigh).filter { y in (column(16)..<bitmap.pixelsWide).contains { dark($0, y) } }
                    // Pink ink in the arrow's cells: the tag's text above, then the arrow, the last run of rows.
                    func pink(_ x: Int, _ y: Int) -> Bool { bitmap.colorAt(x: x, y: y).map { $0.redComponent - $0.greenComponent > 0.5 } ?? false }
                    let rows = (0..<bitmap.pixelsHigh).filter { y in (column(16)..<column(28)).contains { pink($0, y) } }
                    let chevron = rows.reversed().prefix { y in rows.contains(y + 1) || y == rows.last }.reversed().map { $0 }
                    print("Collapsed agent message: arrow at y \(middle(chevron)), text at \(middle(text)) (\(text.count) rows), \(rows.count) pink rows in the arrow's cells")
                    check(abs(middle(chevron) - middle(text) - CollapsibleText.line - 6) <= 3 && rows.count > chevron.count,
                          "an agent message's arrow sits under its body's first line")
                } else { check(false, "the collapsed agent message renders") }
            } else { check(false, "the agent message fixture shows its message") }
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
        do {
            // The window that went blank: a 7,500-line pasted question, its long answer, then a short question still unanswered.
            let source = SessionBackend(session: Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("tail-source")))
            defer { source.close() }
            let question = (1...7500).map { $0 % 50 == 0 ? String(repeating: "word ", count: 200) : "Claim \($0): a line of a pasted list about as long as the real one." }.joined(separator: "\n")
            source.session.show(["id": "tail-q1", "type": "userMessage", "content": [["type": "text", "text": question]]])
            for n in 1...34 { source.session.show(["id": "tail-c\(n)", "type": "commandExecution", "command": "curl -s https://example.com/\(n)", "aggregatedOutput": "output \(n)", "status": "completed"]) }
            source.session.show(["id": "tail-a1", "type": "agentMessage", "provider": "Claude", "text": (1...143).map { "- Answer line \($0) with enough words to wrap across most of the chat column on a window this wide." }.joined(separator: "\n")])
            source.session.show(["id": "tail-q2", "type": "userMessage", "content": [["type": "text", "text": "test"]]])
            let tailSnapshot = source.snapshot()
            func open(_ name: String, _ state: JSON) async -> (Session, NSWindow) {
                let session = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent(name))
                session.ready = true; session.status = "Ready"
                RuntimeUpdate.adopt(state, session: session)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1176, height: 803), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = CXView.host(session)
                await settle(); window.contentView?.layoutSubtreeIfNeeded()
                await Task { session.applyRuntimeSnapshot(tailSnapshot) }.value
                RuntimeUpdate.restore(state, window: window, session: session)
                await settle(); window.contentView?.layoutSubtreeIfNeeded()
                return (session, window)
            }
            let start = Date()
            let (old, oldWindow) = await open("tail-old", [:])
            defer { oldWindow.close(); old.close() }
            let opening = Date().timeIntervalSince(start)
            print("A 7,500-line question opened its window in \(String(format: "%.1f", opening)) s")
            // Measured whole only to keep its width, the question held the window 45 s, and the scrolling done meanwhile came in as one jump.
            check(opening < 10, "a window opens in seconds on a question thousands of lines long")
            if let scroll = RuntimeUpdate.scrollView(in: oldWindow.contentView) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y - 300)); scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05)); oldWindow.contentView?.layoutSubtreeIfNeeded()
            }
            old.follow.attached = false
            await settle(); oldWindow.contentView?.layoutSubtreeIfNeeded()
            let state = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: RuntimeUpdate.state(window: oldWindow, session: old))) as? JSON ?? [:]
            let (new, newWindow) = await open("tail-new", state)
            defer { newWindow.close(); new.close() }
            // Reopened mid-answer, the rows under the answer are estimated from its height: the end sits thousands of points too low.
            if let scroll = RuntimeUpdate.scrollView(in: newWindow.contentView) {
                let estimated = scroll.documentView?.bounds.height ?? 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: estimated - scroll.contentView.bounds.height)); scroll.reflectScrolledClipView(scroll.contentView)
                await settle(); newWindow.contentView?.layoutSubtreeIfNeeded()
                var ink = 0
                if let content = newWindow.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"] { try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent("tail-jump.png")) }
                    let scale = CGFloat(bitmap.pixelsWide) / (newWindow.contentView?.bounds.width ?? 1)
                    for y in stride(from: 0, to: Int(560 * scale), by: 2) {
                        for x in stride(from: Int(300 * scale), to: bitmap.pixelsWide - Int(30 * scale), by: 2) where (bitmap.colorAt(x: x, y: y).map { $0.redComponent + $0.greenComponent + $0.blueComponent < 1.6 } ?? false) { ink += 1 }
                    }
                }
                print("Jumped to the estimated end at \(Int(estimated)) pt: now \(Int(scroll.contentView.bounds.origin.y)) pt of \(Int(scroll.documentView?.bounds.height ?? 0)), \(ink) ink samples in the transcript")
                check(ink > 5000 && new.follow.attached, "a jump past the transcript's last row lands on its end, not on a blank page")
            }
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
        backendSession.event(["method": "item/completed", "params": ["item": ["id": "sm-answer", "type": "agentMessage", "text": "Summing up"]]])
        await backendSession.stop(source: "Escape")
        await settle(); await settle()
        check(backendSession.rows.last?.items.first?.text.contains("Escape") == true, "the stop source stays visible after completion")
        check(backendSession.rows.filter { $0.items.contains { $0.text.contains("Escape") } }.count == 1, "one stop shows one notice")
        check(!backendSession.needsAttention && backendSession.status == "Stopped" && (try state()) == "ready", "Fleet shows a session the user stopped with Escape as ready")
        field.setDraft(NSAttributedString(string: "fix the tpyo")); field.didChangeText()
        await settle()
        _ = try await backend.perform(action: "send", params: ["text": "fix the tpyo", "images": [String](), "draft": draftContent(frontend.draft), "generation": frontend.draftGeneration])
        await settle()
        _ = try await backend.perform(action: "stop", params: ["source": "Escape"])
        await settle(); await settle(); host.layoutSubtreeIfNeeded()
        check(frontend.draft.string == "fix the tpyo" && RuntimeUpdate.composer(in: host)?.string == "fix the tpyo" && !frontend.rows.contains { $0.kind == "user" && ($0.items.first?.data["content"] as? [JSON])?.first?["text"] as? String == "fix the tpyo" },
              "the window gets back a prompt Escape withdrew before any output")
        backendSession.editDraft(NSAttributedString(string: ""))
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
            var completions: [JSON] = []
            claude.event = { message in
                let p = message["params"] as? JSON ?? [:]
                if message["method"] as? String == "item/completed", let item = p["item"] as? JSON { answer = item["text"] as? String ?? answer }
                if message["method"] as? String == "turn/completed" { completions.append(p["turn"] as? JSON ?? [:]) }
            }
            let held = ((try await claude.request("turn/start", ["input": [["type": "text", "text": "WAIT"]]]))["turn"] as? JSON)?["id"] as? String ?? ""
            _ = try await claude.request("turn/steer", ["expectedTurnId": held, "clientUserMessageId": "now", "input": [["type": "text", "text": "do this now"]]])
            let sentNow = try await claude.request("cx/sendNow", ["id": "now"])
            for _ in 0..<200 where completions.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            try await Task.sleep(nanoseconds: 100_000_000)
            check(sentNow["send_now"] as? String == "stopped" && answer == "Now: do this now" && completions.count == 1 && completions.first?["status"] as? String == "completed" && completions.first?["error"] == nil,
                  "send-now on Claude answers the waiting prompt in the same turn, without reporting the cut turn as failed")
        } catch { check(false, "Claude withdrawal: " + error.localizedDescription) }
        do {
            // A main thread that stops answering leaves a report of the callbacks it kept running, as the 11-08 freeze did not.
            // The first eight reports were the Mac's sleep: a wall clock jumps across it, uptime does not. A sleep is simulated by an
            // uptime that stops while the main thread is held, then goes on from where it stopped.
            let real = FreezeTrace.uptime
            nonisolated(unsafe) var frozen: TimeInterval?, lost: TimeInterval = 0
            let clock = NSLock()
            FreezeTrace.uptime = { clock.withLock { frozen ?? real() - lost } }
            defer { FreezeTrace.uptime = real }
            FreezeTrace.folder = directory.appendingPathComponent("freezes")
            FreezeTrace.start(stall: 2, resample: 3)
            func spin(_ seconds: TimeInterval) { let end = Date().addingTimeInterval(seconds); while Date() < end { FreezeTrace.note("stuck callback") } }
            func files() -> [URL] { (try? FileManager.default.contentsOfDirectory(at: FreezeTrace.folder, includingPropertiesForKeys: nil)) ?? [] }
            // A hitch too short for a freeze report still gets a line, told apart by who held the CPU; a stall in the background none.
            let realActive = FreezeTrace.active
            FreezeTrace.hitchLog = directory.appendingPathComponent("hitches.log")
            FreezeTrace.active = { true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            spin(0.8)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            Thread.sleep(forTimeInterval: 0.8)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            FreezeTrace.active = { false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            spin(0.8)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            FreezeTrace.active = realActive
            let hitches = ((try? String(contentsOf: FreezeTrace.hitchLog, encoding: .utf8)) ?? "").split(separator: "\n")
            print("Hitch log: " + hitches.joined(separator: " | "))
            check(hitches.count == 2 && hitches[0].contains("VCX busy") && hitches[1].contains("VCX waiting") && hitches.allSatisfy { $0.contains("top: ") },
                  "a 0.8 s stall in the front app logs one hitch line, busy when spinning, waiting when blocked, none in the background")
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            clock.withLock { frozen = real() - lost }
            spin(5)
            clock.withLock { lost += real() - lost - frozen!; frozen = nil }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            check(files().isEmpty, "a main thread held across a sleep (uptime stopped) writes no freeze report")
            Thread.sleep(forTimeInterval: 5)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            check(files().isEmpty, "a main thread blocked without using the CPU writes no freeze report")
            FreezeTrace.shape(FreezeTrace.Shape(window: "fixture#1", sections: 3, headerOnly: 1, pinned: "abcd1234", viewport: 612, composer: 24, drawn: 5))
            // 16 s: the first report holds the watchdog until its graph dump ends, then it samples again every 3 s.
            let spun = Date()
            spin(16)
            let reports = files()
            func written(_ suffix: String) -> TimeInterval? {
                reports.first { $0.lastPathComponent.hasSuffix(suffix) && !$0.lastPathComponent.contains("-usr1") }
                    .flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }.map { $0.timeIntervalSince(spun) }
            }
            let firstReport = reports.filter { $0.pathExtension == "txt" && !$0.lastPathComponent.contains(".sample") && !$0.lastPathComponent.contains(".graph") }
                .compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }.min().map { $0.timeIntervalSince(spun) }
            let timings = [firstReport, written(".sample.txt"), written(".graph.txt")]
            print("Freeze report written after " + timings.map { $0.map { String(format: "%.1f s", $0) } ?? "never" }.joined(separator: ", ") + " (report, sample, graph)")
            // mac-guard restarts a spinning frontend after 10 s: the whole report must be on disk before, here with a 2 s stall.
            check(timings.allSatisfy { ($0 ?? .infinity) < 7 }, "a freeze report, its sample and its graph dump are written within 7 s of the spin")
            let report = reports.first { $0.pathExtension == "txt" && !$0.lastPathComponent.contains(".sample") && !$0.lastPathComponent.contains(".graph") }.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            print("Freeze report files: " + reports.map(\.lastPathComponent).sorted().joined(separator: ", "))
            check(report.contains("\tstuck callback") && report.contains("fixture#1\t3\t1\tabcd1234\t612\t24\t5") && reports.contains { $0.path.hasSuffix(".sample.txt") },
                  "a main thread spinning in place leaves a report of the callbacks that kept firing, the windows' shapes, and a sample")
            check(reports.contains { $0.path.hasSuffix(".sample-2.txt") }, "a main thread still spinning is sampled again")
            check(reports.contains { $0.path.hasSuffix(".graph.txt") }, "a main thread spinning in place leaves a dump of the SwiftUI attributes it keeps updating")
        }
        do {
            // A question that gets pinned is a new view above the transcript: its first frame already has its settled height.
            for (name, lines) in [("five", 5), ("twenty", 20)] {
                let asking = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("newly-pinned-" + name))
                asking.show(["id": "newly-pinned-" + name, "type": "userMessage", "content": [["type": "text", "text": (1...lines).map { "Line \($0) of a question just pinned" }.joined(separator: "\n")]]])
                guard let item = asking.rows.first?.items.first else { check(false, "a newly pinned question: no item"); continue }
                // Its row in the transcript is drawn first, as it is before it scrolls under the top edge.
                let row = NSHostingView(rootView: UserBubble(item: item, session: asking, collapsible: true).environmentObject(SendAnimation()).frame(width: 1060))
                row.frame = NSRect(x: 0, y: 0, width: 1060, height: 300); row.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let host = NSHostingView(rootView: UserBubble(item: item, session: asking, collapsible: true, pinnedIn: CGSize(width: 1060, height: 800), lifted: true)
                    .environmentObject(SendAnimation()).padding(40).frame(maxHeight: .infinity, alignment: .top).background(Color.white).environment(\.colorScheme, .light))
                host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 1140, height: 420)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.close() }
                func tinted() -> Int {
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let column = Int((tintStart(host, y: 60) + 40) * CGFloat(bitmap.pixelsWide) / host.bounds.width)
                    return (0..<bitmap.pixelsHigh).filter { y in bitmap.colorAt(x: column, y: y).map { $0.blueComponent - $0.greenComponent > 0.02 } ?? false }.count
                }
                let first = tinted()
                await settle()
                let settled = tinted()
                if let destination = ProcessInfo.processInfo.environment["VCX_BUG_RENDER_DIR"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent("newly-pinned-\(name).png"))
                }
                print("Newly pinned \(name)-line question: \(first) tinted rows on its first frame, \(settled) settled")
                check(first > 0 && abs(first - settled) <= 2, "a newly pinned \(name)-line question keeps its height from its first frame")
            }
        }
        print("\(count - failures.count)/\(count) reported-bug checks passed")
        if !failures.isEmpty { throw CXError(message: "Reported-bug checks failed: " + failures.joined(separator: "; ")) }
    }
}

// An offscreen window gets no pointer from the window server: the hosting view is handed the events its tracking area would get.
// y counts from the view's top, as in its render.
@MainActor func pointer(_ view: NSView, at point: NSPoint, entering: Bool = false) {
    let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: point.x, y: view.bounds.height - point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    // As the window's tracking areas do, to the transcript rows' own hosting views too.
    func hosts(_ view: NSView) -> [NSView] { (view is NSHostingView<AnyView> ? [view] : []) + view.subviews.flatMap(hosts) }
    for host in [view] + hosts(view) { entering ? host.mouseEntered(with: event) : host.mouseMoved(with: event) }
}

// A shut question's arrow, in points: the lowest run of coloured rows at its bubble's left, above `below`.
@MainActor func arrowBox(_ view: NSView, left: CGFloat, below: CGFloat = .infinity) -> CGRect? {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width, columns = Int((left + 12) * scale)..<Int((left + 32) * scale)
    func coloured(_ x: Int, _ y: Int) -> Bool {
        bitmap.colorAt(x: x, y: y).map { max($0.redComponent, $0.greenComponent, $0.blueComponent) - min($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.3 } ?? false
    }
    let rows = (0..<min(bitmap.pixelsHigh, Int(min(below, 100_000) * scale))).filter { y in columns.contains { coloured($0, y) } }
    guard let last = rows.last else { return nil }
    var top = last
    while rows.contains(top - 1) { top -= 1 }
    let xs = (top...last).flatMap { y in columns.filter { coloured($0, y) } }
    return CGRect(x: CGFloat(xs.min()!) / scale, y: CGFloat(top) / scale, width: CGFloat(xs.max()! - xs.min()!) / scale, height: CGFloat(last - top) / scale)
}

// Where a bubble's tint starts on a row of the view's render, in points.
@MainActor func tintStart(_ view: NSView, y: CGFloat, from x: CGFloat = 0) -> CGFloat {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
    return CGFloat((Int(x * scale)..<bitmap.pixelsWide).first { column in bitmap.colorAt(x: column, y: Int(y * scale)).map { $0.blueComponent - $0.greenComponent > 0.02 } ?? false } ?? 0) / scale
}
