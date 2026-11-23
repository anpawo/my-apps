import Foundation

// vcx --agy-check: one live Antigravity conversation through AgyConnection (uses a little of agy's quota).
enum AgyCheck {
    static let turnLimit: Double = 180

    @MainActor
    // No ask-mode case: agy's own settings allow every action, so it never asks VCX.
    static func run() async -> Bool {
        var failed = false
        func check(_ value: Bool, _ message: String) { print((value ? "ok: " : "FAIL: ") + message); if !value { failed = true } }
        var events: [JSON] = []
        func turn(_ agy: AgyConnection, _ prompt: String, approve: Bool? = nil) async throws -> JSON? {
            events = []
            var done: JSON?
            agy.event = { message in
                events.append(message)
                if message["method"] as? String == "item/commandExecution/requestApproval", let id = message["id"], let approve { try? agy.respond(id, ["decision": approve ? "accept" : "decline"]) }
                if message["method"] as? String == "turn/completed" { done = (message["params"] as? JSON)?["turn"] as? JSON }
            }
            _ = try await agy.request("turn/start", ["input": [["type": "text", "text": prompt]]], timeout: 30)
            let end = Date().addingTimeInterval(turnLimit)
            while done == nil, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
            return done
        }
        func items(_ type: String) -> [JSON] {
            events.filter { $0["method"] as? String == "item/completed" }.compactMap { ($0["params"] as? JSON)?["item"] as? JSON }.filter { $0["type"] as? String == type }
        }
        let directory = NSTemporaryDirectory()
        do {
            let agy = AgyConnection(cwd: directory)
            try await agy.start()
            let opened = try await agy.request("thread/start", ["cwd": directory, "approvalPolicy": "never"], timeout: 60)
            let thread = (opened["thread"] as? JSON)?["id"] as? String ?? ""
            check(thread.hasPrefix("agy:") && !(opened["model"] as? String ?? "").isEmpty, "a new conversation has an agy: thread and a model")
            check(!((try await agy.request("model/list", [:], timeout: 5))["data"] as? [JSON] ?? []).isEmpty, "model/list names agy's models")
            let first = try await turn(agy, "Run the shell command `echo vcx-agy-ok` with your terminal tool, then reply with just: done")
            let commands = items("commandExecution")
            check(first?["status"] as? String == "completed", "a turn completes (status \(first?["status"] ?? "none"))")
            check(commands.contains { ($0["aggregatedOutput"] as? String ?? "").contains("vcx-agy-ok") && $0["exitCode"] as? Int == 0 }, "in bypass a command runs without asking and its output comes back")
            check(!items("agentMessage").isEmpty && events.contains { $0["method"] as? String == "item/agentMessage/delta" }, "the answer streams, then completes as a message")
            check(events.contains { $0["method"] as? String == "cx/tokens" } && events.contains { $0["method"] as? String == "cx/context" }, "token use and context fill are reported")
            check(!events.contains { $0["method"] as? String == "item/commandExecution/requestApproval" }, "bypass never asks")
            agy.close()
            let again = AgyConnection(cwd: directory)
            try await again.start()
            let resumed = try await again.request("thread/resume", ["threadId": thread, "cwd": directory, "approvalPolicy": "never"], timeout: 60)
            check((resumed["thread"] as? JSON)?["id"] as? String == thread, "a conversation resumes in a new process")
            let recall = try await turn(again, "What exact string did the first shell command you ran in this conversation print? Reply with just that string.")
            check(recall?["status"] as? String == "completed" && items("agentMessage").contains { ($0["text"] as? String ?? "").contains("vcx-agy-ok") }, "a resumed conversation remembers its history")
            again.close()
        } catch { check(false, "Antigravity: " + error.localizedDescription) }
        return !failed
    }
}
