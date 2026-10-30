import CoreGraphics
import Foundation

/// AppKit global rect (origin bottom-left of the main screen) → ScreenCaptureKit `sourceRect`:
/// local to the display, origin top-left, still in points.
public func displayLocal(_ r: CGRect, in screen: CGRect) -> CGRect {
    CGRect(x: r.minX - screen.minX, y: screen.maxY - r.maxY, width: r.width, height: r.height)
}

/// The pixel rect to crop out of a frozen image of `screen` taken at `scale`.
public func pixelCrop(_ r: CGRect, in screen: CGRect, scale: CGFloat) -> CGRect {
    let l = displayLocal(r, in: screen)
    return CGRect(x: (l.minX * scale).rounded(), y: (l.minY * scale).rounded(),
                  width: (l.width * scale).rounded(), height: (l.height * scale).rounded())
}

/// CoreGraphics global rect (origin top-left) → AppKit global rect.
public func appKit(_ r: CGRect, mainHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
}

/// Whether window mode offers a window: the normal ones and the panels floating above them
/// (Jarvis), but not the menu bar and its icons (no taller than 40 pt) nor an overlay covering
/// a whole screen (Fleet, Watcher), which would take every click.
public func pickable(layer: Int, frame: CGRect, screens: [CGRect]) -> Bool {
    layer == 0 || layer > 0 && frame.height > 40 && !screens.contains { frame.contains($0) }
}

/// A corner card: `side` wide for a capture shaped like a screen, and never taller than that
/// one. A taller capture is scaled to that height and centred on a card at least half as
/// wide, so a narrow picture keeps ground to click on each side.
public func cardSize(_ image: CGSize, side: CGFloat) -> CGSize {
    let scale = min(side / image.width, side * 0.625 / image.height)
    return CGSize(width: max((image.width * scale).rounded(), (side / 2).rounded()),
                  height: (image.height * scale).rounded())
}

public func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

/// Arrow keys: move by (dx, dy), or grow by it when `resize`. Never leaves `bounds`.
public func nudge(_ r: CGRect, dx: CGFloat, dy: CGFloat, resize: Bool, bounds: CGRect) -> CGRect {
    var out = r
    if resize {
        out.size.width = max(1, r.width + dx)
        out.size.height = max(1, r.height + dy)
        out.size.width = min(out.width, bounds.maxX - out.minX)
        out.size.height = min(out.height, bounds.maxY - out.minY)
    } else {
        out.origin.x = min(max(r.minX + dx, bounds.minX), bounds.maxX - r.width)
        out.origin.y = min(max(r.minY + dy, bounds.minY), bounds.maxY - r.height)
    }
    return out
}

/// The box drawn `t` (0…1) of the way from `a` to `b`, eased out; exactly `b` once `t` reaches 1.
public func glide(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    guard t < 1 else { return b }
    let e = 1 - pow(1 - max(t, 0), 3)
    func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * e }
    return CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
}

/// The eight handles as (fx, fy) fractions of the rect; index order is stable for hit-testing.
public let handles: [(CGFloat, CGFloat)] = [
    (0, 0), (0.5, 0), (1, 0), (1, 0.5), (1, 1), (0.5, 1), (0, 1), (0, 0.5),
]

public func handlePoint(_ r: CGRect, _ i: Int) -> CGPoint {
    CGPoint(x: r.minX + r.width * handles[i].0, y: r.minY + r.height * handles[i].1)
}

/// Drags handle `i` of `r` to `p`; the opposite side stays put. Returns a normalised rect.
public func resized(_ r: CGRect, handle i: Int, to p: CGPoint) -> CGRect {
    let (fx, fy) = handles[i]
    var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
    if fx == 0 { minX = p.x } else if fx == 1 { maxX = p.x }
    if fy == 0 { minY = p.y } else if fy == 1 { maxY = p.y }
    return rect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY))
}

/// The same shape macOS uses, plus the app for a window shot: `Screenshot Safari 2026-…`.
public func fileName(kind: String, app: String? = nil, ext: String, at date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let app = app.map { " " + $0.replacingOccurrences(of: "/", with: "-") } ?? ""
    return "\(kind)\(app) \(f.string(from: date)).\(ext)"
}

/// By date, not by name: the app sits before the date in a name, so a shot without one sorts
/// last and the history pruned it the moment it was written.
public func newestFirst(_ urls: [URL]) -> [URL] {
    func date(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
    return urls.sorted { date($0) > date($1) }
}
