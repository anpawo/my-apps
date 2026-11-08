import AppKit

struct CapabilityItem: Identifiable {
    let id: String
    let name: String
    let detail: String
    init(name: String, detail: String, id: String? = nil) { self.id = id ?? name; self.name = name; self.detail = detail }
}

func capabilityMatches(_ items: [CapabilityItem], query: String) -> [CapabilityItem] {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    return items.filter { item in words.allSatisfy { (item.name + " " + item.detail).localizedCaseInsensitiveContains($0) } }.sorted {
        let left = $0.name.lowercased().hasPrefix(query.lowercased())
        let right = $1.name.lowercased().hasPrefix(query.lowercased())
        return left != right ? left : $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
}

func mcpSummary(_ server: JSON) -> String? {
    guard let name = server["name"] as? String else { return nil }
    let status = server["status"] as? String ?? server["runtimeStatus"] as? String ?? server["authStatus"] as? String ?? "configured"
    let tools = (server["tools"] as? JSON).map { Array($0.keys).sorted() } ?? (server["tools"] as? [JSON] ?? []).compactMap { $0["name"] as? String }
    let detail = server["description"] as? String ?? (tools.isEmpty ? "" : "Tools: " + tools.joined(separator: ", "))
    return [name, status, detail].filter { !$0.isEmpty }.joined(separator: " · ")
}

func hookSummary(_ hook: JSON, event: String, matcher: String? = nil, plugin: String? = nil) -> String {
    let descriptions = ["sessionstart": "Loads context when a session starts.", "sessionend": "Runs cleanup when a session ends.", "userpromptsubmit": "Checks a prompt before it is sent.", "pretooluse": "Checks a tool call before it runs.", "posttooluse": "Runs after a tool call completes.", "posttoolusefailure": "Handles a failed tool call.", "permissionrequest": "Handles tool permission requests.", "notification": "Handles session notifications.", "stop": "Runs when the agent finishes responding.", "precompact": "Preserves context before compaction.", "configchange": "Responds to configuration changes.", "messagedisplay": "Formats messages for display."]
    let command = hook["command"] as? String ?? ""
    let script = command.range(of: #"[^/\s"']+\.(?:py|sh|bash|zsh|mjs|js|rb|pl|ps1)(?=[\s"']|$)"#, options: .regularExpression).map { String(command[$0]) }
    let name = hook["name"] as? String ?? script ?? plugin ?? hook["tool"] as? String ?? event
    let status = hook["enabled"] as? Bool == false ? "disabled" : hook["trustStatus"] as? String ?? "configured"
    let detail = hook["description"] as? String ?? hook["statusMessage"] as? String ?? descriptions[event.lowercased()] ?? "Runs on " + event + "."
    let match = matcher ?? hook["matcher"] as? String ?? ""
    return ([name, event, status, detail] + (match.isEmpty ? [] : ["Matches: " + match]) + (plugin.map { ["Plugin: " + $0] } ?? [])).joined(separator: " · ")
}

// What Claude Code loads: user settings, each ancestor's project settings, and the hooks of enabled plugins.
func claudeHooks(home: String, folders: [URL], flags: [URL] = []) -> [String] {
    func read(_ url: URL) -> JSON? { (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON } }
    func summaries(_ config: JSON?, plugin: String? = nil) -> [String] {
        let events = config?["hooks"] as? JSON ?? [:]
        return events.keys.sorted().flatMap { event in
            (events[event] as? [JSON] ?? []).flatMap { group in
                (group["hooks"] as? [JSON] ?? []).map { hookSummary($0, event: event, matcher: group["matcher"] as? String, plugin: plugin) }
            }
        }
    }
    var paths: [String] = []
    for url in [URL(fileURLWithPath: home).appendingPathComponent("settings.json")] + folders.flatMap({ folder in [".claude/settings.json", ".claude/settings.local.json"].map { folder.appendingPathComponent($0) } }) + flags where !paths.contains(url.standardizedFileURL.path) {
        paths.append(url.standardizedFileURL.path)
    }
    let settings = paths.compactMap { read(URL(fileURLWithPath: $0)) }
    var enabled: [String: Bool] = [:]
    for value in settings { enabled.merge(value["enabledPlugins"] as? [String: Bool] ?? [:]) { $1 } }
    let installed = read(URL(fileURLWithPath: home).appendingPathComponent("plugins/installed_plugins.json"))?["plugins"] as? JSON ?? [:]
    let folderPaths = Set(folders.map(\.standardizedFileURL.path))
    let plugins = enabled.filter(\.value).keys.sorted().flatMap { id -> [String] in
        let entries = installed[id] as? [JSON] ?? []
        guard let root = entries.first(where: { ($0["projectPath"] as? String).map { folderPaths.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) } ?? true })?["installPath"] as? String else { return [] }
        let base = URL(fileURLWithPath: root), name = String(id.split(separator: "@").first ?? Substring(id))
        let declared = read(base.appendingPathComponent(".claude-plugin/plugin.json"))?["hooks"]
        var files: [URL] = []
        for file in ["hooks/hooks.json"] + ((declared as? String).map { [$0] } ?? declared as? [String] ?? []) {
            let url = base.appendingPathComponent(file).standardizedFileURL
            if !files.contains(url) { files.append(url) }
        }
        return (files.compactMap(read) + [declared as? JSON].compactMap { $0 }).flatMap { summaries($0, plugin: name) }
    }
    return settings.flatMap { summaries($0) } + plugins
}

@MainActor
extension Session {
    func capabilityItems(_ title: String) -> [CapabilityItem] {
        let values = title == "Hooks" ? hooks : title == "Skills" ? skills : title == "Commands" ? builtinCommands : title == "MCP" ? mcp : instructions.map { URL(fileURLWithPath: $0).lastPathComponent }
        let items = values.enumerated().map { index, value in
            let parts = value.components(separatedBy: " · ")
            let name = parts[0]
            let summary = parts.dropFirst().filter { title != "Hooks" || $0 != "trusted" }.joined(separator: " · ")
            let detail: String
            if title == "Skills" || title == "Commands" { detail = providerCommands.first { $0.name == "/" + name }?.detail ?? "Provider skill" }
            else if title == "Hooks" { detail = summary.isEmpty ? "Provider hook" : summary }
            else if title == "Instructions" { return CapabilityItem(name: URL(fileURLWithPath: value).lastPathComponent, detail: value, id: String(index)) }
            else { detail = summary.isEmpty ? "Configured MCP server" : summary }
            return CapabilityItem(name: name, detail: detail, id: String(index))
        }
        guard title == "Hooks" else { return items }
        var grouped: [CapabilityItem] = []
        for item in items {
            if let index = grouped.firstIndex(where: { $0.name == item.name }) {
                let previous = grouped[index]
                grouped[index] = CapabilityItem(name: item.name, detail: previous.detail + "\n\n" + item.detail)
            } else { grouped.append(CapabilityItem(name: item.name, detail: item.detail)) }
        }
        return grouped
    }
    // One spelling on every provider; the namespace stays only where a vcx command owns the bare name.
    func skillInsert(_ name: String) -> String {
        appCommands.contains { $0.name == "/" + name } ? "/" + account.provider + ":skill:" + name + " " : "/" + name + " "
    }
    func applyClaudeCatalog(_ catalog: JSON) {
        if let commands = catalog["commands"] as? [JSON] {
            providerCommands = commands.flatMap { command -> [ChatCommand] in
                guard let name = command["name"] as? String else { return [] }
                let names = [name] + (command["aliases"] as? [String] ?? [])
                return names.map { ChatCommand(name: "/" + $0, detail: command["description"] as? String ?? "Claude command", source: "Claude", insert: skillInsert($0)) }
            }
            skills = commands.filter { $0["builtin"] as? Bool != true }.compactMap { $0["name"] as? String }.sorted()
            builtinCommands = commands.filter { $0["builtin"] as? Bool == true }.compactMap { $0["name"] as? String }.filter { !$0.hasPrefix("_") }.sorted()
        }
        if let catalog = catalog["models"] as? [JSON] {
            models = catalog.compactMap { $0["value"] as? String }
            modelAliases = Dictionary(catalog.compactMap { entry in
                guard let id = entry["value"] as? String, let resolved = entry["resolvedModel"] as? String else { return nil }
                return (id, resolved)
            }, uniquingKeysWith: { first, _ in first })
            modelEfforts = Dictionary(catalog.compactMap { entry in
                guard let id = entry["value"] as? String else { return nil }
                return (id, entry["supportsEffort"] as? Bool == false ? [] : entry["supportedEffortLevels"] as? [String] ?? [])
            }, uniquingKeysWith: { first, _ in first })
        }
        if let mode = catalog["current_permission_mode"] as? String { activeMode = mode == "bypassPermissions" ? "bypass" : "ask" }
        if let servers = catalog["mcp_servers"] as? [JSON] { mcp = servers.compactMap(mcpSummary).sorted() }
    }

    func refreshCapabilities() async {
        // A window mirrors the runtime's lists, so a refresh computed here would be overwritten by its next publish.
        if runtimeClient != nil { await performRuntime("refreshCapabilities"); return }
        let connection = rpc
        await refreshRepository()
        guard rpc === connection else { return }
        let base = account.home ?? NSHomeDirectory() + (account.provider == "claude" ? "/.claude" : "/.codex")
        var folders: [URL] = [], folder = URL(fileURLWithPath: cwd)
        while true {
            folders.insert(folder, at: 0)
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }; folder = parent
        }
        let names = account.provider == "claude" ? ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"] : ["AGENTS.md", "AGENTS.override.md"]
        instructions = ([URL(fileURLWithPath: base).appendingPathComponent(account.provider == "claude" ? "CLAUDE.md" : "AGENTS.md")] + folders.flatMap { folder in names.map { folder.appendingPathComponent($0) } }).filter { FileManager.default.fileExists(atPath: $0.path) }.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        if account.provider == "qwen" {
            hooks = ["Not supported by the Qwen adapter"]
            skills = ["No native skill catalog"]
            mcp = ["No MCP servers; run_command is built in"]
            instructions = ["Project instructions are read by Qwen when working"]
            return
        }
        if account.provider == "claude" {
            hooks = claudeHooks(home: base, folders: folders, flags: [claudeSettingsFile])
            instructions = ClaudeCompatibility(cwd: cwd, home: base).instructions().paths.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
            do {
                let catalog = try await connection.request("cx/catalog", [:], timeout: 25)
                guard rpc === connection else { return }
                applyClaudeCatalog(catalog)
            } catch { if rpc === connection { mcp = ["Catalog unavailable: " + error.localizedDescription] } }
            return
        }
        do {
            let result = try await connection.request("skills/list", ["cwds": [cwd], "forceReload": true], timeout: 15)
            guard rpc === connection else { return }
            let catalog = (result["data"] as? [JSON] ?? []).flatMap { $0["skills"] as? [JSON] ?? [] }.filter { $0["enabled"] as? Bool != false }
            skills = catalog.compactMap { $0["name"] as? String }.sorted()
            skillPaths = Dictionary(catalog.compactMap { item in guard let name = item["name"] as? String, let path = item["path"] as? String else { return nil }; return (name, path) }, uniquingKeysWith: { first, _ in first })
            providerCommands = catalog.compactMap { item in guard let name = item["name"] as? String else { return nil }; return ChatCommand(name: "/" + name, detail: item["description"] as? String ?? "Codex skill", source: "Codex skill", insert: skillInsert(name)) }
            legacyCommandPaths = claudeCompatibility.commands.filter { skillPaths[$0.key] == nil }
            providerCommands += legacyCommandPaths.keys.sorted().map { ChatCommand(name: "/" + $0, detail: "Claude command translated for Codex", source: "Claude command", insert: skillInsert($0)) }
            skills = Array(Set(skills + legacyCommandPaths.keys)).sorted()
        } catch { guard rpc === connection else { return }; skills = ["Catalog unavailable: " + error.localizedDescription] }
        instructions = Array(Set(instructions + claudeCompatibility.instructions().paths.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") })).sorted()
        do {
            let result = try await connection.request("hooks/list", ["threadId": threadID ?? ""], timeout: 15)
            guard rpc === connection else { return }
            hooks = (result["data"] as? [JSON] ?? []).flatMap { $0["hooks"] as? [JSON] ?? [] }.map { hookSummary($0, event: $0["eventName"] as? String ?? "Hook") }
        } catch { guard rpc === connection else { return }; hooks = ["Catalog unavailable: " + error.localizedDescription] }
        do {
            var cursor: String?, servers: [JSON] = []
            repeat {
                var params: JSON = ["threadId": threadID ?? "", "limit": 100, "detail": "toolsAndAuthOnly"]
                if let cursor { params["cursor"] = cursor }
                let result = try await connection.request("mcpServerStatus/list", params, timeout: 15)
                guard rpc === connection else { return }
                servers += result["data"] as? [JSON] ?? []; cursor = result["nextCursor"] as? String
            } while cursor != nil
            mcp = servers.compactMap(mcpSummary).sorted()
        } catch { if rpc === connection { mcp = ["Catalog unavailable: " + error.localizedDescription] } }
    }
    func refreshRepository() async {
        if runtimeClient != nil { await performRuntime("refreshRepository"); return }
        let directory = cwd
        let result = await Task.detached { () -> (String?, String, String, String, String?, [String]) in
            func git(_ arguments: [String], at path: String? = nil) -> String? {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", path ?? directory] + arguments
                process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                do { try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); guard process.terminationStatus == 0 else { return nil }; return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } catch { return nil }
            }
            guard let root = git(["rev-parse", "--show-toplevel"]) else { return (nil, "No repository", "", "", nil, []) }
            let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"]) ?? ""
            var top = common.hasSuffix("/.git") ? String(common.dropLast(5)) : root
            var name = URL(fileURLWithPath: top).lastPathComponent
            while let outer = git(["rev-parse", "--show-toplevel"], at: URL(fileURLWithPath: top).deletingLastPathComponent().path), outer != top {
                top = outer; name = URL(fileURLWithPath: top).lastPathComponent + "/" + name
            }
            let branch = git(["branch", "--show-current"]) ?? ""
            let label = branch.isEmpty ? "detached " + (git(["rev-parse", "--short", "HEAD"]) ?? "?") : branch
            let status: String, porcelain = git(["status", "--porcelain"])
            if let changes = porcelain {
                if !changes.isEmpty { status = "uncommitted" }
                else if branch.isEmpty { status = "" }
                else if git(["rev-parse", "--abbrev-ref", "@{u}"]) == nil { status = "local only" }
                else if let ahead = git(["rev-list", "--count", "@{u}..HEAD"]) { status = ahead == "0" ? "up to date" : "unpushed" }
                else { status = "status unavailable" }
            } else { status = "status unavailable" }
            return (name, URL(fileURLWithPath: root).lastPathComponent, label, status, root, porcelain?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } ?? [])
        }.value
        guard cwd == directory else { return }
        repositoryDirectory = result.0; repository = result.1; branch = result.2; repositoryStatus = result.3; repositoryChanges = result.5
        if let root = result.4 { refreshPullRequest(root: root, branch: result.2) } else { pullRequest = "" }
    }

    // Keyed by repository and branch, so sessions on one checkout share a gh call and a branch switch fetches again.
    static var pullRequests: [String: (date: Date, label: String, url: String)] = [:]
    func refreshPullRequest(root: String, branch: String) {
        let key = root + "\n" + branch, directory = cwd
        let cached = Session.pullRequests[key]
        pullRequestURL = cached?.url ?? ""; pullRequest = cached?.label ?? ""
        if let cached, Date().timeIntervalSince(cached.date) < 300 { return }
        Session.pullRequests[key] = (Date(), pullRequest, pullRequestURL)
        Task {
            let found = await Task.detached { () -> (String, String) in
                func run(_ arguments: [String]) -> Data? {
                    let process = Process(), output = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = arguments; process.environment = agentEnvironment()
                    process.currentDirectoryURL = URL(fileURLWithPath: root)
                    process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    guard (try? process.run()) != nil else { return nil }
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
                    defer { timeout.cancel() }
                    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                    return process.terminationStatus == 0 ? data : nil
                }
                // gh cannot map a remote to its repository when ~/.ssh/config pins github.com to an IP: -R names it.
                guard let remote = run(["git", "remote", "get-url", "origin"]).map({ String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }),
                      remote.contains("github.com"),
                      let data = run(["gh", "pr", "list", "-R", remote.replacingOccurrences(of: "^.*github\\.com[:/]|\\.git$", with: "", options: .regularExpression),
                                      "--author", "@me", "--state", "open", "--limit", "100", "--json", "number,url,headRefName,isDraft,reviewDecision"]),
                      let list = (try? JSONSerialization.jsonObject(with: data)) as? [JSON],
                      let pull = list.first(where: { $0["headRefName"] as? String == branch }) ?? list.first,
                      let number = pull["number"] as? Int, let url = pull["url"] as? String else { return ("", "") }
                let state = pull["isDraft"] as? Bool == true ? "draft" : ["APPROVED": "approved", "CHANGES_REQUESTED": "changes requested", "REVIEW_REQUIRED": "review required"][pull["reviewDecision"] as? String ?? ""] ?? "open"
                return ("PR #\(number) - " + state + (list.count > 1 ? " +\(list.count - 1)" : ""), url)
            }.value
            Session.pullRequests[key] = (Date(), found.0, found.1)
            guard cwd == directory, self.branch == branch else { return }
            pullRequestURL = found.1; pullRequest = found.0
        }
    }
}
