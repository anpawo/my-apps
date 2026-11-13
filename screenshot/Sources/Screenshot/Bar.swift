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
    let go = CaptureButton()
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

        go.font = .systemFont(ofSize: 15)
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

    /// 8 pt off each end, bottoms level with the bar's: they grow upward and away from it.
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

/// A button whose ground lightens under the pointer, fading over 150 ms.
class HoverButton: NSButton {
    private(set) var hovered = false { didSet { paint() } }
    var onHover: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovered = false; onHover?(false) }

    var ground: NSColor? { nil }
    func paint() {
        guard let layer else { return }
        // A view's own layer takes no implicit animation.
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        fade.duration = 0.15
        layer.backgroundColor = ground?.cgColor
        layer.add(fade, forKey: "ground")
    }
}

/// One mode. The selected one sits on a rounded tint, like the system's.
final class ModeButton: HoverButton {
    let mode: BarState
    var isSelected = false {
        didSet {
            paint()
            contentTintColor = NSColor.labelColor.withAlphaComponent(isSelected ? 0.95 : 0.7)
        }
    }

    init(state: BarState, target: AnyObject, action: Selector) {
        self.mode = state
        super.init()
        self.target = target
        self.action = action
        image = Glyph.image(for: state)
        imagePosition = .imageOnly
        contentTintColor = NSColor.labelColor.withAlphaComponent(0.7)
        toolTip = "Capture " + Glyph.tip[state.target]!
    }
    required init?(coder: NSCoder) { nil }

    override var ground: NSColor? {
        isSelected ? NSColor.labelColor.withAlphaComponent(hovered ? 0.14 : 0.1) : hovered ? NSColor.labelColor.withAlphaComponent(0.06) : nil
    }
}

/// Painted by hand: AppKit only tints a default button in a key window, and this one never is.
final class CaptureButton: HoverButton {
    override var isEnabled: Bool { didSet { paint() } }
    override var ground: NSColor? {
        let accent = NSColor.controlAccentColor
        return !isEnabled ? accent.withAlphaComponent(0.4) : hovered ? accent.blended(withFraction: 0.18, of: .white) : accent
    }
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

    private static let pad: CGFloat = 8, titleHeight: CGFloat = 24, row: CGFloat = 30, gap: CGFloat = 2
    private let name: String
    private let growsLeft: Bool
    private let items: () -> [Item]
    private let label: Title           // the name: centred while shrunk, the header while open
    /// A shortcut opens the block a moment, so the flip shows.
    private var peekUntil: CFTimeInterval = 0
    private let body = NSView()        // the small name and the rows, while open
    private(set) var expanded = false
    /// The x of the side facing the bar, and the bottom: what stays put as it grows.
    var anchor = CGPoint.zero
    private var openSize = CGSize.zero
    static let shutHeight: CGFloat = 36
    private var shutSize: CGSize { CGSize(width: ceil(label.width) + 32, height: Section.shutHeight) }

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
        label = Title(name)
        label.header = (Section.pad, Section.titleHeight)
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
        setFrame(target(false), display: false)
        label.frame = back.bounds
        label.autoresizingMask = [.width, .height]
        // Pinned to the top and to the side by the bar, so the edges that move clip it.
        body.autoresizingMask = [.minYMargin, growsLeft ? .minXMargin : .maxXMargin]
        for v in [label, body] as [NSView] {
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
        var y = h - Section.pad - Section.titleHeight
        for k in keys {
            y -= Section.row
            k.frame = CGRect(x: Section.pad, y: y, width: width, height: Section.row)
            body.addSubview(k)
            y -= Section.gap
        }
        body.alphaValue = expanded ? 1 : 0
        label.progress = expanded ? 1 : 0
    }

    /// Grows to its rows or back to its name: an ease-out over 250 ms, the name gliding to the
    /// header and the rows fading in; Reduce Motion keeps the fade alone.
    func expand(_ on: Bool, animated: Bool = true) {
        guard on != expanded || !animated else { return }
        expanded = on
        let f = target(on)
        guard animated else {
            setFrame(f, display: true)
            body.alphaValue = on ? 1 : 0
            label.progress = on ? 1 : 0
            return
        }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if still { setFrame(f, display: true); label.progress = on ? 1 : 0 }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.25
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if !still { animator().setFrame(f, display: true) }
            body.animator().alphaValue = on ? 1 : 0
            if !still { label.animator().progress = on ? 1 : 0 }
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

    /// 0 to 1 as the pointer comes on the row: its ground deepens.
    @objc dynamic var glow: CGFloat = 0 { didSet { needsDisplay = true } }

    init(_ item: Section.Item, flip: @escaping () -> Void) {
        self.item = item
        self.flip = flip
        let text = (item.title as NSString).size(withAttributes: [.font: StripKey.font]).width
        super.init(frame: CGRect(x: 0, y: 0, width: 34 + ceil(text) + 18 + StripKey.capWidth + 8, height: 30))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { flip() }

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "glow" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }
    private func light(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().glow = on ? 1 : 0 }
    }
    override func mouseEntered(with event: NSEvent) { light(true) }
    override func mouseExited(with event: NSEvent) { light(false) }
    /// A click rebuilds the rows under the pointer: the new one starts lit, with no enter to say so.
    override func viewDidMoveToWindow() {
        guard let window else { return }
        glow = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) ? 1 : 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let on = item.on
        let ground = on ? NSColor.controlAccentColor.withAlphaComponent(0.16 + 0.1 * glow) : NSColor.labelColor.withAlphaComponent(0.07 * glow)
        ground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
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

/// A group's name, centred in the block at `progress` between its middle (0) and the header (1),
/// so it glides up as the block opens rather than fading into a copy.
private final class Title: NSView {
    private let name: String
    @objc dynamic var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    init(_ name: String) {
        self.name = name
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "progress" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    private var attrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)]
    }
    var width: CGFloat { size.width }
    private var size: CGSize { (name as NSString).size(withAttributes: attrs) }

    /// `header` is the band under the top padding the open block keeps for the name.
    var header: (pad: CGFloat, height: CGFloat) = (0, 0)

    override func draw(_ dirtyRect: NSRect) {
        let t = min(max(progress, 0), 1)
        let shut = (bounds.height - size.height) / 2
        let open = bounds.height - header.pad - (header.height + size.height) / 2
        (name as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: shut + (open - shut) * t), withAttributes: attrs)
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
