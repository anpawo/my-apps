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

        // The three stills over a desktop of stand-in windows.
        session.windows = stand(s).enumerated().map { WindowInfo(id: CGWindowID($0.offset + 1), frame: $0.element.1, app: $0.element.0) }
        let modes = Overlay(screen: screen, frozen: desktop(s).cgImage!, session: session)
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

    /// The README's GIF as frames and an ffmpeg concat list of their durations: ⌘⇧5, the three
    /// stills clicked in turn, Capture, the thumbnail pinned, then a click, a double click and a
    /// right click on the pin. `docs/make-demo.sh` makes the GIF.
    static func demo(to dir: URL) {
        let session = Session.shared
        let screen = NSScreen.main!
        let s = screen.frame
        let desk = desktop(s)
        session.windows = stand(s).enumerated().map { WindowInfo(id: CGWindowID($0.offset + 1), frame: $0.element.1, app: $0.element.0) }
        // It opens as it was left: the area mode and last time's selection.
        session.selection = rect(s, 0.38, 0.4, 0.34, 0.46)
        session.state = BarState(target: .area, kind: .photo)
        session.hoverScreen = screen
        let overlay = Overlay(screen: screen, frozen: desk.cgImage!, session: session)
        let bar = Bar(session: session, on: screen)
        overlay.refreshLayers()
        func spot(_ v: NSView) -> CGRect { bar.convertToScreen(v.convert(v.bounds, to: nil)) }
        func centre(_ v: NSView) -> CGPoint { CGPoint(x: spot(v).midX, y: spot(v).midY) }

        var p = CGPoint(x: s.minX + s.width * 0.4, y: s.minY + s.height * 0.22)
        var up = false, card: Thumbnail?, pin: Pin?, caption: String?, note: String?, ring = false
        var list = "", count = 0
        /// A dark rounded label, placed from its size.
        func pill(_ text: String, _ points: CGFloat, at place: (CGSize) -> CGPoint) {
            let t = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: points, weight: .semibold), .foregroundColor: NSColor.white])
            let pad = CGSize(width: (points * 0.65).rounded(), height: (points * 0.3).rounded())
            let box = CGRect(origin: .zero, size: CGSize(width: t.size().width + 2 * pad.width, height: t.size().height + 2 * pad.height))
            let r = CGRect(origin: place(box.size), size: box.size)
            NSColor(white: 0, alpha: 0.75).setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            t.draw(at: CGPoint(x: r.minX + pad.width, y: r.minY + pad.height))
        }
        func frame(_ seconds: Double) {
            let pic = Bar.canvas(s.size) {
                if up {
                    Bar.pixels(overlay.contentView!).draw(in: CGRect(origin: .zero, size: s.size))
                    // A hint can stick out of the bar: the picture starts at the corner of both.
                    let i = bar.buttons.firstIndex { spot($0).contains(p) }
                    let strip = i.map(bar.render(hovering:)) ?? Bar.pixels(bar.contentView!)
                    let at = i == nil ? bar.frame.origin : bar.frame.union(bar.hint.frame).origin
                    strip.draw(in: CGRect(origin: at, size: strip.size).offsetBy(dx: -s.minX, dy: -s.minY), from: .zero,
                               operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                } else {
                    desk.draw(in: CGRect(origin: .zero, size: s.size))
                    // The window server's shadow, which a panel drawn offscreen goes without.
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
                    shadow.shadowBlurRadius = 14
                    shadow.shadowOffset = CGSize(width: 0, height: -5)
                    for w in [card as NSWindow?, pin].compactMap({ $0 }) {
                        NSGraphicsContext.saveGraphicsState()
                        shadow.set()
                        Bar.pixels(w.contentView!).draw(in: w.frame.offsetBy(dx: -s.minX, dy: -s.minY), from: .zero,
                                                        operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
                if ring {
                    let o = NSBezierPath(ovalIn: CGRect(x: p.x - s.minX - 14, y: p.y - s.minY - 14, width: 28, height: 28))
                    NSColor(white: 0, alpha: 0.25).setFill()
                    o.fill()
                    o.lineWidth = 2.5
                    NSColor.white.setStroke()
                    o.stroke()
                }
                // The bar sets the arrow, the overlay its own cursors.
                let c = up && !bar.frame.contains(p) ? overlay.cursor(at: p) : .arrow
                let size = c.image.size
                c.image.draw(in: CGRect(x: p.x - c.hotSpot.x - s.minX, y: p.y - size.height + c.hotSpot.y - s.minY,
                                        width: size.width, height: size.height))
                if let caption { pill(caption, 28) { CGPoint(x: 28, y: s.height - 28 - $0.height) } }
                // Below-right of the pointer, kept on the screen.
                if let note {
                    pill(note, 16) { CGPoint(x: min(p.x - s.minX + 18, s.width - $0.width - 8), y: max(p.y - s.minY - 22 - $0.height, 6)) }
                }
            }
            count += 1
            let name = String(format: "%03d.png", count)
            save(pic.representation(using: .png, properties: [:]), dir, name)
            list += "file '\(name)'\nduration \(seconds)\n"
        }
        /// Eased, in 40 ms steps, the last one held: ffmpeg reads the frames at 25 fps, and 50 ms
        /// came out 40 and 80 by turns. Each step does what `mouseMoved` does under the pointer:
        /// the overlay picks the window in window mode, the thumbnail darkens the half.
        func move(to q: CGPoint, steps: Int, hold: Double) {
            let a = p
            for k in 1...steps {
                let t = CGFloat(k) / CGFloat(steps), e = t * t * (3 - 2 * t)
                p = CGPoint(x: a.x + (q.x - a.x) * e, y: a.y + (q.y - a.y) * e)
                if up && !bar.frame.contains(p) {
                    session.hoverWindow = session.state.target == .window ? session.windows.first { $0.frame.contains(p) } : nil
                    overlay.refreshLayers()
                }
                if let card { card.hover(card.frame.contains(p) ? CGPoint(x: p.x - card.frame.minX, y: p.y - card.frame.minY) : nil) }
                frame(k == steps ? hold : 0.04)
            }
        }
        /// A press, `times` over, shown as a ring under the pointer; then what it does, and a note
        /// saying so.
        func click(_ text: String, times: Int = 1, hold: Double, _ action: () -> Void) {
            for i in 0..<times {
                if i > 0 { frame(0.08) }
                ring = true
                frame(0.12)
                ring = false
            }
            action()
            note = text
            frame(hold)
            note = nil
        }
        // `Bar.pick`. The pointer is on the bar, so the hovered window stays as it was.
        func pick(_ i: Int) {
            session.state = bar.buttons[i].mode
            bar.refresh()
            overlay.refreshLayers()
        }

        frame(0.6)
        caption = "⌘⇧5"
        frame(0.52)
        up = true
        frame(0.52)
        caption = nil
        frame(0.32)
        move(to: centre(bar.buttons[0]), steps: 12, hold: 0.32)
        click("Entire Screen", hold: 1) { pick(0) }
        move(to: centre(bar.buttons[1]), steps: 5, hold: 0.2)
        click("Selected Window", hold: 0.8) { pick(1) }
        move(to: CGPoint(x: s.minX + s.width * 0.5, y: s.minY + s.height * 0.55), steps: 14, hold: 0.8)
        move(to: CGPoint(x: s.minX + s.width * 0.78, y: s.minY + s.height * 0.45), steps: 8, hold: 0.6)
        move(to: centre(bar.buttons[2]), steps: 14, hold: 0.2)
        click("Selected Portion", hold: 1) { pick(2) }
        move(to: centre(bar.go), steps: 12, hold: 0.2)
        // Capture, as `Session.commit` takes an area: the overlay goes, the frozen screen is
        // cropped, the thumbnail comes up.
        let r = session.selection!.integral
        let shot = desk.cgImage!.cropping(to: pixelCrop(r, in: s, scale: 2))!
        click("Captured", hold: 0.8) {
            up = false
            card = Thumbnail(.image(shot, dir, r), on: screen)
        }
        // Low on its left half, the pin glyph in view; the pin that replaces it is shorter, and
        // the notes fall just under it.
        move(to: CGPoint(x: card!.frame.minX + card!.frame.width / 4, y: card!.frame.minY + 20), steps: 18, hold: 0.6)
        // The left half: `Thumbnail.pin`, a pin in the same corner.
        click("Pinned", hold: 1) {
            card = nil
            pin = Pin(shot, url: dir, on: screen)
        }
        // `PinView`: a click copies the file, a double click opens it, a right click unpins.
        click("Click: copied", hold: 1) {}
        click("Double click: opens the file", times: 2, hold: 1.2) {}
        click("Right click: unpinned", hold: 1) { pin = nil }
        frame(0.8)
        // The concat demuxer drops the last frame's duration unless the frame comes again.
        list += "file '\(String(format: "%03d.png", count))'\n"
        try! list.write(to: dir.appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
    }

    private static let wall = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Sonoma.heic")!
        .cgImage(forProposedRect: nil, context: nil, hints: nil)!

    /// The stand-in windows, listed front to back like `Capture.windows()`: Tasks covers a
    /// corner of Editor, which covers Files.
    private static func stand(_ s: CGRect) -> [(String, CGRect, (CGSize) -> NSView)] {
        [("Tasks", rect(s, 0.6, 0.2, 0.27, 0.46), tasks),
         ("Editor", rect(s, 0.34, 0.26, 0.4, 0.56), editor),
         ("Files", rect(s, 0.08, 0.34, 0.4, 0.5), files)]
    }

    /// The wallpaper with the stand-in windows on it: the screen the overlay freezes.
    private static func desktop(_ s: CGRect) -> NSBitmapImageRep {
        Bar.canvas(s.size) {
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
            for (title, r, content) in stand(s).reversed() {
                window(title, r.size, content).draw(in: r.offsetBy(dx: -s.minX, dy: -s.minY), from: .zero,
                                                    operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
        }
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
