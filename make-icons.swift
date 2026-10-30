// Draws each app's icon in Fleet's style, white on a dark tile, into <app>/Resources/AppIcon.icns, which its
// build copies into the bundle. Run from the repo root: swift make-icons.swift
import AppKit

func glyph(_ name: String, box: CGFloat, weight: NSFont.Weight = .medium,
           at c: NSPoint = NSPoint(x: 512, y: 512), angle: CGFloat = 0) {
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: weight).applying(.init(paletteColors: [.white]))
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    // Symbols differ in shape: each is fitted to a square box rather than drawn at one point size.
    let k = min(box / image.size.width, box / image.size.height)
    let w = image.size.width * k, h = image.size.height * k
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: c.x, yBy: c.y); t.rotate(byDegrees: angle); t.concat()
    image.draw(in: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
}

// Watcher's: the line left for you, a note pinned to the tile.
func pinnedNote() {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: 512, yBy: 512); t.rotate(byDegrees: -6); t.translateX(by: -512, yBy: -512)
    t.concat()
    NSColor(white: 1, alpha: 0.16).setFill()
    NSBezierPath(roundedRect: NSRect(x: 270, y: 230, width: 484, height: 460), xRadius: 44, yRadius: 44).fill()
    NSColor(white: 1, alpha: 0.55).setFill()
    for (i, w) in [330, 380, 250].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 340, y: 500 - CGFloat(i) * 90, width: CGFloat(w), height: 34),
                     xRadius: 17, yRadius: 17).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    glyph("pin.fill", box: 300, at: NSPoint(x: 560, y: 700), angle: -35)
}

let apps: [(dir: String, draw: () -> Void)] = [
    ("alt-tab", { glyph("macwindow.on.rectangle", box: 480) }),
    ("opener", { glyph("magnifyingglass", box: 470, weight: .semibold) }),
    ("autocorrect", { glyph("character.cursor.ibeam", box: 480) }),
    ("screenshot", { glyph("camera.viewfinder", box: 500) }),
    ("watcher", pinnedNote),
]

func png(_ px: Int, _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let t = NSAffineTransform(); t.scale(by: CGFloat(px) / 1024); t.concat()
    // Apple's macOS icon grid: an 824 pt tile with a 185 pt corner, centred on a 1024 canvas.
    let shape = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.25, blue: 0.28, alpha: 1),
               ending: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1))!.draw(in: shape, angle: -90)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for app in apps {
    let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(app.dir).iconset")
    try? FileManager.default.removeItem(at: set)
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for pt in [16, 32, 128, 256, 512] {
        try! png(pt, app.draw).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
        try! png(pt * 2, app.draw).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", "\(app.dir)/Resources/AppIcon.icns"]
    try! p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { exit(p.terminationStatus) }
}
