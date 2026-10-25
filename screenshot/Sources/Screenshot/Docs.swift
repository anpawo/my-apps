import AppKit
import ScreenshotCore

/// The README's pictures, drawn by the app's own views and never put on screen:
/// `screenshot --render-docs docs`. A stock wallpaper stands in for the desktop, so no real
/// window ends up in a public repo.
@MainActor
enum Docs {
    static func render(to dir: URL) {
        let session = Session.shared
        let screen = NSScreen.main!
        let s = screen.frame
        session.selection = CGRect(x: s.minX + s.width * 0.28, y: s.minY + s.height * 0.3,
                                   width: s.width * 0.44, height: s.height * 0.46).integral
        session.state = BarState(target: .area, kind: .photo)
        let bar = Bar(session: session, on: screen)
        save(bar.render(), dir, "bar.png")
        save(bar.render(hovering: 3).representation(using: .png, properties: [:]), dir, "bar-hover.png")
        session.state = BarState(target: .area, kind: .video)
        bar.refresh()
        save(bar.render(), dir, "bar-record.png")

        session.state = BarState(target: .area, kind: .photo)
        bar.refresh()
        let wall = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Sonoma.heic")!
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let overlay = Overlay(screen: screen, frozen: wall, session: session)
        overlay.refreshLayers()
        // Cropped to the selection and the bar: the whole 2× screen of wallpaper is a 6 MB PNG.
        let crop = session.selection!.insetBy(dx: -120, dy: -48).union(bar.frame.insetBy(dx: 0, dy: -24)).intersection(s)
        let shot = Bar.canvas(crop.size) {
            Bar.pixels(overlay.contentView!).draw(in: s.offsetBy(dx: -crop.minX, dy: -crop.minY))
            // draw(in:) copies, alpha and all: the bar's rounded corners would come out black.
            Bar.pixels(bar.contentView!).draw(in: bar.frame.offsetBy(dx: -crop.minX, dy: -crop.minY), from: .zero,
                                              operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        save(shot.representation(using: .png, properties: [:]), dir, "overlay.png")

        // The three stills over a desktop of stand-in windows, listed front to back like
        // `Capture.windows()`: Tasks covers a corner of Editor, which covers Files.
        let stand: [(String, CGRect, (CGSize) -> NSView)] = [
            ("Tasks", rect(s, 0.6, 0.2, 0.27, 0.46), tasks),
            ("Editor", rect(s, 0.34, 0.26, 0.4, 0.56), editor),
            ("Files", rect(s, 0.08, 0.34, 0.4, 0.5), files),
        ]
        session.windows = stand.enumerated().map { WindowInfo(id: CGWindowID($0.offset + 1), frame: $0.element.1, app: $0.element.0) }
        let desktop = Bar.canvas(s.size) {
            // Sonoma.heic is square: fill the screen from its middle band rather than squash it.
            let h = CGFloat(wall.width) * s.height / s.width
            NSImage(cgImage: wall, size: .zero).draw(in: CGRect(origin: .zero, size: s.size),
                from: CGRect(x: 0, y: (CGFloat(wall.height) - h) / 2, width: CGFloat(wall.width), height: h),
                operation: .copy, fraction: 1)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.4)
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = CGSize(width: 0, height: -12)
            shadow.set()
            for (title, r, content) in stand.reversed() {
                window(title, r.size, content).draw(in: r.offsetBy(dx: -s.minX, dy: -s.minY), from: .zero,
                                                    operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
        }
        let modes = Overlay(screen: screen, frozen: desktop.cgImage!, session: session)
        session.hoverScreen = screen
        session.hoverWindow = session.windows[1]
        session.selection = rect(s, 0.22, 0.42, 0.3, 0.3).integral
        let targets: [Target] = [.screen, .window, .area]
        let panels = targets.map { t in
            session.state = BarState(target: t, kind: .photo)
            bar.refresh()
            modes.refreshLayers()
            return Bar.canvas(s.size) {
                Bar.pixels(modes.contentView!).draw(in: CGRect(origin: .zero, size: s.size))
                Bar.pixels(bar.contentView!).draw(in: bar.frame.offsetBy(dx: -s.minX, dy: -s.minY), from: .zero,
                                                  operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
        }
        // 1100 px a panel: the full 2× screens made a PNG of over 10 MB.
        let w: CGFloat = 550, h = (w * s.height / s.width).rounded(), gap: CGFloat = 10
        let sheet = Bar.canvas(CGSize(width: w, height: 3 * h + 2 * gap)) {
            NSGraphicsContext.current!.imageInterpolation = .high
            for (i, p) in panels.enumerated() {
                let r = CGRect(x: 0, y: CGFloat(2 - i) * (h + gap), width: w, height: h)
                p.draw(in: r)
                let name = NSAttributedString(string: Glyph.tip[targets[i]]!, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
                let pill = CGRect(x: r.minX + 10, y: r.maxY - 30, width: name.size().width + 16, height: name.size().height + 6)
                NSColor(white: 0, alpha: 0.7).setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                name.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 3))
            }
        }
        save(sheet.representation(using: .png, properties: [:]), dir, "modes.png")
    }

    /// `s` scaled: x, y, width and height as fractions of it.
    private static func rect(_ s: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: s.minX + s.width * x, y: s.minY + s.height * y, width: s.width * w, height: s.height * h).integral
    }

    /// A stand-in app window: real AppKit content under a title bar, in a macOS 26 window's
    /// 16 pt continuous corners, light whatever the system's appearance.
    private static func window(_ title: String, _ size: CGSize, _ content: (CGSize) -> NSView) -> NSBitmapImageRep {
        let v = NSView(frame: CGRect(origin: .zero, size: size))
        v.appearance = NSAppearance(named: .aqua)
        v.wantsLayer = true
        v.layer!.cornerRadius = 16
        v.layer!.cornerCurve = .continuous
        v.layer!.masksToBounds = true
        v.layer!.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        v.addSubview(content(CGSize(width: size.width, height: size.height - 40)))
        let name = NSTextField(labelWithString: title)
        name.font = .boldSystemFont(ofSize: 13)
        name.sizeToFit()
        name.setFrameOrigin(CGPoint(x: ((size.width - name.frame.width) / 2).rounded(), y: size.height - 29))
        v.addSubview(name)
        for (i, (r, g, b)) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            let dot = NSView(frame: CGRect(x: 18 + 20 * CGFloat(i), y: size.height - 26, width: 12, height: 12))
            dot.wantsLayer = true
            dot.layer!.cornerRadius = 6
            dot.layer!.backgroundColor = NSColor(red: r, green: g, blue: b, alpha: 1).cgColor
            v.addSubview(dot)
        }
        v.layoutSubtreeIfNeeded()
        return Bar.pixels(v)
    }

    private static func editor(_ size: CGSize) -> NSView {
        let t = NSTextView(frame: CGRect(origin: .zero, size: size))
        t.font = .systemFont(ofSize: 14)
        t.textContainerInset = CGSize(width: 18, height: 14)
        t.string = """
        Release notes

        The bar now opens on the display under the pointer, and the selection you drew last \
        time comes back where you left it.

        Window mode frames only the part of a window you can see: whatever sits in front of it \
        is cut out of the highlight, round corners included.

        Recordings stop with ⌘⇧5, from anywhere.
        """
        return t
    }

    private static func files(_ size: CGSize) -> NSView {
        let v = NSView(frame: CGRect(origin: .zero, size: size))
        v.wantsLayer = true
        v.layer!.backgroundColor = NSColor.white.cgColor
        let side = NSView(frame: CGRect(x: 0, y: 0, width: 150, height: size.height))
        side.wantsLayer = true
        side.layer!.backgroundColor = NSColor(white: 0.92, alpha: 1).cgColor
        side.addSubview(column(["Favorites", "Desktop", "Documents", "Downloads", "Pictures"].map { label($0, gray: $0 == "Favorites") },
                               spacing: 9, top: size.height - 12))
        let grid = NSGridView(views: [["Name", "Date Modified", "Size"], ["Q3 report.pdf", "Today, 09:12", "2.4 MB"],
                                      ["Trip photos", "Yesterday", "--"], ["budget.numbers", "Sep 21", "180 KB"],
                                      ["notes.txt", "Sep 18", "4 KB"], ["logo.svg", "Sep 12", "12 KB"]]
            .enumerated().map { i, row in row.map { label($0, gray: i == 0) } })
        grid.rowSpacing = 12
        grid.columnSpacing = 28
        let fit = grid.fittingSize
        grid.frame = CGRect(x: 170, y: size.height - 12 - fit.height, width: fit.width, height: fit.height)
        v.addSubview(side)
        v.addSubview(grid)
        return v
    }

    private static func tasks(_ size: CGSize) -> NSView {
        let v = NSView(frame: CGRect(origin: .zero, size: size))
        v.wantsLayer = true
        v.layer!.backgroundColor = NSColor.white.cgColor
        v.addSubview(column([("Book the venue", true), ("Send the invites", true), ("Order the cake", false),
                             ("Pick up the chairs", false), ("Print the menus", false)].map { title, done in
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = done ? .on : .off
            return b
        }, spacing: 12, top: size.height - 14))
        return v
    }

    /// `views` stacked downwards from `top`, 18 pt in: a stack view taller than its content
    /// packs it at the bottom.
    private static func column(_ views: [NSView], spacing: CGFloat, top: CGFloat) -> NSStackView {
        let c = NSStackView(views: views)
        c.orientation = .vertical
        c.alignment = .leading
        c.spacing = spacing
        let fit = c.fittingSize
        c.frame = CGRect(x: 18, y: top - fit.height, width: fit.width, height: fit.height)
        return c
    }

    private static func label(_ s: String, gray: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13, weight: gray ? .semibold : .regular)
        l.textColor = gray ? .secondaryLabelColor : .labelColor
        return l
    }

    private static func save(_ png: Data?, _ dir: URL, _ name: String) {
        try! png!.write(to: dir.appendingPathComponent(name))
    }
}
