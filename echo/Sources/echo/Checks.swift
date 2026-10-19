import Carbon.HIToolbox
import SwiftUI

/// S on the panel: every check the hourly watcher has, laid out as the mail-draft preview of the reconciliation
/// site is: a frosted card, a title in a pill, two columns of label-and-pill rows, a footer with a Done button.
struct ChecksView: View {
    @ObservedObject var inbox: Inbox
    static let rows = 9
    static let width: CGFloat = 1240

    private static let ink = Color(white: 0.10)
    private static let panel = Color(white: 0.85).opacity(0.88)
    private static let pill = Color(white: 0.96).opacity(0.75)

    private static func tint(_ state: CheckEntry.State) -> Color {
        switch state {
        case .waiting: return Color(red: 0.78, green: 0.88, blue: 1.00)
        case .dropped: return Color(red: 1.00, green: 0.80, blue: 0.77)
        case .arrived: return Color(red: 0.80, green: 0.95, blue: 0.82)
        }
    }

    private var waiting: [CheckEntry] { inbox.checks.filter { $0.state == .waiting } }
    private var settled: [CheckEntry] { inbox.checks.filter { $0.state != .waiting } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 22) {
                Text("Checks")
                    .font(.system(size: 30, weight: .medium))
                    .padding(.horizontal, 26)
                    .frame(height: 56)
                    .background(Self.pill, in: RoundedRectangle(cornerRadius: 14))
                HStack(alignment: .top, spacing: 28) {
                    column("Waiting", waiting)
                    Rectangle().fill(Self.ink.opacity(0.18)).frame(width: 1)
                    column("Dropped and arrived", settled)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 22)
            footer
        }
        .foregroundStyle(Self.ink)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(LinearGradient(colors: [Color(white: 0.70), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(.top, Inbox.margin)
        .frame(width: Inbox.window.width, height: Inbox.settingsHeight, alignment: .top)
    }

    private func column(_ title: String, _ entries: [CheckEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 20, weight: .semibold))
                pill("\(entries.count)")
            }
            .padding(.bottom, 2)
            ForEach(entries.prefix(Self.rows), id: \.id) { row($0) }
            if entries.count > Self.rows {
                Text("+ \(entries.count - Self.rows) more").font(.system(size: 12)).opacity(0.6).padding(.leading, 6)
            }
            if entries.isEmpty { Text("Nothing here").font(.system(size: 13)).opacity(0.6).padding(.leading, 6) }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: CGFloat(Self.rows * 50 + 40), alignment: .top)
    }

    private func row(_ check: CheckEntry) -> some View {
        HStack(spacing: 10) {
            Text(check.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            pill(check.watching, fixed: false).frame(maxWidth: 170, alignment: .leading)
            pill(check.short, fill: Self.tint(check.state))
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Self.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private func pill(_ text: String, fill: Color? = nil, fixed: Bool = true) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: fixed, vertical: false)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(fill ?? Self.pill, in: Capsule())
    }

    private var footer: some View {
        HStack {
            pill("Last check \(inbox.lastCheck)")
            Spacer()
            Text("Done")
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(.white.opacity(inbox.pressed == kVK_ANSI_S ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .onTapGesture { _ = inbox.key(UInt16(kVK_ANSI_S)) }
        }
        .padding(.horizontal, 26)
        .frame(height: 64)
        .background(Color(white: 0.40).opacity(0.45))
    }
}
