import AppKit
import SwiftUI

@MainActor
enum Check {
    static func live(settings: String) async -> Bool {
        var okay = true
        let claude = ClaudeConnection(account: Account(name: "Default Claude", provider: "claude"), cwd: NSTemporaryDirectory())
        do {
            try await claude.start()
            let catalog = try await claude.request("cx/catalog")
            print("Claude subscription: ready; \((catalog["commands"] as? [JSON] ?? []).count) commands; \((catalog["models"] as? [JSON] ?? []).count) models; permission mode: \(catalog["current_permission_mode"] as? String ?? "not reported")")
            let result = try await claude.request("account/rateLimits/read")
            let session = Session(cwd: NSTemporaryDirectory())
            session.updateUsage(result["rateLimits"] as? JSON ?? [:])
            guard !session.usage.isEmpty else { throw CXError(message: "Claude usage is empty.") }
            print("Claude usage: " + session.usage)
        }
        catch { print("Claude subscription: " + error.localizedDescription); okay = false }
        claude.close()
        let codex = RPC()
        do {
            try await codex.start()
            let models = try await codex.request("model/list", ["limit": 100])
            print("Codex subscription and model catalog: \((models["data"] as? [JSON] ?? []).isEmpty ? "empty" : "ready")")
        } catch { print("Codex subscription: " + error.localizedDescription); okay = false }
        codex.close()
        do {
            let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as! JSON
            let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settings))) as! JSON
            let preferences = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: defaults.merging(stored) { _, value in value }))
            let network = try qwenNetwork(preferences)
            defer { network.invalidateAndCancel() }
            guard var parts = URLComponents(string: preferences.qwenURL) else { throw CXError(message: "Invalid Qwen URL.") }
            parts.path = "/api/tags"
            var request = URLRequest(url: parts.url!); request.timeoutInterval = 10
            let (data, response) = try await network.data(for: request)
            let result = try JSONSerialization.jsonObject(with: data) as? JSON ?? [:]
            let names = (result["models"] as? [JSON] ?? []).compactMap { $0["name"] as? String }
            let ready = (response as? HTTPURLResponse)?.statusCode == 200 && names.contains { $0 == preferences.qwenModel || $0 == preferences.qwenModel + ":latest" }
            print("Jarvis Qwen route and text model: \(ready ? "ready" : "unavailable")")
            okay = okay && ready
        } catch { print("Qwen metadata check: " + error.localizedDescription); okay = false }
        return okay
    }

    static func run() async -> Bool {
        do { try await BugCheck.run() }
        catch { fputs(error.localizedDescription + "\n", stderr); return false }
        await ClaudeParityCheck.run()
        do { _ = try await RuntimeCheck.run() }
        catch { fputs(error.localizedDescription + "\n", stderr); return false }
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { count += 1; if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) } }
        do {
            let session = Session(cwd: "/fixture")
            session.model = "gpt-6-astra"; session.effort = "high"
            session.contextLimit = 258400; session.usage = "16% wk - reset 1h"
            check(session.contextLabel == "0% token - 258K", "context capacity rounds to whole thousands")
            session.contextLimit = 258600
            check(session.contextLabel == "0% token - 259K", "context capacity rounds up at half a thousand")
            for width: CGFloat in [300, 540, 840] {
                let host = NSHostingView(rootView: CXView(session: session).statusBar.frame(width: width))
                host.layoutSubtreeIfNeeded()
                let height = host.fittingSize.height
                print("Status bar at \(Int(width)): \(height)pt")
                check(height > 0 && height <= 32, "status bar stays on one line at width \(width)")
            }
        }
        do {
            let view = ActivityDotView()
            view.frame = NSRect(x: 0, y: 0, width: 12, height: 10)
            view.layoutSubtreeIfNeeded()
            view.update(busy: false, reduceMotion: false)
            let dot = view.layer!.sublayers!.first!
            check(dot.backgroundColor == NSColor(readyColor).cgColor, "ready dot matches the light-theme green")
            check(dot.animationKeys()?.isEmpty != false, "offscreen dot does not animate")
            view.setMoving(true)
            check(dot.animationKeys()?.isEmpty != false, "idle dot stays still when visible")
            view.update(busy: true, reduceMotion: false)
            check(dot.backgroundColor == NSColor(accent).cgColor, "thinking dot is purple")
            view.setMoving(true)
            let animation = dot.animation(forKey: "drift") as? CABasicAnimation
            check(animation?.keyPath == "transform.translation.x" && animation?.autoreverses == true && animation?.repeatCount == .infinity, "dot motion uses a repeating compositor animation")
            view.update(busy: false, reduceMotion: false)
            check(dot.animationKeys()?.isEmpty != false, "finished turn stops dot animation")
            view.update(busy: true, reduceMotion: true)
            view.setMoving(true)
            check(dot.animationKeys()?.isEmpty != false, "reduce motion stops dot animation")
        }
        do {
            let short = "| Topic | Details |\n| --- | --- |\n| Opinions | Stable. |\n| Incidents | Increasing. |\n| Public speech | More visible. |"
            let long = short.replacingOccurrences(of: "Stable.", with: String(repeating: "Long-term tolerance can improve while recorded incidents increase. ", count: 8))
            for width: CGFloat in [420, 760, 1120] {
                func height(_ text: String) -> CGFloat {
                    let host = NSHostingView(rootView: MarkdownBody(text: text).frame(width: width))
                    host.layoutSubtreeIfNeeded()
                    return host.fittingSize.height
                }
                let shortHeight = height(short), longHeight = height(long)
                print("Table height at \(width): short \(shortHeight), wrapped \(longHeight)")
                check(longHeight > shortHeight + 100, "wrapped table cells expand their rows at width \(width)")
            }
        }
        do {
            let host = NSHostingView(rootView: ProseView(text: "Open [compare.png](file:///tmp/compare.png) now.\n\n⟶ Next: open [it](file:///tmp/it.png).\n\nNo link here.").frame(width: 500))
            host.layoutSubtreeIfNeeded()
            func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
            var links: Set<String> = []
            for view in textViews(host) {
                let storage = view.textStorage ?? NSTextStorage()
                storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in if let url = value as? URL { links.insert(url.path) } }
                check(view.frame.height >= 15, "a reply link paragraph keeps its height")
            }
            check(links == ["/tmp/compare.png", "/tmp/it.png"], "reply links render in clickable text views")
        }
        func composerLine(_ image: Bool) -> (CGFloat, CGFloat) {
            let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 600, height: 150))
            storage.addLayoutManager(manager); manager.addTextContainer(container)
            let field = ComposerText(frame: NSRect(x: 0, y: 0, width: 600, height: 150), textContainer: container)
            field.heldStorage = storage
            let text = NSMutableAttributedString(string: "Before ")
            if image { text.append(NSAttributedString(attachment: ImageChip(path: "/fixture.png", number: 1))) }
            text.append(NSAttributedString(string: " after"))
            text.addAttributes(field.typingAttributes, range: NSRange(location: 0, length: text.length))
            storage.setAttributedString(text); manager.ensureLayout(for: container)
            return (manager.usedRect(for: container).height, manager.location(forGlyphAt: manager.numberOfGlyphs - 1).y)
        }
        let plainLine = composerLine(false), imageLine = composerLine(true)
        print("Composer line: plain \(plainLine.0)/\(plainLine.1), image \(imageLine.0)/\(imageLine.1)")
        check(abs(plainLine.0 - imageLine.0) < 0.5 && abs(plainLine.1 - imageLine.1) < 0.5, "pasting an image preserves text line height and baseline")
        let typingStorage = NSTextStorage(), typingManager = NSLayoutManager(), typingContainer = NSTextContainer(size: NSSize(width: 600, height: 150))
        typingStorage.addLayoutManager(typingManager); typingManager.addTextContainer(typingContainer)
        let typingField = ComposerText(frame: NSRect(x: 0, y: 0, width: 600, height: 24), textContainer: typingContainer)
        typingField.heldStorage = typingStorage
        let inputWindow = ComposerWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        inputWindow.isReleasedWhenClosed = false
        inputWindow.contentView!.addSubview(typingField)
        var focusRequests = 0
        inputWindow.focusComposer = { focusRequests += 1; inputWindow.makeFirstResponder(typingField) }
        func key(_ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: inputWindow.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        for (code, text) in [(UInt16(49), " "), (36, "\r"), (76, "\u{3}")] {
            inputWindow.makeFirstResponder(nil)
            inputWindow.sendEvent(key(code, text))
            check(inputWindow.firstResponder === typingField && typingField.string.isEmpty, "unfocused key \(code) focuses the composer without inserting or submitting")
        }
        let focusedRequests = focusRequests
        inputWindow.sendEvent(key(49, " "))
        check(typingField.string == " " && focusRequests == focusedRequests, "space edits the already focused composer normally")
        for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            inputWindow.makeFirstResponder(nil)
            inputWindow.sendEvent(key(49, " ", flags: flags))
            check(focusRequests == focusedRequests, "modified space keeps its normal behavior")
        }
        let otherInput = NSTextView(frame: NSRect(x: 0, y: 50, width: 200, height: 24))
        inputWindow.contentView!.addSubview(otherInput)
        inputWindow.makeFirstResponder(otherInput)
        inputWindow.sendEvent(key(49, " "))
        check(inputWindow.firstResponder === otherInput && otherInput.string == " " && focusRequests == focusedRequests, "other text inputs retain space")
        inputWindow.focusComposer = {}; inputWindow.close()
        typingField.setDraft(NSAttributedString(string: ""))
        typingField.insertText("Typed after clearing", replacementRange: NSRange(location: 0, length: 0))
        check((typingField.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .black, "typing after an empty draft remains black")
        typingField.setDraft(NSAttributedString(string: "Restored text", attributes: [.foregroundColor: NSColor.white]))
        check((typingField.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .black, "restored dark-theme drafts use black composer text")
        var follow = FollowState()
        check(follow.attached, "starts attached")
        follow.userScroll(distance: 120); check(!follow.attached, "scroll up detaches")
        follow.userScroll(distance: 0); check(follow.attached, "return to bottom attaches")
        do {
            let notice = Row("notice", []), question = Row("user", []), activity = Row("activity", []), answer = Row("assistant", []), nextQuestion = Row("user", [])
            let sections = conversationSections([notice, question, activity, answer, nextQuestion])
            check(conversationSections([]).isEmpty, "an empty transcript has no pinned question")
            check(sections.count == 3 && sections[0].question == nil && sections[0].rows.map(\.id) == [notice.id], "notices before the first question remain in the transcript")
            check(sections[1].question?.id == question.id && sections[1].rows.map(\.id) == [activity.id, answer.id], "each question heads its actions and answer in order")
            check(sections[2].id == nextQuestion.id && sections[2].rows.isEmpty, "a new unanswered question starts its own stable section")
        }
        check(usageLimit(["error": ["codexErrorInfo": "usageLimitExceeded"]]), "Codex usage limit")
        check(usageLimit(["error": "rate_limit"]), "Claude usage limit")
        check(!usageLimit(["error": "Network unavailable"]), "network failure is not a usage limit")
        check(Item(["id": "tool", "exitCode": 2]).failed, "failed tool counted")
        check(!Item(["id": "tool", "exitCode": 0, "error": NSNull()]).failed, "successful tool")
        let child = Process(), childOutput = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh"); child.arguments = ["-c", "sleep 10 & wait"]
        child.standardOutput = childOutput; child.standardError = FileHandle.nullDevice
        try! child.run()
        check(getpgid(child.processIdentifier) == child.processIdentifier, "tool process has an isolated process group")
        endProcess(child, signal: SIGKILL)
        let killed = await Task.detached { childOutput.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit(); return child.terminationStatus != 0 }.value
        check(killed, "stop terminates the command and its children")
        let blocks = markdownBlocks("Text\n```swift\nlet x = 1\n```\nDone")
        check(blocks.count == 3 && blocks[1].code && blocks[1].language == "swift", "code fences")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vcx-check-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func gitCheck(_ args: [String], at path: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try! process.run(); process.waitUntilExit()
            precondition(process.terminationStatus == 0, "Repository fixture failed")
        }
        let repoPath = directory.appendingPathComponent("atlas").path
        try! FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let repoSession = Session(cwd: repoPath)
        await repoSession.refreshRepository()
        check(repoSession.directoryLabel == repoPath && repoSession.repositoryLabel == "not a repo", "non-repository footer keeps the directory")
        gitCheck(["init", "-b", "main"], at: repoPath)
        await repoSession.refreshRepository()
        check(repoSession.directoryLabel == "atlas" && repoSession.repositoryLabel == "@main - local only", "empty repositories retain their branch")
        try! Data("fixture".utf8).write(to: URL(fileURLWithPath: repoPath + "/file"))
        gitCheck(["add", "file"], at: repoPath)
        gitCheck(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "Fixture"], at: repoPath)
        let remotePath = directory.appendingPathComponent("remote.git").path
        gitCheck(["init", "--bare", remotePath], at: repoPath)
        gitCheck(["remote", "add", "origin", remotePath], at: repoPath)
        gitCheck(["push", "-u", "origin", "main"], at: repoPath)
        await repoSession.refreshRepository()
        check(repoSession.repositoryLabel == "@main - up to date", "pushed repositories show the green state")
        try! Data("changed".utf8).write(to: URL(fileURLWithPath: repoPath + "/file"))
        await repoSession.refreshRepository()
        check(repoSession.repositoryLabel == "@main - uncommitted", "uncommitted changes take priority")
        gitCheck(["add", "file"], at: repoPath)
        gitCheck(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "Change fixture"], at: repoPath)
        await repoSession.refreshRepository()
        check(repoSession.repositoryLabel == "@main - unpushed", "local commits show the amber state")
        let worktreePath = directory.appendingPathComponent("atlas-worktree").path
        gitCheck(["worktree", "add", "--detach", worktreePath], at: repoPath)
        let worktreeSession = Session(cwd: worktreePath)
        await worktreeSession.refreshRepository()
        check(worktreeSession.directoryLabel == "atlas" && worktreeSession.repositoryLabel.hasPrefix("@detached ") && worktreeSession.repositoryStatus.isEmpty, "worktrees use the original repository name and detached status")
        let nestedPath = repoPath + "/inner"
        try! FileManager.default.createDirectory(atPath: nestedPath, withIntermediateDirectories: true)
        gitCheck(["init", "-b", "main"], at: nestedPath)
        let nestedSession = Session(cwd: nestedPath)
        await nestedSession.refreshRepository()
        check(nestedSession.directoryLabel == "atlas/inner", "nested repositories retain the enclosing repository name")
        let profile = directory.appendingPathComponent("claude-profile")
        try! FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: ["effortLevel": "high", "modelSettings": ["claude-opus-5-5": ["effortLevel": "xhigh"]]]).write(to: profile.appendingPathComponent("settings.json"))
        let effortSession = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("effort-state"))
        effortSession.connectionFactory = { account, _ in FixtureConnection(account) }
        try! await effortSession.activate(Account(name: "Effort fixture", provider: "claude", home: profile.path), resume: nil, keepRows: false)
        check(effortSession.effort == nil && effortSession.modelStatusLabel.hasSuffix(" - high"), "fresh Claude sessions display their configured effort without a manual selection")
        try! FileManager.default.createDirectory(at: directory.appendingPathComponent("effort-state"), withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: ["claude-opus-5-5": 1000000]).write(to: directory.appendingPathComponent("effort-state/claude-context-windows.json"))
        effortSession.event(["method": "cx/model", "params": ["model": "claude-opus-5-5"]])
        check(effortSession.modelStatusLabel == "Opus 5.5 - xhigh", "Claude resolved models display per-model effort overrides")
        check(effortSession.contextLabel == "0% token - 1M", "a new Claude session shows its model's remembered window before the first reply, like Claude Code")
        effortSession.models = ["other-model"]
        await effortSession.changeModel("other-model")
        check(effortSession.modelStatusLabel == "Other Model - high", "Claude model changes restore the configured default effort")
        effortSession.contextLimit = 1000000
        await effortSession.changeModel("other-model", effort: "high")
        check(effortSession.contextLimit == 1000000, "Claude effort changes retain reported context capacity")
        effortSession.close()
        let codexDefaults = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("codex-effort-state"))
        codexDefaults.connectionFactory = { account, _ in FixtureConnection(account) }
        try! await codexDefaults.activate(Account(name: "Codex effort fixture", provider: "codex"), resume: nil, keepRows: false)
        await codexDefaults.refreshCatalog()
        check(codexDefaults.modelStatusLabel.hasSuffix(" - high"), "Codex initialization uses its catalog default effort")
        await codexDefaults.changeModel("fixture-model")
        check(codexDefaults.modelStatusLabel.hasSuffix(" - high"), "Codex model changes retain catalog effort when resume omits it")
        codexDefaults.close()
        let fleetSession = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("fleet-state"))
        let presence = FleetPresence(session: fleetSession)
        let presenceFile = fleetSession.stateDirectory.appendingPathComponent("fleet/\(getpid()).json")
        func fleetRecord() -> JSON { try! JSONSerialization.jsonObject(with: Data(contentsOf: presenceFile)) as! JSON }
        check(fleetRecord()["state"] as? String == "fresh", "Fleet publishes an unprompted native window")
        do {
            let fleetSession = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("directory-fleet-state"))
            let presence = FleetPresence(session: fleetSession)
            let file = fleetSession.stateDirectory.appendingPathComponent("fleet/\(getpid()).json")
            func fleetRecord() -> JSON { try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! JSON }
            fleetSession.event(["method": "item/completed", "params": ["item": ["id": "project-command", "type": "commandExecution", "command": "pwd", "cwd": repoPath, "exitCode": 0, "status": "completed"]]])
            presence.publish(fleetSession)
            check(fleetRecord()["cwd"] as? String == repoPath && fleetSession.cwd == repoPath, "successful shell work updates the session and Fleet directory")
            let target = directory.appendingPathComponent("project with spaces").path
            try! FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
            func item(_ command: String, status: String = "completed", exit: Int = 0) -> JSON {
                ["type": "commandExecution", "command": command, "cwd": directory.path, "status": status, "exitCode": exit]
            }
            for command in ["cd '\(target)'", "cd -- \"\(target)\"", "/bin/zsh -lc 'cd \"\(target)\"'", "cd 'project with spaces'"] {
                check(shellDirectory(item(command), current: repoPath, initial: directory.path) == target, "standalone directory changes support shell wrappers, spaces and relative paths")
            }
            for command in ["(cd '\(target)')", "cd '\(target)' && pwd", "echo cd '\(target)'", "cd $(pwd)", "cd '\(target)", "cd /", "cd missing-directory"] {
                check(shellDirectory(item(command), current: repoPath, initial: directory.path) == nil, "temporary, dynamic, invalid and out-of-scope commands do not move the session")
            }
            check(shellDirectory(item("cd '\(target)'", exit: 1), current: repoPath, initial: directory.path) == nil, "failed cd does not change directory")
            check(shellDirectory(item("cd '\(target)'", status: "inProgress"), current: repoPath, initial: directory.path) == nil, "unfinished cd does not change directory")
            check(shellDirectory(item("pwd"), current: repoPath, initial: directory.path) == nil, "default shell directories cannot undo an explicit project selection")
            let snapshotDirectory = fleetSession.nativeDirectory
            fleetSession.event(["method": "item/completed", "params": ["item": item("cd '\(target)'").merging(["id": "cd-project"]) { _, new in new }]])
            presence.publish(fleetSession)
            check(fleetSession.cwd == target && fleetRecord()["cwd"] as? String == target, "Fleet follows a completed standalone cd")
            check(fleetSession.nativeDirectory == snapshotDirectory, "shell directory changes retain the conversation storage location")
            presence.close(); fleetSession.close()
        }
        fleetSession.show(["id": "fleet-user", "type": "userMessage", "sentAt": 123.0, "content": [["type": "text", "text": "Fix the layout"]]])
        fleetSession.busy = true
        presence.publish(fleetSession)
        check(fleetRecord()["state"] as? String == "working" && fleetRecord()["prompt"] as? String == "Fix the layout", "Fleet receives the prompt and live working state")
        try! "Fix Fleet names\n".write(to: fleetSession.fleetContextFile, atomically: true, encoding: .utf8)
        fleetSession.busy = false
        try? await Task.sleep(nanoseconds: 350_000_000)
        check(fleetRecord()["context"] as? String == "Fix Fleet names", "Fleet receives the session-written task context automatically")
        fleetSession.busy = true
        let promptTime = fleetRecord()["lastPromptAt"] as? Double
        fleetSession.permissions = [Permission(rpcID: 1, method: "item/tool/requestUserInput", params: [:])]
        presence.publish(fleetSession)
        check(fleetRecord()["state"] as? String == "waiting", "Fleet approvals take precedence over busy")
        fleetSession.permissions = []; fleetSession.busy = false
        presence.publish(fleetSession)
        check(fleetRecord()["state"] as? String == "ready" && fleetRecord()["lastPromptAt"] as? Double == promptTime, "Fleet completion keeps the prompt timestamp")
        fleetSession.show(["id": "fleet-user", "type": "userMessage", "content": [["type": "text", "text": "Fix the layout"]]])
        presence.publish(fleetSession)
        check(fleetRecord()["lastPromptAt"] as? Double == 123, "backend echoes preserve the original prompt timestamp")
        let restoredItem = Item(fleetSession.rows[0].items[0].data)
        fleetSession.rows = [Row("user", [restoredItem])]
        presence.publish(fleetSession)
        check(fleetRecord()["lastPromptAt"] as? Double == 123, "restoring saved rows does not invent a new Fleet prompt time")
        fleetSession.busy = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        check(fleetRecord()["state"] as? String == "working", "Fleet observes state changes after published values settle")
        let mode = (try! FileManager.default.attributesOfItem(atPath: presenceFile.path))[.posixPermissions] as? Int
        check(mode == 0o600, "Fleet state is private")
        presence.close()
        fleetSession.close()
        check(!FileManager.default.fileExists(atPath: fleetSession.fleetContextFile.deletingLastPathComponent().path), "closing a session removes its private context directory")
        fleetSession.busy = false
        try? await Task.sleep(nanoseconds: 350_000_000)
        check(!FileManager.default.fileExists(atPath: presenceFile.path), "closing a window removes Fleet presence and cancels updates")
        let sourceFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/native_peer.py").path
        let imagePath = directory.appendingPathComponent("screen shot.png").path
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: imagePath))
        let escaped = imagePath.replacingOccurrences(of: " ", with: "\\ ")
        let pieces = pastedPieces("📷 Check this " + escaped)
        check(pieces.contains { if case .image(let path) = $0 { return path == imagePath }; return false }, "escaped paths after emoji become images")
        let draft = NSMutableAttributedString(string: "Look at ")
        draft.append(NSAttributedString(attachment: ImageChip(path: imagePath, number: 1)))
        check(draftContent(draft).count == 2 && draftContent(draft).last?["path"] as? String == imagePath, "draft attachments retain their place")
        let chip = ImageChip(path: imagePath, number: 1)
        let chipLabel = NSAttributedString(string: "[Image #1]", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        check(abs((chip.attachmentCell?.cellSize().width ?? 0) - chipLabel.size().width - 12) < 0.01, "image chips reserve six points on each side without changing message text")
        draft.deleteCharacters(in: NSRange(location: draft.length - 1, length: 1))
        check(draftContent(draft).count == 1, "deleting a chip removes its attachment")
        check((try! agentImage(imagePath)).1 == "image/png", "image type is determined from its contents")
        check(tableCells("| Provider | Status |") == ["Provider", "Status"], "native table cells")
        let fixture = Bundle.main.url(forResource: "native_peer", withExtension: "py")?.path ?? sourceFixture
        let rpc = RPC()
        var notified = false
        rpc.event = { if $0["method"] as? String == "test/event" { notified = true } }
        do {
            try await rpc.start(command: ["python3", fixture, "codex"])
            let result = try await rpc.request("echo", ["hello": "world"])
            check(result["hello"] as? String == "world" && notified, "RPC replies and notifications")
            do { _ = try await rpc.request("fail"); check(false, "RPC error must throw") } catch { check(true, "RPC error") }
            do { _ = try await rpc.request("timeout", [:], timeout: 0.03); check(false, "timeout must throw") } catch { check(true, "RPC timeout") }
        } catch { check(false, "RPC integration: " + error.localizedDescription) }
        rpc.close()
        let account = Account(id: "test", name: "Test", provider: "claude")
        let claude = ClaudeConnection(account: account, cwd: directory.path)
        var claudeText = "", claudeDone = false, claudeCompletions = 0, claudeStarts = 0, claudeMessageIDs: [String] = []
        claude.event = { message in
            let p = message["params"] as? JSON ?? [:]
            if ["item/started", "item/completed"].contains(message["method"] as? String), let item = p["item"] as? JSON, item["type"] as? String == "agentMessage" { claudeMessageIDs.append(item["id"] as? String ?? "") }
            if message["method"] as? String == "item/agentMessage/delta" { claudeText += p["delta"] as? String ?? "" }
            if message["method"] as? String == "turn/completed" { claudeDone = true; claudeCompletions += 1 }
            if message["method"] as? String == "turn/started" { claudeStarts += 1 }
        }
        do {
            try await claude.start(command: ["python3", fixture, "claude"])
            _ = try await claude.request("thread/start", ["developerInstructions": "Fleet fixture instruction"])
            let catalog = try await claude.request("cx/catalog")
            check(catalog["appendedSystemPrompt"] as? String == "Fleet fixture instruction", "Claude receives Fleet instructions through its system prompt argument")
            check((catalog["commands"] as? [JSON])?.first?["name"] as? String == "fixture-skill", "Claude command catalog uses initialize without a model turn")
            check((catalog["mcp_servers"] as? [JSON])?.first?["name"] as? String == "fixture-mcp", "Claude MCP catalog uses control status")
            check((catalog["models"] as? [JSON])?.compactMap { $0["value"] as? String } == ["fixture-claude"] && claude.model == "fixture-claude-1", "Claude resolves the default model and hides the default entry")
            do {
                let aliases = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("alias-state"))
                aliases.applyClaudeCatalog(catalog)
                aliases.model = claude.model
                aliases.showCommands("/model " + aliases.account.provider + " ", preserveDraft: false)
                check(aliases.commandOptions.map(\.name) == ["fixture-claude"] && aliases.commandOptions[aliases.commandSelection].isCurrent, "the model menu highlights the alias of the resolved default model")
            }
            let previousModel = claude.model
            do {
                _ = try await claude.request("thread/resume", ["threadId": claude.thread, "model": "reject-me"])
                check(false, "Claude model rejection must surface")
            } catch { check(claude.model == previousModel && error.localizedDescription.contains("rejected"), "Claude model changes require acknowledgement") }
            _ = try await claude.request("thread/resume", ["threadId": claude.thread, "model": "accepted-model"])
            check(claude.model == "accepted-model", "acknowledged Claude model changes apply")
            _ = try await claude.request("thread/resume", ["threadId": claude.thread, "model": "effort-model", "effort": "high"])
            check(claude.model == "effort-model", "Claude changes model and effort through acknowledged live settings")
            do {
                _ = try await claude.request("thread/resume", ["threadId": claude.thread, "model": "reject-me", "effort": "high"])
                check(false, "Claude must reject invalid live settings")
            } catch { check(claude.model == "effort-model", "rejected Claude settings preserve the model") }
            let started = try await claude.request("turn/start", ["input": [["type": "text", "text": "Hello"]]])
            let turn = (started["turn"] as? JSON)?["id"] as? String ?? ""
            let steered = try await claude.request("turn/steer", ["expectedTurnId": turn, "input": [["type": "text", "text": "Guidance"]]])
            check((steered["turn"] as? JSON)?["id"] as? String == turn, "Claude steering preserves turn ownership")
            for _ in 0..<100 where !claudeDone { try await Task.sleep(nanoseconds: 10_000_000) }
            check(claudeDone && claudeText == "Hello from ClaudeHello from Claude", "Claude streaming protocol")
            check(claudeStarts == 1 && claudeCompletions == 1, "Claude stays busy until queued guidance is answered")
            claude.receive(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "claude-cd", "name": "Bash", "input": ["command": "cd '\(repoPath)'"]]]]])
            claude.receive(["type": "user", "message": ["content": [["tool_use_id": "claude-cd", "content": "", "is_error": false]]]])
            check(claude.cwd == repoPath, "Claude tracks a successful Bash directory change")
            claudeMessageIDs.removeAll()
            claude.receive(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "msg_think"]]])
            claude.receive(["type": "stream_event", "event": ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]]])
            claude.receive(["type": "assistant", "message": ["id": "msg_think", "content": [["type": "text", "text": "Hi"]]]])
            check(claudeMessageIDs == ["msg_think-1", "msg_think-1"], "Claude completes a text that follows a thinking block in its streamed row")
        } catch { check(false, "Claude integration: " + error.localizedDescription) }
        claude.close()
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env"); server.arguments = ["python3", fixture, "http"]; server.standardOutput = output; server.standardError = FileHandle.nullDevice
        do {
            try server.run()
            let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            var preferences = Preferences(); preferences.mode = "ask"; preferences.qwenURL = "http://127.0.0.1:" + port + "/api/chat"
            let qwen = QwenConnection(preferences: preferences)
            var qwenText = "", qwenDone = false
            qwen.event = { message in
                let p = message["params"] as? JSON ?? [:]
                if message["method"] as? String == "item/agentMessage/delta" { qwenText += p["delta"] as? String ?? "" }
                if message["method"] as? String == "turn/completed" { qwenDone = true }
            }
            _ = try await qwen.request("turn/start", ["input": [["type": "text", "text": "Hello"]]])
            for _ in 0..<100 where !qwenDone { try await Task.sleep(nanoseconds: 10_000_000) }
            check(qwenDone && qwenText == "Hello from Qwen", "Qwen HTTP streaming")
            _ = try await qwen.request("thread/start", ["developerInstructions": "Fleet fixture instruction"])
            _ = try await qwen.request("thread/resume", ["threadId": qwen.thread])
            qwenText = ""; qwenDone = false
            _ = try await qwen.request("turn/start", ["input": [["type": "text", "text": "CONTEXT"]]])
            for _ in 0..<100 where !qwenDone { try await Task.sleep(nanoseconds: 10_000_000) }
            check(qwenDone && qwenText.hasSuffix("Fleet fixture instruction"), "Qwen receives Fleet instructions in its outbound system message and retains them on resume")
            qwen.close()
            let tools = QwenConnection(preferences: preferences, cwd: directory.path)
            var approved = false, toolDone = false, toolOutput = ""
            tools.event = { message in
                let p = message["params"] as? JSON ?? [:]
                if let id = message["id"] { approved = true; try? tools.respond(id, ["decision": "accept"]) }
                if let item = p["item"] as? JSON, item["type"] as? String == "commandExecution" { toolOutput = item["aggregatedOutput"] as? String ?? "" }
                if message["method"] as? String == "turn/completed" { toolDone = true }
            }
            _ = try await tools.request("turn/start", ["input": [["type": "text", "text": "TOOLS"]]])
            for _ in 0..<200 where !toolDone { try await Task.sleep(nanoseconds: 10_000_000) }
            check(approved && toolDone && toolOutput == "native-tool-check", "Qwen commands require approval and return their output")
            tools.close()
            preferences.mode = "bypass"
            let bypass = QwenConnection(preferences: preferences, cwd: directory.path)
            var bypassAsked = false, bypassDone = false, bypassOutput = ""
            bypass.event = { message in
                if message["id"] != nil { bypassAsked = true }
                let params = message["params"] as? JSON ?? [:]
                if let item = params["item"] as? JSON { bypassOutput = item["aggregatedOutput"] as? String ?? bypassOutput }
                if message["method"] as? String == "turn/completed" { bypassDone = true }
            }
            _ = try await bypass.request("turn/start", ["input": [["type": "text", "text": "TOOLS"]]])
            for _ in 0..<200 where !bypassDone { try await Task.sleep(nanoseconds: 10_000_000) }
            check(bypassDone && !bypassAsked && bypassOutput == "native-tool-check", "Qwen bypass executes without approval")
            bypassDone = false; bypassOutput = ""
            _ = try await bypass.request("turn/start", ["input": [["type": "text", "text": "DIRECTORY_TOOLS " + repoPath]]])
            for _ in 0..<200 where !bypassDone { try await Task.sleep(nanoseconds: 10_000_000) }
            let reportedDirectory = URL(fileURLWithPath: bypassOutput.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
            check(bypassDone && bypass.cwd == repoPath && reportedDirectory == URL(fileURLWithPath: repoPath).resolvingSymlinksInPath().path, "Qwen runs the next shell command in the selected directory")
            bypass.close()
            Settings.shared.value = preferences; Settings.shared.value.provider = "qwen"; Settings.shared.save()
            let configured = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("qwen-config"))
            await configured.connect(resume: nil)
            await configured.command("/qwen model fixture-new-model")
            await configured.send(text: "MODEL", images: [])
            for _ in 0..<200 where configured.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            check(configured.model == "fixture-new-model" && configured.rows.last?.items.first?.text == "fixture-new-model", "Qwen configuration changes the outbound HTTP model")
            configured.close()
            Settings.shared.value = Preferences(); Settings.shared.save()
        } catch { check(false, "Qwen integration: " + error.localizedDescription) }
        if server.isRunning { server.terminate() }
        Settings.shared.value = Preferences()
        var connections: [String: FixtureConnection] = [:]
        do {
            for (resume, provider) in [("claude:legacy-watcher", "claude"), ("legacy-watcher", "codex")] {
                let restored = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("legacy-" + provider))
                var connection: FixtureConnection?
                restored.connectionFactory = { account, _ in
                    let fixture = FixtureConnection(account); connection = fixture; return fixture
                }
                await restored.connect(resume: resume)
                check(restored.ready && restored.account.provider == provider && connection?.opened.first?["threadId"] as? String == resume,
                      "Watcher legacy resume keeps its original provider and conversation")
                restored.close()
            }
        }
        let session = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
        session.connectionFactory = { account, _ in
            let connection = FixtureConnection(account)
            connection.limit = account.provider == "claude"
            connections[account.id] = connection
            return connection
        }
        await session.connect(resume: nil)
        check(session.ready && session.account.provider == "claude", "Claude is the default")
        check(connections["claude-default"]?.opened.first?["developerInstructions"] as? String == session.fleetInstructions, "native thread creation supplies the session's exact Fleet context path")
        try! "Build feature".write(to: session.fleetContextFile, atomically: true, encoding: .utf8)
        Settings.shared.value.provider = "claude"; Settings.shared.save()
        session.draft = NSAttributedString(string: "Build the feature")
        await session.send(text: "Build the feature", images: [])
        check(session.rows.first { $0.kind == "user" }?.items.first?.data["sentAt"] as? Double != nil, "new prompts carry a timestamp into saved conversation history")
        for _ in 0..<200 where session.busy || session.account.provider != "codex" || connections["codex-default"]?.sent.count != 1 { try? await Task.sleep(nanoseconds: 10_000_000) }
        check(session.account.provider == "codex", "explicit limit falls back to Codex")
        check(session.fleetContext == "Build feature" && (connections["codex-default"]?.opened.first?["developerInstructions"] as? String)?.hasSuffix(session.fleetInstructions) == true, "provider fallback retains context and supplies it to Codex")
        check(!session.rows.contains { $0.kind == "notice" }, "successful fallback stays silent")
        check(session.rows.filter { $0.kind == "user" }.count == 1, "fallback does not duplicate the user message")
        check(connections["codex-default"]?.sent.count == 1, "fallback retries once")
        check((connections["codex-default"]?.sent.first?["input"] as? [JSON])?.first?["text"] as? String != "Build the feature", "handoff includes recent context")
        check(connections["claude-default"]?.closed == true, "only one backend remains active")
        connections["codex-default"]?.failSend = true
        session.draft = NSAttributedString(string: "Keep this draft")
        await session.send(text: "Keep this draft", images: [directory.appendingPathComponent("image.png").path])
        check(session.draft.string == "Keep this draft", "failed sends restore the draft")
        check(!session.busy, "failed sends leave the session usable")
        connections["codex-default"]?.failSend = false
        connections["codex-default"]?.hold = true
        session.draft = NSAttributedString(string: "Wait")
        await session.send(text: "Wait", images: [])
        check(session.busy, "in-progress turn")
        await session.stop()
        check(!session.busy && session.status == "Stopped", "interrupt reaches the backend")
        session.models = ["other-model", "fixture-model"]
        session.modelEfforts = ["other-model": ["low", "high"], "fixture-model": ["low", "high"]]
        session.effort = "high"
        let pickerProvider = Settings.shared.value.provider
        session.statusCommand(session.modelCommand)
        await Task.yield()
        check(session.commandOptions.map(\.name) == session.models, "clicking Model opens the active provider's models")
        check(session.commandOptions[session.commandSelection].name == "fixture-model", "clicking Model highlights the current model")
        check(Settings.shared.value.provider == pickerProvider, "opening the model picker preserves the provider preference")
        session.dismissCommands()
        session.showCommands("/model ")
        check(session.commandOptions.map(\.name) == ["Claude", "Codex", "Qwen"], "model selection lists providers without Auto")
        check(session.commandOptions[session.commandSelection].name == "Codex", "opening model selection highlights the active provider after fallback")
        session.updateCommands("/model c", caret: 8)
        check(session.commandOptions[session.commandSelection].name == "Codex", "typing the model command highlights the active provider")
        session.showCommands("/model codex ", preserveDraft: false)
        check(session.commandOptions.map(\.name) == ["other-model", "fixture-model"], "provider selection leads to models")
        check(session.commandOptions[session.commandSelection].name == "fixture-model", "the current model is highlighted even when it is not first")
        session.updateCommands("/model codex other", caret: 18)
        check(session.commandSelection == 0 && session.commandOptions.first?.name == "other-model", "filtering out the current model selects the first match")
        session.showCommands("/model codex fixture-model ", preserveDraft: false)
        check(session.commandOptions.map(\.name) == ["low", "high"], "model selection leads to supported effort levels")
        check(session.commandOptions[session.commandSelection].name == "high", "keeping the current model highlights its current effort")
        session.modelDefaultEfforts["other-model"] = "high"
        session.showCommands("/model codex other-model ", preserveDraft: false)
        check(session.commandOptions[session.commandSelection].name == "high", "a different model highlights its catalog default effort")
        session.effort = nil
        session.defaultEffort = "high"
        session.showCommands("/model codex fixture-model ", preserveDraft: false)
        check(session.commandOptions.map(\.name) == ["low", "high"], "inherited effort menus contain only concrete levels")
        check(session.commandOptions[session.commandSelection].name == "high", "an inherited effort highlights the provider's configured level")
        session.dismissCommands()
        await session.command("/model codex fixture-model high")
        check(session.effort == "high" && connections["codex-default"]?.opened.last?["effort"] as? String == "high", "confirming an inherited level applies the displayed effort")
        session.dismissCommands()
        await session.command("/model codex fixture-model high")
        check(session.model == "fixture-model" && session.effort == "high", "combined model command applies effort")
        session.draft = NSAttributedString(string: "Another turn")
        await session.send(text: "Another turn", images: [])
        check(connections["codex-default"]?.sent.last?["effort"] as? String == "high", "Codex receives selected effort on the next turn")
        check(session.busy && !session.performingAction, "busy generation starts in thinking state")
        session.event(["method": "item/started", "params": ["item": ["id": "activity-dot", "type": "commandExecution", "status": "inProgress"]]])
        check(session.performingAction, "activity dot detects a running action")
        session.event(["method": "item/completed", "params": ["item": ["id": "activity-dot", "type": "commandExecution", "status": "completed"]]])
        check(!session.performingAction, "completed actions return the dot to thinking")
        await session.command("/model codex fixture-model low")
        check(session.busy && session.effort == "high" && session.pendingModelCommand != nil, "model changes during generation wait without interrupting")
        await session.stop()
        for _ in 0..<100 where session.pendingModelCommand != nil || session.effort != "low" { try? await Task.sleep(nanoseconds: 10_000_000) }
        check(session.effort == "low" && session.pendingModelCommand == nil, "queued model changes apply when the active turn ends")
        await session.command("/settings")
        check(session.showingSettings, "settings opens a dedicated settings view")
        Settings.shared.value.provider = "auto"; Settings.shared.save()
        session.draft = NSAttributedString(string: "Unsent draft")
        session.save()
        let files = try! FileManager.default.contentsOfDirectory(at: session.nativeDirectory, includingPropertiesForKeys: nil)
        check(files.count == 1, "one private conversation snapshot")
        let permissions = try! FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int
        check(permissions == 0o600, "conversation file is private")
        let record = try! JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as! JSON
        check(record["accountId"] as? String == "codex-default", "snapshot tracks the selected account")
        check((record["draft"] as? [JSON])?.first?["text"] as? String == "Unsent draft", "unsent draft is persisted")
        let promptTimes = session.rows.filter { $0.kind == "user" }.compactMap { $0.items.first?.data["sentAt"] as? Double }
        session.close()
        let restored = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
        restored.connectionFactory = { account, _ in FixtureConnection(account) }
        await restored.connect(resume: "last")
        check(restored.ready && restored.draft.string == "Unsent draft", "saved native conversation restores its draft")
        check(restored.rows.filter { $0.kind == "user" }.count == 3, "native history is restored without duplicates")
        check(!promptTimes.isEmpty && restored.rows.filter { $0.kind == "user" }.compactMap { $0.items.first?.data["sentAt"] as? Double } == promptTimes, "saved conversation restores its original prompt times")
        check(restored.effort == "low", "saved conversation restores the selected effort")
        check(restored.fleetContext == "Build feature", "saved conversations restore their session-written Fleet context")
        let secondWindow = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
        secondWindow.connectionFactory = { account, _ in FixtureConnection(account) }
        await secondWindow.connect(resume: "last")
        check(!secondWindow.ready && secondWindow.rows.contains { $0.items.contains { $0.text.contains("already open") } }, "a second window cannot edit the same conversation snapshot")
        restored.draft = NSAttributedString(string: "Newer draft from first window"); restored.save()
        secondWindow.close()
        let latest = try! JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as! JSON
        check((latest["draft"] as? [JSON])?.first?["text"] as? String == "Newer draft from first window", "a rejected second window cannot overwrite the first window’s draft")
        restored.close()
        let reopened = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
        reopened.connectionFactory = { account, _ in FixtureConnection(account) }
        await reopened.connect(resume: "last")
        check(reopened.ready && reopened.draft.string == "Newer draft from first window", "closing a window releases conversation ownership")
        reopened.close()
        do {
            let state = directory.appendingPathComponent("directory-resume")
            let moving = Session(cwd: directory.path, stateDirectory: state)
            moving.connectionFactory = { account, _ in FixtureConnection(account) }
            await moving.connect(resume: nil)
            let conversation = moving.currentConversationID
            moving.event(["method": "item/completed", "params": ["item": ["id": "cd-resume", "type": "commandExecution", "command": "cd '\(repoPath)'", "cwd": directory.path, "exitCode": 0, "status": "completed"]]])
            await moving.send(text: "Keep working", images: [])
            check((moving.rpc as? FixtureConnection)?.sent.last?["cwd"] as? String == repoPath, "the next turn uses the selected project directory")
            check(moving.currentConversationID == conversation && moving.nativeRecent().contains { $0.id == conversation }, "project selection preserves conversation identity and resume discovery")
            moving.close()
            let resumed = Session(cwd: directory.path, stateDirectory: state)
            resumed.connectionFactory = { account, _ in FixtureConnection(account) }
            await resumed.connect(resume: "last")
            check(resumed.ready && resumed.cwd == repoPath && resumed.currentConversationID == conversation, "resume restores the selected working directory and same conversation")
            check((resumed.rpc as? FixtureConnection)?.opened.first?["cwd"] as? String == repoPath, "the resumed backend opens in the selected project")
            resumed.close()
        }
        let envA = agentEnvironment(Account(name: "A", provider: "codex", home: "/tmp/account-a"))
        let envB = agentEnvironment(Account(name: "B", provider: "codex", home: "/tmp/account-b"))
        check(envA["CODEX_HOME"] == "/tmp/account-a" && envB["CODEX_HOME"] == "/tmp/account-b", "account homes stay isolated")
        check(envA["OPENAI_API_KEY"] == nil && envA["ANTHROPIC_API_KEY"] == nil, "subscription mode strips inherited API keys")
        check(Settings.shared.candidates.map(\.provider) == ["claude", "codex", "qwen"], "default provider priority")
        check(try! LaunchOptions(["--cwd", directory.path, "--resume"]).resume == "last", "CLI resume is compatible")
        let settingsA = Settings(), settingsB = Settings()
        settingsB.value.accounts.append(Account(id: "extra", name: "Another Claude", provider: "claude"))
        settingsB.value.provider = "codex"; settingsB.save()
        settingsA.updateLimit(account: "codex-default", reset: Date().timeIntervalSince1970 + 3600)
        let fresh = Settings()
        check(fresh.value.accounts.contains { $0.id == "extra" } && fresh.value.provider == "codex", "stale usage writes preserve account selection from another window")
        check(fresh.value.limits["codex-default"] != nil, "shared limit mutation is retained")
        settingsA.updateLimit(account: "claude-default", reset: 0)
        settingsB.updateLimit(account: "extra", reset: Date().timeIntervalSince1970 + 60)
        check(Settings().value.limits["codex-default"] != nil && Settings().value.limits["extra"] != nil, "independent limit mutations merge")
        Settings.shared.reload(); Settings.shared.value.provider = "auto"; Settings.shared.save()
        var failDestination = true
        let transactional = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("transaction"))
        transactional.connectionFactory = { account, _ in
            let connection = FixtureConnection(account)
            connection.failStart = account.provider == "codex" && failDestination
            return connection
        }
        await transactional.connect(resume: nil)
        try! "Keep task".write(to: transactional.fleetContextFile, atomically: true, encoding: .utf8)
        let originalID = transactional.threadID
        let originalConversation = transactional.currentConversationID
        Settings.shared.value.provider = "codex"; Settings.shared.save()
        Settings.shared.updateLimit(account: "codex-default", reset: 0)
        transactional.draft = NSAttributedString(string: "Keep my work")
        await transactional.send(text: "Keep my work", images: [])
        check(!transactional.ready && transactional.account.provider == "claude" && transactional.threadID == originalID, "failed activation preserves account and thread ownership")
        check(transactional.fleetContext == "Keep task", "failed activation preserves the session's Fleet context")
        transactional.save()
        let transactionFiles = try! FileManager.default.contentsOfDirectory(at: transactional.nativeDirectory, includingPropertiesForKeys: nil)
        let savedTransaction = try! JSONSerialization.jsonObject(with: Data(contentsOf: transactionFiles[0])) as! JSON
        check(savedTransaction["accountId"] as? String == "claude-default" && savedTransaction["threadId"] as? String == originalID, "failed activation cannot corrupt the saved conversation")
        failDestination = false
        await transactional.reconnect()
        check(transactional.ready && transactional.account.provider == "codex" && transactional.threadID == "codex:fixture", "reconnect retries the correct destination without reusing a foreign thread ID")
        check(transactional.currentConversationID == originalConversation && transactional.draft.string == "Keep my work", "recovery keeps the conversation and unsent draft")
        transactional.event(["id": "approval", "method": "item/commandExecution/requestApproval", "params": ["command": "echo example"]])
        transactional.event(["method": "turn/completed", "params": ["turn": ["id": "finished", "status": "interrupted"]]])
        check(transactional.permissions.isEmpty, "interrupted turns clear stale permission requests")
        transactional.close()
        let staleRestore = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("state"))
        var failRestore = true
        staleRestore.connectionFactory = { account, _ in
            let connection = FixtureConnection(account); connection.failStart = failRestore; return connection
        }
        await staleRestore.connect(resume: "last")
        check(!staleRestore.ready, "failed restore remains recoverable")
        failRestore = false
        try! "Previous task".write(to: staleRestore.fleetContextFile, atomically: true, encoding: .utf8)
        await staleRestore.switchThread(nil)
        check(staleRestore.fleetContext.isEmpty, "new conversations clear the previous Fleet task context")
        let newRecord = staleRestore.currentConversationID
        staleRestore.draft = NSAttributedString(string: "Draft in the new conversation")
        staleRestore.event(["method": "cx/disconnected", "params": ["message": "Fixture disconnect"]])
        await staleRestore.reconnect()
        check(staleRestore.ready && staleRestore.currentConversationID == newRecord && staleRestore.draft.string == "Draft in the new conversation", "new conversation clears a failed restore target before reconnect")
        staleRestore.close()

        Settings.shared.value = Preferences(); Settings.shared.save()
        let commands = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("commands"))
        commands.connectionFactory = { account, _ in FixtureConnection(account) }
        check(commands.activeMode == "bypass", "permission mode defaults to bypass")
        await commands.send(text: "/help", images: [])
        check(!commands.ready && commands.rows.last?.items.first?.text.contains("/model") == true, "commands work before a provider is connected")
        commands.updateCommands("/", caret: 1)
        check(commands.commandOptions.contains { $0.name == "/mode" }, "slash opens application command catalog")
        commands.updateCommands("/mode ", caret: 6)
        check(commands.commandOptions.map(\.name) == ["bypass", "ask"], "permission choices autocomplete")
        commands.updateCommands("/answer yes", caret: 11)
        check(commands.commandQuery == nil, "freeform command arguments hide empty completion popup")
        commands.updateCommands("/qwen ", caret: 6)
        commands.chooseCommand(commands.commandOptions[0])
        check(commands.draft.string == "/qwen url " && commands.commandQuery != nil, "freeform settings wait for their value")
        commands.draft = NSAttributedString(string: "Keep this prompt")
        commands.showCommands("/provider ")
        commands.dismissCommands()
        check(commands.draft.string == "Keep this prompt", "sidebar shortcuts preserve existing drafts")
        commands.showCommands("/status")
        await commands.command("/status")
        check(commands.draft.string == "Keep this prompt", "settings commands restore an existing draft")
        await commands.connect(resume: nil)
        check(commands.ready && (commands.rpc as? FixtureConnection)?.opened.first?["approvalPolicy"] as? String == "never" && (commands.rpc as? FixtureConnection)?.opened.first?["sandbox"] as? String == "danger-full-access", "Codex-compatible threads apply bypass, not only the label")
        commands.draft = NSAttributedString(string: "Keep this prompt")
        commands.statusCommand("/mode ")
        commands.chooseCommand(commands.commandOptions[1])
        for _ in 0..<200 where commands.savedCommandDraft != nil || commands.changing { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(commands.activeMode == "ask" && (commands.rpc as? FixtureConnection)?.opened.first?["approvalPolicy"] as? String == "on-request", "footer mode selection executes the permission command without Return")
        check(commands.draft.string == "Keep this prompt" && commands.commandQuery == nil, "footer selection restores the unsent prompt")
        commands.statusCommand("/tokens")
        for _ in 0..<200 where commands.savedCommandDraft != nil { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(commands.draft.string == "Keep this prompt" && commands.rows.last?.items.first?.text.contains("Not reported") == true, "footer token button executes its command and preserves the draft")
        commands.draft = NSAttributedString(string: "")
        commands.statusCommand("/repo")
        for _ in 0..<200 where commands.savedCommandDraft != nil { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(commands.draft.length == 0 && commands.commandQuery == nil, "footer commands leave an empty composer empty")
        commands.draft = NSAttributedString(string: "/mode ask")
        await commands.command("/mode ask")
        check(commands.ready && commands.activeMode == "ask" && (commands.rpc as? FixtureConnection)?.opened.first?["approvalPolicy"] as? String == "on-request", "chat mode change reconnects using the requested policy")
        commands.applyClaudeCatalog(["commands": [["name": "fixture-skill", "description": "Fixture", "aliases": ["fixture-alias"]]], "models": [["value": "fixture-claude"]]])
        commands.updateCommands("/fixture", caret: 8)
        check(commands.commandOptions.count == 2, "provider commands and aliases appear in slash search")
        commands.draft = NSAttributedString(string: "/claude:fixture-skill check")
        await commands.command("/claude:fixture-skill check")
        check(((commands.rpc as? FixtureConnection)?.sent.last?["input"] as? [JSON])?.last?["text"] as? String == "/fixture-skill check", "provider slash commands are forwarded without a vcx formatting prompt")
        for _ in 0..<100 where commands.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        let nextDirectory = directory.appendingPathComponent("next")
        try! FileManager.default.createDirectory(at: nextDirectory, withIntermediateDirectories: true)
        commands.draft = NSAttributedString(string: "/dir " + nextDirectory.path)
        await commands.command("/dir " + nextDirectory.path)
        check(commands.cwd == nextDirectory.path && commands.ready, "chat changes directory and starts a session there")
        commands.close()
        Settings.shared.value = Preferences(); Settings.shared.save()
        let draftsDirectory = directory.appendingPathComponent("draft-switches")
        let first = Session(cwd: directory.path, stateDirectory: draftsDirectory)
        first.connectionFactory = { account, _ in FixtureConnection(account) }
        await first.connect(resume: nil)
        let draftA = NSMutableAttributedString(string: "Draft A ")
        draftA.append(NSAttributedString(attachment: ImageChip(path: imagePath, number: 1)))
        first.draft = draftA; first.save()
        let firstID = first.currentConversationID
        let second = Session(cwd: directory.path, stateDirectory: draftsDirectory)
        second.connectionFactory = { account, _ in FixtureConnection(account) }
        await second.connect(resume: nil)
        let draftB = NSMutableAttributedString(string: "Draft B ")
        draftB.append(NSAttributedString(attachment: ImageChip(path: imagePath, number: 1)))
        second.draft = draftB; second.save()
        let secondID = second.currentConversationID
        second.close()
        first.showCommands("/")
        first.chooseCommand(ChatCommand(name: "/resume", detail: "", insert: "/resume " + secondID))
        await first.command("/resume " + secondID)
        check(first.savedCommandDraft == nil && first.draft.string == draftB.string && draftContent(first.draft).last?["path"] as? String == imagePath, "resume preserves the destination draft and its image")
        func storedDraft(_ id: String) -> [JSON] {
            let file = first.nativeDirectory.appendingPathComponent(String(id.dropFirst(7)) + ".json")
            return ((try! JSONSerialization.jsonObject(with: Data(contentsOf: file))) as! JSON)["draft"] as! [JSON]
        }
        check(storedDraft(firstID).first?["text"] as? String == "Draft A " && storedDraft(secondID).first?["text"] as? String == "Draft B ", "command resume saves each draft only into its own record")
        first.draft = draftA; first.showCommands("/")
        first.applyClaudeCatalog(["commands": [["name": "fixture-skill", "description": "Fixture"]]])
        first.chooseCommand(first.providerCommands[0])
        await first.command("/claude:fixture-skill ")
        check(first.savedCommandDraft == nil && draftContent(first.draft).last?["path"] as? String == imagePath && first.draft.string == draftA.string, "native commands restore a previous text and image draft")
        for _ in 0..<100 where first.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        first.draft = NSAttributedString(string: "New visible draft"); first.save()
        check(storedDraft(secondID).first?["text"] as? String == "New visible draft", "later saves cannot persist a stale command buffer")
        first.draft = NSAttributedString(string: "/review unfinished")
        first.showCommands("/mode "); first.dismissCommands()
        check(first.draft.string == "/review unfinished", "shortcuts preserve slash-prefixed drafts too")
        first.showCommands("/profile broken"); await first.command("/profile broken")
        check(first.draft.string == "/review unfinished" && first.savedCommandDraft == nil, "failed configuration restores the original draft")
        Settings.shared.value.accounts[1].enabled = false; Settings.shared.save()
        await first.command("/provider codex")
        check(Settings.shared.value.provider == "auto" && first.account.provider == "claude", "an unavailable provider is rejected instead of reconnecting the wrong provider")
        await first.command("/qwen proxy socks5://localhost")
        check(Settings.shared.value.qwenProxy.isEmpty && !validQwenProxy("socks5://localhost") && validQwenProxy("socks5://localhost:1055"), "a proxy requires a supported scheme and explicit port")
        check(validQwenProxy("socks5h://localhost:1055"), "Jarvis SOCKS5 hostname-proxy URLs remain compatible")
        let question = Permission(rpcID: "fixture-question", method: "item/tool/requestUserInput", params: ["questions": [["id": "question", "question": "Choose"]]])
        first.permissions.append(question); await first.command("/decline")
        check(first.permissions.isEmpty, "questions can be cancelled through chat")
        first.close()
        Settings.shared.value = Preferences(); Settings.shared.value.provider = "codex"; Settings.shared.save()
        let codexCommands = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("codex-commands"))
        codexCommands.connectionFactory = { account, _ in FixtureConnection(account) }
        await codexCommands.connect(resume: nil)
        do {
            let claudePalette = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("unique-commands"))
            for palette in [codexCommands, claudePalette] {
                palette.providerCommands = [ChatCommand(name: "/MODEL", detail: "Model skill collision", source: "Fixture skill", insert: "/" + palette.account.provider + ":skill:model ")]
                for query in ["/", "/model", "/compact", "/status"] {
                    palette.commandQuery = query
                    let names = palette.commandOptions.map { $0.name.lowercased() }
                    check(Set(names).count == names.count, "command names are unique for \(palette.account.provider) query \(query)")
                }
                palette.commandQuery = "/model"
                check(palette.commandOptions.filter { $0.name.lowercased() == "/model" }.map(\.source) == ["vcx"], "application commands win name collisions")
                palette.commandQuery = "/" + palette.account.provider + ":model"
                check(palette.commandOptions.count == 1 && palette.commandOptions[0].source == palette.account.provider.capitalized, "explicit provider aliases remain accessible")
                palette.commandQuery = "/" + palette.account.provider + ":skill:model"
                check(palette.commandOptions.count == 1 && palette.commandOptions[0].source == "Fixture skill", "namespaced skills remain accessible despite name collisions")
                palette.providerCommands = []; palette.commandQuery = nil
            }
            claudePalette.close()
        }
        do {
            let ranking = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("command-ranking"))
            ranking.providerCommands = [
                ChatCommand(name: "/beeper", detail: "Read SMS", source: "Codex skill", insert: "/codex:skill:beeper "),
                ChatCommand(name: "/smoke", detail: "Run checks", source: "Codex skill", insert: "/codex:skill:smoke "),
                ChatCommand(name: "/sm", detail: "Summarize", source: "Codex skill", insert: "/codex:skill:sm "),
                ChatCommand(name: "/xlsx", detail: "Read .xlsm files", source: "Codex skill", insert: "/codex:skill:xlsx ")
            ]
            for query in ["/sm", "/SM", "/codex:skill:sm"] {
                ranking.updateCommands(query, caret: query.count)
                check(ranking.commandOptions.first?.name == "/sm" && ranking.commandSelection == 0, "exact command names rank before prefixes and description matches: \(query)")
            }
            ranking.updateCommands("/sm", caret: 3)
            check(ranking.commandOptions.map(\.name) == ["/sm", "/smoke", "/beeper", "/xlsx"], "command prefixes rank before description matches without hiding results")
            check(ranking.completeCommand() && ranking.draft.string == "/codex:skill:sm ", "completion inserts the exact skill instead of a description match")
            ranking.updateCommands("/", caret: 1)
            check(Array(ranking.commandOptions.prefix(ranking.appCommands.count)) == ranking.appCommands, "an empty command search preserves catalog order")
            ranking.close()
        }
        codexCommands.providerCommands = [ChatCommand(name: "/fixture", detail: "Fixture skill", source: "Codex skill", insert: "/codex:skill:fixture ")]
        codexCommands.skillPaths = ["fixture": "/fixture/SKILL.md"]
        codexCommands.draft = NSAttributedString(string: "/codex:skill:fixture check")
        await codexCommands.command("/codex:skill:fixture check")
        let skillInput = (codexCommands.rpc as? FixtureConnection)?.sent.last?["input"] as? [JSON] ?? []
        check(skillInput.last?["type"] as? String == "skill" && skillInput.last?["path"] as? String == "/fixture/SKILL.md", "Codex slash skills include a native skill payload")
        for _ in 0..<100 where codexCommands.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        do {
            for provider in ["claude", "codex"] {
                Settings.shared.value.provider = provider; Settings.shared.save()
                let selection = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("skill-enter-" + provider))
                selection.connectionFactory = { account, _ in FixtureConnection(account) }
                await selection.connect(resume: nil)
                check(selection.ready && selection.account.provider == provider, "skill selection fixture connects to \(provider)")
                selection.providerCommands = [ChatCommand(name: "/fixture", detail: "Fixture skill", source: provider, insert: "/" + provider + ":skill:fixture ")]
                selection.skillPaths = ["fixture": "/fixture/SKILL.md"]
                let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 600, height: 150))
                storage.addLayoutManager(manager); manager.addTextContainer(container)
                let field = ComposerText(frame: .zero, textContainer: container)
                field.heldStorage = storage; field.session = selection
                let input = Composer.Coordinator(selection)
                selection.showCommands("/fixt"); field.setDraft(selection.draft)
                check(input.textView(field, doCommandBy: #selector(NSResponder.insertTab(_:))) && (selection.rpc as? FixtureConnection)?.sent.isEmpty == true, "Tab completes a \(provider) skill without sending")
                for query in ["/fixt", "/fixture", "/" + provider + ":skill:fixture"] {
                    selection.showCommands(query, preserveDraft: false); field.setDraft(selection.draft)
                    let before = (selection.rpc as! FixtureConnection).sent.count
                    check(input.textView(field, doCommandBy: #selector(NSResponder.insertNewline(_:))), "Return handles the highlighted \(provider) skill")
                    for _ in 0..<200 where (selection.rpc as! FixtureConnection).sent.count == before || selection.busy { try? await Task.sleep(nanoseconds: 1_000_000) }
                    let sent = (selection.rpc as! FixtureConnection).sent
                    check(sent.count == before + 1, "one Return sends the \(provider) skill: \(query), sent \(sent.count - before)")
                    check(selection.draft.length == 0, "Return clears the \(provider) skill draft: \(query)")
                    check(selection.commandQuery == nil, "Return closes the \(provider) skill popup: \(query)")
                    let content = sent.last?["input"] as? [JSON] ?? []
                    check(content.first?["text"] as? String == (provider == "codex" ? "$fixture" : "/fixture"), "Return forwards the canonical \(provider) skill")
                    if provider == "codex" { check(content.last?["type"] as? String == "skill" && content.last?["path"] as? String == "/fixture/SKILL.md", "Return includes the native Codex skill payload") }
                }
                selection.close()
            }
            Settings.shared.value.provider = "codex"; Settings.shared.save()
        }
        codexCommands.updateCommands("/", caret: 1)
        check(codexCommands.commandOptions.contains { $0.name == "/fork" && $0.source != "Codex terminal" }, "the native Codex catalog exposes implemented fork support")
        let editor = ComposerText(frame: .zero, textContainer: nil)
        editor.session = codexCommands; editor.string = "/"
        let coordinator = Composer.Coordinator(codexCommands)
        check(coordinator.textView(editor, doCommandBy: #selector(NSResponder.moveDown(_:))) && codexCommands.commandSelection == 1, "composer arrow keys navigate completion")
        check(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))) && codexCommands.draft.string == "/account ", "composer Tab completes without sending")
        check(coordinator.textView(editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))) && codexCommands.commandQuery == nil, "composer Escape dismisses completion")
        codexCommands.editDraft(NSAttributedString(string: ""))
        codexCommands.rows = [Row("user", [Item(["content": [["type": "text", "text": "First prompt"]]])]), Row("user", [Item(["content": [["type": "text", "text": "Latest prompt "], ["type": "localImage", "path": imagePath]]])])]
        check(coordinator.textView(editor, doCommandBy: #selector(NSResponder.moveUp(_:))) && codexCommands.draft.string.hasPrefix("Latest prompt") && draftContent(codexCommands.draft).last?["path"] as? String == imagePath, "Up recalls the latest prompt including images")
        check(codexCommands.movePromptHistory(-1) && codexCommands.draft.string == "First prompt", "Up walks back through prompts")
        check(codexCommands.movePromptHistory(-1) && codexCommands.draft.string == "First prompt", "history stops at the oldest prompt")
        check(codexCommands.movePromptHistory(1) && codexCommands.draft.string.hasPrefix("Latest prompt"), "Down moves toward newer prompts")
        check(coordinator.textView(editor, doCommandBy: #selector(NSResponder.moveDown(_:))) && codexCommands.draft.length == 0, "Down past the latest prompt restores the empty draft")
        check(!codexCommands.movePromptHistory(1), "Down in an empty draft stays native")
        codexCommands.editDraft(NSAttributedString(string: "Unsent text"))
        check(!codexCommands.movePromptHistory(-1), "history does not overwrite a nonempty draft")
        codexCommands.editDraft(NSAttributedString(string: "")); _ = codexCommands.movePromptHistory(-1)
        codexCommands.editDraft(NSAttributedString(string: "Edited recall"))
        check(!codexCommands.movePromptHistory(1), "editing a recalled prompt restores native arrow behavior")
        let entries = [CapabilityItem(name: "zeta", detail: "Inspect UI layout"), CapabilityItem(name: "ui-tweak", detail: "Adjust the interface"), CapabilityItem(name: "build", detail: "Compile")]
        check(capabilityMatches(entries, query: "UI").map(\.name) == ["ui-tweak", "build", "zeta"], "capability search ranks name prefixes before substring matches")
        check(capabilityMatches(entries, query: "inspect layout").map(\.name) == ["zeta"], "capability search matches multiple description terms")
        check(mcpSummary(["name": "Fixture", "runtimeStatus": "ready", "tools": ["read": [:], "write": [:]]]) == "Fixture · ready · Tools: read, write", "MCP popup summaries include available tools")
        codexCommands.model = "claude-opus-5-5"
        check(codexCommands.modelLabel == "Opus 5.5", "sidebar model omits the provider prefix")
        codexCommands.defaultEffort = "medium"
        check(codexCommands.modelStatusLabel == "Opus 5.5 - medium", "footer displays reported default effort")
        codexCommands.effort = "high"
        check(codexCommands.modelStatusLabel == "Opus 5.5 - high", "selected effort appears beside the model")
        codexCommands.event(["method": "thread/tokenUsage/updated", "params": ["tokenUsage": ["last": ["totalTokens": 240000], "modelContextWindow": 1000000]]])
        check(codexCommands.contextLabel == "24% token - 1M", "context matches the Claude Code status line")
        codexCommands.contextLimit = nil
        check(codexCommands.contextLabel == "240,000 tokens", "unreported capacity retains the known token count without a placeholder")
        codexCommands.contextUsed = nil; codexCommands.contextLimit = 1000000
        check(codexCommands.contextLabel == "0% token - 1M", "unreported token usage defaults to zero")
        do {
            let home = directory.appendingPathComponent("codex-context")
            try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let cache: JSON = ["models": [["slug": "fixture-model", "context_window": 500000, "effective_context_window_percent": 95] as JSON, ["slug": "other-model", "context_window": 1000000, "effective_context_window_percent": 95] as JSON]]
            try! JSONSerialization.data(withJSONObject: cache).write(to: home.appendingPathComponent("models_cache.json"))
            check(codexContextWindow(model: "fixture-model", home: home.path) == 475000, "Codex capacity uses the catalog and its effective context percentage")
            check(codexContextWindow(model: "fixture-model", home: home.path, configured: 1000000) == 950000, "configured Codex capacity overrides the catalog size")
            check(codexContextWindow(model: "unknown", home: home.path) == nil, "unknown models do not borrow another capacity")
            check(codexContextWindow(model: "fixture-model", home: directory.path) == nil, "missing catalogs do not invent capacity")
            let contextSession = Session(cwd: directory.path, stateDirectory: home.appendingPathComponent("state"))
            contextSession.connectionFactory = { account, _ in FixtureConnection(account) }
            let savedAccounts = Settings.shared.value.accounts
            Settings.shared.value.accounts = [Account(id: "codex-context", name: "Fixture", provider: "codex", home: home.path)]
            await contextSession.connect(resume: nil)
            check(contextSession.contextLabel == "0% token - 475K", "Codex capacity is available before the first turn")
            contextSession.models.append("other-model")
            (contextSession.rpc as? FixtureConnection)?.contextDuringConfig = 900000
            await contextSession.changeModel("other-model")
            check(contextSession.contextLimit == 900000, "live capacity arriving during config lookup takes precedence over cached metadata")
            (contextSession.rpc as? FixtureConnection)?.contextDuringConfig = nil
            (contextSession.rpc as? FixtureConnection)?.contextDuringResume = 800000
            await contextSession.changeModel("fixture-model")
            check(contextSession.contextLimit == 800000, "live capacity arriving during model resume takes precedence over cached metadata")
            (contextSession.rpc as? FixtureConnection)?.contextDuringResume = nil
            await contextSession.changeModel("fixture-model", effort: "high")
            check(contextSession.contextLimit == 800000, "Codex effort-only changes preserve live capacity")
            (contextSession.rpc as? FixtureConnection)?.failResume = true
            await contextSession.changeModel("other-model")
            check(contextSession.model == "fixture-model" && contextSession.contextLimit == 800000, "failed model switches restore the previous capacity")
            contextSession.close()
            Settings.shared.value.accounts = savedAccounts
        }
        let claudeContext = ClaudeConnection(account: Account(name: "Fixture", provider: "claude"), cwd: directory.path)
        let usageDisplay = Session(cwd: directory.path)
        claudeContext.usageReader = { account in
            guard account.name == "Fixture" else { throw CXError(message: "Incorrect usage profile") }
            return ["five_hour": NSNull(), "seven_day": ["utilization": 100.0, "resets_at": "2099-11-04T00:59:59.934184+00:00"]]
        }
        do {
            let result = try await claudeContext.request("account/rateLimits/read")
            let rate = result["rateLimits"] as? JSON ?? [:]
            usageDisplay.updateUsage(rate)
            check(usageDisplay.usagePercent == 100, "footer color follows the exhausted weekly quota")
            check(usageDisplay.usage == "100% wk - reset Wed 1h59", "weekly reset shows Paris time without a leading hour zero")
            check((rate["secondary"] as? JSON)?["resetsAt"] as? Double != nil, "Claude fractional reset timestamps are parsed")
            usageDisplay.updateUsage(["primary": ["usedPercent": 10.0, "windowDurationMins": 10080, "resetsAt": ISO8601DateFormatter().date(from: "2099-07-04T16:59:59Z")!.timeIntervalSince1970] as JSON])
            check(usageDisplay.usage == "10% wk - reset Sat 18h59", "weekly reset follows Paris daylight saving time")
            usageDisplay.updateUsage(["primary": ["usedPercent": 20.0, "windowDurationMins": 10080, "resetsAt": ISO8601DateFormatter().date(from: "2099-11-04T17:00:00Z")!.timeIntervalSince1970] as JSON])
            check(usageDisplay.usage == "20% wk - reset Wed 18h00", "evening weekly reset retains both hour digits")
            usageDisplay.rpc = claudeContext; usageDisplay.ready = true
            await usageDisplay.refreshUsage()
            check(usageDisplay.usage.hasPrefix("100% wk - reset "), "session refresh reads Claude usage before a turn")
            usageDisplay.updateUsage(["primary": ["usedPercent": 25.0, "windowDurationMins": 1440] as JSON, "secondary": ["usedPercent": 40.0, "windowDurationMins": 10080] as JSON])
            check(usageDisplay.usagePercent == 40, "footer color follows the most depleted quota")
            check(usageDisplay.usage == "25% 1d - 40% wk", "reported daily and weekly windows retain their units")
            usageDisplay.updateUsage(["primary": ["usedPercent": 18.0, "windowDurationMins": 300, "resetsAt": Date().timeIntervalSince1970 + 10230] as JSON, "secondary": ["usedPercent": 32.0, "windowDurationMins": 10080] as JSON])
            check(usageDisplay.usage == "18% usage - reset 2h50m - 32% wk", "active usage matches Claude Code wording and compact countdown")
            claudeContext.usageReader = { _ in [:] }
            do { _ = try await claudeContext.request("account/rateLimits/read"); check(false, "missing Claude usage must fail explicitly") } catch { check(true, "missing Claude usage is not silently empty") }
            await usageDisplay.refreshUsage()
            check(usageDisplay.usage == "Usage unavailable", "failed usage refresh stays explicit without disconnecting")
            check(usageDisplay.usagePercent == nil && !usageDisplay.usageLoading, "unavailable usage clears the old quota color and loading indicator")
        } catch { check(false, "Claude usage: " + error.localizedDescription) }
        claudeContext.event = { message in
            var message = message, params = message["params"] as? JSON ?? [:]
            params.removeValue(forKey: "threadId"); message["params"] = params
            codexCommands.event(message)
        }
        claudeContext.receive(["type": "assistant", "message": ["model": "fixture-served", "usage": ["input_tokens": 100, "cache_read_input_tokens": 200000, "cache_creation_input_tokens": 3000, "output_tokens": 500]]])
        claudeContext.receive(["type": "result", "modelUsage": ["fixture-served": ["contextWindow": 1000000]]])
        check(codexCommands.contextUsed == 203100 && codexCommands.contextLabel == "20% token - 1M", "Claude context counts the last message's input and cached tokens like Claude Code, under the model that served it")
        do {
            let fresh = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("codex-commands"))
            fresh.event(["method": "cx/context", "params": ["used": 50000, "model": "fixture-served"]])
            check(fresh.contextLabel == "5% token - 1M", "a new Claude session shows the remembered window before its first turn ends")
        }
        codexCommands.applyClaudeCatalog(["commands": [["name": "fixture-skill", "description": "Fixture skill description"]]])
        check(codexCommands.capabilityItems("Skills").first?.detail == "Fixture skill description", "skill popups retain provider descriptions")
        codexCommands.hooks = [hookSummary(["command": "python3 /private/hooks/check.py", "trustStatus": "trusted"], event: "PreToolUse"), hookSummary(["command": "bash /private/hooks/verify.sh", "enabled": false], event: "PreToolUse")]
        check(codexCommands.capabilityItems("Hooks").count == 2 && codexCommands.capabilityItems("Hooks")[0].detail.contains("before") && Set(codexCommands.capabilityItems("Hooks").map(\.id)).count == 2, "hook popups retain separate registrations with descriptions")
        check(codexCommands.capabilityItems("Hooks").map(\.name) == ["check.py", "verify.sh"] && codexCommands.hooks[0].contains("trusted") && codexCommands.hooks[1].contains("disabled") && !codexCommands.hooks.joined().contains("/private"), "hook summaries show script names and states without command paths")
        check(hookSummary(["handlerType": "prompt", "statusMessage": "Check formatting"], event: "Stop", matcher: "Bash").contains("Check formatting · Matches: Bash"), "hook summaries preserve provider descriptions and matchers")
        codexCommands.hooks.append(hookSummary(["command": "python3 /private/hooks/check.py", "trustStatus": "trusted"], event: "PostToolUse"))
        let groupedHooks = codexCommands.capabilityItems("Hooks")
        check(groupedHooks.count == 2 && groupedHooks[0].detail.contains("PreToolUse") && groupedHooks[0].detail.contains("PostToolUse"), "repeated hooks share one card while retaining each registration")
        check(capabilityMatches(groupedHooks, query: "PostToolUse").map(\.name) == ["check.py"], "grouped hook search includes every registration")
        check(!groupedHooks[0].detail.contains("trusted") && groupedHooks[1].detail.contains("disabled"), "hook cards omit trusted while preserving disabled status and descriptions")
        do {
            let usageState = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("usage-loading"))
            check(usageState.usageLoading, "usage starts with a loading indicator")
            let mirror = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("usage-mirror"))
            mirror.applyRuntimeMetadata(usageState.runtimeMetadata())
            check(mirror.usageLoading, "runtime metadata carries pending usage to the frontend")
            usageState.updateUsage([:])
            check(!usageState.usageLoading && usageState.usage.isEmpty, "an empty usage response stops loading and remains not reported")
            mirror.applyRuntimeMetadata(usageState.runtimeMetadata())
            check(!mirror.usageLoading, "runtime metadata clears the frontend loading indicator")
        }
        do {
            let animation = SendAnimation()
            let origin = CGRect(x: 170, y: 700, width: 900, height: 54)
            let target = CGRect(x: 700, y: 500, width: 370, height: 48)
            let old = Row("user", [Item(["id": "old", "content": [["type": "text", "text": "Send this"]]])])
            let new = Row("user", [Item(["id": "new", "content": [["type": "text", "text": "Send this"]]])])
            animation.update(frames: ["composer": origin], rows: [old], reduceMotion: false)
            animation.prepare(text: "Send this", images: [], rows: [old])
            animation.update(frames: ["composer": origin, "old": target], rows: [old], reduceMotion: false)
            check(animation.flight == nil, "existing identical messages do not animate on submission")
            animation.update(frames: ["composer": origin, "new": target], rows: [old, new], reduceMotion: false)
            check(animation.flight?.item.id == "new" && animation.flight?.origin == origin && animation.flight?.destination == target, "accepted messages animate from the composer to their measured bubble")
            animation.update(frames: ["composer": origin], rows: [old], reduceMotion: false)
            check(animation.flight == nil, "failed sends remove the moving bubble")
            animation.prepare(text: "Send this", images: [], rows: [old])
            animation.update(frames: ["composer": origin, "new": target], rows: [old, new], reduceMotion: true)
            check(animation.flight == nil, "Reduce Motion skips the send flight")
        }
        do {
            let submission = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("send-animation"))
            submission.connectionFactory = { account, _ in FixtureConnection(account) }
            await submission.connect(resume: nil)
            let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 600, height: 150))
            storage.addLayoutManager(manager); manager.addTextContainer(container)
            let field = ComposerText(frame: .zero, textContainer: container)
            field.heldStorage = storage; field.session = submission
            var prepared = false
            field.willSubmit = { text, images, _ in prepared = text == "Animate this message" && images.isEmpty }
            submission.editDraft(NSAttributedString(string: "Animate this message")); field.setDraft(submission.draft)
            let input = Composer.Coordinator(submission)
            check(input.textView(field, doCommandBy: #selector(NSResponder.insertNewline(_:))) && prepared, "Return prepares the composer morph before sending")
            for _ in 0..<200 where submission.rows.allSatisfy({ $0.kind != "user" }) { try? await Task.sleep(nanoseconds: 1_000_000) }
            check(submission.rows.contains { $0.kind == "user" } && submission.draft.length == 0, "the animated Return path still sends and clears the accepted draft")
            submission.close()
        }
        codexCommands.close()
        Settings.shared.value = Preferences(); Settings.shared.save()
        let delayed = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("delayed-commands"))
        delayed.connectionFactory = { account, _ in let fixture = FixtureConnection(account); fixture.sendDelay = 100_000_000; return fixture }
        await delayed.connect(resume: nil)
        delayed.applyClaudeCatalog(["commands": [["name": "fixture-skill", "description": "Fixture"]]])
        delayed.draft = draftA; delayed.showCommands("/"); delayed.chooseCommand(delayed.providerCommands[0])
        let pendingCommand = Task { await delayed.command("/claude:skill:fixture-skill ") }
        for _ in 0..<100 where (delayed.rpc as? FixtureConnection)?.sent.isEmpty != false { try? await Task.sleep(nanoseconds: 1_000_000) }
        delayed.editDraft(NSAttributedString(string: "/review new pending draft"))
        delayed.updateCommands(delayed.draft.string, caret: delayed.draft.length)
        await pendingCommand.value
        check(delayed.savedCommandDraft == nil && delayed.draft.string.contains("Draft A") && delayed.draft.string.contains("/review new pending draft") && draftContent(delayed.draft).contains { $0["path"] as? String == imagePath }, "new slash input during native dispatch preserves both drafts and attachments")
        for _ in 0..<100 where delayed.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        delayed.draft = draftA; delayed.showCommands("/")
        delayed.editDraft(NSAttributedString(string: "Normal replacement"))
        delayed.updateCommands(delayed.draft.string, caret: delayed.draft.length)
        check(delayed.savedCommandDraft == nil && delayed.draft.string.contains("Normal replacement") && delayed.draft.string.contains("Draft A"), "abandoning command mode restores the buffer visibly and clears it")
        for source in ["/claude:compact", "/vcx:compact", "/claude:review pending changes"] {
            delayed.draft = NSAttributedString(string: source)
            await delayed.command(source)
            let canonical = source.replacingOccurrences(of: "/claude:", with: "/").replacingOccurrences(of: "/vcx:", with: "/")
            check(((delayed.rpc as? FixtureConnection)?.sent.last?["input"] as? [JSON])?.last?["text"] as? String == canonical, "scoped Claude commands forward the canonical verb")
            for _ in 0..<100 where delayed.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        delayed.close()
        let destinationText = storedDraft(secondID).compactMap { $0["text"] as? String }.joined()
        let transitions = Session(cwd: directory.path, stateDirectory: draftsDirectory)
        var transitionDelay: UInt64 = 0, transitionFail = false
        transitions.connectionFactory = { account, _ in
            let fixture = FixtureConnection(account); fixture.startDelay = transitionDelay; fixture.failStart = transitionFail; return fixture
        }
        await transitions.connect(resume: nil)
        transitions.draft = draftA
        transitionDelay = 100_000_000
        let typedWhileConnecting = NSMutableAttributedString(string: "Typed while connecting ")
        typedWhileConnecting.append(NSAttributedString(attachment: ImageChip(path: imagePath, number: 1)))
        let pendingImagePath = directory.appendingPathComponent("attached during resume.png").path
        try! FileManager.default.copyItem(atPath: imagePath, toPath: pendingImagePath)
        for operation in ["resume", "failed-resume", "failed-directory"] {
            transitionFail = operation != "resume"
            transitions.draft = draftA; transitions.showCommands("/")
            let previousConversation = transitions.currentConversationID
            let source = operation == "failed-directory" ? "/dir " + nextDirectory.path : "/resume " + secondID
            transitions.chooseCommand(ChatCommand(name: "/resume", detail: "", insert: source))
            let pendingTransition = Task { await transitions.command(source) }
            for _ in 0..<100 where (transitions.rpc as? FixtureConnection)?.startDelay != transitionDelay { try? await Task.sleep(nanoseconds: 1_000_000) }
            try? await Task.sleep(nanoseconds: 10_000_000)
            check(transitions.changing, "connection startup keeps transitions serialized")
            let connection = transitions.rpc
            await transitions.command("/provider qwen")
            check(transitions.rpc === connection && Settings.shared.value.provider == "auto", "a second provider transition cannot replace a starting connection")
            if operation == "resume" { await transitions.command("/attach " + pendingImagePath) }
            else { transitions.editDraft(typedWhileConnecting) }
            await pendingTransition.value
            let expectedImagePath = operation == "resume" ? pendingImagePath : imagePath
            check((operation == "resume" || transitions.draft.string.contains("Typed while connecting")) && draftContent(transitions.draft).contains { $0["path"] as? String == expectedImagePath }, "\(operation) preserves text and images entered during connection")
            if operation == "resume" { check(!destinationText.isEmpty && transitions.draft.string.hasPrefix(destinationText), "successful resume merges the destination draft with pending edits") }
            else { check(transitions.draft.string.contains("Draft A"), "\(operation) retains the original draft when rolling back") }
            transitionFail = false
            await transitions.reconnect()
            if operation == "failed-directory" { check(transitions.currentConversationID == previousConversation && transitions.cwd == directory.path, "failed directory changes reconnect to the original record and directory") }
        }
        transitions.close()
        let listing = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("delayed-list"))
        listing.connectionFactory = { account, _ in FixtureConnection(account) }
        await listing.connect(resume: nil)
        let listingConnection = listing.rpc as! FixtureConnection
        listingConnection.catalogDelay = 100_000_000
        let previousCatalogRequests = listingConnection.catalogRequests
        listing.draft = draftA; listing.showCommands("/resume")
        let pendingListing = Task { await listing.command("/resume") }
        for _ in 0..<100 where listingConnection.catalogRequests == previousCatalogRequests { try? await Task.sleep(nanoseconds: 1_000_000) }
        listing.editDraft(typedWhileConnecting)
        listing.updateCommands(listing.draft.string, caret: listing.draft.length)
        await pendingListing.value
        check(listing.savedCommandDraft == nil && listing.draft.string.contains("Typed while connecting") && draftContent(listing.draft).contains { $0["path"] as? String == imagePath }, "resume listing keeps text and images entered while catalog refreshes")
        listing.close()
        Settings.shared.value = Preferences(); Settings.shared.save()
        let unavailable = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("unavailable"))
        unavailable.connectionFactory = { account, _ in
            let connection = FixtureConnection(account)
            connection.failStart = account.provider == "claude"
            return connection
        }
        await unavailable.connect(resume: nil)
        check(unavailable.ready && unavailable.account.provider == "codex" && unavailable.rows.isEmpty, "an unavailable first provider is skipped silently at startup")
        unavailable.draft = draftA
        unavailable.effort = "high"
        unavailable.showCommands("/model ")
        check(unavailable.completeCommand(), "Return accepts the highlighted current provider")
        for _ in 0..<100 where unavailable.commandQuery != "/model codex " { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(unavailable.commandOptions.map(\.name) == ["fixture-model"], "choosing a provider opens its model menu immediately")
        check(unavailable.completeCommand(), "Return accepts the highlighted current model")
        for _ in 0..<100 where unavailable.commandQuery != "/model codex fixture-model " { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(unavailable.commandOptions.map(\.name) == ["low", "high"], "choosing a model opens its effort menu immediately")
        check(unavailable.commandOptions[unavailable.commandSelection].name == "high", "provider and model navigation retains the selected effort")
        check(unavailable.completeCommand(), "Return accepts the highlighted current effort")
        for _ in 0..<100 where unavailable.savedCommandDraft != nil || unavailable.changing { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(unavailable.effort == "high" && unavailable.draft.isEqual(to: draftA) && unavailable.savedCommandDraft == nil, "finishing model selection restores the original prompt and attachments")
        unavailable.close()
        print("\(count) native checks passed")
        return true
    }
}

@MainActor
enum Render {
    static func run(directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let table = """
        | What we measure | What the data shows |
        | --- | --- |
        | Opinions | Long-term tolerance can improve while recorded incidents increase. These indicators describe different aspects of society and should be assessed separately. |
        | Recorded incidents | Recorded crimes and offences increased in the latest annual reports. Reporting behaviour and recording practices also affect these figures. |
        | Public speech | Public expression can become more openly hostile without every member of society adopting more hostile opinions. This is harder to measure directly. |

        This paragraph must remain below the complete table, with every row readable.
        """
        for width: CGFloat in [420, 760, 1120] {
            write(MarkdownBody(text: table).padding(24).foregroundStyle(.black).background(Color.white), size: CGSize(width: width, height: 720), path: directory + "/table-\(Int(width)).png")
        }
        let session = Session(cwd: "/Users/example/projects/atlas", stateDirectory: URL(fileURLWithPath: directory + "/state"))
        session.ready = true; session.status = "Ready"; session.model = "claude-opus-5-5"; session.providerLabel = "Claude"
        session.contextUsed = 240000; session.contextLimit = 1000000
        session.context = "24% context"; session.usage = "18% usage - reset 2h50m - 32% wk"; session.usageLoading = false; session.tokens = "48,320"
        session.usagePercent = 32
        session.activeMode = "bypass"; session.repository = "atlas"; session.branch = "main"; session.repositoryDirectory = "atlas"; session.repositoryStatus = "up to date"; session.effort = "high"
        session.hooks = [hookSummary(["command": "python3 /hooks/context.py", "statusMessage": "Load project context."], event: "SessionStart"), hookSummary(["command": "python3 /hooks/command-check.py", "trustStatus": "trusted", "statusMessage": "Check commands before execution."], event: "PreToolUse", matcher: "Bash"), hookSummary(["command": "bash /hooks/verify.sh", "enabled": false], event: "PostToolUse")]
        session.skills = ["ponytail", "ui-tweak", "swift-macos", "diagnosing-bugs", "playwright-cli", "writing-style"]
        session.providerCommands = [ChatCommand(name: "/ui-tweak", detail: "Adjust an existing interface and verify the result offscreen.", source: "Claude", insert: "/ui-tweak "), ChatCommand(name: "/ponytail", detail: "Solve the whole task with the smallest complete change.", source: "Claude", insert: "/ponytail ")]
        session.mcp = ["Filesystem · connected · Read and write files in the workspace.", "GitHub · connected · Browse repositories, issues, and pull requests."]
        session.instructions = ["AGENTS.md", "CLAUDE.md"]
        write(SettingsPopup(session: session), size: CGSize(width: 480, height: 520), path: directory + "/settings.png")
        write(CapabilityPopup(session: session, title: "Skills"), size: CGSize(width: 380, height: 440), path: directory + "/skills.png")
        write(CapabilityPopup(session: session, title: "Hooks"), size: CGSize(width: 380, height: 440), path: directory + "/hooks.png")
        write(CapabilityPopup(session: session, title: "MCP"), size: CGSize(width: 380, height: 440), path: directory + "/mcp.png")
        write(CapabilityPopup(session: session, title: "Instructions"), size: CGSize(width: 380, height: 440), path: directory + "/instructions.png")
        session.hooks.append(hookSummary(["command": "python3 /hooks/command-check.py", "trustStatus": "trusted"], event: "PostToolUse"))
        write(CapabilityPopup(session: session, title: "Hooks"), size: CGSize(width: 380, height: 440), path: directory + "/grouped-hooks.png")
        let catalogHooks = session.hooks
        session.hooks = ["PreToolUse", "PermissionRequest", "PostToolUse", "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop"].map { hookSummary(["command": "python3 /hooks/session-state.py", "trustStatus": "trusted"], event: $0) }
        write(CapabilityPopup(session: session, title: "Hooks"), size: CGSize(width: 380, height: 440), path: directory + "/compact-hooks.png")
        session.hooks = catalogHooks
        session.recent = [Recent(id: "1", title: "Build a clearer workspace"), Recent(id: "2", title: "Review the authentication flow"), Recent(id: "3", title: "Improve image attachments")]
        let image = NSImage(size: NSSize(width: 600, height: 360), flipped: false) { rect in
            NSColor(calibratedRed: 0.22, green: 0.14, blue: 0.38, alpha: 1).setFill(); rect.fill()
            NSColor.systemPink.withAlphaComponent(0.6).setFill(); NSBezierPath(ovalIn: NSRect(x: 350, y: 60, width: 180, height: 180)).fill()
            NSAttributedString(string: "A clearer workspace", attributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.white]).draw(at: NSPoint(x: 35, y: 260))
            return true
        }
        let imagePath = directory + "/sample.png"
        if let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data) { try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: imagePath)) }
        session.show(["id": "user", "type": "userMessage", "content": [["type": "text", "text": "Make the workspace feel like this, with compact image attachments."], ["type": "localImage", "path": imagePath]]])
        session.show(["id": "tool", "type": "commandExecution", "command": "swift build -c release", "status": "completed", "exitCode": 0, "aggregatedOutput": "Build complete."])
        session.show(["id": "answer", "type": "agentMessage", "provider": "Claude", "text": "The workspace now uses native SwiftUI and AppKit, just like Jarvis.\n\n• Images stay in one compact card. Click to preview.\n• Actions stay folded so the conversation stays clear.\n• Scroll up to read; return to the bottom to follow.\n\n```swift\nlet workspace = Workspace(project: \"atlas\")\nworkspace.open()\n```\n\nType / to find commands, change settings, or resume a conversation."])
        let draft = NSMutableAttributedString(string: "Can you refine this? ", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])
        session.draft = NSAttributedString(attributedString: draft)
        write(CXView(session: session), size: CGSize(width: 1120, height: 820), path: directory + "/conversation-no-image.png")
        draft.append(NSAttributedString(attachment: ImageChip(path: imagePath, number: 1)))
        draft.append(NSAttributedString(string: "next characters"))
        session.draft = draft; session.draftRevision += 1
        write(CXView(session: session), size: CGSize(width: 1120, height: 820), path: directory + "/conversation.png")
        session.preview = imagePath
        write(CXView(session: session), size: CGSize(width: 1120, height: 820), path: directory + "/image-popup.png")
        write(CXView(session: session), size: CGSize(width: 780, height: 560), path: directory + "/image-popup-narrow.png")
        session.preview = nil
        session.busy = true
        write(CXView(session: session), size: CGSize(width: 1120, height: 820), path: directory + "/thinking.png")
        session.event(["method": "item/started", "params": ["item": ["id": "active-tool", "type": "commandExecution", "command": "swift build", "status": "inProgress"]]])
        write(CXView(session: session), size: CGSize(width: 1120, height: 820), path: directory + "/action.png")
        session.busy = false
        session.showCommands("/")
        write(CXView(session: session), size: CGSize(width: 1120, height: 820), path: directory + "/commands.png")
        write(CXView(session: session), size: CGSize(width: 780, height: 560), path: directory + "/commands-narrow.png")
        session.commandQuery = nil
        session.permissions = [Permission(rpcID: "question", method: "item/tool/requestUserInput", params: ["questions": [["id": "interface", "question": "Which interface should we keep?", "options": [["label": "Keep it native", "description": "Use SwiftUI and AppKit."], ["label": "Use a web view", "description": "Render the workspace in WebKit."]]]]])]
        session.draft = NSAttributedString(string: "/answer Keep it native", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black]); session.draftRevision += 1
        write(CXView(session: session), size: CGSize(width: 780, height: 560), path: directory + "/question-narrow.png")
        let empty = Session(cwd: "/Users/example/projects/atlas", stateDirectory: URL(fileURLWithPath: directory + "/empty"))
        empty.ready = true; empty.status = "Ready"; empty.model = "Claude"
        write(CXView(session: empty), size: CGSize(width: 860, height: 640), path: directory + "/empty.png")
        write(CXView(session: empty), size: CGSize(width: 1280, height: 820), path: directory + "/empty-wide.png")
        let modelMenu = Session(cwd: "/Users/example/projects/atlas")
        modelMenu.model = "claude-opus-5-5"; modelMenu.effort = "high"
        modelMenu.models = ["claude-haiku-4-5", "claude-opus-5-5"]
        modelMenu.modelEfforts = ["claude-opus-5-5": ["low", "medium", "high"]]
        for (name, query) in [("provider", "/model "), ("model", modelMenu.modelCommand), ("effort", "/model claude claude-opus-5-5 ")] {
            modelMenu.showCommands(query, preserveDraft: false)
            write(CommandPalette(session: modelMenu), size: CGSize(width: 700, height: 260), path: directory + "/selected-" + name + ".png")
        }
        let sticky = Session(cwd: "/Users/example/projects/atlas", stateDirectory: URL(fileURLWithPath: directory + "/sticky"))
        sticky.ready = true; sticky.status = "Ready"
        for turn in 1...2 {
            sticky.show(["id": "question-\(turn)", "type": "userMessage", "content": [["type": "text", "text": "Question \(turn): Keep this question visible while I read its answer."]]])
            sticky.show(["id": "action-\(turn)", "type": "commandExecution", "command": "swift build", "status": "completed", "exitCode": 0])
            sticky.show(["id": "answer-\(turn)", "type": "agentMessage", "text": (1...20).map { "Step \($0) for question \(turn). This answer continues below the question, with enough detail to require scrolling." }.joined(separator: "\n\n")])
        }
        write(CXView(session: sticky), size: CGSize(width: 1120, height: 820), path: directory + "/sticky.png", scrollOffsets: [0, 400, 1000, 0])
        session.permissions = []; session.draft = NSAttributedString(string: ""); session.draftRevision += 1
        session.providerLabel = "Codex"; session.model = "gpt-6.1-sol"; session.effort = "high"
        session.contextUsed = 0; session.contextLimit = 258400
        session.updateUsage(["primary": ["usedPercent": 11.0, "windowDurationMins": 10080, "resetsAt": 1794357394.0] as JSON])
        session.repositoryStatus = "uncommitted"
        write(CXView(session: session), size: CGSize(width: 1120, height: 820), path: directory + "/codex-footer.png")
        write(CXView(session: session), size: CGSize(width: 1280, height: 820), path: directory + "/codex-footer-wide.png")
        write(CXView(session: session), size: CGSize(width: 780, height: 560), path: directory + "/codex-footer-narrow.png")
        write(ProseView(text: "⟶ Your answer is ready.\n\n✓ Done: Changes verified.\n\n⟶ Next: Review the updated layout.").padding(24).background(Color.white), size: CGSize(width: 700, height: 240), path: directory + "/answer-highlights.png")
        write(ProseView(text: "⟶ This highlighted message wraps onto another line and fits its content without an empty line underneath.\n").padding(24).background(Color.white), size: CGSize(width: 500, height: 180), path: directory + "/green-height.png")
        let linkFixture = "Preview the installed logo, fused C and X, white on charcoal black, wrapping onto a second line here."
        write(ProseView(text: [linkFixture, linkFixture.replacingOccurrences(of: "installed logo", with: "[installed logo](file:///tmp/icon.png)"), "⟶ " + linkFixture, "⟶ Next: open " + "[compare.png](file:///tmp/compare.png) and check the C."].joined(separator: "\n\n")).padding(24).background(Color.white), size: CGSize(width: 520, height: 420), path: directory + "/links.png")
        motion(directory: directory, name: "short", text: "Move this message into the chat.")
        motion(directory: directory, name: "wrapped", text: "Keep the exact text from the composer as this longer message lifts into the conversation, changes size, and settles into its final bubble without jumping between lines.")
        motion(directory: directory, name: "tall", text: (1...20).map { "Line \($0) of a pasted text block." }.joined(separator: "\n"), history: true)
        print("Rendered conversation, command popup, narrow layout, inline question, and empty state offscreen")
    }
    static func motion(directory: String, name: String, text: String, history: Bool = false) {
        let session = Session(cwd: "/Users/example/projects/atlas", stateDirectory: URL(fileURLWithPath: directory + "/motion-" + name))
        session.ready = true; session.status = "Ready"
        session.draft = NSAttributedString(string: text)
        if history {
            session.show(["id": "earlier-question", "type": "userMessage", "content": [["type": "text", "text": "Earlier question"]]])
            session.show(["id": "earlier-answer", "type": "agentMessage", "text": (1...40).map { "Line \($0) of an earlier answer." }.joined(separator: "\n\n")])
            session.revision += 1
        }
        let animation = SendAnimation()
        let host = NSHostingView(rootView: CXView(session: session, sending: animation))
        host.appearance = NSAppearance(named: .aqua)
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 780, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded()
        func editor(_ view: NSView) -> ComposerText? {
            if let field = view as? ComposerText { return field }
            return view.subviews.lazy.compactMap { editor($0) }.first
        }
        guard let field = editor(host), let snapshot = field.sendSnapshot() else { fatalError("Composer snapshot is missing") }
        field.willSubmit(text, [], snapshot)
        session.draft = NSAttributedString(string: ""); session.draftRevision += 1
        session.show(["id": "motion-message", "type": "userMessage", "content": [["type": "text", "text": text]]])
        session.revision += 1
        let start = Date()
        var samples: [JSON] = []
        for index in 0..<75 {
            RunLoop.main.run(until: start.addingTimeInterval(Double(index) / 60))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Motion capture failed") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let file = String(format: "/send-%@-%03d.png", name, index)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory + file))
            samples.append(["time": Date().timeIntervalSince(start), "flying": animation.flight != nil, "frame": [animation.frame.minX, animation.frame.minY, animation.frame.width, animation.frame.height], "blend": animation.blend])
        }
        try! JSONSerialization.data(withJSONObject: samples).write(to: URL(fileURLWithPath: directory + "/send-" + name + ".json"))
        precondition(samples.contains { $0["flying"] as? Bool == true }, "Send animation never started")
        precondition(animation.flight == nil, "Send animation did not finish")
    }
    static func write(_ view: some View, size: CGSize, path: String, scrollOffsets: [CGFloat] = []) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded()
        let offsets: [CGFloat?] = scrollOffsets.isEmpty ? [nil] : scrollOffsets.map { $0 }
        for (index, scrollOffset) in offsets.enumerated() {
            if let scrollOffset {
                func findScroll(_ view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView, scroll.frame.width > 300 { return scroll }
                    return view.subviews.lazy.compactMap { findScroll($0) }.first
                }
                guard let scroll = findScroll(host) else { fatalError("Transcript scroll view not found") }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scrollOffset))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded()
                print("Offscreen transcript offset: \(scroll.contentView.bounds.origin.y)")
            }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let output = scrollOffset == nil ? path : (path as NSString).deletingPathExtension + "-\(index).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
    }
}

@MainActor
final class FixtureConnection: Connection {
    var event: (JSON) -> Void = { _ in }
    let account: Account
    var sent: [JSON] = []
    var opened: [JSON] = []
    var forkID: String?
    var renamed: JSON?
    var responses: [JSON] = []
    var sendDelay: UInt64 = 0
    var startDelay: UInt64 = 0
    var catalogDelay: UInt64 = 0
    var catalogRequests = 0
    var contextDuringConfig: Int?
    var contextDuringResume: Int?
    var failResume = false
    var failStart = false
    var failSend = false
    var limit = false
    var hold = false
    var closed = false
    var pendingTurn = "fixture-turn"
    init(_ account: Account) { self.account = account }
    func start(command: [String]?) async throws { if startDelay > 0 { try await Task.sleep(nanoseconds: startDelay) }; if failStart { throw CXError(message: "Expected connection failure") } }
    func request(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON {
        switch method {
        case "thread/fork": return ["thread": ["id": forkID ?? "fixture-fork"]]
        case "thread/name/set": renamed = params; return [:]
        case "config/read":
            if let contextDuringConfig { event(["method": "thread/tokenUsage/updated", "params": ["tokenUsage": ["modelContextWindow": contextDuringConfig]]]) }
            return [:]
        case "thread/start", "thread/resume":
            if method == "thread/resume" {
                if failResume { throw CXError(message: "Expected resume failure") }
                if let contextDuringResume { event(["method": "thread/tokenUsage/updated", "params": ["tokenUsage": ["modelContextWindow": contextDuringResume]]]) }
            }
            opened.append(params); return ["thread": ["id": account.provider + ":fixture"], "model": params["model"] as? String ?? "fixture-model", "approvalPolicy": params["approvalPolicy"] ?? "on-request", "sandbox": ["type": params["sandbox"] as? String == "danger-full-access" ? "dangerFullAccess" : "workspaceWrite"]]
        case "thread/list":
            catalogRequests += 1
            if catalogDelay > 0 { try await Task.sleep(nanoseconds: catalogDelay) }
            return ["data": []]
        case "thread/turns/list": return ["data": []]
        case "model/list": return ["data": [["id": "fixture-model", "defaultReasoningEffort": "high", "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]]]]]
        case "turn/start", "turn/steer":
            sent.append(params)
            if sendDelay > 0 { try await Task.sleep(nanoseconds: sendDelay) }
            if failSend { throw CXError(message: "Expected send failure") }
            event(["method": "turn/started", "params": ["turn": ["id": pendingTurn]]])
            Task { @MainActor in
                await Task.yield()
                if self.limit { self.event(["method": "cx/limit", "params": ["limit": ["resetsAt": Date().timeIntervalSince1970 + 3600]]]) }
                else if !self.hold {
                    self.event(["method": "item/completed", "params": ["item": ["id": UUID().uuidString, "type": "agentMessage", "text": "Finished", "provider": self.account.provider]]])
                    self.event(["method": "turn/completed", "params": ["turn": ["id": self.pendingTurn, "status": "completed"]]])
                }
            }
            return ["turn": ["id": pendingTurn]]
        case "turn/interrupt": event(["method": "turn/completed", "params": ["turn": ["id": pendingTurn, "status": "interrupted"]]]); return [:]
        default: return [:]
        }
    }
    func respond(_ id: Any, _ result: JSON) throws { responses.append(result) }
    func reject(_ id: Any, method: String) throws {}
    func close() { closed = true }
}

struct AppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.25, blue: 0.28), Color(red: 0.09, green: 0.09, blue: 0.11)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            Path { path in
                path.move(to: CGPoint(x: 30, y: 36))
                path.addLine(to: CGPoint(x: 104, y: 224))
                path.addLine(to: CGPoint(x: 178, y: 36))
                path.move(to: CGPoint(x: 310, y: 55))
                path.addCurve(to: CGPoint(x: 242, y: 45), control1: CGPoint(x: 282, y: 22), control2: CGPoint(x: 274, y: 20))
                path.addCurve(to: CGPoint(x: 240, y: 208), control1: CGPoint(x: 199, y: 77), control2: CGPoint(x: 202, y: 169))
                path.addCurve(to: CGPoint(x: 348, y: 202), control1: CGPoint(x: 264, y: 233), control2: CGPoint(x: 322, y: 230))
                path.addLine(to: CGPoint(x: 500, y: 36))
                path.move(to: CGPoint(x: 363, y: 36))
                path.addLine(to: CGPoint(x: 500, y: 224))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 32, lineCap: .round, lineJoin: .round))
            .frame(width: 530, height: 260)
        }
    }
}
