import AppKit
import AVFoundation
import ScreenshotCore

/// The corner card after a capture. Eight seconds, paused under the mouse; the file is already
/// written, unlike the system's, whose card *is* the wait.
@MainActor
final class Thumbnail: NSPanel {
    enum Content {
        case image(CGImage, URL, CGRect)
        case movie(CGImage?, URL)
    }

    private static var current: Thumbnail?
    private let content: Content
    private var timer: Timer?
    private var pinButton: NSImageView?

    static func show(_ content: Content) {
        guard Settings.thumbnail else { return }
        current?.orderOut(nil)
        current = Thumbnail(content, on: .underMouse)
        current?.orderFrontRegardless()
        current?.arm()
    }

    /// Off screen until `show` puts it there: Docs draws one without.
    init(_ content: Content, on screen: NSScreen) {
        self.content = content
        // Top-right corner, a tenth of the screen wide at most, the capture centred on it.
        let v = screen.visibleFrame
        let width = (v.width / 10).rounded()
        var size = CGSize(width: width, height: (width * 0.625).rounded())
        switch content {
        case .image(let img, _, _), .movie(.some(let img), _):
            size = cardSize(CGSize(width: img.width, height: img.height), side: width)
        default: break
        }
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = CardView(frame: CGRect(origin: .zero, size: frame.size), card: self)
        contentView = view
        switch content {
        case .image(let img, _, _), .movie(.some(let img), _):
            let iv = NSImageView(frame: view.bounds)
            iv.image = NSImage(cgImage: img, size: .zero)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.autoresizingMask = [.width, .height]
            view.addSubview(iv)
        case .movie(nil, _):
            view.addSubview(label("Recording", in: view.bounds))
        }
        if case .image = content {
            // The whole card is the pin button: a white symbol on a tint, so it reads on any
            // picture. Not an NSButton, which would swallow the drag. Shown while hovered.
            let b = NSImageView(image: NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")!)
            b.contentTintColor = .white
            b.toolTip = "Pin"
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor(white: 0, alpha: 0.4).cgColor
            b.frame = view.bounds
            b.isHidden = true
            view.addSubview(b)
            pinButton = b
        }

        // Under the pinned cards, if any.
        setFrameOrigin(CGPoint(x: v.maxX - frame.width - 16, y: Pin.stackBottom(on: screen) - frame.height - 16))
    }

    private func label(_ s: String, in r: CGRect) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.frame = r
        t.textColor = .white
        t.maximumNumberOfLines = 8
        t.alignment = .center
        return t
    }

    func arm() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }
    func hold() { timer?.invalidate() }
    func hover(_ p: CGPoint?) { pinButton?.isHidden = p == nil }

    func click(at p: CGPoint) {
        if pinButton != nil { pin() } else { open() }
    }

    func dismiss() {
        timer?.invalidate()
        orderOut(nil)
        if Thumbnail.current === self { Thumbnail.current = nil }
    }

    var url: URL {
        switch content {
        case .image(_, let u, _), .movie(_, let u): return u
        }
    }

    func open() {
        NSWorkspace.shared.open(url)
        dismiss()
    }

    private func pin() {
        if case .image(let img, let url, _) = content { Pin.show(img, url: url) }
        dismiss()
    }

    private final class CardView: NSView, NSDraggingSource {
        unowned let card: Thumbnail
        private var down: CGPoint?
        init(frame: CGRect, card: Thumbnail) {
            self.card = card
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.95).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
            layer?.borderWidth = 2
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { card.hold(); card.hover(event.locationInWindow) }
        override func mouseMoved(with event: NSEvent) { card.hover(event.locationInWindow) }
        override func mouseExited(with event: NSEvent) { card.arm(); card.hover(nil) }
        override func mouseDown(with event: NSEvent) { down = event.locationInWindow }
        override func mouseUp(with event: NSEvent) { if let down { card.click(at: down) }; down = nil }
        override func mouseDragged(with event: NSEvent) {
            guard let start = down, start.distance(to: event.locationInWindow) > 6 else { return }
            down = nil
            let item = NSDraggingItem(pasteboardWriter: card.url as NSURL)
            let image = card.contentView?.subviews.compactMap { $0 as? NSImageView }.first?.image
            item.setDraggingFrame(image.map { AVMakeRect(aspectRatio: $0.size, insideRect: bounds) } ?? bounds, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }
        func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
        func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) { card.dismiss() }
    }
}
