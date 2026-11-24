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

    static func checkMarkdown() -> Bool {
        let source = "# Heading\n\nA **bold** and *italic* [link](https://example.com).\n\n- First\n- Second\n\n```swift\nlet value = 1\n```"
        let formatted = MarkdownPreview.formatted(source)
        var passed = true
        func expect(_ condition: Bool, _ name: String) {
            print("\(condition ? "ok" : "FAIL"): \(name)")
            if !condition { passed = false }
        }
        expect(formatted.string == "Heading\nA bold and italic link.\n• First\n• Second\nlet value = 1\n",
               "renders headings, paragraphs, list items and fenced code")
        let headingFont = formatted.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        expect((headingFont?.pointSize ?? 0) > Theme.fontSize, "renders headings with a larger font")
        let bold = (formatted.string as NSString).range(of: "bold").location
        let boldFont = formatted.attribute(.font, at: bold, effectiveRange: nil) as? NSFont
        expect(boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true,
               "renders strong emphasis in bold")
        let link = (formatted.string as NSString).range(of: "link").location
        expect(formatted.attribute(.link, at: link, effectiveRange: nil) != nil, "preserves clickable links")
        let nested = MarkdownPreview.formatted("1. Parent\n   - Child\n2. Last")
        expect(nested.string == "1. Parent\n• Child\n2. Last", "renders nested lists with one marker per item")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-markdown-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try source.write(to: file, atomically: true, encoding: .utf8)
            let doc = try Document(url: file)
            let media = TextMedia(doc, onDrop: { _ in }, onReload: {})
            doc.storage.append(NSAttributedString(string: "\nUnsaved text"))
            doc.dirty = true
            let edited = doc.storage.string
            media.showMarkdownPreview(true)
            expect(media.previewsMarkdown, "switches Markdown to preview")
            media.showMarkdownPreview(false)
            expect(!media.previewsMarkdown && doc.storage.string == edited && doc.dirty,
                   "returns to editable text without losing unsaved edits")
            let preview = MarkdownPreview()
            preview.show(edited)
            expect(!preview.textView.isEditable && preview.textView.string.contains("Unsaved text"),
                   "preview displays unsaved source without allowing edits")
            expect(try String(contentsOf: file, encoding: .utf8) == source, "switching modes leaves the file unchanged")
        } catch { expect(false, "opens the Markdown fixture") }
        return passed
    }

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
