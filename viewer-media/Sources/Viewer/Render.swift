import AppKit

/// `--render`: the whole window, toolbar included, drawn into a PNG without showing it.
/// `cacheDisplay` cannot draw backdrop, blur or Liquid Glass layers (they come out white), so they
/// are hidden and the glass shapes are painted over them as plain translucent fills.
@MainActor enum Render {
    private static let hiddenClasses = ["NSVisualEffectView", "BackdropView", "PortalView", "PocketBlur",
                                        "LuminanceAdjustment", "NSBlurryAlleywayView", "AdditionalDimmingView"]
    private static let glassClasses = ["NSContainerConcentricGlassEffectView", "NSToolbarPlatterView"]
    private static let sidebarRadius: CGFloat = 18
    private static let glassAlpha = 0.09
    private static let rimAlpha = 0.14

    static func draw(_ window: NSWindow, to out: URL) -> Bool {
        guard let root = window.contentView?.superview else { return false }
        root.layoutSubtreeIfNeeded()
        var glass: [NSRect] = []
        strip(root, root: root, glass: &glass)
        guard let views = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return false }
        root.cacheDisplay(in: root.bounds, to: views)
        let image = NSImage(size: root.bounds.size)
        image.addRepresentation(views)
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: views.pixelsWide, pixelsHigh: views.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        canvas.size = root.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            root.bounds.fill()
            image.draw(in: root.bounds)
            for frame in glass { paintGlass(frame) }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = canvas.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: out)) != nil
    }

    private static func strip(_ view: NSView, root: NSView, glass: inout [NSRect]) {
        let name = String(describing: type(of: view))
        if hiddenClasses.contains(name) || name.hasSuffix("<RootView>") { view.isHidden = true }
        if glassClasses.contains(name) { glass.append(view.convert(view.bounds, to: root)) }
        view.subviews.forEach { strip($0, root: root, glass: &glass) }
    }

    private static func paintGlass(_ frame: NSRect) {
        let radius = min(sidebarRadius, frame.height / 2)
        let shape = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(glassAlpha).setFill()
        shape.fill()
        NSColor.labelColor.withAlphaComponent(rimAlpha).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}
