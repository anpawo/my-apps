import AppKit

/// `text --render out.png file...`: the window laid out offscreen with those files open (the
/// first one shown), drawn into a PNG, then exit. How its look is checked without a window.
///
/// On macOS 26 an offscreen `cacheDisplay` of the window draws the title bar but leaves the glass
/// sidebar and the scroll views blank, so each part is drawn on its own and laid over it.
enum Render {
    static let settle: TimeInterval = 0.2
    /// The sidebar's glass panel, as it shows over the dark window.
    static let panel = Theme.rgb(0x1c1d1f)
    static let panelRadius: CGFloat = 16
    /// The traffic lights the window server draws: close, minimize, zoom.
    static let lights = [Theme.rgb(0xff5f57), Theme.rgb(0xfebc2e), Theme.rgb(0x28c840)]
    static let lightCenter = NSPoint(x: 28, y: 26)
    static let lightGap: CGFloat = 20
    static let lightRadius: CGFloat = 6.5

    static func run(out: URL, files: [URL]) -> Never {
        NSApp.setActivationPolicy(.prohibited)
        let main = MainWindow()
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
        let editor = main.scroll.superview!
        let below = frame.convert(main.window.contentLayoutRect, from: nil)
        let side = main.sidebar.view
        let column = frame.convert(side.bounds, from: side)
        Theme.background.setFill()
        NSRect(x: 0, y: 0, width: column.maxX, height: frame.bounds.height).fill()
        frame.convert(editor.bounds, from: editor).intersection(below).fill()
        panel.setFill()
        NSBezierPath(roundedRect: column, xRadius: panelRadius, yRadius: panelRadius).fill()
        if let table = (side as? NSScrollView)?.documentView { draw(table, table.visibleRect, over: frame) }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: below).setClip()
        if main.current == nil {
            draw(main.emptyState, main.emptyState.bounds, over: frame)
        } else {
            let clip = main.scroll.contentView
            draw(main.textView, main.textView.convert(clip.bounds, from: clip), over: frame)
            if let gutter = main.scroll.verticalRulerView { draw(gutter, gutter.bounds, over: frame) }
        }
        NSGraphicsContext.restoreGraphicsState()
        for (i, color) in lights.enumerated() {
            let center = NSPoint(x: lightCenter.x + CGFloat(i) * lightGap, y: frame.bounds.height - lightCenter.y)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - lightRadius, y: center.y - lightRadius,
                                        width: lightRadius * 2, height: lightRadius * 2)).fill()
        }
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
