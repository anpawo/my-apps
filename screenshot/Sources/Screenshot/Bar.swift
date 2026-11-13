import AppKit
import ScreenshotCore

/// The ⌘⇧5 strip, laid out like the system's: the stills and the button, between Save in on
/// its left and Options on its right. Never key: keys go to the overlay.
final class Bar: NSPanel {
    // Apple's geometry, measured on the system bar at 2×: 53 pt tall, stills on a
    // 50 pt pitch in 44×36 buttons, a divider 7 pt after them, the button 17.5 pt after that.
    static let height: CGFloat = 53
    private unowned let session: Session
    private(set) var buttons: [ModeButton] = []
    let go = NSButton()
    let hint = Hint()
    let saveIn = Section.saveIn()
    let options = Section.options()
    var sections: [Section] { [saveIn, options] }

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
        var x: CGFloat = 8.5
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
        placeSections()
    }

    override var canBecomeKey: Bool { false }
    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        for s in sections { s.reload(); s.expand(false, animated: false) }
        placeSections()
        sections.forEach { $0.orderFrontRegardless() }
        // The pointer is polled, not tracked: a tracking area fired exits while its window was
        // growing under the pointer, and the group snapped shut and open again.
        watch?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchPointer() }
        }
        RunLoop.main.add(t, forMode: .common)
        watch = t
    }
    override func orderOut(_ sender: Any?) {
        watch?.invalidate()
        watch = nil
        hint.hide()
        sections.forEach { $0.orderOut(nil) }
        super.orderOut(sender)
    }

    private var watch: Timer?

    private func watchPointer() {
        let p = NSEvent.mouseLocation
        if sections.map({ $0.hover(p) }).contains(true) { NSCursor.pointingHand.set() }
    }

    /// 8 pt off each end, bottoms level: they grow upward and away from the bar.
    private func placeSections() {
        saveIn.anchor = CGPoint(x: frame.minX - 8, y: frame.minY)
        options.anchor = CGPoint(x: frame.maxX + 8, y: frame.minY)
        for s in sections { s.setFrame(s.target(s.expanded), display: false) }
    }

    /// ⌥ + `key`; false when no setting has that letter.
    func flip(_ key: String) -> Bool { sections.contains { $0.flip(key) } }
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
        var parts: [NSWindow] = [self] + sections
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

    func place(_ s: String, above button: NSView, in bar: Bar) {
        text.stringValue = s
        text.sizeToFit()
        let size = CGSize(width: text.frame.width + 16, height: text.frame.height + 8)
        text.frame.origin = CGPoint(x: 8, y: 4)
        let b = bar.convertToScreen(button.convert(button.bounds, to: nil))
        setFrame(CGRect(x: (b.midX - size.width / 2).rounded(), y: b.maxY + 12, width: size.width, height: size.height), display: true)
    }

    func hide() { orderOut(nil) }
}

/// One group of settings beside the bar, shrunk to its name. Hovered, it grows upward and away
/// from the bar to a row per setting. A click or ⌥ + the letter shown on its row flips one.
final class Section: NSPanel {
    struct Item {
        let key: String, title: String, on: Bool
        let flip: () -> Void
    }

    private static let pad: CGFloat = 8, titleHeight: CGFloat = 20, row: CGFloat = 30, gap: CGFloat = 2
    private let name: String
    private let growsLeft: Bool
    private let items: () -> [Item]
    private let label: NSTextField     // the name alone, while shrunk
    private let grip: Grip             // in the corner away from the bar, while shrunk
    /// A shortcut opens the block a moment, so the flip shows.
    private var peekUntil: CFTimeInterval = 0
    private let body = NSView()        // the small name and the rows, while open
    private(set) var expanded = false
    /// The x of the side facing the bar, and the bottom: what stays put as it grows.
    var anchor = CGPoint.zero
    private var openSize = CGSize.zero
    private var shutSize: CGSize { CGSize(width: ceil(label.frame.width) + 32, height: Bar.height) }

    static func saveIn() -> Section {
        Section("Save in", growsLeft: true) {
            zip(["D", "L", "O"], Settings.standardFolders).map { key, f in
                Item(key: key, title: (f.1.path as NSString).abbreviatingWithTildeInPath, on: Settings.folders.contains { $0.path == f.1.path }) { Settings.toggle(folder: f.1) }
            }
        }
    }

    static func options() -> Section {
        Section("Options", growsLeft: false) {
            [Item(key: "C", title: "Copy to Clipboard", on: Settings.copies) { Settings.copies.toggle() },
             Item(key: "P", title: "Pin Thumbnail", on: Settings.thumbnail) { Settings.thumbnail.toggle() },
             Item(key: "M", title: "Capture Mouse", on: Settings.cursor) { Settings.cursor.toggle() }]
        }
    }

    private init(_ name: String, growsLeft: Bool, items: @escaping () -> [Item]) {
        self.name = name
        self.growsLeft = growsLeft
        self.items = items
        label = NSTextField(labelWithString: name)
        grip = Grip(left: growsLeft)
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
        let back = Ground()
        contentView = back
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.85)
        label.sizeToFit()
        setFrame(target(false), display: false)
        label.setFrameOrigin(CGPoint(x: 16, y: ((Bar.height - label.frame.height) / 2).rounded()))
        // Even margins stretch evenly: the name stays centred while it fades out.
        label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        // Pinned to the top and to the side by the bar, so the edges that move clip it.
        body.autoresizingMask = [.minYMargin, growsLeft ? .minXMargin : .maxXMargin]
        grip.setFrameOrigin(CGPoint(x: growsLeft ? 0 : shutSize.width - grip.frame.width, y: Bar.height - grip.frame.height))
        grip.autoresizingMask = [.minYMargin, growsLeft ? .maxXMargin : .minXMargin]
        for v in [label, grip, body] as [NSView] {
            v.wantsLayer = true
            back.addSubview(v)
        }
        reload()
    }

    override var canBecomeKey: Bool { false }

    func target(_ open: Bool) -> CGRect {
        let size = open ? openSize : shutSize
        return CGRect(x: growsLeft ? anchor.x - size.width : anchor.x, y: anchor.y, width: size.width, height: size.height)
    }

    /// Opens while the pointer is on it, shut or open; true when it is.
    func hover(_ p: CGPoint) -> Bool {
        let inside = target(expanded).contains(p) || CACurrentMediaTime() < peekUntil
        if inside != expanded { expand(inside) }
        return inside
    }

    func reload() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let all = items()
        let keys = all.map { item in StripKey(item) { [weak self] in item.flip(); self?.reload() } }
        let width = keys.map(\.frame.width).max()!
        let n = CGFloat(keys.count)
        let h = 2 * Section.pad + Section.titleHeight + n * Section.row + (n - 1) * Section.gap
        openSize = CGSize(width: max(width + 2 * Section.pad, shutSize.width), height: h)
        let size = contentView!.frame.size
        body.frame = CGRect(x: growsLeft ? size.width - openSize.width : 0, y: size.height - h, width: openSize.width, height: h)
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.sizeToFit()
        var y = h - Section.pad - Section.titleHeight
        title.setFrameOrigin(CGPoint(x: Section.pad + 6, y: y + 3))
        body.addSubview(title)
        for k in keys {
            y -= Section.row
            k.frame = CGRect(x: Section.pad, y: y, width: width, height: Section.row)
            body.addSubview(k)
            y -= Section.gap
        }
        body.alphaValue = expanded ? 1 : 0
        label.alphaValue = expanded ? 0 : 1
        grip.alphaValue = label.alphaValue
    }

    /// Grows to its rows or back to its name: an ease-out over 250 ms, the two crossfading;
    /// Reduce Motion keeps the crossfade alone.
    func expand(_ on: Bool, animated: Bool = true) {
        guard on != expanded || !animated else { return }
        expanded = on
        let f = target(on)
        guard animated else {
            setFrame(f, display: true)
            body.alphaValue = on ? 1 : 0
            label.alphaValue = on ? 0 : 1
            grip.alphaValue = label.alphaValue
            return
        }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if still { setFrame(f, display: true) }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.25
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if !still { animator().setFrame(f, display: true) }
            body.animator().alphaValue = on ? 1 : 0
            label.animator().alphaValue = on ? 0 : 1
            grip.animator().alphaValue = on ? 0 : 1
        }
    }

    /// ⌥ + `key`; false when no setting here has that letter.
    func flip(_ key: String) -> Bool {
        guard let item = items().first(where: { $0.key == key.uppercased() }) else { return false }
        item.flip()
        peekUntil = CACurrentMediaTime() + 1.2
        reload()
        return true
    }
}

/// One setting: its key on a cap, its name, and a tick when it is on; on, the row sits on the
/// accent colour.
private final class StripKey: NSView {
    private let item: Section.Item
    private let flip: () -> Void
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let keyFont = NSFont.systemFont(ofSize: 12)
    private static let tick = NSFont.systemFont(ofSize: 11, weight: .bold)
    private var chord: String { "⌥" + item.key }
    /// One width for every cap, the widest letter's, so they line up.
    private static let capWidth = ceil(("⌥M" as NSString).size(withAttributes: [.font: keyFont]).width) + 12

    init(_ item: Section.Item, flip: @escaping () -> Void) {
        self.item = item
        self.flip = flip
        let text = (item.title as NSString).size(withAttributes: [.font: StripKey.font]).width
        super.init(frame: CGRect(x: 0, y: 0, width: 34 + ceil(text) + 18 + StripKey.capWidth + 8, height: 30))
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
        let box = CGRect(x: 8, y: (bounds.height - 18) / 2, width: 18, height: 18)
        if on {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            let p = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
            p.lineWidth = 1
            p.stroke()
        }
        func put(_ s: String, _ attrs: [NSAttributedString.Key: Any], x: CGFloat? = nil, right: CGFloat? = nil, in r: CGRect) {
            let size = (s as NSString).size(withAttributes: attrs)
            let left = right.map { $0 - size.width } ?? x ?? r.midX - size.width / 2
            (s as NSString).draw(at: CGPoint(x: left, y: r.midY - size.height / 2), withAttributes: attrs)
        }
        if on { put("✓", [.font: StripKey.tick, .foregroundColor: NSColor.white], in: box) }
        put(item.title, [.font: StripKey.font,
                         .foregroundColor: NSColor.labelColor.withAlphaComponent(on ? 0.95 : 0.6)], x: 34, in: bounds)
        // The shortcut on a small light key cap.
        let attrs: [NSAttributedString.Key: Any] = [.font: StripKey.keyFont, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.7)]
        let w = StripKey.capWidth
        let cap = CGRect(x: bounds.maxX - 8 - w, y: (bounds.height - 20) / 2, width: w, height: 20)
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: cap, xRadius: 5, yRadius: 5).fill()
        put(chord, attrs, in: cap)
    }
}

/// Two short diagonals across a corner, like a resize grip: the block opens.
private final class Grip: NSView {
    private let left: Bool
    init(left: Bool) {
        self.left = left
        super.init(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath()
        // Across the top corner, 5 pt in: clear of the 12 pt rounding.
        for a: CGFloat in [10, 5] {
            let x0: CGFloat = left ? 5 : bounds.maxX - 5
            let edge = CGPoint(x: x0, y: bounds.maxY - 5 - a)
            let top = CGPoint(x: left ? x0 + a : x0 - a, y: bounds.maxY - 5)
            p.move(to: edge)
            p.line(to: top)
        }
        p.lineWidth = 1.5
        p.lineCapStyle = .round
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        p.stroke()
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
}
