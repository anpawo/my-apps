import AppKit

/// `text --render out.png file...`: the window laid out offscreen with those files open (the
/// first one shown), drawn into a PNG, then exit. How its look is checked without a window.
///
/// On macOS 26 an offscreen `cacheDisplay` of the window leaves the glass (sidebar, toolbar
/// capsules) and the scroll views blank or white, so each part is drawn on its own.
enum Render {
    static let settle: TimeInterval = 0.2
    /// The sidebar's glass panel, as it shows over the dark window.
    static let panel = Theme.rgb(0x1c1d1f)
    static let panelRadius: CGFloat = 16
    /// The toolbar's glass capsules, as they show over the dark window.
    static let capsuleFill = Theme.rgb(0x262729)
    static let capsuleEdge = Theme.rgb(0xffffff, alpha: 0x14)
    /// The traffic lights the window server draws: close, minimize, zoom.
    static let lights = [Theme.rgb(0xff5f57), Theme.rgb(0xfebc2e), Theme.rgb(0x28c840)]
    static let lightCenter = NSPoint(x: 28, y: 26)
    static let lightGap: CGFloat = 20
    static let lightRadius: CGFloat = 6.5

    static func run(out: URL, files: [URL]) -> Never {
        NSApp.setActivationPolicy(.prohibited)
        let main = MainWindow()
        main.remembersFiles = false
        main.window.setContentSize(MainWindow.size)
        main.open(files)
        main.show(main.docs.first)
        let content = main.window.contentView!
        let frame = content.superview ?? content
        content.layoutSubtreeIfNeeded()
        main.textView.layoutManager?.ensureLayout(for: main.textView.textContainer!)
        // The table adds rows on its next pass: give it one.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: settle))
        frame.layoutSubtreeIfNeeded()
        frame.displayIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { fail("no bitmap") }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { fail("no context") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        compose(main, over: frame)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("no PNG") }
        do { try png.write(to: out) } catch { fail(error.localizedDescription) }
        print(out.path)
        exit(0)
    }

    private static func compose(_ main: MainWindow, over frame: NSView) {
        Theme.background.setFill()
        frame.bounds.fill()
        let side = main.list.view
        panel.setFill()
        NSBezierPath(roundedRect: frame.convert(side.bounds, from: side), xRadius: panelRadius, yRadius: panelRadius).fill()
        var tables: [NSView] = []
        collect(side, into: &tables) { $0 is NSTableView }
        for table in tables { draw(table, table.visibleRect, over: frame) }
        for case let title as NSTextField in side.subviews { draw(title, title.bounds, over: frame) }
        let editor = main.scroll.superview!
        Theme.border.setFill()
        NSRect(x: frame.convert(editor.bounds, from: editor).minX - 1, y: 0, width: 1, height: frame.bounds.height).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frame.convert(main.window.contentLayoutRect, from: nil)).setClip()
        if main.current == nil {
            draw(main.emptyState, main.emptyState.bounds, over: frame)
        } else {
            let clip = main.scroll.contentView
            draw(main.textView, main.textView.convert(clip.bounds, from: clip), over: frame)
            if let gutter = main.scroll.verticalRulerView { draw(gutter, gutter.bounds, over: frame) }
        }
        NSGraphicsContext.restoreGraphicsState()
        toolbar(over: frame)
        for (i, color) in lights.enumerated() {
            let center = NSPoint(x: lightCenter.x + CGFloat(i) * lightGap, y: frame.bounds.height - lightCenter.y)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - lightRadius, y: center.y - lightRadius,
                                        width: lightRadius * 2, height: lightRadius * 2)).fill()
        }
    }

    /// Each glass capsule as a filled one, then the items and the title over them.
    private static func toolbar(over frame: NSView) {
        guard let bar = find(frame, { $0.className == "NSToolbarView" }) else { return }
        var glass: [NSView] = []
        collect(bar, into: &glass) { $0.className == "NSGlassEffectView" }
        for view in glass {
            let rect = frame.convert(view.bounds, from: view)
            let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            capsuleFill.setFill()
            capsule.fill()
            capsuleEdge.setStroke()
            capsule.stroke()
        }
        for item in bar.subviews where item.className != "NSGlassContainerView" { draw(item, item.bounds, over: frame) }
    }

    private static func find(_ root: NSView, _ match: (NSView) -> Bool) -> NSView? {
        if match(root) { return root }
        for child in root.subviews { if let hit = find(child, match) { return hit } }
        return nil
    }

    private static func collect(_ root: NSView, into out: inout [NSView], _ match: (NSView) -> Bool) {
        if match(root) { out.append(root) }
        for child in root.subviews { collect(child, into: &out, match) }
    }

    private static func draw(_ view: NSView, _ rect: NSRect, over frame: NSView) {
        guard !rect.isEmpty, let part = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: part)
        part.draw(in: frame.convert(rect, from: view), from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: nil)
    }

    static func fail(_ why: String) -> Never {
        FileHandle.standardError.write(Data("render: \(why)\n".utf8))
        exit(1)
    }
}
