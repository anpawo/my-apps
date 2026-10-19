import Carbon.HIToolbox
import SwiftUI

/// S on the panel: every check the hourly watcher has, laid out as the mail-draft dialog of the reconciliation site
/// is (s14 `recon-v3-mr/web`: components/mail.tsx, ui/dialog.tsx, app/globals.css `.light`), at its sizes in points:
/// a frosted dialog, its title in a block, two panes split by a thin line, label-and-pill rows, a footer with a button.
struct ChecksView: View {
    @ObservedObject var inbox: Inbox
    static let rows = 9
    static let width: CGFloat = 1280

    private static let ink = Color(red: 0x1C / 255, green: 0x21 / 255, blue: 0x27 / 255)
    private static let line = Color(red: 0xC5 / 255, green: 0xCB / 255, blue: 0xD3 / 255)
    private static let blue = Color(red: 0x2D / 255, green: 0x72 / 255, blue: 0xD2 / 255)
    private static let glass = Color(red: 220 / 255, green: 224 / 255, blue: 229 / 255).opacity(0.4)
    private static let radius: CGFloat = 14

    private static func hex(_ v: Int) -> Color {
        Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }

    /// Tailwind's -100 fill and -900 ink, as the site's pills have them (`tone-usual`, `tone-added`).
    private static func tone(_ state: CheckEntry.State) -> (fill: Color, ink: Color) {
        switch state {
        case .waiting: return (hex(0xDBEAFE), hex(0x1C398E))
        case .dropped: return (hex(0xFEE2E2), hex(0x82181A))
        case .arrived: return (hex(0xDCFCE7), hex(0x0D542B))
        }
    }

    private var waiting: [CheckEntry] { inbox.checks.filter { $0.state == .waiting } }
    private var settled: [CheckEntry] { inbox.checks.filter { $0.state != .waiting } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 36) {
                Text("Checks")
                    .font(.system(size: 30, weight: .medium))
                    .tracking(-0.75)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .block()
                HStack(alignment: .top, spacing: 24) {
                    pane("Waiting", waiting)
                    Rectangle().fill(Self.line).frame(width: 1)
                    pane("Dropped and arrived", settled)
                }
            }
            .padding(16)
            footer
        }
        .font(.system(size: 14))
        .foregroundStyle(Self.ink)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .background(Self.glass)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(.white.opacity(0.4), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(Self.ink.opacity(0.1), lineWidth: 1).padding(-1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(.top, Inbox.margin)
        .frame(width: Inbox.window.width, height: Inbox.settingsHeight, alignment: .top)
    }

    private func pane(_ title: String, _ entries: [CheckEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 18, weight: .semibold))
                pill("\(entries.count)")
            }
            VStack(spacing: 8) {
                ForEach(entries.prefix(Self.rows), id: \.id) { row($0) }
                if entries.count > Self.rows { Text("+ \(entries.count - Self.rows) more").padding(.top, 2) }
                if entries.isEmpty { Text("Nothing here").padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CGFloat(Self.rows * 38 + (Self.rows - 1) * 8 + 62), alignment: .top)
    }

    private func row(_ check: CheckEntry) -> some View {
        let tone = Self.tone(check.state)
        return HStack(spacing: 12) {
            Text(check.name).fontWeight(.medium).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            pill(check.watching, fixed: false).frame(maxWidth: 170, alignment: .leading)
            pill(check.short, fill: tone.fill, ink: tone.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 38)
        .block()
    }

    private func pill(_ text: String, fill: Color? = nil, ink: Color? = nil, fixed: Bool = true) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: fixed, vertical: false)
            .foregroundStyle(ink ?? Self.ink)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(fill ?? Self.ink.opacity(0.08), in: Capsule())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            pill("Last check \(inbox.lastCheck)")
            Spacer()
            Text("Done")
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Self.blue.opacity(inbox.pressed == kVK_ANSI_S ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .onTapGesture { _ = inbox.key(UInt16(kVK_ANSI_S)) }
        }
        .padding(16)
        .background(.white.opacity(0.25))
        .overlay(alignment: .top) { Rectangle().fill(Self.line).frame(height: 1) }
    }
}

private extension View {
    /// The site's `block`: rounded-lg, a border, a whiter glass.
    func block() -> some View {
        background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(red: 0xC5 / 255, green: 0xCB / 255, blue: 0xD3 / 255), lineWidth: 1))
    }
}
