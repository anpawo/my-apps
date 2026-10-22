import Foundation

/// `watcher mcp`: a stdio MCP server over the checker's state files, so Claude Code reads and sets aside Watcher's lines
/// without Fleet or the app being in the way. Newline-delimited JSON-RPC, one reply per request.
enum Mcp {
    private static let tools: [[String: Any]] = [
        tool("watcher_lines", "The lines Watcher holds for Marius: what the hourly checker's follow-ups finished (done) or stopped on (needs). `past: true` lists the ones set aside, newest first.",
             ["past": ["type": "boolean"]]),
        tool("watcher_checks", "Every awaited answer the hourly checker watches: waiting, arrived or dropped, and when it last ran.", [:]),
        tool("watcher_set_aside", "Sets one waiting line aside as done (moved to done/, still on disk).",
             ["id": ["type": "string"]], required: ["id"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    static func serve() -> Never {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = request["method"] as? String else { continue }
            // A notification has no id and gets no reply.
            guard let id = request["id"] else { continue }
            reply(id, handle(method, request["params"] as? [String: Any] ?? [:]))
        }
        exit(0)
    }

    private static func handle(_ method: String, _ params: [String: Any]) -> [String: Any] {
        switch method {
        case "initialize":
            return ["result": ["protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                               "capabilities": ["tools": [String: Any]()],
                               "serverInfo": ["name": "watcher", "version": "0.1.0"]]]
        case "tools/list": return ["result": ["tools": tools]]
        case "tools/call":
            let (text, failed) = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
            return ["result": ["content": [["type": "text", "text": text]], "isError": failed]]
        case "ping": return ["result": [String: Any]()]
        default: return ["error": ["code": -32601, "message": "unknown method \(method)"]]
        }
    }

    private static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        switch name {
        case "watcher_lines":
            let past = args["past"] as? Bool ?? false
            let items = past ? Array(Store.lines(in: Store.inbox.appending(path: "done")).reversed().prefix(Store.pastShown))
                             : Store.lines(in: Store.inbox)
            return (json(items.map { ["id": $0.id, "kind": $0.kind, "subject": $0.subject, "line": $0.line,
                                      "at": Store.when($0.at), "dir": $0.dir, "session": $0.session ?? ""] }), false)
        case "watcher_checks":
            let (entries, last) = CheckEntry.load()
            return (json(["last_check": last, "checks": entries.map {
                ["id": $0.id, "name": $0.name, "watching": $0.watching, "state": $0.state.rawValue, "detail": $0.detail]
            }]), false)
        case "watcher_set_aside":
            guard let id = args["id"] as? String, !id.contains("/") else { return ("missing or bad id", true) }
            return Store.take(id) ? ("set aside: \(id)", false) : ("no waiting line \(id)", true)
        default: return ("unknown tool \(name)", true)
        }
    }

    private static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func reply(_ id: Any, _ body: [String: Any]) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
        message.merge(body) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
