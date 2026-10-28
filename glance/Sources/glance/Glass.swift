import AppKit
import SwiftUI

/// Watcher's watch list glass (watcher/Sources/watcher/Checks.swift), his pick for glance too: the site's `.light`
/// glass, `backdrop-filter: blur(40px) saturate(200%) brightness(1.15)`, on what is behind the window. A behind-window
/// effect view whose backdrop layer takes those filters, its own tints hidden.
final class Glass: NSVisualEffectView {
    /// CSS `saturate(200%) brightness(1.15)` on sRGB values, the Filter Effects spec's matrix: rows R, G, B. Times 0.7
    /// first: Watcher's card stands on its veil, black at 0.3, and glance takes the same look without one.
    static let matrix: [[Double]] = {
        let s = 2.0
        return [[0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s],
                [0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s],
                [0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s]].map { $0.map { $0 * 0.7 * 1.15 } }
    }()

    /// The site's glass fill over the backdrop, and its rims. The fill at 0.1, not 0.4, and the blur 10 pt, not 40:
    /// clearer, his pick (28/10/2026; 0.3 and 30 pt did not show).
    static let tint = Color(red: 220 / 255, green: 224 / 255, blue: 229 / 255).opacity(0.1)
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
    func makeNSView(context: Context) -> Glass { Glass(blur: 10, tone: Glass.matrix, radius: radius) }
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
