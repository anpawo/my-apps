import AppKit
import SwiftUI

/// The Jarvis app (`~/self/jarvis`), a card on the grid while it runs on its Qwen chat (asked
/// 2026-11-01): the screen it keeps in its defaults to open on, panel shown or not.
enum Jarvis {
    static let bundle = "com.mr.jarvis"

    static var onQwen: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
            && UserDefaults(suiteName: bundle)?.bool(forKey: "jarvisChatting") == true
    }

    /// Its panel, where he left it. An agent app has no window for `activate` to raise.
    static func open() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.mr.jarvis.open"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    static let icon: NSImage? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        .map { NSWorkspace.shared.icon(forFile: $0.path) }
}

/// Jarvis's card: a session card's shape, its icon where a session has nothing, the chat under
/// the name where a session has its folder, and the border in the icon's own colours, which no
/// state wears.
struct JarvisTile: View {
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
