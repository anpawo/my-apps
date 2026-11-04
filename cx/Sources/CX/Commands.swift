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
            ("mode", "Choose bypass / YOLO or ask for approval", true),
            ("dir", "Change the working directory", true),
            ("window", "Open another vcx instance, optionally in a directory", false),
            ("new", "Start a new conversation; current work stays saved", false),
            ("clear", "Start a new conversation", false),
            ("resume", "Choose a saved conversation", true),
            ("reconnect", "Reconnect the current conversation", false),
            ("stop", "Interrupt the current response", false),
            ("settings", "Show configuration and available settings commands", false),
            ("login", "Add a Claude or Codex subscription, or cancel sign-in", true),
            ("profile", "Import an existing account: claude|codex <folder>", true),
            ("qwen", "Configure url, proxy, text model, or vision model", true),
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
    var codexAliases: [String: String] { ["permissions": "mode", "config": "settings", "cd": "dir", "pwd": "dir", "cwd": "dir", "clean": "stop"] }
    var codexNativeCommands: [ChatCommand] {
        codexNativeNames.map { name in
            let mapped = codexAliases[name] ?? name
            let available = appCommands.contains { $0.name == "/" + mapped } || ["compact", "review"].contains(mapped)
            return ChatCommand(name: "/" + name, detail: available ? "Use through vcx /" + mapped : "Unavailable in vcx (Codex terminal action)", source: available ? "Codex" : "Codex terminal", insert: "/codex:" + name + (available && ["mode", "model", "resume"].contains(mapped) ? " " : ""))
        }
    }

    // shortcut: CLI reference built-ins are a snapshot; refresh after upstream changes. SDK skills stay live.
    var claudeNativeNames: [String] { "add-dir advisor agents artifact-capabilities artifact-diagramming artifacts auto-mode-setup autocompact autofix-pr background batch branch btw bug cd chrome claude-api claude-in-chrome clear code-review color compact config context copy cost dataviz debug deep-research design design-login design-sync desktop diff doctor effort exit export fast feedback fewer-permission-prompts focus fork goal heapdump help hooks ide import init insights install-github-app install-slack-app keybindings list-agents login logout loop mcp memory mobile model output-style passes permissions plan plugin plugin-authoring powerup pr-comments privacy-settings radio rate-limit-options recap release-notes reload-plugins reload-skills remote-control remote-env rename restart resume review rewind run run-skill-generator sandbox schedule scroll-speed security-review setup-bedrock setup-vertex simplify skill-doctor skills slides stats status statusline stickers stop subtask tasks team-onboarding teleport terminal-setup theme tui ultraplan ultrareview update-config upgrade usage usage-credits verify vim voice web-setup workflow-authoring workflows".split(separator: " ").map(String.init) }
    var claudeAliases: [String: String] { ["permissions": "mode", "config": "settings", "cd": "dir", "context": "tokens", "cost": "tokens", "restart": "reconnect"] }
    var claudeNativeCommands: [ChatCommand] {
        claudeNativeNames.map { name in
            let mapped = claudeAliases[name] ?? name
            let available = appCommands.contains { $0.name == "/" + mapped } || ["compact", "review"].contains(mapped)
            return ChatCommand(name: "/" + name, detail: available ? "Use through vcx /" + mapped : "Unavailable in vcx (Claude CLI reference)", source: available ? "Claude" : "Claude terminal", insert: "/claude:" + name + (available && ["mode", "model", "resume"].contains(mapped) ? " " : ""))
        }
    }

    var commandOptions: [ChatCommand] {
        guard let query = commandQuery else { return [] }
        let parts = query.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var verb = (parts.first ?? "").replacingOccurrences(of: "/vcx:", with: "/")
        if account.provider == "codex", verb.hasPrefix("/codex:") {
            let native = String(verb.dropFirst(7))
            if codexNativeNames.contains(native) { verb = "/" + (codexAliases[native] ?? native) }
        }
        if account.provider == "claude", verb.hasPrefix("/claude:") {
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
                    return models.filter { args[1].isEmpty || $0.localizedCaseInsensitiveContains(args[1]) }.map {
                        option(provider + " " + $0 + ((modelEfforts[$0] ?? []).isEmpty ? "" : " "), "Choose model", label: $0, isCurrent: $0 == model)
                    }
                }
                choices = (modelEfforts[args[1]] ?? []).filter { args[2].isEmpty || $0.contains(args[2]) }.map {
                    option(provider + " " + args[1] + " " + $0, "Reasoning effort", label: $0, isCurrent: $0 == (args[1] == model ? effectiveEffort : modelDefaultEfforts[args[1]]))
                }
                return choices
            case "/mode": choices = [option("bypass", "YOLO: no tool approval prompts"), option("ask", "Ask before actions that need permission")]
            case "/account":
                choices = Settings.shared.value.accounts.map { option($0.id, $0.provider.capitalized + ($0.enabled ? " · enabled" : " · disabled"), label: $0.name) }
                choices += ["enable ", "disable ", "rename "].map { option($0, "Account ID follows") }
                let accountParts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if ["enable", "disable", "rename"].contains(accountParts.first ?? ""), accountParts.count > 1 {
                    choices = Settings.shared.value.accounts.map { option(accountParts[0] + " " + $0.id + (accountParts[0] == "rename" ? " " : ""), $0.provider.capitalized, label: $0.name) }
                    return choices.filter { argument.hasSuffix(" ") || $0.name.lowercased().contains(accountParts[1]) || $0.insert.lowercased().contains(argument) }
                }
            case "/login": choices = ["claude", "codex", "cancel"].map { option($0, $0 == "cancel" ? "Cancel sign-in" : "Sign in with subscription") }
            case "/qwen": choices = ["url ", "proxy ", "model ", "vision "].map { option($0, "Enter the value after this setting") }
            case "/resume": choices = recent.map { option($0.id, "Resume conversation", label: $0.title) }
            default: return []
            }
            return choices.filter { argument.isEmpty || $0.name.lowercased().contains(argument) || $0.insert.lowercased().contains(query.lowercased()) }
        }
        var commands = appCommands + providerCommands
        if account.provider == "codex" { commands += codexNativeCommands }
        if account.provider == "claude" { commands += claudeNativeCommands }
        if ["claude", "codex"].contains(account.provider) { commands += [ChatCommand(name: "/compact", detail: "Compact the current context", source: providerLabel, insert: "/compact"), ChatCommand(name: "/review", detail: "Review uncommitted changes or custom instructions", source: providerLabel, insert: "/review ")] }
        if query.hasPrefix("/vcx:") { commands = appCommands.map { var c = $0; c.insert = c.insert.replacingOccurrences(of: "/", with: "/vcx:"); return c } }
        let needle = query.replacingOccurrences(of: "/vcx:", with: "/").lowercased()
        func rank(_ command: ChatCommand) -> Int {
            let name = command.name.lowercased(), insert = command.insert.lowercased().trimmingCharacters(in: .whitespaces)
            if name == needle || insert == query.lowercased() { return 0 }
            if name.hasPrefix(needle) || insert.hasPrefix(query.lowercased()) { return 1 }
            return name.contains(needle) ? 2 : 3
        }
        return commands.filter { needle == "/" || $0.name.lowercased().contains(needle) || $0.insert.lowercased().hasPrefix(query.lowercased()) || $0.detail.lowercased().contains(String(needle.dropFirst())) }.sorted { rank($0) < rank($1) }
    }

    func updateCommands(_ text: String, caret: Int) {
        if !text.isEmpty, !text.hasPrefix("/"), text == draft.string, let saved = savedCommandDraft {
            let restored = NSMutableAttributedString(attributedString: saved)
            if restored.length > 0 { restored.append(NSAttributedString(string: "\n")) }
            restored.append(draft); draft = restored; savedCommandDraft = nil; draftRevision += 1; commandQuery = nil
            return
        }
        let trimmed = text.trimmingCharacters(in: .newlines)
        let next: String? = trimmed.hasPrefix("/") && !trimmed.contains("\n") && caret == (text as NSString).length ? trimmed : nil
        if next != commandQuery {
            commandQuery = next; commandSelection = commandOptions.firstIndex(where: \.isCurrent) ?? 0
            if next?.contains(" ") == true, commandOptions.isEmpty { commandQuery = nil }
        }
    }
    func showCommands(_ text: String, preserveDraft: Bool = true) {
        guard !changing || !preserveDraft else { notice("Wait for the connection change before opening session settings."); return }
        if preserveDraft, draft.length > 0, savedCommandDraft == nil { savedCommandDraft = draft }
        editDraft(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white]))
        commandQuery = text; commandSelection = commandOptions.firstIndex(where: \.isCurrent) ?? 0; focusComposer()
    }
    func dismissCommands() {
        commandQuery = nil
        if let saved = savedCommandDraft { editDraft(saved); savedCommandDraft = nil }
    }
    func statusCommand(_ source: String) {
        guard !changing else { return }
        if savedCommandDraft == nil { savedCommandDraft = draft }
        showCommands(source)
        if source != "/mode " && source != "/model " && source != modelCommand { Task { await command(source) } }
    }
    func chooseCommand(_ command: ChatCommand) {
        if command.insert.hasPrefix("/model ") || command.insert.hasPrefix("/provider ") || command.insert.hasPrefix("/mode "),
           command.insert.split(separator: " ").count > 1 {
            if command.insert.hasPrefix("/mode ") {
                if savedCommandDraft == nil { savedCommandDraft = NSAttributedString(string: "") }
                showCommands(command.insert, preserveDraft: false)
            }
            Task { await self.command(command.insert) }
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

    func command(_ source: String) async {
        let pieces = source.split(separator: " ", maxSplits: 1).map(String.init)
        let original = pieces.first ?? ""
        var verb = original.replacingOccurrences(of: "/vcx:", with: "/")
        if account.provider == "codex", original.hasPrefix("/codex:"), codexNativeNames.contains(String(original.dropFirst(7))) {
            let name = String(original.dropFirst(7)); verb = "/" + (codexAliases[name] ?? name)
        } else if account.provider == "codex", !original.hasPrefix("/vcx:"), let mapped = codexAliases[String(original.dropFirst())] { verb = "/" + mapped }
        if account.provider == "claude", original.hasPrefix("/claude:"), claudeNativeNames.contains(String(original.dropFirst(8))) {
            let name = String(original.dropFirst(8)); verb = "/" + (claudeAliases[name] ?? name)
        } else if account.provider == "claude", !original.hasPrefix("/vcx:"), let mapped = claudeAliases[String(original.dropFirst())] { verb = "/" + mapped }
        let argument = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let settings = Settings.shared
        let commandDraft = draft, commandGeneration = draftGeneration
        commandQuery = nil
        defer {
            if let saved = savedCommandDraft, commandQuery == nil {
                let restored = NSMutableAttributedString(attributedString: saved)
                if draft.length > 0, draftGeneration != commandGeneration || (draft.string != source && !draft.isEqual(to: commandDraft)) {
                    if restored.length > 0 { restored.append(NSAttributedString(string: "\n")) }
                    restored.append(draft)
                }
                draft = restored; savedCommandDraft = nil; draftRevision += 1
            }
            if !changing { save() }
        }
        if !original.hasPrefix("/vcx:"), let native = providerCommands.first(where: { ($0.insert.trimmingCharacters(in: .whitespaces) == original || original == "/" + account.provider + ":" + $0.name.dropFirst()) && $0.insert.hasPrefix("/" + account.provider + ":") || $0.name == original && !appCommands.contains(where: { $0.name == original }) }) {
            let name = native.name.dropFirst()
            if draft.string == source { commandQuery = nil }
            let prefix = account.provider == "codex" ? "$" : "/"
            let skill = skillPaths[String(name)].map { ["type": "skill", "name": String(name), "path": $0] }
            await send(text: prefix + name + (argument.isEmpty ? "" : " " + argument), images: [], commandHandled: true, skill: skill)
            return
        }
        do {
            switch verb {
            case "/provider", "/model":
                if argument.isEmpty { showCommands("/model ", preserveDraft: false); return }
                guard !changing else { throw CXError(message: "A connection change is already in progress.") }
                if busy {
                    pendingModelCommand = "/model " + argument
                    if draftGeneration == commandGeneration, draft.isEqual(to: commandDraft), draft.string.hasPrefix("/") { draft = NSAttributedString(string: ""); draftRevision += 1 }
                    return
                }
                let args = argument.split(separator: " ").map(String.init)
                let providers = ["auto", "claude", "codex", "qwen"]
                if providers.contains(args[0]) {
                    let provider = args[0], previousProvider = settings.value.provider
                    settings.value.provider = provider
                    guard let next = available.first, provider == "auto" || next.provider == provider else {
                        settings.value.provider = previousProvider
                        throw CXError(message: "No enabled account is available for " + provider + ". Enable one with /account or add one with /login.")
                    }
                    try saveSettings()
                    if next.id != account.id || !ready {
                        try await activate(next, resume: nil, keepRows: true)
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
                if draftGeneration == commandGeneration, draft.isEqual(to: commandDraft), draft.string.hasPrefix("/") { draft = NSAttributedString(string: ""); draftRevision += 1 }
            case "/mode":
                guard !argument.isEmpty else { showCommands("/mode ", preserveDraft: false); return }
                guard ["bypass", "yolo", "ask"].contains(argument) else { throw CXError(message: "Use /mode bypass or /mode ask.") }
                try idle(); settings.value.mode = argument == "yolo" ? "bypass" : argument; try saveSettings(); await reconnect()
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
                    let selected = settings.value.accounts[index]
                    settings.value.provider = selected.provider
                    for n in settings.value.accounts.indices where settings.value.accounts[n].provider == selected.provider { settings.value.accounts[n].enabled = n == index }
                } else { settings.value.accounts[index].enabled = operation == "enable" }
                try saveSettings(); await reconnect()
            case "/dir":
                if argument.isEmpty { notice(cwd + "\nUse /dir <folder> to change directory.") }
                else { try await changeDirectory(unquoted(argument)) }
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
            case "/reconnect": try idle(); await reconnect()
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
                guard args.count == 2, ["url", "proxy", "model", "vision"].contains(args[0]) else { showCommands("/qwen ", preserveDraft: false); return }
                let value = args[1] == "none" ? "" : args[1]
                guard !["model", "vision"].contains(args[0]) || !value.isEmpty else { throw CXError(message: "Model names cannot be empty.") }
                if args[0] == "url" {
                    guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw CXError(message: "Enter an HTTP or HTTPS Ollama URL without credentials.") }
                    settings.value.qwenURL = value
                } else if args[0] == "proxy" {
                    guard value.isEmpty || validQwenProxy(value) else { throw CXError(message: "Use socks5://host:port without credentials, or none.") }
                    settings.value.qwenProxy = value
                } else if args[0] == "model" { settings.value.qwenModel = value }
                else { settings.value.qwenVisionModel = value }
                try saveSettings(); if account.provider == "qwen" { if args[0] == "model" { model = value }; await reconnect() }; notice("Qwen setting saved.")
            case "/hooks", "/skills", "/mcp", "/instructions":
                if argument == "reload" { try idle(); await reconnect() }
                let values = verb == "/hooks" ? hooks : verb == "/skills" ? skills : verb == "/mcp" ? mcp : instructions
                notice(values.isEmpty ? "No entries reported for " + String(verb.dropFirst()) + "." : values.joined(separator: "\n"))
            case "/tokens": notice(tokens + (context.isEmpty ? "" : "\n" + context))
            case "/usage": await refreshUsage(); notice(usage.isEmpty ? "The provider has not reported subscription usage yet." : usage)
            case "/repo": await refreshRepository(); notice(repository + " · " + repositoryLabel)
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
            case "/quit", "/exit": NSApp.terminate(nil)
            default:
                if account.provider == "codex", codexNativeNames.contains(String(verb.dropFirst())) {
                    notice("\(verb) is listed from the Codex terminal catalog but is not implemented in vcx. It was not sent to the model. Use /help for available vcx actions."); break
                }
                if account.provider == "claude", claudeNativeNames.contains(String(verb.dropFirst())) {
                    notice("\(verb) is listed from the Claude CLI reference but is not implemented in vcx. It was not sent to the model. Use /help for available vcx actions."); break
                }
                throw CXError(message: "Unknown command. Type / to see the active provider’s commands and vcx settings.")
            }
            if draftGeneration == commandGeneration, draft.string == source { draft = NSAttributedString(string: ""); draftRevision += 1 }
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
