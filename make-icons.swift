// Draws each app's icon in Fleet's style, a white SF Symbol on a dark tile, into <app>/Resources/AppIcon.icns,
// which its build copies into the bundle. Run from the repo root: swift make-icons.swift
import AppKit

let apps: [(dir: String, symbol: String, box: CGFloat, weight: NSFont.Weight)] = [
    ("alt-tab", "macwindow.on.rectangle", 480, .medium),
    ("opener", "magnifyingglass", 470, .semibold),
    ("autocorrect", "character.cursor.ibeam", 480, .medium),
    ("screenshot", "camera.viewfinder", 500, .medium),
]

func png(_ px: Int, _ name: String, _ box: CGFloat, _ weight: NSFont.Weight) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // Apple's macOS icon grid: an 824 pt tile with a 185 pt corner, centred on a 1024 canvas.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.25, blue: 0.28, alpha: 1),
               ending: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1))!.draw(in: shape, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: weight).applying(.init(paletteColors: [.white]))
    let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    // Symbols differ in shape: each is fitted to a square box rather than drawn at one point size.
    let k = min(box / glyph.size.width, box / glyph.size.height) * s
    let w = glyph.size.width * k, h = glyph.size.height * k
    glyph.draw(in: NSRect(x: (CGFloat(px) - w) / 2, y: (CGFloat(px) - h) / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for app in apps {
    let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(app.dir).iconset")
    try? FileManager.default.removeItem(at: set)
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for pt in [16, 32, 128, 256, 512] {
        try! png(pt, app.symbol, app.box, app.weight).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
        try! png(pt * 2, app.symbol, app.box, app.weight).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", "\(app.dir)/Resources/AppIcon.icns"]
    try! p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { exit(p.terminationStatus) }
}
