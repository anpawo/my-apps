import AppKit
import ScreenshotCore

/// The ⌘⇧5 strip, laid out like the system's: ✕, the stills, the button, with every setting
/// above it. Never key: keys go to the overlay.
final class Bar: NSPanel {
    // Apple's geometry, measured on the system bar at 2×: 53 pt tall, ✕ at 14.5, stills on a
    // 50 pt pitch in 44×36 buttons, a divider 7 pt after them, the button 17.5 pt after that.
    static let height: CGFloat = 53
    private unowned let session: Session
    private(set) var buttons: [ModeButton] = []
    let go = NSButton()
    let hint = Hint()
    let strip = Strip()

    init(session: Session, on screen: NSScreen) {
        self.session = session
        super.init(contentRect: CGRect(x: 0, y: 0, width: 700, height: Bar.height), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        acceptsMouseMovedEvents = true
        let back = Ground()
        contentView = back
        // The overlay sets its own cursor on every move; the bar takes the arrow back.
        back.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))

        let mid = Bar.height / 2
        let close = NSButton(image: Glyph.close, target: self, action: #selector(cancel))
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.contentTintColor = NSColor.labelColor.withAlphaComponent(0.4)
        close.frame = CGRect(x: 14.5, y: mid - 8.5, width: 17, height: 17)
        back.addSubview(close)

        var x: CGFloat = 43.75
        for state in BarState.all {
            let b = ModeButton(state: state, target: self, action: #selector(pick(_:)))
            b.onHover = { [weak self, weak b] over in
                guard let self, let b else { return }
                if over { self.hint.show(b.toolTip!, above: b, in: self) } else { self.hint.hide() }
            }
            b.frame = CGRect(x: x, y: mid - 18, width: 44, height: 36)
            x += 50
            back.addSubview(b)
            buttons.append(b)
        }
        back.addSubview(Bar.divider(at: x + 0.75))            // 7 pt after the last still
        x += 18.25

        // Painted by hand: AppKit only tints a default button in a key window, and this one never is.
        go.isBordered = false
        go.font = .systemFont(ofSize: 15)
        go.wantsLayer = true
        go.layer?.cornerRadius = 8
        go.target = self
        go.action = #selector(commit)
        go.attributedTitle = NSAttributedString(string: "Capture", attributes: [.foregroundColor: NSColor.white, .font: go.font!])
        go.frame = CGRect(x: x, y: mid - 18.25, width: go.attributedTitle.size().width + 30, height: 36.5)
        back.addSubview(go)
        refresh()

        let width = go.frame.maxX + 8.5
        back.frame = CGRect(x: 0, y: 0, width: width, height: Bar.height)
        let v = screen.visibleFrame
        setFrame(CGRect(x: (v.midX - width / 2).rounded(), y: v.minY + 24, width: width, height: Bar.height), display: false)
        strip.place(above: self)
    }

    override var canBecomeKey: Bool { false }
    override func orderFrontRegardless() { super.orderFrontRegardless(); strip.reload(); strip.place(above: self); strip.orderFrontRegardless() }
    override func orderOut(_ sender: Any?) { hint.hide(); strip.orderOut(nil); super.orderOut(sender) }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }

    func refresh() {
        let s = session.state
        for b in buttons { b.isSelected = b.mode == s }
        go.isEnabled = !(s.needsSelection && session.selection == nil)
        go.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(go.isEnabled ? 1 : 0.4).cgColor
    }

    /// The bar and its settings as PNG, at 2×, without ever being on screen.
    func render() -> Data? { picture().0.representation(using: .png, properties: [:]) }

    /// The bar, its settings and, given `i`, the hint of button `i`, as the screen shows them,
    /// still never on screen; with the frame they cover.
    func picture(hovering i: Int? = nil) -> (NSBitmapImageRep, CGRect) {
        var parts: [NSWindow] = [self, strip]
        if let i {
            hint.place(buttons[i].toolTip!, above: buttons[i], in: self)
            parts.append(hint)
        }
        let all = parts.reduce(frame) { $0.union($1.frame) }
        let rep = Bar.canvas(all.size) {
            // draw(in:) copies, alpha and all: rounded corners would come out black.
            for w in parts {
                Bar.pixels(w.contentView!).draw(in: w.frame.offsetBy(dx: -all.minX, dy: -all.minY), from: .zero,
                                                operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
        }
        return (rep, all)
    }

    static func pixels(_ view: NSView) -> NSBitmapImageRep {
        let rep = canvas(view.bounds.size) {}
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// A blank 2× bitmap of `size` points, drawn into by `draw`.
    static func canvas(_ size: CGSize, _ draw: () -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func divider(at x: CGFloat) -> NSView {
        let v = NSView(frame: CGRect(x: x, y: (Bar.height - 22) / 2, width: 1, height: 22))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        return v
    }

    @objc private func pick(_ b: ModeButton) { session.state = b.mode; session.refresh() }
    @objc private func cancel() { session.close() }
    @objc private func commit() { session.commit() }
}

/// The bar's ground: one opaque gray. A material let the desktop show through and changed
/// colour with whatever was behind it.
private final class Ground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(white: dark ? 0.29 : 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
}

/// One mode. The selected one sits on a rounded tint, like the system's.
final class ModeButton: NSButton {
    let mode: BarState
    var isSelected = false {
        didSet {
            layer?.backgroundColor = isSelected ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
            contentTintColor = NSColor.labelColor.withAlphaComponent(isSelected ? 0.95 : 0.7)
        }
    }

    init(state: BarState, target: AnyObject, action: Selector) {
        self.mode = state
        super.init(frame: .zero)
        self.target = target
        self.action = action
        image = Glyph.image(for: state)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = NSColor.labelColor.withAlphaComponent(0.7)
        toolTip = "Capture " + Glyph.tip[state.target]!
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        layer?.cornerRadius = 8
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The system shows the mode's name above the button as soon as the mouse is on it, with
    /// none of a tooltip's delay.
    var onHover: ((Bool) -> Void)?
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The little dark label above a hovered button.
final class Hint: NSPanel {
    private let text = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let back = NSView()
        back.wantsLayer = true
        back.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        back.layer?.cornerRadius = 5
        text.font = .systemFont(ofSize: 12)
        text.textColor = .white
        back.addSubview(text)
        contentView = back
    }

    override var canBecomeKey: Bool { false }

    func show(_ s: String, above button: NSView, in bar: Bar) {
        place(s, above: button, in: bar)
        orderFrontRegardless()
    }

    /// Above the button, and above the settings that sit over it.
    func place(_ s: String, above button: NSView, in bar: Bar) {
        text.stringValue = s
        text.sizeToFit()
        let size = CGSize(width: text.frame.width + 16, height: text.frame.height + 8)
        text.frame.origin = CGPoint(x: 8, y: 4)
        let b = bar.convertToScreen(button.convert(button.bounds, to: nil))
        setFrame(CGRect(x: (b.midX - size.width / 2).rounded(), y: bar.strip.frame.maxY + 8, width: size.width, height: size.height), display: true)
    }

    func hide() { orderOut(nil) }
}

/// Every setting, always above the bar: three titled columns of three. A click or ⌘ + its key
/// flips one; the timer's three are one choice.
final class Strip: NSPanel {
    struct Item {
        let key: String, title: String, on: Bool
        let flip: () -> Void
    }

    private static let pad: CGFloat = 8, titleHeight: CGFloat = 20, row: CGFloat = 30, gap: CGFloat = 2
    static let height = pad + titleHeight + 3 * row + 2 * gap + pad

    static func sections() -> [(String, [Item])] {
        let folders = zip(["D", "L", "O"], Settings.standardFolders).map { key, f in
            Item(key: key, title: f.0, on: Settings.folders.contains { $0.path == f.1.path }) { Settings.toggle(folder: f.1) }
        }
        let timer = [("0", "None", 0), ("5", "5 Seconds", 5), ("1", "10 Seconds", 10)].map { key, title, secs in
            Item(key: key, title: title, on: Settings.timer == secs) { Settings.timer = secs }
        }
        let options = [
            Item(key: "C", title: "Clipboard", on: Settings.copies) { Settings.copies.toggle() },
            Item(key: "F", title: "Thumbnail", on: Settings.thumbnail) { Settings.thumbnail.toggle() },
            Item(key: "P", title: "Pointer", on: Settings.cursor) { Settings.cursor.toggle() },
        ]
        return [("Save in", folders), ("Timer", timer), ("Options", options)]
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = Ground()
        contentView!.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        reload()
    }

    override var canBecomeKey: Bool { false }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }

    func reload() {
        let back = contentView!
        back.subviews.forEach { $0.removeFromSuperview() }
        var x = Strip.pad
        for (name, items) in Strip.sections() {
            let title = NSTextField(labelWithString: name)
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = .secondaryLabelColor
            title.sizeToFit()
            title.setFrameOrigin(CGPoint(x: x + 6, y: Strip.height - Strip.pad - Strip.titleHeight + 3))
            back.addSubview(title)
            let keys = items.map { item in StripKey(item) { [weak self] in item.flip(); self?.reload() } }
            let width = keys.map(\.frame.width).max()!
            var y = Strip.height - Strip.pad - Strip.titleHeight
            for k in keys {
                y -= Strip.row
                k.frame = CGRect(x: x, y: y, width: width, height: Strip.row)
                back.addSubview(k)
                y -= Strip.gap
            }
            x += width + 12
        }
        setContentSize(CGSize(width: x - 12 + Strip.pad, height: Strip.height))
    }

    /// ⌘ + `key`; false when no setting has that letter.
    func flip(_ key: String) -> Bool {
        guard let item = Strip.sections().flatMap(\.1).first(where: { $0.key == key.uppercased() }) else { return false }
        item.flip()
        reload()
        return true
    }

    func place(above bar: NSWindow) {
        setFrameOrigin(CGPoint(x: (bar.frame.midX - frame.width / 2).rounded(), y: bar.frame.maxY + 8))
    }

    func hide() { orderOut(nil) }
}

/// One setting: its key on a cap, its name, and a tick when it is on; on, the row sits on the
/// accent colour.
private final class StripKey: NSView {
    private let item: Strip.Item
    private let flip: () -> Void
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let keyFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let tick = NSFont.systemFont(ofSize: 13, weight: .bold)

    init(_ item: Strip.Item, flip: @escaping () -> Void) {
        self.item = item
        self.flip = flip
        let text = (item.title as NSString).size(withAttributes: [.font: StripKey.font]).width
        super.init(frame: CGRect(x: 0, y: 0, width: 32 + ceil(text) + 30, height: 30))
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { flip() }

    override func draw(_ dirtyRect: NSRect) {
        let on = item.on
        if on {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let cap = CGRect(x: 6, y: (bounds.height - 20) / 2, width: 20, height: 20)
        if on {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: cap, xRadius: 5, yRadius: 5).fill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            let p = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
            p.lineWidth = 1
            p.stroke()
        }
        func centre(_ s: String, _ attrs: [NSAttributedString.Key: Any], x: CGFloat? = nil, in r: CGRect) {
            let size = (s as NSString).size(withAttributes: attrs)
            (s as NSString).draw(at: CGPoint(x: x ?? r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }
        centre(item.key, [.font: StripKey.keyFont,
                          .foregroundColor: on ? NSColor.white : NSColor.labelColor.withAlphaComponent(0.6)], in: cap)
        centre(item.title, [.font: StripKey.font,
                            .foregroundColor: NSColor.labelColor.withAlphaComponent(on ? 0.95 : 0.5)], x: 32, in: bounds)
        if on {
            centre("✓", [.font: StripKey.tick, .foregroundColor: NSColor.controlAccentColor],
                   in: CGRect(x: bounds.maxX - 24, y: 0, width: 18, height: bounds.height))
        }
    }
}

/// The system's glyphs, traced from its bar: a 28.5 × 22.5 rounded rect with a 2 pt stroke and
/// 4.5 pt corners; a menu-bar line and a dock for the display, three dots for the window,
/// dashes for the area.
enum Glyph {
    static let tip: [Target: String] = [.screen: "Entire Screen", .window: "Selected Window", .area: "Selected Portion"]

    static func image(for s: BarState) -> NSImage {
        let img = NSImage(size: CGSize(width: 29, height: 22.5), flipped: true) { _ in
            let r = CGRect(x: 1, y: 1, width: 26.5, height: 20.5)      // 2 pt stroke, centred on 1
            let stroke = NSBezierPath()
            stroke.lineWidth = 2
            stroke.lineCapStyle = .butt
            let radius: CGFloat = 4.5
            switch s.target {
            case .screen, .window:
                stroke.appendRoundedRect(r, xRadius: radius, yRadius: radius)
            case .area:
                // Solid corners, two dashes on the long edges, one on the short ones.
                dashedRoundedRect(r, radius: radius, into: stroke)
            }
            stroke.stroke()
            switch s.target {
            case .screen:
                let bar = NSBezierPath()
                bar.move(to: CGPoint(x: r.minX + 1, y: 5)); bar.line(to: CGPoint(x: r.maxX - 1, y: 5))
                bar.lineWidth = 2
                bar.stroke()
                NSBezierPath(roundedRect: CGRect(x: 6, y: 14.5, width: 17.5, height: 3.5), xRadius: 1.75, yRadius: 1.75).fill()
            case .window:
                for i in 0..<3 { NSBezierPath(ovalIn: CGRect(x: 4.2 + CGFloat(i) * 3.4, y: 4.2, width: 2.2, height: 2.2)).fill() }
            case .area: break
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func dashedRoundedRect(_ r: CGRect, radius: CGFloat, into p: NSBezierPath) {
        func dashes(from a: CGPoint, to b: CGPoint, count: Int) {
            let len = hypot(b.x - a.x, b.y - a.y)
            let gap = (len - CGFloat(count) * 5.5) / CGFloat(count + 1)
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            for i in 0..<count {
                let s = gap + CGFloat(i) * (5.5 + gap)
                p.move(to: CGPoint(x: a.x + ux * s, y: a.y + uy * s))
                p.line(to: CGPoint(x: a.x + ux * (s + 5.5), y: a.y + uy * (s + 5.5)))
            }
        }
        dashes(from: CGPoint(x: r.minX + radius, y: r.minY), to: CGPoint(x: r.maxX - radius, y: r.minY), count: 2)
        dashes(from: CGPoint(x: r.maxX, y: r.minY + radius), to: CGPoint(x: r.maxX, y: r.maxY - radius), count: 1)
        dashes(from: CGPoint(x: r.minX + radius, y: r.maxY), to: CGPoint(x: r.maxX - radius, y: r.maxY), count: 2)
        dashes(from: CGPoint(x: r.minX, y: r.minY + radius), to: CGPoint(x: r.minX, y: r.maxY - radius), count: 1)
        // The four corners: quarter arcs, in the flipped (y-down) space.
        for (cx, cy, a0) in [(r.maxX - radius, r.minY + radius, 270.0), (r.maxX - radius, r.maxY - radius, 0.0),
                             (r.minX + radius, r.maxY - radius, 90.0), (r.minX + radius, r.minY + radius, 180.0)] as [(CGFloat, CGFloat, Double)] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: CGPoint(x: cx, y: cy), radius: radius, startAngle: a0, endAngle: a0 + 90)
            p.append(arc)
        }
    }

    /// The ✕: a 17 pt disc with a knocked-out cross.
    static let close: NSImage = {
        let img = NSImage(size: CGSize(width: 17, height: 17), flipped: true) { _ in
            NSBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 17, height: 17)).fill()
            NSGraphicsContext.current!.compositingOperation = .destinationOut
            let x = NSBezierPath()
            x.move(to: CGPoint(x: 5.5, y: 5.5)); x.line(to: CGPoint(x: 11.5, y: 11.5))
            x.move(to: CGPoint(x: 11.5, y: 5.5)); x.line(to: CGPoint(x: 5.5, y: 11.5))
            x.lineWidth = 1.8
            x.lineCapStyle = .round
            x.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
