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
