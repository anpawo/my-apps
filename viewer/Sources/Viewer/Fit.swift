import AppKit

/// Keeps the viewer area 16:9 at launch and on every window resize, so a 16:9 video fills it with no
/// black bars. A column shown or hidden takes or gives room inside the window, which keeps its size.
/// A file open alone sets its own shape instead (`setAspect`), a portrait video a portrait window.
@MainActor
final class StageFit: NSObject, NSWindowDelegate {
    private static let standardAspect: CGFloat = 16.0 / 9.0
    /// Smaller than any real difference between two shapes, larger than rounding.
    private static let aspectTolerance: CGFloat = 0.001

    private let window: NSWindow
    private let stage: () -> NSSize
    private var aspect = standardAspect
    /// After the window took a new size, for a picture to refit it.
    var didFit: () -> Void = {}
    /// The window delegate's close question, for unsaved text.
    var shouldClose: () -> Bool = { true }

    init(window: NSWindow, splitView: NSSplitView, stage: @escaping () -> NSSize) {
        self.window = window
        self.stage = stage
        super.init()
        window.delegate = self
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: splitView,
                                               queue: .main) { [weak self] _ in self?.didFit() }
    }

    /// The viewer area takes this width-to-height ratio, or 16:9 for nil, and the window refits to it.
    func setAspect(_ new: CGFloat?) {
        let target = new ?? Self.standardAspect
        guard abs(target - aspect) > Self.aspectTolerance else { return }
        aspect = target
        if window.isVisible, !window.styleMask.contains(.fullScreen) { fillScreen() }
    }

    /// The window at its usual width (or narrower when the screen, or a tall picture, needs it), its height
    /// giving the viewer its shape, centred.
    func fillScreen() {
        guard let area = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let chrome = chromeSize()
        let width = min(initialWindowSize.width, area.width) - chrome.width
        let fitted = min(width, (area.height - chrome.height) * aspect)
        let size = NSSize(width: fitted + chrome.width, height: (fitted / aspect).rounded() + chrome.height)
        window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        didFit()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose() }

    func windowWillResize(_ sender: NSWindow, to size: NSSize) -> NSSize {
        let chrome = chromeSize()
        return NSSize(width: size.width, height: ((size.width - chrome.width) / aspect).rounded() + chrome.height)
    }

    private func chromeSize() -> NSSize {
        window.contentView?.layoutSubtreeIfNeeded()
        // The height above the stage is read off the window: the stage's own height lags while a column
        // folds, and the fit fed that back into the window (338 pt tall for one file).
        return NSSize(width: window.frame.width - stage().width, height: window.frame.height - window.contentLayoutRect.height)
    }
}

