import AppKit

/// The letters typed with ⌘ held: a pill sitting across the panel's top edge.
///
/// A child window of its own rather than a view in the panel, because half of it is outside the
/// panel and the panel's height is not to change while typing.
@MainActor
enum Badge {

    static let font = NSFont.systemFont(ofSize: 26, weight: .semibold)
    private static let height: CGFloat = 44
    private static let pad: CGFloat = 22
    /// Room around the pill for its shadow.
    private static let margin: CGFloat = 20

    private static var window: NSPanel?
    private static let pill = CALayer()
    private static let kept = CATextLayer()
    private static let refused = CATextLayer()
    private static var query = ""
    private static var isUp = false
    /// Bumped by every change, so a delayed step of an older one knows it has been overtaken.
    private static var generation = 0

    private static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func show(_ query: String, on panel: NSPanel) {
        generation += 1
        self.query = query
        guard !query.isEmpty else { return leave() }
        attach(to: panel)
        if !isUp {
            isUp = true
            still {
                layout(extra: 0)
                refused.opacity = 0
            }
            popIn()
        } else {
            animate(0.2) {
                layout(extra: 0)
                refused.opacity = 0
            }
        }
    }

    /// The letter in red after the kept ones, the pill shaken, then the letter faded and the
    /// pill closed back around what was kept.
    static func reject(_ letter: Character, on panel: NSPanel) {
        generation += 1
        let mine = generation
        attach(to: panel)
        let width = size(String(letter)).width
        let appearing = !isUp
        isUp = true
        still {
            refused.string = String(letter)
            refused.opacity = 1
        }
        if appearing {
            still { layout(extra: width) }
            popIn()
        } else {
            animate(0.12) { layout(extra: width) }
        }
        if !reduce {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -8, 8, -5, 5, -2, 0]
            shake.duration = 0.32
            shake.isAdditive = true
            pill.add(shake, forKey: "shake")
        }
        after(0.3, mine) {
            animate(0.15) { refused.opacity = 0 }
            after(0.15, mine) {
                if query.isEmpty { leave() } else { animate(0.2) { layout(extra: 0) } }
            }
        }
    }

    /// The panel going away takes the badge with it, at once.
    static func hide() {
        generation += 1
        query = ""
        isUp = false
        still {
            pill.opacity = 0
            refused.opacity = 0
        }
        detach()
    }

    /// The pill over a panel of this size, for `Panel.png`: a layer tree drawn into a bitmap.
    static func image(_ query: String, refusing letter: Character? = nil, panelWidth: CGFloat, scale: CGFloat) -> CGImage? {
        let window = built()
        window.setFrame(NSRect(x: 0, y: 0, width: panelWidth, height: height + margin * 2), display: false)
        self.query = query
        still {
            kept.contentsScale = scale
            refused.contentsScale = scale
            refused.string = letter.map(String.init) ?? ""
            refused.opacity = letter == nil ? 0 : 1
            layout(extra: letter.map { size(String($0)).width } ?? 0)
            pill.opacity = 1
            pill.transform = CATransform3DIdentity
        }
        guard let root = window.contentView?.layer,
              let ctx = CGContext(data: nil, width: Int(panelWidth * scale), height: Int((height + margin * 2) * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        root.render(in: ctx)
        return ctx.makeImage()
    }

    static var overhang: CGFloat { height / 2 + margin }

    /// Built ahead of the first letter: a layer created in the same transaction it changes in is
    /// not animated, and the first badge of the session would pop in without its fade.
    static func warm() { _ = built() }

    /// Explicit rather than implicit, for that same reason: it plays however new the layer is.
    private static func popIn() {
        still {
            pill.opacity = 1
            pill.transform = CATransform3DIdentity
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        var parts: [CAAnimation] = [fade]
        if !reduce {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.8
            grow.toValue = 1
            parts.append(grow)
        }
        let group = CAAnimationGroup()
        group.animations = parts
        group.duration = reduce ? 0.12 : 0.25
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pill.add(group, forKey: "pop")
    }

    private static func leave() {
        guard isUp else { return }
        isUp = false
        let mine = generation
        animate(0.18) {
            pill.opacity = 0
            if !reduce { pill.transform = CATransform3DMakeScale(0.9, 0.9, 1) }
        }
        after(0.2, mine) { detach() }
    }

    /// Centred on the panel's top edge. Only on a panel that is up: a child window added to one
    /// that is not would be put on the screen by itself.
    private static func attach(to panel: NSPanel) {
        let window = built()
        window.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - overhang,
                               width: panel.frame.width, height: height + margin * 2), display: false)
        let scale = panel.backingScaleFactor
        kept.contentsScale = scale
        refused.contentsScale = scale
        guard panel.isVisible, window.parent !== panel else { return }
        panel.addChildWindow(window, ordered: .above)
    }

    private static func detach() {
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    private static func size(_ text: String) -> CGSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    /// The pill around the kept letters plus `extra` points for a refused one, centred in the
    /// window; the refused letter keeps its own width so a fade never squeezes it.
    private static func layout(extra: CGFloat) {
        guard let width = window?.contentView?.bounds.width else { return }
        let keptWidth = size(query).width
        let pillWidth = max(height, keptWidth + extra + pad * 2)
        pill.bounds = CGRect(x: 0, y: 0, width: pillWidth, height: height)
        pill.position = CGPoint(x: (width / 2).rounded(), y: margin + height / 2)
        let textHeight = ceil(font.ascender - font.descender)
        let y = ((height - textHeight) / 2).rounded()
        kept.string = query
        kept.frame = CGRect(x: ((pillWidth - keptWidth - extra) / 2).rounded(), y: y,
                            width: keptWidth + 1, height: textHeight)
        let refusedWidth = size(refused.string as? String ?? "").width
        refused.frame = CGRect(x: kept.frame.minX + keptWidth, y: y, width: refusedWidth + 1, height: textHeight)
    }

    private static func built() -> NSPanel {
        if let window { return window }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: height + margin * 2),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .popUpMenu
        w.animationBehavior = .none
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.setAccessibilitySubrole(.unknown)

        let root = NSView(frame: w.contentLayoutRect)
        root.wantsLayer = true
        w.contentView = root

        pill.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        pill.borderColor = NSColor.controlAccentColor.cgColor
        pill.borderWidth = 2
        pill.cornerRadius = height / 2
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOpacity = 0.35
        pill.shadowRadius = 9
        pill.shadowOffset = CGSize(width: 0, height: -3)
        pill.opacity = 0
        for (layer, color) in [(kept, NSColor.white), (refused, NSColor.systemRed)] {
            layer.font = font
            layer.fontSize = font.pointSize
            layer.foregroundColor = color.cgColor
            layer.alignmentMode = .left
            layer.actions = ["string": NSNull()]
            pill.addSublayer(layer)
        }
        refused.opacity = 0
        root.layer?.addSublayer(pill)
        window = w
        return w
    }

    private static func animate(_ duration: CFTimeInterval, _ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduce ? min(duration, 0.12) : duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        body()
        CATransaction.commit()
    }

    private static func still(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private static func after(_ seconds: Double, _ mine: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                guard mine == generation else { return }
                body()
            }
        }
    }
}
