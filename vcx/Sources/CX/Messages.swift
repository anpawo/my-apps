import AppKit
import Foundation
import NaturalLanguage

// One agent writes to another VCX window as Marius would type, shaped `claude from [<window name>]: "<text>"` so it is not taken for him.
// `vcx --send` drops a ticket beside the open tickets; the frontend sends it once that window is idle.
@MainActor
enum AgentMessages {
    static let suffix = ".send.json"

    struct Window { let id: String, provider: String, state: String, cwd: String, name: String }

    static func windows() -> [Window] {
        let home = NSHomeDirectory() + "/.local/state/cx"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: home + "/fleet")) ?? []
        var found: [Window] = []
        for file in files where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: home + "/fleet/" + file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? JSON,
                  let pid = (root["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0 else { continue }
            for record in root["sessions"] as? [JSON] ?? [] {
                guard let id = record["sessionId"] as? String else { continue }
                let recovery = FileManager.default.contents(atPath: RuntimeIdentity.directory.path + "/recovery/" + id + ".window.json")
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON }
                let thread = (recovery?["state"] as? JSON)?["threadID"] as? String ?? ""
                let provider = thread.hasPrefix("claude:") ? "claude" : thread.hasPrefix("qwen:") ? "qwen" : "codex"
                let context = (record["context"] as? String).map { $0.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ") } ?? ""
                found.append(Window(id: id, provider: provider, state: record["state"] as? String ?? "?", cwd: record["cwd"] as? String ?? "",
                                    name: context.isEmpty ? title(record["prompt"] as? String ?? "New session") : context))
            }
        }
        return found
    }

    // Fleet's card name for a window with no task label (Fleet VCX.swift shortTitle), so both say the same.
    static func title(_ prompt: String) -> String {
        let text = String(prompt.prefix(2000))
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var words: [String] = []
        let ignored: Set<String> = ["context", "conversation", "user", "assistant", "thing"]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = text[range].lowercased()
            if tag == .noun, !ignored.contains(word), !words.contains(word), (words + [word]).joined(separator: " ").count <= 24 { words.append(word) }
            return words.count < 3
        }
        return words.isEmpty ? "VCX session" : words.joined(separator: " ")
    }

    static func match(_ key: String, _ windows: [Window]) -> Window? {
        let key = key.lowercased()
        let hits = windows.filter { $0.id.lowercased() == key || (key.count >= 4 && $0.id.lowercased().hasPrefix(key)) }
        if hits.count == 1 { return hits[0] }
        let named = windows.filter { $0.name.lowercased() == key }
        return named.count == 1 ? named[0] : nil
    }

    // What another window's agent sent, as he sees it and as the agent reads it.
    static func isMessage(_ text: String) -> Bool {
        ["claude", "codex", "qwen", "agent"].contains { text.hasPrefix($0 + " from [") } && text.contains("]: \"") && text.hasSuffix("\"")
    }

    static func list() -> Int32 {
        let all = windows()
        if all.isEmpty { print("No VCX window is open.") }
        for window in all { print([String(window.id.prefix(8)), window.provider, window.state, window.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"), window.name].joined(separator: "\t")) }
        return 0
    }

    static func send(_ args: [String]) -> Int32 {
        var words: [String] = [], from: String?, i = 0
        while i < args.count {
            if args[i] == "--from", i + 1 < args.count { from = args[i + 1]; i += 2; continue }
            words.append(args[i]); i += 1
        }
        guard words.count >= 2 else {
            FileHandle.standardError.write(Data("usage: vcx --send <window id or name> [--from <window id or name>] <message…>   (message - reads stdin; vcx --sessions lists windows)\n".utf8))
            return 2
        }
        var text = words.dropFirst().joined(separator: " ")
        if text == "-" { text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = windows()
        guard !text.isEmpty, let target = match(words[0], all) else {
            FileHandle.standardError.write(Data((text.isEmpty ? "Empty message.\n" : "No single open window matches \(words[0]). Open windows:\n" + all.map { "  \($0.id.prefix(8))  \($0.provider)  \($0.name)" }.joined(separator: "\n") + "\n").utf8))
            return 1
        }
        // A Claude agent carries its transcript id, a Qwen command the thread VCX gave it; either names the window it runs in.
        let environment = ProcessInfo.processInfo.environment
        let threads = [environment["CLAUDE_CODE_SESSION_ID"].map { "claude:" + $0 }, environment["VCX_THREAD_ID"]].compactMap { $0 }
        let caller = all.first { window in
            let data = FileManager.default.contents(atPath: RuntimeIdentity.directory.path + "/recovery/" + window.id + ".window.json")
            let thread = ((data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON })?["state"] as? JSON)?["threadID"] as? String
            return thread.map(threads.contains) ?? false
        }
        let sender = from.flatMap { match($0, all) } ?? caller
        let message = "\(sender?.provider ?? "agent") from [\(sender?.name ?? "unknown")]: \"\(text)\""
        do {
            let ticket = try RuntimeUpdate.writeTicket(["sessionId": target.id, "text": message, "sentAt": Date().timeIntervalSince1970], suffix: suffix)
            DistributedNotificationCenter.default().postNotificationName(RuntimeUpdate.openNotification, object: nil, userInfo: nil, deliverImmediately: true)
            for _ in 0..<30 where FileManager.default.fileExists(atPath: ticket.path) { usleep(100_000) }
            print(FileManager.default.fileExists(atPath: ticket.path)
                  ? "Queued for \"\(target.name)\" (\(target.id.prefix(8)), \(target.state)): it is sent when that window is idle."
                  : "Sent to \"\(target.name)\" (\(target.id.prefix(8)), \(target.provider)).")
            return 0
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); return 1 }
    }

    private static var retrying = false

    static func drain(_ windows: [AppDelegate.FrontendWindow]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: RuntimeIdentity.directory, includingPropertiesForKeys: nil)) ?? []
        var waiting = false
        for file in files where file.lastPathComponent.hasSuffix(suffix) {
            guard let value = try? RuntimeUpdate.readTicket(file.path, suffix: suffix), let id = value["sessionId"] as? String,
                  let text = value["text"] as? String else { try? FileManager.default.removeItem(at: file); continue }
            guard let session = windows.first(where: { $0.session.runtimeClient?.sessionID == id })?.session else {
                // Its window closed, or this frontend does not hold it yet (an update in flight): keep it an hour.
                if Date().timeIntervalSince1970 - (value["sentAt"] as? Double ?? 0) > 3600 { try? FileManager.default.removeItem(at: file) }
                continue
            }
            guard session.ready, !session.busy, !session.changing else { waiting = true; continue }
            try? FileManager.default.removeItem(at: file)
            // A generation no draft has, so his half-typed draft in that window stays where it is.
            Task { await session.send(text: text, images: [], commandHandled: true, expectedDraft: NSAttributedString(), expectedGeneration: -1) }
        }
        guard waiting, !retrying else { return }
        retrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { retrying = false; (NSApp.delegate as? AppDelegate)?.drainOpenRequests() }
        }
    }
}
