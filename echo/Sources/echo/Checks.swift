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

    @Environment(\.renderBackdrop) private var renderBackdrop

    /// What the glass shows: behind the window, through the site's filters. In a render nothing is behind, so the
    /// render's own backdrop goes through the same matrix in its place (a blur leaves a vertical gradient as it is).
    @ViewBuilder private var behindGlass: some View {
        if let renderBackdrop {
            GeometryReader { g in
                let at = g.frame(in: .global)
                LinearGradient(colors: renderBackdrop.map(Glass.filtered), startPoint: .top, endPoint: .bottom)
                    .frame(width: Inbox.screen.width, height: Inbox.screen.height)
                    .offset(x: -at.minX, y: -at.minY)
            }
        } else {
            GlassView(blur: 40, tone: Glass.matrix, radius: Self.radius)
        }
    }

    /// The dialog's overlay over the whole screen: what is behind blurred 4 pt (`backdrop-blur-xs`) under black at 0.3.
    /// A click on it goes back to the lines, as a click outside closes the dialog.
    private var veil: some View {
        ZStack {
            if renderBackdrop == nil { GlassView(blur: 4, tone: nil, radius: 0) }
            Color.black.opacity(0.3)
        }
        .contentShape(Rectangle())
        .onTapGesture { _ = inbox.key(UInt16(kVK_Escape)) }
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
        .background(Self.glass)
        .background { behindGlass }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(.white.opacity(0.4), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(Self.ink.opacity(0.1), lineWidth: 1).padding(-1))
        .onTapGesture {}
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { veil }
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
            // the site's Done, its outline button: white, and the muted grey while pressed
            Text("Done")
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color(white: inbox.pressed == kVK_ANSI_S ? 0.97 : 1), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Self.line, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { _ = inbox.key(UInt16(kVK_ANSI_S)) }
        }
        .padding(16)
        .background(.white.opacity(0.25))
        .overlay(alignment: .top) { Rectangle().fill(Self.line).frame(height: 1) }
    }
}

/// The site's `.light` glass, `backdrop-filter: blur(40px) saturate(200%) brightness(1.15)`, on what is behind the
/// window: a behind-window effect view whose backdrop layer takes those filters, its own tints hidden. Measured through
/// CARenderer: CA's gaussianBlur `inputRadius` is CSS's standard deviation, and a colour matrix gives CSS's saturate
/// and brightness exactly (CA's colorBrightness adds where CSS multiplies).
final class Glass: NSVisualEffectView {
    /// CSS `saturate(200%) brightness(1.15)` on sRGB values, the Filter Effects spec's matrix: rows R, G, B. Times 0.7
    /// first: on the site the dialog stands on its veil, black at 0.3 (globals.css), and the glass shows the page through it.
    static let matrix: [[Double]] = {
        let s = 2.0
        return [[0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s],
                [0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s],
                [0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s]].map { $0.map { $0 * 0.7 * 1.15 } }
    }()

    static func filtered(_ color: Color) -> Color {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map(Double.init)
        let out = matrix.map { row in min(1, max(0, zip(row, v).map(*).reduce(0, +))) }
        return Color(.sRGB, red: out[0], green: out[1], blue: out[2])
    }

    /// A matrix as CAColorMatrix holds it: four rows of five, the R, G, B and A weights, then an offset.
    static func pack(_ matrix: [[Double]]) -> [Float] {
        matrix.flatMap { row -> [Float] in row.map { Float($0) } + [0, 0] } + [0, 0, 0, 1, 0]
    }

    let blur: Double
    /// Nil: the blur alone.
    let tone: [[Double]]?

    /// Nil when QuartzCore no longer has the private filters: the system's own blur stays.
    func filters() -> [NSObject]? {
        guard let type = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        func make(_ name: String) -> NSObject? {
            type.perform(NSSelectorFromString("filterWithType:"), with: name)?.takeUnretainedValue() as? NSObject
        }
        guard let gauss = make("gaussianBlur") else { return nil }
        gauss.setValue("cssBlur", forKey: "name")
        gauss.setValue(blur, forKey: "inputRadius")
        gauss.setValue(true, forKey: "inputNormalizeEdges")
        guard let tone else { return [gauss] }
        guard let colour = make("colorMatrix") else { return nil }
        var m = Self.pack(tone)
        colour.setValue(NSValue(bytes: &m, objCType: "{CAColorMatrix=ffffffffffffffffffff}"), forKey: "inputColorMatrix")
        return [gauss, colour]
    }

    init(blur: Double, tone: [[Double]]?, radius r: CGFloat) {
        self.blur = blur
        self.tone = tone
        super.init(frame: .zero)
        blendingMode = .behindWindow
        state = .active
        guard r > 0 else { return }
        let mask = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        maskImage = mask
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() { super.updateLayer(); takeFilters() }
    override func layout() { super.layout(); takeFilters() }

    /// The material's layer holds the backdrop and the tints over it: the tints go, the backdrop takes the site's
    /// filters after the system's HDR one. Done again whenever the view rebuilds them.
    private func takeFilters() {
        for sub in layer?.sublayers?.flatMap({ $0.sublayers ?? [] }) ?? [] {
            guard sub.name == "backdrop" else { sub.isHidden = true; continue }
            let names = (sub.filters ?? []).compactMap { ($0 as? NSObject)?.value(forKey: "name") as? String }
            guard !names.contains("cssBlur"), let css = filters() else { continue }
            sub.filters = (sub.filters ?? []).filter { ($0 as? NSObject)?.value(forKey: "name") as? String == "sdrNormalize" } + css
        }
    }
}

struct GlassView: NSViewRepresentable {
    let blur: Double
    let tone: [[Double]]?
    let radius: CGFloat
    func makeNSView(context: Context) -> Glass { Glass(blur: blur, tone: tone, radius: radius) }
    func updateNSView(_ view: Glass, context: Context) {}
}

private struct RenderBackdrop: EnvironmentKey { static let defaultValue: [Color]? = nil }

extension EnvironmentValues {
    /// The colours a render stands on, top to bottom; nil on the screen.
    var renderBackdrop: [Color]? {
        get { self[RenderBackdrop.self] }
        set { self[RenderBackdrop.self] = newValue }
    }
}

private extension View {
    /// The site's `block`: rounded-lg, a border, a whiter glass.
    func block() -> some View {
        background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(red: 0xC5 / 255, green: 0xCB / 255, blue: 0xD3 / 255), lineWidth: 1))
    }
}
