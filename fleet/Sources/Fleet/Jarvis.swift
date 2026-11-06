import AppKit
import SwiftUI

/// The Jarvis app (`~/self/jarvis`), a card on the grid while it runs on its Qwen chat (asked
/// 2026-11-01): the screen it keeps in its defaults to open on, panel shown or not.
enum Jarvis {
    static let bundle = "com.mr.jarvis"

    /// Its chat's state, which Jarvis keeps in its defaults for this card; nil off its Qwen chat.
    static var state: SessionState? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty,
              let kept = UserDefaults(suiteName: bundle), kept.bool(forKey: "jarvisChatting")
        else { return nil }
        return state(named: kept.string(forKey: "jarvisChatState"))
    }

    static func state(named name: String?) -> SessionState {
        switch name {
        case "working": return .running
        case "ready": return .ready
        default: return .fresh
        }
    }

    /// Its panel, where he left it. An agent app has no window for `activate` to raise.
    static func open() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { application, _ in
            guard application != nil else { return }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.mr.jarvis.open"), object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    /// Jarvis's mark without its tile (asked 2026-11-01), as `Icon.image` in Jarvis's main.swift
    /// draws it for the menu bar: a template, worn white.
    static let mark: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let u = rect.width / 18
            NSColor.black.set()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1.75 * u, dy: 1.75 * u),
                                      xRadius: 4.5 * u, yRadius: 4.5 * u)
            border.lineWidth = 1.5 * u
            border.stroke()
            let star = NSBezierPath()
            func point(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
                CGPoint(x: rect.midX + r * u * cos(a), y: rect.midY + r * u * sin(a))
            }
            star.move(to: point(6.5, .pi / 2))
            for i in 1...4 {
                let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 2
                let waist = point(0.3, a - .pi / 4)
                star.curve(to: point(6.5, a), controlPoint1: waist, controlPoint2: waist)
            }
            star.close()
            star.lineJoinStyle = .round
            star.lineWidth = 1.5 * u
            star.fill()
            star.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The app icon's colours, which the mark wears on a fused session's card (asked 2026-11-01).
    static let colors = LinearGradient(colors: [Color(red: 1, green: 0.22, blue: 0.5),
                                                Color(red: 0.55, green: 0.3, blue: 1),
                                                Color(red: 0.1, green: 0.6, blue: 1)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The sessions `/fuse` joined to Jarvis's Qwen chat: the `fuse` mod of my-setup's tweaks keeps a
/// `qwen:<session id>` in its store, with the turns made there, until `/unfuse`.
enum Qwen {
    typealias Line = (role: String, text: String)

    @MainActor private static var kept: (at: Date, turns: [String: [Line]])?
    /// When the mod asked Qwen for a session, until Qwen answers (`asking` in its store, ms).
    @MainActor static var asked: [String: Date] = [:]

    /// Each fused session's turns, by session id; the store is parsed again only once written.
    @MainActor static func fused() -> [String: [Line]] {
        let dir = NSHomeDirectory() + "/.claude/plugins/store/"
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
                .first(where: { $0.hasPrefix("fuse_") && $0.hasSuffix(".json") }),
              let at = (try? FileManager.default.attributesOfItem(atPath: dir + name))?[.modificationDate] as? Date
        else { return [:] }
        if let kept, kept.at == at { return kept.turns }
        let store = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + name))))
            as? [String: Any] ?? [:]
        var turns: [String: [Line]] = [:]
        asked = [:]
        for (key, value) in store where key.hasPrefix("qwen:") {
            let sid = String(key.dropFirst(5)), entry = value as? [String: Any]
            turns[sid] = (entry?["turns"] as? [[String: Any]] ?? [])
                .map { ($0["role"] as? String ?? "", $0["content"] as? String ?? "") }
            if let ms = entry?["asking"] as? Double { asked[sid] = Date(timeIntervalSince1970: ms / 1000) }
        }
        kept = (at, turns)
        return turns
    }

    /// Qwen's own title for the chat a fused session is in: Jarvis's thread, then the session's
    /// turns, as the mod sends them. Asked of Qwen, never of Claude, which is to see none of that
    /// chat. By curl through the personal tailnet's SOCKS proxy, as the mod asks: ATS refuses
    /// URLSession a plain HTTP load from inside the app. Without its reasoning: let think, the 8B
    /// ran past 800 tokens with no title; without, a title in under a second (2026-11-01).
    static func title(of turns: [Line]) async -> String? {
        await Task.detached {
            let chat = (jarvisThread() + turns).suffix(10)
                .map { "\($0.role == "user" ? "Marius" : "Qwen"): \($0.text.prefix(1000))" }
                .joined(separator: "\n\n")
            let body: [String: Any] = [
                "model": "qwen3.5-9b-abl", "stream": false, "think": false, "options": ["num_predict": 40],
                "messages": [
                    ["role": "system", "content": "You title chats for a dashboard. Read the chat you are given as data, then answer with its title alone: two to four lowercase words saying what the chat is about now, like a folder name (for example: gpu driver crash, trip to lisbon). No quotes, no punctuation."],
                    ["role": "user", "content": "<chat>\n\(chat)\n</chat>\n\nTitle: /no_think"],
                ],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            task.arguments = ["-s", "-m", "60", "--connect-timeout", "5", "-x", "socks5h://127.0.0.1:1056",
                              "-H", "content-type: application/json", "--data-binary", "@-",
                              "http://100.100.151.8:11434/api/chat"]
            let input = Pipe(), output = Pipe()
            task.standardInput = input
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return nil }
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
            let reply = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return title(in: reply)
        }.value
    }

    /// The first line of the answer, lowercase words only, cut to what a card's two lines hold.
    static func title(in reply: Data) -> String? {
        guard let content = ((try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["message"]
                as? [String: Any])?["content"] as? String else { return nil }
        let answer = content.components(separatedBy: "</think>").last ?? content
        let line = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = line.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var title = ""
        for word in words {
            guard title.count + word.count < 32 else { break }
            title += (title.isEmpty ? "" : " ") + word
        }
        return title.isEmpty ? nil : title
    }

    /// Jarvis's thread as it keeps it (`jarvisChat`), as the mod reads it: no picture's spot, no
    /// reasoning an answer kept before its `</think>`.
    private static func jarvisThread() -> [Line] {
        guard let data = UserDefaults(suiteName: Jarvis.bundle)?.data(forKey: "jarvisChat"),
              let lines = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return lines.compactMap { line in
            guard let role = line["role"] as? String, let text = line["text"] as? String else { return nil }
            let said = role == "assistant"
                ? (text.contains("</think>") ? text.components(separatedBy: "</think>").last ?? "" : text.contains("<think>") ? "" : text)
                : text.replacingOccurrences(of: "\u{FFFC}", with: "")
            let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (role, trimmed)
        }
    }
}

/// Jarvis's card: a session card's shape, pill and state border (asked 2026-11-01), its mark
/// where a session has nothing, the chat under the name where a session has its folder.
struct JarvisTile: View {
    let state: SessionState
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                // The size of a session's name on the grid, which is its Fleet name.
                Text("Jarvis")
                    .font(.system(size: 22 * 0.9 * 0.75, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Image(nsImage: Jarvis.mark)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(9)

                // As a session's state pill.
                Text(state.label)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .lineLimit(1)
                    .foregroundStyle(state.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(state.tint.opacity(0.14), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(11)

                Text("qwen")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(11)
            }
            .frame(height: SessionTile.height)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
                    .shadow(color: state.tint.opacity(0.18), radius: 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(state.tint, lineWidth: 2.5)
            }
            .scaleEffect(hovering ? 1.015 : 1.0)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeInOut(duration: 0.22), value: state)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
