import AppKit

struct ChatCommand: Identifiable, Equatable {
    var name: String
    var detail: String
    var source = "vcx"
    var insert: String
    var isCurrent = false
    var id: String { source + ":" + insert }
}

@MainActor
extension Session {
    var modelCommand: String { "/model " + account.provider + " " }

    var appCommands: [ChatCommand] {
        [
            ("model", "Choose provider, model, and reasoning effort", true),
            ("account", "Use, enable, disable, or rename a subscription account", true),
            ("perms", "Choose bypass / YOLO or ask for approval", true),
            ("dir", "Change the working directory", true),
            ("window", "Open another window, optionally in a directory", false),
            ("new", "Start a new conversation; current work stays saved", false),
            ("clear", "Start a new conversation", false),
            ("resume", "Choose a saved conversation", true),
            ("fork", "Branch the current Codex conversation", false),
            ("rename", "Name the current conversation", true),
            ("plan", "Use Codex plan mode; off returns to implementation", true),
            ("effort", "Set reasoning effort for the active model", true),
            ("reconnect", "Reconnect the current conversation", false),
            ("stop", "Interrupt the current response", false),
            ("settings", "Show configuration and available settings commands", false),
            ("login", "Add a Claude or Codex subscription, or cancel sign-in", true),
            ("profile", "Import an existing account: claude|codex <folder>", true),
            ("qwen", "Configure url, proxy, or model", true),
            ("hooks", "List provider hooks; add reload to refresh", false),
            ("skills", "List provider skills; add reload to refresh", false),
            ("mcp", "List Model Context Protocol servers; add reload to refresh", false),
            ("instructions", "List discovered instruction files", false),
            ("tokens", "Show reported token and context usage", false),
            ("usage", "Refresh subscription usage", false),
            ("repo", "Show repository and branch", false),
            ("status", "Show the current session", false),
            ("details", "Expand or collapse action details", false),
            ("focus", "Expand or collapse action details", false),
            ("attach", "Attach an image by its path", true),
            ("preview", "Preview the last image in the conversation", false),
            ("answer", "Answer the current question from chat", true),
            ("allow", "Approve the pending action", false),
            ("decline", "Decline the pending action", false),
            ("help", "Show commands and keyboard shortcuts", false),
            ("quit", "Save and close this instance", false),
            ("exit", "Save and close this instance", false)
        ].map { name, detail, argument in ChatCommand(name: "/" + name, detail: detail, insert: "/" + name + (argument ? " " : "")) }
    }

    // shortcut: built-ins follow Codex 0.166.0; refresh this catalog when the CLI changes.
    var codexNativeNames: [String] { "model presets daybreak ide permissions keymap vim setup-default-sandbox experimental approve memories skills import hooks review rename new archive delete resume fork worktree app init compact config recap plan voice goal agents side btw copy export raw tui diff mention status daemon warnings cd pwd usage debug-config title statusline theme pets mcp apps plugins logout quit exit feedback ps stop clear subagents cwd pet clean".split(separator: " ").map(String.init) }
    var codexAliases: [String: String] { claudeAliases.merging(["pwd": "dir", "cwd": "dir", "clean": "stop"]) { _, value in value } }
    var codexNativeCommands: [ChatCommand] {
        codexNativeNames.map { name in
            let mapped = codexAliases[name] ?? name
            let available = appCommands.contains { $0.name == "/" + mapped } || ["compact", "review"].contains(mapped)
            return ChatCommand(name: "/" + name, detail: available ? "Use through vcx /" + mapped : "Unavailable in vcx (Codex terminal action)", source: available ? "Codex" : "Codex terminal", insert: "/codex:" + name + (available && ["perms", "model", "resume"].contains(mapped) ? " " : ""))
        }
    }

    // shortcut: CLI reference built-ins are a snapshot; refresh after upstream changes. SDK skills stay live.
    var claudeNativeNames: [String] { "add-dir advisor agents artifact-capabilities artifact-diagramming artifacts auto-mode-setup autocompact autofix-pr background batch branch btw bug cd chrome claude-api claude-in-chrome clear code-review color compact config context copy cost dataviz debug deep-research design design-login design-sync desktop diff doctor effort exit export fast feedback fewer-permission-prompts focus fork goal heapdump help hooks ide import init insights install-github-app install-slack-app keybindings list-agents login logout loop mcp memory mobile model output-style passes permissions plan plugin plugin-authoring powerup pr-comments privacy-settings radio rate-limit-options recap release-notes reload-plugins reload-skills remote-control remote-env rename restart resume review rewind run run-skill-generator sandbox schedule scroll-speed security-review setup-bedrock setup-vertex simplify skill-doctor skills slides stats status statusline stickers stop subtask tasks team-onboarding teleport terminal-setup theme tui ultraplan ultrareview update-config upgrade usage usage-credits verify vim voice web-setup workflow-authoring workflows".split(separator: " ").map(String.init) }
    var claudeAliases: [String: String] { ["permissions": "perms", "config": "settings", "cd": "dir", "context": "tokens", "cost": "tokens", "memory": "instructions", "restart": "reconnect", "reload-skills": "skills", "reload-plugins": "reconnect"] }
    var claudeNativeCommands: [ChatCommand] {
        claudeNativeNames.map { name in
            let mapped = claudeAliases[name] ?? name
            let available = appCommands.contains { $0.name == "/" + mapped } || ["compact", "review"].contains(mapped)
            return ChatCommand(name: "/" + name, detail: available ? "Use through vcx /" + mapped : "Unavailable in vcx (Claude CLI reference)", source: available ? "Claude" : "Claude terminal", insert: "/claude:" + name + (available && ["perms", "model", "resume"].contains(mapped) ? " " : ""))
        }
    }

    var commandCatalog: [ChatCommand] {
        var commands = appCommands + providerCommands
        if account.provider == "codex" {
            commands += codexNativeCommands
            commands += claudeAliases.keys.sorted().filter { !codexNativeNames.contains($0) }.map { ChatCommand(name: "/" + $0, detail: "Claude alias for /" + claudeAliases[$0]!, source: "Claude compatibility", insert: "/" + $0) }
        }
        if account.provider == "claude" { commands += claudeNativeCommands }
        if ["claude", "codex"].contains(account.provider) { commands += [ChatCommand(name: "/compact", detail: "Compact the current context", source: providerLabel, insert: "/compact"), ChatCommand(name: "/review", detail: "Review uncommitted changes or custom instructions", source: providerLabel, insert: "/review ")] }
        return commands
    }

    // Names that do something here, without their "/": what the composer lights up.
    var commandWords: Set<String> {
        Set(commandCatalog.filter { !$0.source.hasSuffix(" terminal") }.flatMap { [$0.name, $0.insert.trimmingCharacters(in: .whitespaces)] }.map { String($0.dropFirst()) })
    }

    var commandOptions: [ChatCommand] {
        guard let query = commandQuery else { return [] }
        let parts = query.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var verb = (parts.first ?? "").replacingOccurrences(of: "/vcx:", with: "/")
        if account.provider == "codex", verb.hasPrefix("/codex:") {
            let native = String(verb.dropFirst(7))
            if codexNativeNames.contains(native) { verb = "/" + (codexAliases[native] ?? native) }
        }
        if ["claude", "codex"].contains(account.provider), verb.hasPrefix("/claude:") {
            let native = String(verb.dropFirst(8))
            if claudeNativeNames.contains(native) { verb = "/" + (claudeAliases[native] ?? native) }
        }
        let argument = parts.count > 1 ? parts[1].lowercased() : ""
        var choices: [ChatCommand] = []
        if parts.count > 1 {
            func option(_ value: String, _ description: String, label: String? = nil, isCurrent: Bool = false) -> ChatCommand {
                ChatCommand(name: label ?? value, detail: description, insert: verb + " " + value, isCurrent: isCurrent)
            }
            switch verb {
            case "/provider", "/model":
                let args = argument.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                let providers = ["claude", "codex", "qwen"]
                if args.count == 1 {
                    return providers.filter { argument.isEmpty || $0.contains(argument) }.map { option($0 + " ", "Choose a " + $0.capitalized + " model", label: $0.capitalized, isCurrent: $0 == account.provider) }
                }
                let provider = args[0]
                guard provider == account.provider || provider == "auto" else { return [] }
                if args.count == 2 {
                    // Claude lists its newest models only as aliases ("opus" → claude-opus-5-5), so the row names what the alias runs.
                    return models.filter { args[1].isEmpty || $0.localizedCaseInsensitiveContains(args[1]) || (modelAliases[$0].map { $0.localizedCaseInsensitiveContains(args[1]) || modelName($0).localizedCaseInsensitiveContains(args[1]) } ?? false) }.map {
                        let id = $0, resolved = modelAliases[id].flatMap { $0 == id ? nil : $0 }
                        return option(provider + " " + id + ((modelEfforts[id] ?? []).isEmpty ? "" : " "), resolved ?? "Choose model", label: resolved.map { id + " · " + modelName($0) } ?? id, isCurrent: id == model || modelAliases[id] == model)
                    }
                }
                choices = (modelEfforts[args[1]] ?? []).filter { args[2].isEmpty || $0.contains(args[2]) }.map {
                    option(provider + " " + args[1] + " " + $0, "Reasoning effort", label: $0, isCurrent: $0 == (args[1] == model || modelAliases[args[1]] == model ? effectiveEffort : modelDefaultEfforts[args[1]]))
                }
                return choices
            case "/perms": choices = [option("bypass", "YOLO: no tool approval prompts"), option("ask", "Ask before actions that need permission")]
            case "/plan": choices = [option("on", "Plan without implementing"), option("off", "Return to implementation")]
            case "/effort": choices = (modelEfforts[model] ?? []).map { option($0, "Reasoning effort", isCurrent: $0 == effort) }
            case "/account":
                choices = Settings.shared.value.accounts.map { option($0.id, $0.provider.capitalized + ($0.enabled ? " · enabled" : " · disabled"), label: $0.name) }
                choices += ["enable ", "disable ", "rename "].map { option($0, "Account ID follows") }
                let accountParts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if ["enable", "disable", "rename"].contains(accountParts.first ?? ""), accountParts.count > 1 {
                    choices = Settings.shared.value.accounts.map { option(accountParts[0] + " " + $0.id + (accountParts[0] == "rename" ? " " : ""), $0.provider.capitalized, label: $0.name) }
                    return choices.filter { argument.hasSuffix(" ") || $0.name.lowercased().contains(accountParts[1]) || $0.insert.lowercased().contains(argument) }
                }
            case "/login": choices = ["claude", "codex", "cancel"].map { option($0, $0 == "cancel" ? "Cancel sign-in" : "Sign in with subscription") }
            case "/qwen": choices = ["url ", "proxy ", "model "].map { option($0, "Enter the value after this setting") }
            case "/resume": choices = recent.map { option($0.id, "Resume conversation", label: $0.title) }
            default: return []
            }
            return choices.filter { argument.isEmpty || $0.name.lowercased().contains(argument) || $0.insert.lowercased().contains(query.lowercased()) }
        }
        var commands = commandCatalog
        if query.hasPrefix("/vcx:") { commands = appCommands.map { var c = $0; c.insert = c.insert.replacingOccurrences(of: "/", with: "/vcx:"); return c } }
        let needle = query.replacingOccurrences(of: "/vcx:", with: "/").lowercased()
        func rank(_ command: ChatCommand) -> Int {
            let name = command.name.lowercased(), insert = command.insert.lowercased().trimmingCharacters(in: .whitespaces)
            if name == needle || insert == query.lowercased() { return 0 }
            if name.hasPrefix(needle) || insert.hasPrefix(query.lowercased()) { return 1 }
            return name.contains(needle) ? 2 : 3
        }
        var names = Set<String>()
        return commands.filter { needle == "/" || $0.name.lowercased().contains(needle) || $0.insert.lowercased().hasPrefix(query.lowercased()) || $0.detail.lowercased().contains(String(needle.dropFirst())) }.filter { names.insert($0.name.lowercased()).inserted }.sorted { rank($0) < rank($1) }
    }

    func updateCommands(_ text: String, caret: Int) {
        let typed = text == draft.string ? draft.commandText : text
        if !typed.isEmpty, !typed.hasPrefix("/"), text == draft.string, let saved = savedCommandDraft {
            let restored = NSMutableAttributedString(attributedString: saved)
            if restored.length > 0 { restored.append(NSAttributedString(string: "\n")) }
            restored.append(draft); draft = restored; savedCommandDraft = nil; draftRevision += 1; commandQuery = nil
            return
        }
        let trimmed = typed.trimmingCharacters(in: .newlines)
        var next: String? = trimmed.hasPrefix("/") && !trimmed.contains("\n") && caret == (text as NSString).length ? trimmed : nil
        let word = slashWord(text, caret: caret)
        commandToken = nil
        if let word, word.location > 0 || next == nil { next = (text as NSString).substring(with: word); commandToken = word }
        if next != commandQuery {
            commandQuery = next; commandSelection = commandOptions.firstIndex(where: \.isCurrent) ?? 0
            if next?.contains(" ") == true || commandToken != nil, commandOptions.isEmpty { commandQuery = nil }
        }
    }
    // The "/word" ending at the caret, at the start of the text or after a space.
    func slashWord(_ text: String, caret: Int) -> NSRange? {
        let string = text as NSString
        func blank(_ index: Int) -> Bool { UnicodeScalar(string.character(at: index)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false }
        guard caret <= string.length, caret == string.length || blank(caret) else { return nil }
        var start = caret
        while start > 0, !blank(start - 1) { start -= 1 }
        guard start < caret, string.character(at: start) == 47 else { return nil }
        return NSRange(location: start, length: caret - start)
    }
    func lockCommand(_ label: String, _ value: String, space: Bool, in range: NSRange) {
        let piece = NSMutableAttributedString(attachment: CommandChip(label: label, value: value))
        piece.addAttribute(.toolTip, value: value, range: NSRange(location: 0, length: piece.length))
        if space { piece.append(NSAttributedString(string: " ")) }
        commandToken = nil
        if replaceInComposer(range, piece) { return }
        let edited = NSMutableAttributedString(attributedString: draft)
        edited.replaceCharacters(in: NSMaxRange(range) <= draft.length ? range : NSRange(location: 0, length: draft.length), with: piece)
        editDraft(edited)
    }
    func showCommands(_ text: String, preserveDraft: Bool = true) {
        guard !changing || !preserveDraft else { notice("Wait for the connection change before opening session settings."); return }
        if preserveDraft, draft.length > 0, savedCommandDraft == nil { savedCommandDraft = draft }
        editDraft(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black]))
        commandToken = nil
        commandQuery = text; commandSelection = commandOptions.firstIndex(where: \.isCurrent) ?? 0; focusComposer()
    }
    func dismissCommands() {
        commandQuery = nil; commandToken = nil
        if let saved = savedCommandDraft { editDraft(saved); savedCommandDraft = nil }
    }
    func statusCommand(_ source: String) {
        guard !changing else { return }
        // These only report into the chat: written into the chat box first, they flashed over the draft until the answer came.
        if ["/tokens", "/usage", "/repo"].contains(source) { Task { await command(source) }; return }
        if savedCommandDraft == nil { savedCommandDraft = draft }
        showCommands(source)
        if source != "/perms " && source != "/model " && source != modelCommand { Task { await command(source) } }
    }
    func chooseCommand(_ command: ChatCommand) {
        if command.insert.hasPrefix("/model ") || command.insert.hasPrefix("/provider ") || command.insert.hasPrefix("/perms "),
           command.insert.split(separator: " ").count > 1 {
            if command.insert.hasPrefix("/perms ") {
                if savedCommandDraft == nil { savedCommandDraft = NSAttributedString(string: "") }
                showCommands(command.insert, preserveDraft: false)
            }
            Task { await self.command(command.insert) }
            return
        }
        // A command (not one of its values) locks in as a chip showing its name.
        let value = command.insert.trimmingCharacters(in: .whitespaces)
        if !value.contains(" ") {
            let inline = commandToken
            lockCommand(command.name, value, space: command.insert.hasSuffix(" "), in: inline ?? NSRange(location: 0, length: draft.length))
            commandQuery = inline == nil && command.insert.hasSuffix(" ") ? command.insert : nil
            commandSelection = commandOptions.firstIndex(where: \.isCurrent) ?? 0
            focusComposer()
            return
        }
        showCommands(command.insert, preserveDraft: false)
        // Keep the selected value in the composer for review before Return executes it.
        commandQuery = command.insert.hasSuffix(" ") ? command.insert : nil
    }
    func moveCommand(_ direction: Int) {
        guard !commandOptions.isEmpty else { return }
        commandSelection = (commandSelection + direction + commandOptions.count) % commandOptions.count
    }
    func completeCommand() -> Bool {
        let options = commandOptions
        guard commandQuery != nil, !options.isEmpty else { return false }
        chooseCommand(options[min(commandSelection, options.count - 1)]); return true
    }

    // A provider or skill namespace (/codex:skill:sm, /claude:sm) names the same skill as /sm; a bare name owned by vcx stays vcx's.
    func providerSkill(_ source: String) -> ChatCommand? {
        let original = String(source.split(separator: " ", maxSplits: 1).first ?? "")
        guard !original.hasPrefix("/vcx:") else { return nil }
        let verb = original.replacingOccurrences(of: "^/(claude|codex):(skill:)?", with: "/", options: .regularExpression)
        return providerCommands.first { $0.name == verb && (verb != original || !appCommands.contains { $0.name == original }) }
    }

    func command(_ source: String, images: [String] = []) async {
        guard !frontendReplacing else { return }
        let pieces = source.split(separator: " ", maxSplits: 1).map(String.init)
        let original = pieces.first ?? ""
        var verb = original.replacingOccurrences(of: "/vcx:", with: "/")
        if account.provider == "codex", original.hasPrefix("/codex:"), codexNativeNames.contains(String(original.dropFirst(7))) {
            let name = String(original.dropFirst(7)); verb = "/" + (codexAliases[name] ?? name)
        } else if account.provider == "codex", !original.hasPrefix("/vcx:"), let mapped = codexAliases[String(original.dropFirst())] { verb = "/" + mapped }
        if ["claude", "codex"].contains(account.provider), original.hasPrefix("/claude:"), claudeNativeNames.contains(String(original.dropFirst(8))) {
            let name = String(original.dropFirst(8)); verb = "/" + (claudeAliases[name] ?? name)
        } else if account.provider == "claude", !original.hasPrefix("/vcx:"), let mapped = claudeAliases[String(original.dropFirst())] { verb = "/" + mapped }
        var argument = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if ["/reload-skills", "/claude:reload-skills"].contains(original) { argument = "reload" }
        if runtimeClient != nil {
            if argument.isEmpty, ["/provider", "/model", "/perms", "/account", "/qwen"].contains(verb) {
                showCommands((verb == "/provider" ? "/model" : verb) + " ", preserveDraft: false)
                return
            }
            if verb == "/resume", argument.isEmpty {
                let generation = draftGeneration
                await performRuntime("refreshCatalog")
                if generation == draftGeneration { showCommands("/resume ", preserveDraft: false) }
                return
            }
            let localCommands = ["/window", "/settings", "/login", "/attach", "/preview", "/quit", "/exit", "/details", "/focus"]
            if !localCommands.contains(verb) {
                let generation = draftGeneration
                let preserved = savedCommandDraft ?? (draft.commandText == source ? NSAttributedString(string: "") : draft)
                commandQuery = nil
                let result = await performRuntime("command", ["text": source, "draft": draftContent(preserved), "generation": generation])
                Settings.shared.reload()
                guard generation == draftGeneration else { return }
                if let query = result?["commandQuery"] as? String {
                    if savedCommandDraft == nil { savedCommandDraft = preserved }
                    showCommands(query, preserveDraft: false)
                } else if result != nil {
                    if let saved = savedCommandDraft { draft = saved; savedCommandDraft = nil; draftRevision += 1 }
                    else if draft.commandText == source { draft = NSAttributedString(string: ""); draftRevision += 1 }
                    checkpointRuntimeDraft()
                }
                return
            }
        }
        let settings = Settings.shared
        let commandDraft = draft, commandGeneration = draftGeneration
        commandQuery = nil
        defer {
            if let saved = savedCommandDraft, commandQuery == nil {
                let restored = NSMutableAttributedString(attributedString: saved)
                if draft.length > 0, draftGeneration != commandGeneration || (draft.commandText != source && !draft.isEqual(to: commandDraft)) {
                    if restored.length > 0 { restored.append(NSAttributedString(string: "\n")) }
                    restored.append(draft)
                }
                draft = restored; savedCommandDraft = nil; draftRevision += 1
            }
            if !changing { save() }
        }
        if let native = providerSkill(source) {
            let name = native.name.dropFirst()
            if draft.commandText == source { commandQuery = nil }
            // The chat shows the command as typed, never its namespace or the prompt it becomes.
            let shown = source.replacingOccurrences(of: "^/(claude|codex):(skill:)?", with: "/", options: .regularExpression)
            if let path = legacyCommandPaths[String(name)] {
                await send(text: "Run the Claude command /\(name) from \(path) using the available Codex tools. Read the complete command file first. Substitute $ARGUMENTS with the following arguments, and $1, $2, etc. with their positional values. Preserve the command's restrictions and use normal approval checks for shell commands. If an instruction cannot be enforced, stop and explain it.\nArguments: " + argument, images: images, commandHandled: true, displayText: shown)
                return
            }
            let prefix = account.provider == "codex" ? "$" : "/"
            let skill = skillPaths[String(name)].map { ["type": "skill", "name": String(name), "path": $0] }
            await send(text: prefix + name + (argument.isEmpty ? "" : " " + argument), images: images, commandHandled: true, skill: skill, displayText: shown)
            return
        }
        do {
            switch verb {
            case "/provider", "/model":
                if argument.isEmpty { showCommands("/model ", preserveDraft: false); return }
                guard !changing else { throw CXError(message: "A connection change is already in progress.") }
                if busy {
                    pendingModelCommand = "/model " + argument
                    if draftGeneration == commandGeneration, draft.isEqual(to: commandDraft), draft.commandText.hasPrefix("/") { draft = NSAttributedString(string: ""); draftRevision += 1 }
                    return
                }
                let args = argument.split(separator: " ").map(String.init)
                let providers = ["auto", "claude", "codex", "qwen"]
                if providers.contains(args[0]) {
                    let provider = args[0], previousProvider = providerChoice
                    providerChoice = provider
                    guard let next = available.first, provider == "auto" || next.provider == provider else {
                        providerChoice = previousProvider
                        throw CXError(message: "No enabled account is available for " + provider + ". Enable one with /account or add one with /login.")
                    }
                    if next.id != account.id || !ready {
                        try await activate(next, resume: nil, keepRows: true, reason: "provider changed")
                        await refreshCatalog()
                    }
                    if args.count == 1 { showCommands("/model " + provider + " ", preserveDraft: false); return }
                    guard args.count <= 3, models.contains(args[1]) else { throw CXError(message: "Choose a model from the menu.") }
                    let efforts = modelEfforts[args[1]] ?? []
                    if args.count == 2, !efforts.isEmpty { showCommands("/model " + provider + " " + args[1] + " ", preserveDraft: false); return }
                    guard args.count == 2 || efforts.contains(args[2]) else { throw CXError(message: "Choose an effort from the menu.") }
                    await changeModel(args[1], effort: args.count == 3 ? args[2] : nil)
                } else {
                    guard ready else { throw CXError(message: "Reconnect before changing models.") }
                    await changeModel(argument)
                }
                if draftGeneration == commandGeneration, draft.isEqual(to: commandDraft), draft.commandText.hasPrefix("/") { draft = NSAttributedString(string: ""); draftRevision += 1 }
            case "/perms":
                guard !argument.isEmpty else { showCommands("/perms ", preserveDraft: false); return }
                guard ["bypass", "yolo", "ask"].contains(argument) else { throw CXError(message: "Use /perms bypass or /perms ask.") }
                try idle(); modeChoice = argument == "yolo" ? "bypass" : argument; await switchMode()
            case "/account":
                guard !argument.isEmpty else { showCommands("/account ", preserveDraft: false); return }
                try idle()
                let args = argument.split(separator: " ", maxSplits: 2).map(String.init)
                let operation = ["enable", "disable", "rename"].contains(args[0]) ? args[0] : "use"
                let id = operation == "use" ? argument : args.count > 1 ? args[1] : ""
                guard let index = settings.value.accounts.firstIndex(where: { $0.id == id || $0.name.caseInsensitiveCompare(id) == .orderedSame }) else { throw CXError(message: "Choose an account from /account.") }
                if operation == "rename" {
                    guard args.count == 3, !args[2].isEmpty else { throw CXError(message: "Use /account rename <id> <name>.") }
                    settings.value.accounts[index].name = args[2]
                } else if operation == "use" {
                    providerChoice = settings.value.accounts[index].provider; accountChoice = settings.value.accounts[index].id
                } else { settings.value.accounts[index].enabled = operation == "enable" }
                if operation != "use" { try saveSettings() }
                await reconnect(reason: operation == "use" ? "account changed" : "account settings changed")
            case "/dir":
                if argument.isEmpty { notice(cwd + "\nUse /dir <folder> to change directory.") }
                else { try await changeDirectory(unquoted(argument)) }
            case "/fork":
                try idle(); guard ready, account.provider == "codex" else { throw CXError(message: "Fork is available for Codex conversations.") }
                let sourcePlanning = planning, sourceName = conversationName
                let result = try await rpc.request("thread/fork", ["threadId": threadID ?? "", "excludeTurns": true])
                guard let id = (result["thread"] as? JSON)?["id"] as? String else { throw CXError(message: "Codex did not return a forked conversation.") }
                if await switchThread(id, fromCommand: true) { planning = sourcePlanning; conversationName = sourceName; save() }
                return
            case "/rename":
                try idle(); guard ready, !argument.isEmpty else { throw CXError(message: "Use /rename <name> in a connected conversation.") }
                if account.provider == "codex" { _ = try await rpc.request("thread/name/set", ["threadId": threadID ?? "", "name": argument]) }
                conversationName = argument
                save(); await refreshCatalog()
            case "/plan":
                try idle(); guard ready else { throw CXError(message: "Reconnect first.") }
                if account.provider == "claude" { await send(text: "/plan" + (argument.isEmpty ? "" : " " + argument), images: [], commandHandled: true); return }
                guard account.provider == "codex" else { throw CXError(message: "Qwen has no native plan mode.") }
                planning = !["off", "execute", "default"].contains(argument)
                if !argument.isEmpty, !["on", "off", "execute", "default"].contains(argument) {
                    await send(text: argument, images: [], commandHandled: true); return
                }
                notice(planning ? "Plan mode enabled. Use /plan off to implement." : "Implementation mode enabled.")
            case "/effort":
                try idle()
                guard (modelEfforts[model] ?? []).contains(argument) else { throw CXError(message: "Choose an effort supported by the active model: " + (modelEfforts[model] ?? []).joined(separator: ", ")) }
                await changeModel(model, effort: argument)
            case "/window":
                let path = argument.isEmpty ? cwd : resolvedPath(argument)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw CXError(message: "Directory does not exist.") }
                (NSApp.delegate as? AppDelegate)?.openWindow(cwd: path)
            case "/new", "/clear", "/resume":
                try idle()
                if verb == "/resume", argument.isEmpty {
                    await refreshCatalog()
                    if draftGeneration == commandGeneration, draft.isEqual(to: commandDraft) { showCommands("/resume ", preserveDraft: false) }
                    else { notice("Conversations refreshed. Use /resume again when your draft is ready.") }
                    return
                }
                _ = await switchThread(verb == "/resume" ? argument : nil, fromCommand: true)
            case "/reconnect":
                let name = original.split(separator: ":").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
                try idle(); await reconnect(reason: name == "reload-plugins" ? "plugins reloaded" : name + " requested")
            case "/stop": await stop()
            case "/settings":
                showingSettings = true
            case "/login":
                if argument == "cancel" { settings.cancelSignIn(); settings.loginMessage = "" }
                else if argument == "dismiss" { settings.loginMessage = "" }
                else if ["claude", "codex"].contains(argument) { settings.signIn(provider: argument); if !settings.error.isEmpty { throw CXError(message: settings.error) } }
                else { showCommands("/login ", preserveDraft: false); return }
            case "/profile":
                let args = argument.split(separator: " ", maxSplits: 1).map(String.init)
                guard args.count == 2, ["claude", "codex"].contains(args[0]) else { throw CXError(message: "Use /profile claude|codex <profile directory>.") }
                try settings.addProfile(provider: args[0], path: resolvedPath(args[1])); notice("Profile added. Select it with /account.")
            case "/qwen":
                try idle()
                let args = argument.split(separator: " ", maxSplits: 1).map(String.init)
                guard args.count == 2, ["url", "proxy", "model"].contains(args[0]) else { showCommands("/qwen ", preserveDraft: false); return }
                let value = args[1] == "none" ? "" : args[1]
                guard args[0] != "model" || !value.isEmpty else { throw CXError(message: "Model names cannot be empty.") }
                if args[0] == "url" {
                    guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw CXError(message: "Enter an HTTP or HTTPS Ollama URL without credentials.") }
                    settings.value.qwenURL = value
                } else if args[0] == "proxy" {
                    guard value.isEmpty || validQwenProxy(value) else { throw CXError(message: "Use socks5://host:port without credentials, or none.") }
                    settings.value.qwenProxy = value
                } else { settings.value.qwenModel = value }
                try saveSettings(); if account.provider == "qwen" { if args[0] == "model" { model = value }; await reconnect(reason: "Qwen settings changed") }; notice("Qwen setting saved.")
            case "/hooks", "/skills", "/mcp", "/instructions":
                if argument == "reload" { try idle(); await reconnect(reason: String(verb.dropFirst()) + " reloaded") }
                let values = verb == "/hooks" ? hooks : verb == "/skills" ? skills : verb == "/mcp" ? mcp : instructions
                notice(values.isEmpty ? "No entries reported for " + String(verb.dropFirst()) + "." : values.joined(separator: "\n"))
            case "/tokens": notice(tokens + (context.isEmpty ? "" : "\n" + context))
            case "/usage": await refreshUsage(); notice(usage.isEmpty ? "The provider has not reported subscription usage yet." : usage)
            case "/repo": await refreshRepository(); notice(([repository + " · " + repositoryLabel] + repositoryChanges).joined(separator: "\n"))
            case "/compact", "/review":
                try idle(); guard ready else { throw CXError(message: "Reconnect first.") }
                if account.provider == "codex" {
                    if verb == "/compact" { _ = try await rpc.request("thread/compact/start", ["threadId": threadID ?? ""]) }
                    else { _ = try await rpc.request("review/start", ["threadId": threadID ?? "", "target": argument.isEmpty ? ["type": "uncommittedChanges"] : ["type": "custom", "instructions": argument], "delivery": "inline"]) }
                } else if account.provider == "claude" { await send(text: verb + (argument.isEmpty ? "" : " " + argument), images: [], commandHandled: true); return }
                else { throw CXError(message: "Qwen has no native compact/review command. Ask it to review in a message.") }
            case "/details", "/focus": details.toggle()
            case "/status": notice("Directory: \(cwd)\nProvider: \(providerLabel) · \(account.name)\nMode: \(mode)\nModel: \(model)\nTokens: \(tokens)\nUsage: \(usage.isEmpty ? "Not reported" : usage)\nRepository: \(repository) · \(branch)")
            case "/attach":
                let path = resolvedPath(argument)
                guard !argument.isEmpty, thumbnail(path) != nil else { throw CXError(message: "Use /attach <image path>.") }
                let attached = NSMutableAttributedString(attributedString: savedCommandDraft ?? NSAttributedString(string: ""))
                attached.append(NSAttributedString(attachment: ImageChip(path: path, number: 1)))
                editDraft(attached); savedCommandDraft = nil
            case "/preview":
                guard let path = rows.reversed().flatMap({ $0.items.reversed() }).flatMap({ $0.data["content"] as? [JSON] ?? [] }).compactMap({ $0["path"] as? String }).first else { throw CXError(message: "No image is available in this conversation.") }
                preview = path
            case "/allow", "/decline", "/answer":
                guard let pending = permissions.first else { throw CXError(message: "No pending question or approval.") }
                if pending.method == "item/tool/requestUserInput", verb == "/decline" { answer(pending, result: ["answers": [:]]) }
                else if pending.method == "item/tool/requestUserInput" {
                    guard verb == "/answer", !argument.isEmpty else { throw CXError(message: "Use /answer <text> for the next question.") }
                    let questions = pending.params["questions"] as? [JSON] ?? []
                    if questions.count == 1, let id = questions.first?["id"] as? String { answer(pending, result: ["answers": [id: ["answers": [argument]]]]) }
                    else {
                        guard let data = argument.data(using: .utf8), let values = try? JSONSerialization.jsonObject(with: data) as? [String: String], questions.allSatisfy({ q in (q["id"] as? String).flatMap { values[$0] }?.isEmpty == false }) else { throw CXError(message: "Use /answer followed by a JSON object mapping every question ID to an answer.") }
                        answer(pending, result: ["answers": values.mapValues { ["answers": [$0]] }])
                    }
                } else { answer(pending, result: ["decision": verb == "/allow" ? "accept" : "decline"]) }
            case "/help": notice((appCommands + providerCommands + (account.provider == "codex" ? codexNativeCommands : account.provider == "claude" ? claudeNativeCommands : [])).map { $0.name + " · " + $0.source + ": " + $0.detail }.joined(separator: "\n") + "\nType / to search. ↑/↓ select. Tab completes. Return runs highlighted skills immediately; other commands complete first and run on the next Return. Escape dismisses the popup. Shift+Return adds a line. /vcx:<command> explicitly selects vcx commands.")
            case "/quit", "/exit": (NSApp.delegate as? AppDelegate)?.closeWindow(session: self)
            default:
                if account.provider == "codex", codexNativeNames.contains(String(verb.dropFirst())) {
                    notice("\(verb) is listed from the Codex terminal catalog but is not implemented in vcx. It was not sent to the model. Use /help for available vcx actions."); break
                }
                if account.provider == "claude", claudeNativeNames.contains(String(verb.dropFirst())) {
                    notice("\(verb) is listed from the Claude CLI reference but is not implemented in vcx. It was not sent to the model. Use /help for available vcx actions."); break
                }
                throw CXError(message: "Unknown command. Type / to see the active provider’s commands and vcx settings.")
            }
            if draftGeneration == commandGeneration, draft.commandText == source { draft = NSAttributedString(string: ""); draftRevision += 1 }
            commandQuery = nil
        } catch { notice(error.localizedDescription); commandQuery = nil }
    }
    private func idle() throws { if busy || changing { throw CXError(message: "Stop the current response before changing session settings.") } }
    private func saveSettings() throws { Settings.shared.save(); if !Settings.shared.error.isEmpty { throw CXError(message: Settings.shared.error) } }
    private func unquoted(_ text: String) -> String {
        if text.count >= 2, (text.first == "\"" && text.last == "\"") || (text.first == "'" && text.last == "'") { return String(text.dropFirst().dropLast()) }; return text
    }
    private func resolvedPath(_ text: String) -> String {
        URL(fileURLWithPath: (unquoted(text) as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardized.path
    }
}
