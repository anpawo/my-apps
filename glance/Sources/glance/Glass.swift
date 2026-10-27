import AppKit
import SwiftUI

/// Watcher's watch list glass (watcher/Sources/watcher/Checks.swift), his pick for glance too: what is behind the window
/// blurred 40 pt, toned by `matrix`. A behind-window effect view whose backdrop layer takes those filters, its own tints
/// hidden.
final class Glass: NSVisualEffectView {
    /// Watcher's card as it shows on his screen rather than its CSS: over the same Ghostty window, the card read
    /// (197, 202, 200) and glance, with the site's `saturate(200%) brightness(1.15)`, a beige (214, 210, 200), the
    /// highlighted lines under the top of the screen saturated (27/10/2026). Black at 0.3, Watcher's veil, and no more:
    /// the tint over it gives (195, 197, 199) on white. Rows R, G, B.
    static let matrix: [[Double]] = [[0.7, 0, 0], [0, 0.7, 0], [0, 0, 0.7]]

    /// The site's glass fill over the backdrop, and its rims.
    static let tint = Color(red: 220 / 255, green: 224 / 255, blue: 229 / 255).opacity(0.4)
    static let ink = Color(red: 0x1C / 255, green: 0x21 / 255, blue: 0x27 / 255)
    static let line = Color(red: 0xC5 / 255, green: 0xCB / 255, blue: 0xD3 / 255)

    /// A matrix as CAColorMatrix holds it: four rows of five, the R, G, B and A weights, then an offset.
    static func pack(_ matrix: [[Double]]) -> [Float] {
        matrix.flatMap { row -> [Float] in row.map { Float($0) } + [0, 0] } + [0, 0, 0, 1, 0]
    }

    let blur: Double
    let tone: [[Double]]

    /// Nil when QuartzCore no longer has the private filters: the system's own blur stays.
    func filters() -> [NSObject]? {
        guard let type = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        func make(_ name: String) -> NSObject? {
            type.perform(NSSelectorFromString("filterWithType:"), with: name)?.takeUnretainedValue() as? NSObject
        }
        guard let gauss = make("gaussianBlur"), let colour = make("colorMatrix") else { return nil }
        gauss.setValue("cssBlur", forKey: "name")
        gauss.setValue(blur, forKey: "inputRadius")
        gauss.setValue(true, forKey: "inputNormalizeEdges")
        var m = Self.pack(tone)
        colour.setValue(NSValue(bytes: &m, objCType: "{CAColorMatrix=ffffffffffffffffffff}"), forKey: "inputColorMatrix")
        return [gauss, colour]
    }

    init(blur: Double, tone: [[Double]], radius r: CGFloat) {
        self.blur = blur
        self.tone = tone
        super.init(frame: .zero)
        blendingMode = .behindWindow
        state = .active
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
    let radius: CGFloat
    func makeNSView(context: Context) -> Glass { Glass(blur: 40, tone: Glass.matrix, radius: radius) }
    func updateNSView(_ view: Glass, context: Context) {}
}

private struct RenderBehind: EnvironmentKey { static let defaultValue: NSImage? = nil }

extension EnvironmentValues {
    /// In a render, where nothing is behind the window: what the glass would show, already blurred and toned, from the
    /// card's top-left corner down (`Demo.behind`). Nil on the screen.
    var renderBehind: NSImage? {
        get { self[RenderBehind.self] }
        set { self[RenderBehind.self] = newValue }
    }
}
