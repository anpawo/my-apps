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
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.mr.jarvis.open"), object: nil, userInfo: nil, deliverImmediately: true)
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
