import AppKit
import SwiftUI

/// The Jarvis app (`~/self/jarvis`), a card on the grid while it runs and the PC's ollama has a
/// Qwen loaded, which is what `ollama ps` calls running (asked 2026-11-01).
enum Jarvis {
    static let bundle = "com.mr.jarvis"

    static var running: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    /// The Qwen ollama holds, without its `:latest`; nil for none, or a PC out of reach. Asked
    /// as Jarvis's own chat asks, curl through the personal tailnet's SOCKS proxy: ATS refuses
    /// URLSession a plain HTTP load from inside an app (measured 2026-11-01).
    static func qwen() async -> String? {
        await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            task.arguments = ["-s", "-m", "3", "-x", "socks5h://127.0.0.1:1056",
                              "http://100.100.151.8:11434/api/ps"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return qwen(in: data)
        }.value
    }

    static func qwen(in data: Data) -> String? {
        guard let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"]
                as? [[String: Any]]
        else { return nil }
        return models.compactMap { $0["name"] as? String }
            .first { $0.lowercased().contains("qwen") }
            .map { $0.hasSuffix(":latest") ? String($0.dropLast(7)) : $0 }
    }

    /// Its panel, where he left it. An agent app has no window for `activate` to raise.
    static func open() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.mr.jarvis.open"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    static let icon: NSImage? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        .map { NSWorkspace.shared.icon(forFile: $0.path) }
}

/// Jarvis's card: a session card's shape, its icon where a session has nothing, the model under
/// the name where a session has its folder, and the border in the icon's own colours, which no
/// state wears.
struct JarvisTile: View {
    let model: String
    let onSelect: () -> Void

    @State private var hovering = false

    private static let colors = [Color(red: 1, green: 0.22, blue: 0.5), Color(red: 0.55, green: 0.3, blue: 1),
                                 Color(red: 0.1, green: 0.6, blue: 1)]

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Text("Jarvis")
                    .font(.system(size: 31 * 0.9 * 0.75, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let icon = Jarvis.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                }

                Text(model)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(11)
            }
            .frame(height: SessionTile.height)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
                    .shadow(color: Self.colors[1].opacity(0.18), radius: 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LinearGradient(colors: Self.colors, startPoint: .topLeading,
                                                 endPoint: .bottomTrailing), lineWidth: 2.5)
            }
            .scaleEffect(hovering ? 1.015 : 1.0)
            .animation(.easeOut(duration: 0.18), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
