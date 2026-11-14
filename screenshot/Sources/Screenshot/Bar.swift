import AppKit
import ScreenshotCore

/// The ⌘⇧5 strip: the stills, Capture, then Save in and Options as icons whose settings rise
/// above them on hover. Never key: keys go to the overlay.
final class Bar: NSPanel {
    // Apple's geometry, measured on the system bar at 2×: 53 pt tall, stills on a
    // 50 pt pitch in 44×36 buttons.
    static let height: CGFloat = 53
    /// Each divider sits this far from the buttons on both of its sides.
    private static let gap: CGFloat = 10
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
        // The overlay sets its own cursor on every move; the bar takes it back: a hand on a button.
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
            x = b.frame.maxX + 6
            back.addSubview(b)
            buttons.append(b)
        }
        x = buttons.last!.frame.maxX + Bar.gap
        back.addSubview(Bar.divider(at: x))
        x += 1 + Bar.gap

        go.font = .systemFont(ofSize: 15)
        go.target = self
        go.action = #selector(commit)
        go.attributedTitle = NSAttributedString(string: "Capture", attributes: [.foregroundColor: NSColor.white, .font: go.font!])
        go.frame = CGRect(x: x, y: mid - 18.25, width: go.attributedTitle.size().width + 30, height: 36.5)
        back.addSubview(go)
        refresh()
        x = go.frame.maxX + Bar.gap
        back.addSubview(Bar.divider(at: x))
        x += 1 + Bar.gap

        for s in sections {
            s.button.frame = CGRect(x: x, y: mid - 18, width: 44, height: 36)
            x = s.button.frame.maxX + 6
            back.addSubview(s.button)
        }

        let width = options.button.frame.maxX + 8.5
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
        if sections.map({ $0.hover(p) }).contains(true) || onButton(p) { NSCursor.pointingHand.set() }
    }

    /// Over a button that a click would press.
    func onButton(_ p: CGPoint) -> Bool {
        (contentView?.hitTest(convertPoint(fromScreen: p)) as? NSButton)?.isEnabled == true
    }
    private func pointer() { (onButton(NSEvent.mouseLocation) ? NSCursor.pointingHand : .arrow).set() }

    /// Each group 8 pt above the bar, centred on its button.
    private func placeSections() {
        for s in sections {
            s.spot = convertToScreen(s.button.frame)
            s.floor = frame.maxY + 8
            s.setFrame(s.target(s.expanded), display: false)
        }
    }

    /// ⌥ + `key`; false when no setting has that letter.
    func flip(_ key: String) -> Bool { sections.contains { $0.flip(key) } }
    override func mouseEntered(with event: NSEvent) { pointer() }
    override func mouseMoved(with event: NSEvent) { pointer() }

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
        var parts: [NSWindow] = [self] + sections.filter(\.expanded)
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

/// An icon on the bar whose ground stays lit while its group is open.
final class IconButton: HoverButton {
    var open = false { didSet { paint() } }

    init(_ symbol: String, _ name: String) {
        super.init()
        image = Glyph.image(for: symbol)
        setAccessibilityLabel(name)
        imagePosition = .imageOnly
        contentTintColor = NSColor.labelColor.withAlphaComponent(0.7)
    }
    required init?(coder: NSCoder) { nil }

    override var ground: NSColor? { hovered || open ? NSColor.labelColor.withAlphaComponent(0.06) : nil }
}

/// One group of settings, hidden above its icon on the bar. Hovered, the icon lets it rise and
/// fade in, a row per setting. A click or ⌥ + the letter shown on its row flips one.
final class Section: NSPanel {
    struct Item {
        let key: String, title: String, on: Bool
        let flip: () -> Void
    }

    private static let pad: CGFloat = 8, titleHeight: CGFloat = 24, row: CGFloat = 30, gap: CGFloat = 2, rise: CGFloat = 8
    let name: String
    let button: IconButton
    private let items: () -> [Item]
    /// A shortcut opens the group a moment, so the flip shows.
    private var peekUntil: CFTimeInterval = 0
    private(set) var expanded = false
    /// Its icon's frame on screen, and the bottom it rises to.
    var spot = CGRect.zero
    var floor: CGFloat = 0
    private var size = CGSize.zero

    static func saveIn() -> Section {
        Section("Save in", icon: "folder") {
            zip(["D", "L", "O"], Settings.standardFolders).map { key, f in
                Item(key: key, title: (f.1.path as NSString).abbreviatingWithTildeInPath, on: Settings.folders.contains { $0.path == f.1.path }) { Settings.toggle(folder: f.1) }
            }
        }
    }

    static func options() -> Section {
        Section("Options", icon: "gearshape") {
            [Item(key: "C", title: "Copy to Clipboard", on: Settings.copies) { Settings.copies.toggle() },
             Item(key: "P", title: "Pin Thumbnail", on: Settings.thumbnail) { Settings.thumbnail.toggle() },
             Item(key: "M", title: "Capture Mouse", on: Settings.cursor) { Settings.cursor.toggle() }]
        }
    }

    private init(_ name: String, icon: String, items: @escaping () -> [Item]) {
        self.name = name
        self.items = items
        button = IconButton(icon, name)
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
        alphaValue = 0
        ignoresMouseEvents = true
        reload()
    }

    override var canBecomeKey: Bool { false }

    /// Open: `floor` up, centred on its icon; shut: `rise` lower, where it fades in from.
    func target(_ open: Bool) -> CGRect {
        CGRect(x: (spot.midX - size.width / 2).rounded(), y: floor - (open ? 0 : Section.rise), width: size.width, height: size.height)
    }

    /// Opens while the pointer is on its icon, on the way up from it, or on the open group.
    func hover(_ p: CGPoint) -> Bool {
        let open = target(true)
        let path = CGRect(x: spot.minX, y: spot.minY, width: spot.width, height: open.minY - spot.minY)
        let inside = path.contains(p) || expanded && open.contains(p) || CACurrentMediaTime() < peekUntil
        if inside != expanded { expand(inside) }
        return inside
    }

    func reload() {
        let back = contentView!
        back.subviews.forEach { $0.removeFromSuperview() }
        let keys = items().map { item in StripKey(item) { [weak self] in item.flip(); self?.reload() } }
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor.labelColor.withAlphaComponent(0.6)
        title.sizeToFit()
        let width = max(keys.map(\.frame.width).max()!, title.frame.width)
        let n = CGFloat(keys.count)
        let h = 2 * Section.pad + Section.titleHeight + n * Section.row + (n - 1) * Section.gap
        size = CGSize(width: width + 2 * Section.pad, height: h)
        setFrame(target(expanded), display: false)
        var y = h - Section.pad - Section.titleHeight
        title.frame.origin = CGPoint(x: Section.pad + 4, y: y + (Section.titleHeight - title.frame.height) / 2)
        back.addSubview(title)
        for k in keys {
            y -= Section.row
            k.frame = CGRect(x: Section.pad, y: y, width: width, height: Section.row)
            back.addSubview(k)
            y -= Section.gap
        }
    }

    /// Rises 8 pt and fades in over 250 ms, ease-out; shuts the same way back. Reduce Motion
    /// keeps the fade alone.
    func expand(_ on: Bool, animated: Bool = true) {
        guard on != expanded || !animated else { return }
        expanded = on
        button.open = on
        ignoresMouseEvents = !on
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let f = target(on || still)
        guard animated else {
            setFrame(f, display: true)
            alphaValue = on ? 1 : 0
            return
        }
        if still { setFrame(f, display: true) }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = on ? 0.25 : 0.2
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if !still { animator().setFrame(f, display: true) }
            animator().alphaValue = on ? 1 : 0
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

    /// The folder and the gear in the stills' hand: the same 2 pt stroke, size and corners.
    static func image(for symbol: String) -> NSImage {
        let img = NSImage(size: CGSize(width: 29, height: 22.5), flipped: true) { _ in
            let p = NSBezierPath()
            p.lineWidth = 2
            if symbol == "folder" {
                // A tab on the top left, the body below it.
                p.move(to: CGPoint(x: 1, y: 12))
                p.appendArc(from: CGPoint(x: 1, y: 1), to: CGPoint(x: 11, y: 1), radius: 3.5)
                p.appendArc(from: CGPoint(x: 11, y: 1), to: CGPoint(x: 14, y: 5), radius: 1.5)
                p.appendArc(from: CGPoint(x: 14, y: 5), to: CGPoint(x: 27.5, y: 5), radius: 1.5)
                p.appendArc(from: CGPoint(x: 27.5, y: 5), to: CGPoint(x: 27.5, y: 21.5), radius: 4.5)
                p.appendArc(from: CGPoint(x: 27.5, y: 21.5), to: CGPoint(x: 1, y: 21.5), radius: 4.5)
                p.appendArc(from: CGPoint(x: 1, y: 21.5), to: CGPoint(x: 1, y: 1), radius: 4.5)
                p.close()
                // A tick in the body: the folders it saves to.
                p.move(to: CGPoint(x: 9.5, y: 13.5))
                p.line(to: CGPoint(x: 12.75, y: 16.75))
                p.line(to: CGPoint(x: 19, y: 10.25))
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                p.stroke()
            } else {
                // One outline: eight tapered teeth on a ring, a round hub inside.
                let c = CGPoint(x: 14.5, y: 11.25), tip: CGFloat = 10.25, root: CGFloat = 7.75
                func at(_ r: CGFloat, _ deg: CGFloat) -> CGPoint {
                    CGPoint(x: c.x + r * cos(deg * .pi / 180), y: c.y + r * sin(deg * .pi / 180))
                }
                for i in 0..<8 {
                    let a = CGFloat(i) * 45
                    i == 0 ? p.move(to: at(root, a - 15)) : p.line(to: at(root, a - 15))
                    p.line(to: at(tip, a - 9))
                    p.line(to: at(tip, a + 9))
                    p.line(to: at(root, a + 15))
                }
                p.close()
                p.appendOval(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
                p.lineJoinStyle = .round
                p.stroke()
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
