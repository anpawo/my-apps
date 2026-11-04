import AppKit

@MainActor
extension Session {
    func applyClaudeCatalog(_ catalog: JSON) {
        if let commands = catalog["commands"] as? [JSON] {
            providerCommands = commands.flatMap { command -> [ChatCommand] in
                guard let name = command["name"] as? String else { return [] }
                let names = [name] + (command["aliases"] as? [String] ?? [])
                return names.map { ChatCommand(name: "/" + $0, detail: command["description"] as? String ?? "Claude command", source: "Claude", insert: "/claude:skill:" + $0 + " ") }
            }
            skills = commands.compactMap { $0["name"] as? String }.sorted()
        }
        if let catalog = catalog["models"] as? [JSON] { models = catalog.compactMap { $0["value"] as? String } }
        if let mode = catalog["current_permission_mode"] as? String { activeMode = mode == "bypassPermissions" ? "bypass" : "ask" }
        if let servers = catalog["mcp_servers"] as? [JSON] { mcp = servers.compactMap { server in (server["name"] as? String).map { $0 + " · " + (server["status"] as? String ?? "configured") } }.sorted() }
    }

    func refreshCapabilities() async {
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
            let files = [URL(fileURLWithPath: base).appendingPathComponent("settings.json")] + folders.flatMap { folder in [".claude/settings.json", ".claude/settings.local.json"].map { folder.appendingPathComponent($0) } }
            hooks = files.flatMap { file -> [String] in
                guard let data = try? Data(contentsOf: file), let value = try? JSONSerialization.jsonObject(with: data) as? JSON else { return [] }
                return (value["hooks"] as? JSON ?? [:]).keys.sorted().map { $0 + " · configured · " + file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
            }
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
            providerCommands = catalog.compactMap { item in guard let name = item["name"] as? String else { return nil }; return ChatCommand(name: "/" + name, detail: item["description"] as? String ?? "Codex skill", source: "Codex skill", insert: "/codex:skill:" + name + " ") }
        } catch { guard rpc === connection else { return }; skills = ["Catalog unavailable: " + error.localizedDescription] }
        do {
            let result = try await connection.request("hooks/list", ["threadId": threadID ?? ""], timeout: 15)
            guard rpc === connection else { return }
            hooks = (result["data"] as? [JSON] ?? []).flatMap { $0["hooks"] as? [JSON] ?? [] }.map { ($0["eventName"] as? String ?? "Hook") + " · " + ($0["enabled"] as? Bool == false ? "disabled" : $0["trustStatus"] as? String ?? "configured") }
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
            mcp = servers.compactMap { s in (s["name"] as? String).map { $0 + " · " + (s["runtimeStatus"] as? String ?? s["authStatus"] as? String ?? "configured") } }.sorted()
        } catch { if rpc === connection { mcp = ["Catalog unavailable: " + error.localizedDescription] } }
    }
    func refreshRepository() async {
        let directory = cwd
        let result = await Task.detached { () -> [String] in
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory, "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do { try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); guard process.terminationStatus == 0 else { return [] }; return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) } catch { return [] }
        }.value
        guard cwd == directory else { return }
        repository = result.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No repository"
        branch = result.count > 1 ? result[1] : ""
    }
}
