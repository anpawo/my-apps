import Carbon.HIToolbox
import SwiftUI

/// S on the panel: the checks the hourly watcher still waits on, and under them those done in the last 7 days, laid
/// out as the mail-draft dialog of the reconciliation site is (s14 `recon-v3-mr/web`: components/mail.tsx,
/// ui/dialog.tsx, app/globals.css `.light`), at its sizes in points: a frosted dialog, its title in a block, the two
/// sections split by a thin line, a block per check, a footer with a button.
struct ChecksView: View {
    @ObservedObject var inbox: Inbox
    /// The site's dialog of one pane, `sm:max-w-3xl`.
    static let width: CGFloat = 768

    private static func hex(_ v: Int) -> Color {
        Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }

    /// Tailwind's pink-100 fill and pink-900 ink, as the site's pills have their colours: every channel's, its logo
    /// telling them apart.
    private static let pink = (fill: hex(0xFCE7F3), ink: hex(0x861043))

    @Environment(\.renderBackdrop) private var renderBackdrop
    @State private var hovered: String?

    private var waiting: [CheckEntry] { inbox.checks.filter { $0.state == .waiting } }
    private var done: [CheckEntry] {
        let since = (Date().timeIntervalSince1970 - 7 * 86_400) * 1000
        return inbox.checks.filter { $0.state == .arrived && $0.at >= since }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 36) {
                Text("Watch list")
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
        .foregroundStyle(Site.ink)
        .frame(width: Self.width)
        .card()
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sections: some View {
        let (waiting, done) = (waiting, done)
        // the channels' pills are as wide as the widest of the list, as the mail's names are, up to a width
        let widest = (waiting + done).map { ($0.watching as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width + 44 }
            .reduce(0, max).rounded(.up)
        let via = min(260, widest)
        return VStack(spacing: 24) {
            section("Watching", waiting, via: via)
            Rectangle().fill(Site.line).frame(height: 1)
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

    /// A check in one block, as a field of the mail is: its name, then the pills of its channel, with the logo of
    /// what it reads, of how often it is read, and of its day and time. They keep one width, so the columns line up. Under
    /// the pointer, a check done shows Add back over its time, unless it is watched again already.
    private func row(_ check: CheckEntry, via: CGFloat) -> some View {
        let addable = check.state == .arrived && !waiting.contains { $0.id == check.id }
        return HStack(spacing: 16) {
            title(check)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            pill(check.watching, logo: check.logo, fill: Self.pink.fill, ink: Self.pink.ink, fixed: false).frame(width: via, alignment: .leading)
            // every waiting check is read in the checker's one run, at :10 of every hour (LaunchAgent mac.checker)
            pill("Hourly").opacity(check.state == .waiting ? 1 : 0)
            pill(Store.when(check.at, day: true))
                .monospacedDigit()
                .overlay {
                    if addable && hovered == check.id { addBack(check) }
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .block()
        .onHover { hovered = $0 ? check.id : hovered == check.id ? nil : hovered }
    }

    /// The name, with the one it is awaited from in a grey pill; a space beside the pill becomes its margin.
    @ViewBuilder private func title(_ check: CheckEntry) -> some View {
        if let p = check.parts {
            HStack(spacing: 0) {
                if !p.before.isEmpty { Text(p.before.trimmingCharacters(in: .whitespaces)).layoutPriority(1) }
                pill(p.who)
                    .padding(.leading, p.before.last?.isWhitespace == true ? 5 : 0)
                    .padding(.trailing, p.after.first?.isWhitespace == true ? 5 : 0)
                if !p.after.isEmpty { Text(p.after.trimmingCharacters(in: .whitespaces)) }
            }
        } else {
            Text(check.name)
        }
    }

    /// The site's outline button, as Done is, at a row's size, covering the time.
    private func addBack(_ check: CheckEntry) -> some View {
        Text("Add back")
            .fontWeight(.medium)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Site.line, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { inbox.addBack(check) }
    }

    private func pill(_ text: String, logo name: String? = nil, fill: Color? = nil, ink: Color? = nil, fixed: Bool = true) -> some View {
        HStack(spacing: 6) {
            if let name { logo(name) }
            Text(text)
                .lineLimit(1)
                .fixedSize(horizontal: fixed, vertical: false)
        }
        .foregroundStyle(ink ?? Site.ink)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(fill ?? Site.ink.opacity(0.08), in: Capsule())
    }

    /// A brand's logo from the app's `logos`, else the SF Symbol of that name, in the pill's ink.
    private func logo(_ name: String) -> some View {
        Group {
            if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "logos"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: name).font(.system(size: 12))
            }
        }
        .frame(width: 16, height: 16)
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
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Site.line, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { _ = inbox.key(UInt16(kVK_ANSI_S)) }
        }
        .padding(16)
        .background(.white.opacity(0.25))
        .overlay(alignment: .top) { Rectangle().fill(Site.line).frame(height: 1) }
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

/// The colours of the site's `.light` dialog, which every view of Watcher takes.
enum Site {
    static let ink = Color(red: 0x1C / 255, green: 0x21 / 255, blue: 0x27 / 255)
    static let line = Color(red: 0xC5 / 255, green: 0xCB / 255, blue: 0xD3 / 255)
    static let glass = Color(red: 220 / 255, green: 224 / 255, blue: 229 / 255).opacity(0.4)
    static let radius: CGFloat = 14
}

/// The site's dialog: its frosted glass, rounded, a white rim inside a dark one. A click on it stays in it.
private struct Card: ViewModifier {
    @Environment(\.renderBackdrop) private var renderBackdrop

    func body(content: Content) -> some View {
        content
            .background(Site.glass)
            .background { behindGlass }
            .clipShape(RoundedRectangle(cornerRadius: Site.radius))
            .overlay(RoundedRectangle(cornerRadius: Site.radius).strokeBorder(.white.opacity(0.4), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: Site.radius).strokeBorder(Site.ink.opacity(0.1), lineWidth: 1).padding(-1))
            .onTapGesture {}
    }

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
            GlassView(blur: 40, tone: Glass.matrix, radius: Site.radius)
        }
    }
}

/// The dialog's overlay over the whole screen: what is behind blurred 4 pt (`backdrop-blur-xs`) under black at 0.3.
/// A click on it closes Watcher, as a click outside closes the dialog.
struct Veil: View {
    let inbox: Inbox
    @Environment(\.renderBackdrop) private var renderBackdrop

    var body: some View {
        ZStack {
            if renderBackdrop == nil { GlassView(blur: 4, tone: nil, radius: 0) }
            Color.black.opacity(0.3)
        }
        .contentShape(Rectangle())
        .onTapGesture { inbox.hide() }
    }
}

extension View {
    func card() -> some View { modifier(Card()) }
}

private extension View {
    /// The site's `block`: rounded-lg, a border, a whiter glass.
    func block() -> some View { block(in: RoundedRectangle(cornerRadius: 10)) }
}
