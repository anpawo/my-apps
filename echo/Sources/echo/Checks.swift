import Carbon.HIToolbox
import SwiftUI

/// S on the panel: the checks the hourly watcher still waits on, and under them those done in the last 7 days, laid
/// out as the mail-draft dialog of the reconciliation site is (s14 `recon-v3-mr/web`: components/mail.tsx,
/// ui/dialog.tsx, app/globals.css `.light`), at its sizes in points: a frosted dialog, its title in a block, the two
/// sections split by a thin line, a row of field blocks per check, a footer with a button.
struct ChecksView: View {
    @ObservedObject var inbox: Inbox
    /// The site's dialog of one pane, `sm:max-w-3xl`.
    static let width: CGFloat = 768

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
    /// A click on it closes Echo, as a click outside closes the dialog.
    private var veil: some View {
        ZStack {
            if renderBackdrop == nil { GlassView(blur: 4, tone: nil, radius: 0) }
            Color.black.opacity(0.3)
        }
        .contentShape(Rectangle())
        .onTapGesture { _ = inbox.key(UInt16(kVK_Escape)) }
    }

    private var waiting: [CheckEntry] { inbox.checks.filter { $0.state == .waiting } }
    private var done: [CheckEntry] {
        let since = (Date().timeIntervalSince1970 - 7 * 86_400) * 1000
        return inbox.checks.filter { $0.state == .arrived && $0.at >= since }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 36) {
                Text("Checks")
                    .font(.system(size: 30, weight: .medium))
                    .tracking(-0.75)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .block()
                ViewThatFits(in: .vertical) {
                    sections
                    // ImageRenderer draws no NSScrollView: a render shows the list's top, as the scroll does at first
                    if renderBackdrop == nil { ScrollView { sections } } else { sections.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() }
                }
            }
            .padding(16)
            footer
        }
        .font(.system(size: 14))
        .foregroundStyle(Self.ink)
        .frame(width: Self.width)
        .background(Self.glass)
        .background { behindGlass }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(.white.opacity(0.4), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(Self.ink.opacity(0.1), lineWidth: 1).padding(-1))
        .onTapGesture {}
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { veil }
    }

    private var sections: some View {
        let (waiting, done) = (waiting, done)
        // the channels' pills are as wide as the widest of the list, as the mail's names are, up to a width
        let widest = (waiting + done).map { ($0.watching as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width + 22 }
            .reduce(0, max).rounded(.up)
        let via = min(160, widest)
        return VStack(spacing: 24) {
            section("Waiting", waiting, via: via)
            Rectangle().fill(Self.line).frame(height: 1)
            section("Done in the last 7 days", done, via: via)
        }
    }

    private func section(_ title: String, _ entries: [CheckEntry], via: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 18, weight: .semibold))
                pill("\(entries.count)")
            }
            VStack(spacing: 8) { ForEach(entries, id: \.id) { row($0, via: via) } }
            if entries.isEmpty { Text("Nothing here") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A check as a mail of the thread is: its name in a block of its own with no label, as the mail's subject, then
    /// its fields, each a block with its label and a pill, the time in its state's colour. The fields keep one width,
    /// so the columns line up.
    private func row(_ check: CheckEntry, via: CGFloat) -> some View {
        let tone = Self.tone(check.state)
        return HStack(spacing: 8) {
            Text(check.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38, alignment: .leading)
                .block()
            field("Via") { pill(check.watching, fixed: false).frame(width: via, alignment: .leading) }
            field("When") {
                ZStack(alignment: .leading) {
                    pill("00/00 00h00").hidden()
                    pill(Store.when(check.at), fill: tone.fill, ink: tone.ink)
                }
            }
        }
    }
    private func field(_ name: String, @ViewBuilder _ value: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(name).fixedSize()
            value()
        }
        .padding(.horizontal, 12)
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
