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
        check(backendSession.rows.last?.items.first?.text.contains("Escape") == true, "the stop source stays visible after completion")
        await settle(); await settle()
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
        print("\(count - failures.count)/\(count) reported-bug checks passed")
        if !failures.isEmpty { throw CXError(message: "Reported-bug checks failed: " + failures.joined(separator: "; ")) }
    }
}
