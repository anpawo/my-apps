import AppKit

@MainActor
enum ClaudeParityCheck {
    static func run() async {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            guard value() else { fputs("FAIL: Claude parity: " + message + "\n", stderr); exit(1) }
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vcx-parity-" + UUID().uuidString)
        let home = root.appendingPathComponent("profile"), project = root.appendingPathComponent("project"), child = project.appendingPathComponent("child")
        func write(_ relative: String, _ text: String) {
            let file = root.appendingPathComponent(relative)
            try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! text.write(to: file, atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        write("profile/CLAUDE.md", "Global rules\n@./shared.md\n`@./inline.md`\n```\n@./fenced.md\n```")
        write("profile/shared.md", "Imported rules\n@./CLAUDE.md")
        write("profile/inline.md", "Do not load inline code")
        write("profile/fenced.md", "Do not load fenced code")
        write("profile/rules/common.md", "Global rule")
        write("project/CLAUDE.md", "Project rules\nSee @./extra.md")
        write("project/extra.md", "Project import")
        write("project/.claude/CLAUDE.md", "Nested configuration")
        write("project/child/CLAUDE.local.md", "Local rules")
        write("project/child/.claude/rules/swift.md", "---\npaths: [\"**/*.swift\"]\n---\nSwift rule")
        write("profile/skills/fixture/SKILL.md", "---\nname: fixture\ndescription: Fixture\n---\nSkill body")
        write("project/.claude/skills/local/SKILL.md", "Local skill")
        write("profile/commands/release.md", "Global command $ARGUMENTS")
        write("project/child/.claude/commands/release.md", "Local command $ARGUMENTS")
        write("project/.claude/commands/team/check.md", "Nested command")
        write("profile/agents/reviewer.md", "Reviewer instructions")
        let bridge = ClaudeCompatibility(cwd: child.path, home: home.path)
        let loaded = bridge.instructions()
        check(loaded.text.contains("Global rules") && loaded.text.contains("Local rules"), "global and ancestor instructions load")
        check(loaded.text.contains("Imported rules") && loaded.text.contains("Project import"), "imports resolve relative to their source")
        check(!loaded.text.contains("Do not load"), "inline and fenced examples do not import files")
        check(loaded.paths.count == Set(loaded.paths).count, "cyclic imports load once")
        check(loaded.text.contains("Global rule") && loaded.text.contains("Swift rule"), "global and scoped rules retain frontmatter")
        check(loaded.text.contains("Claude agent definition:") && !loaded.text.contains("Reviewer instructions"), "agent definitions stay available for on-demand delegation")
        let deduplicated = bridge.instructions(nativeSources: [home.appendingPathComponent("CLAUDE.md").path])
        check(!deduplicated.text.contains("Global rules") && deduplicated.text.contains("Imported rules"), "native instruction files still resolve their Claude imports")
        check(bridge.skillRoots == [home.appendingPathComponent("skills").path, project.appendingPathComponent(".claude/skills").path], "Claude skills register in global-to-project order")
        check(bridge.commands["release"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == child.appendingPathComponent(".claude/commands/release.md").resolvingSymlinksInPath(), "local commands override global commands")
        check(bridge.commands["team:check"] != nil, "command subdirectories preserve namespacing")
        for n in 0...7 { write("profile/depth\(n).md", "Depth \(n)\n@./depth\(n + 1).md") }
        write("profile/CLAUDE.md", "@./depth0.md")
        let deep = bridge.instructions().text
        check(deep.contains("Depth 4") && !deep.contains("Depth 5"), "imports stop after five hops")

        let saved = Settings.shared.value
        defer { Settings.shared.value = saved; Settings.shared.save() }
        let fixtureAccount = Account(id: "codex-default", name: "Fixture", provider: "codex")
        Settings.shared.value.provider = "codex"
        for index in Settings.shared.value.accounts.indices { Settings.shared.value.accounts[index].enabled = Settings.shared.value.accounts[index].id == fixtureAccount.id }
        Settings.shared.save()
        let session = Session(cwd: child.path, stateDirectory: root.appendingPathComponent("state"))
        let connection = FixtureConnection(fixtureAccount)
        session.connectionFactory = { _, _ in connection }
        try! await session.activate(fixtureAccount, resume: nil, keepRows: false)
        await session.refreshCatalog()
        let instructions = connection.opened.last?["developerInstructions"] as? String ?? ""
        check(instructions.contains("Local rules"), "Codex receives project Claude instructions (cwd exists: \(FileManager.default.fileExists(atPath: session.cwd)), source exists: \(FileManager.default.fileExists(atPath: session.cwd + "/CLAUDE.local.md")))")
        check(instructions.contains(ClaudeCompatibility.guidance) && instructions.hasSuffix(session.fleetInstructions), "Codex receives compatibility guidance and Fleet context")
        await session.command("/claude:plan on")
        check(session.planning, "Claude plan command selects native Codex plan mode")
        await session.send(text: "Plan the fixture", images: [])
        let collaboration = connection.sent.last?["collaborationMode"] as? JSON
        check(collaboration?["mode"] as? String == "plan" && (collaboration?["settings"] as? JSON)?["model"] as? String == session.model, "plan mode reaches the model through the Codex protocol")
        for _ in 0..<100 where session.busy { try? await Task.sleep(nanoseconds: 1_000_000) }
        await session.command("/plan off")
        check(!session.planning, "implementation mode can be restored")
        await session.command("/claude:effort high")
        check(session.effort == "high", "Claude effort maps to a supported Codex effort")
        session.providerCommands = [ChatCommand(name: "/release", detail: "Fixture", source: "Claude command", insert: "/codex:skill:release ")]
        session.legacyCommandPaths = ["release": bridge.commands["release"]!]
        await session.command("/claude:skill:release staging")
        let commandText = (connection.sent.last?["input"] as? [JSON])?.first?["text"] as? String ?? ""
        check(commandText.contains(bridge.commands["release"]!) && commandText.hasSuffix("Arguments: staging"), "legacy command invocation carries its source, arguments, and permission rules")
        for _ in 0..<100 where session.busy { try? await Task.sleep(nanoseconds: 1_000_000) }
        session.skillPaths = ["fixture": home.appendingPathComponent("skills/fixture/SKILL.md").path]
        session.providerCommands = [ChatCommand(name: "/fixture", detail: "Fixture", source: "Codex skill", insert: "/codex:skill:fixture ")]
        await session.command("/claude:skill:fixture check")
        let skill = (connection.sent.last?["input"] as? [JSON])?.last
        check(skill?["type"] as? String == "skill" && skill?["name"] as? String == "fixture", "Claude skill names map to native Codex skill payloads")
        for _ in 0..<100 where session.busy { try? await Task.sleep(nanoseconds: 1_000_000) }
        await session.command("/rename Parity fixture")
        check(session.conversationName == "Parity fixture" && session.nativeRecent().first?.title == "Parity fixture" && connection.renamed?["name"] as? String == "Parity fixture", "conversation rename persists in both Codex and the vcx catalog")
        let originalRecord = session.currentConversationID
        session.planning = true
        connection.forkID = "parity-fork"
        await session.command("/claude:fork")
        check(session.currentConversationID != originalRecord && connection.opened.last?["threadId"] as? String == "parity-fork", "fork switches to a separate conversation on the active account")
        check(session.planning && session.conversationName == "Parity fixture", "fork retains plan mode and the source conversation name")
        await session.send(text: "Continue planning", images: [])
        check((connection.sent.last?["collaborationMode"] as? JSON)?["mode"] as? String == "plan", "the first forked turn remains in plan mode")
        for _ in 0..<100 where session.busy { try? await Task.sleep(nanoseconds: 1_000_000) }
        session.updateCommands("/", caret: 1)
        check(session.commandOptions.contains { $0.name == "/memory" && $0.source == "Claude compatibility" }, "Claude aliases remain discoverable on Codex")
        check((connection.opened.first?["dynamicTools"] as? [JSON])?.first?["name"] as? String == "AskUserQuestion", "normal Codex conversations expose the Claude question tool")
        let options: [JSON] = [["label": "First", "description": "First choice"], ["label": "Second", "description": "Second choice"]]
        let question: JSON = ["question": "Which choices?", "header": "Choices", "multiSelect": true, "options": options]
        let call: JSON = ["tool": "AskUserQuestion", "arguments": ["questions": [question]], "threadId": session.threadID ?? "", "callId": "fixture-question-call", "turnId": "fixture-turn"]
        session.event(["id": "question-call", "method": "item/tool/call", "params": call])
        check(session.permissions.count == 1 && session.permissions.first?.method == "item/tool/requestUserInput", "question calls use the existing inline question interface")
        let pending = session.permissions[0]
        let choices = questionAnswers(pending.params["questions"] as! [JSON], text: ["question-0": "Custom"], selections: ["question-0": ["Second", "First"]])
        check(choices["question-0"] == ["First", "Second", "Custom"], "multiple choices retain option order and free-text answers")
        session.answer(pending, result: ["answers": choices.mapValues { ["answers": $0] }])
        let reply = connection.responses.last!
        let replyText = (reply["contentItems"] as? [JSON])?.first?["text"] as? String ?? ""
        check(reply["success"] as? Bool == true && replyText.contains("Custom") && session.permissions.isEmpty, "the user's choices return through the Codex dynamic tool protocol")
        session.event(["id": "cancel-question", "method": "item/tool/call", "params": call])
        session.answer(session.permissions[0], result: ["answers": [:]])
        check(connection.responses.last?["success"] as? Bool == false && session.permissions.isEmpty, "cancellation resolves the tool without inventing an answer")
        var duplicate = call
        duplicate["arguments"] = ["questions": [question, question.merging(["header": "Other choices"]) { _, value in value }]]
        session.event(["id": "duplicate-question", "method": "item/tool/call", "params": duplicate])
        session.answer(session.permissions[0], result: ["answers": ["question-0": ["answers": ["First"]], "question-1": ["answers": ["Second"]]]])
        let duplicateText = (connection.responses.last?["contentItems"] as? [JSON])?.first?["text"] as! String
        let duplicateResult = try! JSONSerialization.jsonObject(with: Data(duplicateText.utf8)) as! JSON
        let duplicateAnswers = duplicateResult["answers"] as! [JSON]
        check(duplicateAnswers.count == 2 && duplicateAnswers.map { $0["id"] as! String } == ["question-0", "question-1"] && duplicateAnswers.last?["header"] as? String == "Other choices", "identically worded questions retain separate identities, headers, and answers")
        var keyed = call
        keyed["arguments"] = ["questions": [question.merging(["multiSelect": false]) { _, value in value }, question.merging(["header": "Other choices"]) { _, value in value }]]
        session.event(["id": "keyed-question", "method": "item/tool/call", "params": keyed])
        check(!session.chooseOption(3) && session.chooseOption(2) && session.questionFlow?.step == 1 && session.permissions.count == 1, "a number picks its option and moves on to the next question")
        check(session.chooseOption(2) && session.chooseOption(1) && session.questionFlow?.step == 1, "numbers toggle choices on a multiple-choice question")
        let keyedStorage = NSTextStorage(), keyedManager = NSLayoutManager(), keyedContainer = NSTextContainer(size: NSSize(width: 600, height: 150))
        keyedStorage.addLayoutManager(keyedManager); keyedManager.addTextContainer(keyedContainer)
        let keyedField = ComposerText(frame: NSRect(x: 0, y: 0, width: 600, height: 24), textContainer: keyedContainer)
        keyedField.heldStorage = keyedStorage; keyedField.session = session
        keyedField.setDraft(NSAttributedString(string: "Also this")); keyedField.submit()
        let keyedText = (connection.responses.last?["contentItems"] as? [JSON])?.first?["text"] as? String ?? ""
        check(session.permissions.isEmpty && session.questionFlow == nil && keyedText.contains(#""answers":["Second"]"#) && keyedText.contains(#""answers":["First","Second","Also this"]"#), "Return in the composer confirms the last question and sends every answer")
        var invalid = call; invalid["arguments"] = ["questions": []]
        session.event(["id": "invalid-question", "method": "item/tool/call", "params": invalid])
        check(connection.responses.last?["success"] as? Bool == false && session.permissions.isEmpty, "malformed question calls fail without blocking the conversation")
        let catalogRequests = connection.catalogRequests
        await session.command("/reload-skills")
        check(connection.catalogRequests > catalogRequests, "reload-skills refreshes the catalog instead of displaying cached entries")
        let savedConversation = session.currentConversationID
        session.close()
        let restored = Session(cwd: child.path, stateDirectory: root.appendingPathComponent("state"))
        restored.connectionFactory = { account, _ in FixtureConnection(account) }
        await restored.connect(resume: savedConversation)
        check(restored.planning && restored.conversationName == "Parity fixture", "saved conversations restore planning and their explicit name")
        restored.close()
        print("\(count) Claude-to-Codex parity checks passed")
    }
}
