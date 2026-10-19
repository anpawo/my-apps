import Carbon.HIToolbox
import SwiftUI

/// S on the panel: every check the hourly watcher has, dropped ones marked.
struct ChecksView: View {
    @ObservedObject var inbox: Inbox
    static let shown = 18

    private static func colour(_ state: CheckEntry.State) -> Color {
        switch state {
        case .waiting: return Color(red: 0.40, green: 0.70, blue: 1.00)
        case .dropped: return Color(red: 1.00, green: 0.45, blue: 0.40)
        case .arrived: return Color(red: 0.24, green: 0.82, blue: 0.35)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Checks")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 22)
                .frame(height: 34)
                .block(in: Capsule())
            Text("Last check \(inbox.lastCheck)")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 22)
                .frame(height: 34)
                .block(in: Capsule())
            VStack(spacing: 3) {
                ForEach(inbox.checks.prefix(Self.shown), id: \.id) { row($0) }
                if inbox.checks.count > Self.shown {
                    Text("+ \(inbox.checks.count - Self.shown) arrived earlier").font(.system(size: 11)).opacity(0.6)
                }
            }
            KeyBubble(symbol: "gearshape", label: "back", off: false, tint: nil, icon: nil, pressed: inbox.pressed == kVK_ANSI_S) {
                _ = inbox.key(UInt16(kVK_ANSI_S))
            }
        }
        .fixedSize()
        .foregroundStyle(Spotlight.ink)
        .padding(.top, Inbox.margin)
        .frame(width: Inbox.window.width, height: Inbox.settingsHeight, alignment: .top)
    }

    private func row(_ check: CheckEntry) -> some View {
        HStack(spacing: 14) {
            Text(check.state.rawValue.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Self.colour(check.state))
                .frame(width: 62, alignment: .leading)
            Text(check.name).font(.system(size: 13, weight: .semibold)).frame(width: 300, alignment: .leading)
            Text(check.watching).font(.system(size: 12)).opacity(0.7).frame(width: 130, alignment: .leading)
            Text(check.detail).font(.system(size: 12)).frame(width: 290, alignment: .leading)
        }
        .lineLimit(1)
        .padding(.horizontal, 22)
        .frame(height: 24)
        .block(in: Capsule(), fill: Spotlight.fill.mix(with: check.state == .dropped ? Self.colour(.dropped) : .clear, by: 0.25))
    }
}
