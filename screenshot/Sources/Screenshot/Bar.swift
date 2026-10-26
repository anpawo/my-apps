import AppKit
import ScreenshotCore

/// The ⌘⇧5 strip, laid out like the system's: ✕, the stills, the recordings, Options, the
/// button. Never key: keys go to the overlay.
final class Bar: NSPanel, NSMenuDelegate {
    // Apple's geometry, measured on the system bar at 2×: 53 pt tall, ✕ at 14.5, stills on a
    // 50 pt pitch in 44×36 buttons, recordings on a 59.25 pt pitch in 53-wide ones, dividers
    // 10 and 7 pt after the groups, Options 17.5 pt after, the button 15 pt after that.
    static let height: CGFloat = 53
    private unowned let session: Session
    private(set) var buttons: [ModeButton] = []
    let go = NSButton()
    private let options = NSButton()
    private let hint = Hint()

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
            let wide = state.kind == .video
            if wide && buttons.last?.mode.kind == .photo {
                back.addSubview(Bar.divider(at: x + 4))       // 10 pt after the last still
                x += 16.5
            }
            b.frame = CGRect(x: x, y: mid - 18, width: wide ? 53 : 44, height: 36)
            x += wide ? 59.25 : 50
            back.addSubview(b)
            buttons.append(b)
        }
        back.addSubview(Bar.divider(at: x + 0.75))            // 7 pt after the last recording
        x += 18.25

        options.title = "Options"
        options.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        options.imagePosition = .imageTrailing
        options.imageHugsTitle = true
        options.isBordered = false
        options.font = .systemFont(ofSize: 15)
        options.contentTintColor = .labelColor
        options.target = self
        options.action = #selector(showOptions)
        options.sizeToFit()
        options.frame = CGRect(x: x, y: mid - options.frame.height / 2, width: options.frame.width + 4, height: options.frame.height)
        back.addSubview(options)
        x = options.frame.maxX + 15

        // Painted by hand: AppKit only tints a default button in a key window, and this one never is.
        go.isBordered = false
        go.font = .systemFont(ofSize: 15)
        go.wantsLayer = true
        go.layer?.cornerRadius = 8
        go.target = self
        go.action = #selector(commit)
        // As wide as its widest title: the bar keeps one width from stills to recordings.
        let widest = ["Capture", "Record"].map { ($0 as NSString).size(withAttributes: [.font: go.font!]).width }.max()!
        go.frame = CGRect(x: x, y: mid - 18.25, width: widest + 30, height: 36.5)
        back.addSubview(go)
        refresh()

        let width = go.frame.maxX + 8.5
        back.frame = CGRect(x: 0, y: 0, width: width, height: Bar.height)
        let v = screen.visibleFrame
        setFrame(CGRect(x: (v.midX - width / 2).rounded(), y: v.minY + 24, width: width, height: Bar.height), display: false)
    }

    override var canBecomeKey: Bool { false }
    override func orderOut(_ sender: Any?) { hint.hide(); super.orderOut(sender) }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }

    func refresh() {
        let s = session.state
        for b in buttons { b.isSelected = b.mode == s }
        let title = s.kind == .photo ? "Capture" : "Record"
        go.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.white, .font: go.font!])
        go.isEnabled = !(s.needsSelection && session.selection == nil)
        go.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(go.isEnabled ? 1 : 0.4).cgColor
    }

    /// The bar as pixels, at 2×, without ever being on screen.
    func render() -> Data? { Bar.pixels(contentView!).representation(using: .png, properties: [:]) }

    /// The bar with the hint of button `i` above it, as the hover shows them, still never on screen.
    func render(hovering i: Int) -> NSBitmapImageRep {
        let b = buttons[i]
        hint.place(b.toolTip!, above: b, in: self)
        let all = frame.union(hint.frame)
        return Bar.canvas(all.size) {
            Bar.pixels(contentView!).draw(in: frame.offsetBy(dx: -all.minX, dy: -all.minY))
            Bar.pixels(hint.contentView!).draw(in: hint.frame.offsetBy(dx: -all.minX, dy: -all.minY))
        }
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

    @objc private func showOptions() {
        let menu = optionsMenu()
        menu.delegate = self
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: options.bounds.height + 6), in: options)
    }

    func menuWillOpen(_ menu: NSMenu) { session.unregisterChords() }
    func menuDidClose(_ menu: NSMenu) { session.registerChords() }

    /// The system's three sections, filled with what this app actually does. Save targets
    /// add up: several folders and the clipboard can all be on.
    private func optionsMenu() -> NSMenu {
        let menu = NSMenu()
        func header(_ t: String) { menu.addItem(withTitle: t, action: nil, keyEquivalent: "") }
        func item(_ t: String, _ sel: Selector, on: Bool, tag: Int = 0, object: Any? = nil) {
            let m = menu.addItem(withTitle: t, action: sel, keyEquivalent: "")
            m.target = self
            m.state = on ? .on : .off
            m.tag = tag
            m.representedObject = object
            m.indentationLevel = 1
        }
        header("Save to")
        let home = FileManager.default.homeDirectoryForCurrentUser
        var known = [("Desktop", home.appendingPathComponent("Desktop")),
                     ("Downloads", home.appendingPathComponent("Downloads")),
                     ("Documents", home.appendingPathComponent("Documents"))]
        for f in Settings.folders where !known.contains(where: { $0.1.path == f.path }) { known.append((f.lastPathComponent, f)) }
        for (name, dir) in known {
            item(name, #selector(toggleFolder(_:)), on: Settings.folders.contains { $0.path == dir.path }, object: dir)
        }
        item("Clipboard", #selector(toggleCopy), on: Settings.copies)
        item("Other Folder…", #selector(pickFolder), on: false)
        menu.addItem(.separator())
        header("Timer")
        for (t, secs) in [("None", 0), ("5 Seconds", 5), ("10 Seconds", 10)] {
            item(t, #selector(setTimer(_:)), on: Settings.timer == secs, tag: secs)
        }
        menu.addItem(.separator())
        header("Options")
        item("Show Floating Thumbnail", #selector(toggleThumbnail), on: Settings.thumbnail)
        item("Show Mouse Pointer", #selector(toggleCursor), on: Settings.cursor)
        if session.state.kind == .video { item("Record Microphone", #selector(toggleMic), on: Settings.microphone) }
        return menu
    }

    @objc private func toggleFolder(_ item: NSMenuItem) {
        let dir = item.representedObject as! URL
        var folders = Settings.folders
        if let i = folders.firstIndex(where: { $0.path == dir.path }) { folders.remove(at: i) } else { folders.append(dir) }
        Settings.folders = folders
    }
    @objc private func toggleThumbnail() { Settings.thumbnail.toggle() }
    @objc private func toggleCopy() { Settings.copies.toggle() }

    @objc private func pick(_ b: ModeButton) { session.state = b.mode; session.refresh() }
    @objc private func cancel() { session.close() }
    @objc private func commit() { session.commit() }
    @objc private func setTimer(_ item: NSMenuItem) { Settings.timer = item.tag }
    @objc private func toggleCursor() { Settings.cursor.toggle() }
    @objc private func toggleMic() { Settings.microphone.toggle() }

    @objc private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Settings.folder
        panel.level = level
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url, !Settings.folders.contains(where: { $0.path == url.path }) {
            Settings.folders.append(url)
        }
    }
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
        toolTip = (state.kind == .video ? "Record " : "Capture ") + Glyph.tip[state.target]!
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

    func show(_ s: String, above button: NSView, in bar: NSWindow) {
        place(s, above: button, in: bar)
        orderFrontRegardless()
    }

    func place(_ s: String, above button: NSView, in bar: NSWindow) {
        text.stringValue = s
        text.sizeToFit()
        let size = CGSize(width: text.frame.width + 16, height: text.frame.height + 8)
        text.frame.origin = CGPoint(x: 8, y: 4)
        let b = bar.convertToScreen(button.convert(button.bounds, to: nil))
        setFrame(CGRect(x: (b.midX - size.width / 2).rounded(), y: b.maxY + 12, width: size.width, height: size.height), display: true)
    }

    func hide() { orderOut(nil) }
}

/// The system's glyphs, traced from its bar: a 28.5 × 22.5 rounded rect with a 2 pt stroke and
/// 4.5 pt corners; a menu-bar line and a dock for the display, three dots for the window,
/// dashes for the area; the recordings add a ring badge that punches through the corner.
enum Glyph {
    static let tip: [Target: String] = [.screen: "Entire Screen", .window: "Selected Window", .area: "Selected Portion"]

    static func image(for s: BarState) -> NSImage {
        let recording = s.kind == .video
        let size = recording ? CGSize(width: 34, height: 25) : CGSize(width: 29, height: 22.5)
        let img = NSImage(size: size, flipped: true) { _ in
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
            if recording {
                let ctx = NSGraphicsContext.current!
                ctx.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: CGRect(x: 19.75, y: 10.75, width: 15.5, height: 15.5)).fill()
                ctx.compositingOperation = .sourceOver
                let ring = NSBezierPath(ovalIn: CGRect(x: 22.25, y: 13.25, width: 10.5, height: 10.5))
                ring.lineWidth = 2
                ring.stroke()
                NSBezierPath(ovalIn: CGRect(x: 24, y: 15, width: 7, height: 7)).fill()
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
