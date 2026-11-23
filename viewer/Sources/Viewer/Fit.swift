import AppKit

/// Keeps the viewer area 16:9 whatever the window's width and whichever columns show, so a 16:9 video
/// fills it with no black bars: at launch at the usual width, then on every resize or column toggle.
/// A file open alone sets its own shape instead (`setAspect`), a portrait video a portrait window.
@MainActor
final class StageFit: NSObject, NSWindowDelegate {
    private static let standardAspect: CGFloat = 16.0 / 9.0
    /// Smaller than any real difference between two shapes, larger than rounding.
    private static let aspectTolerance: CGFloat = 0.001
    /// Below this a height difference is rounding, not a change to follow.
    private static let tolerance: CGFloat = 1

    private let window: NSWindow
    private let stage: () -> NSSize
    private var aspect = standardAspect
    private var lastChromeWidth: CGFloat = 0
    /// After the window took a new size, for a picture to refit it.
    var didFit: () -> Void = {}
    /// The window delegate's close question, for unsaved text.
    var shouldClose: () -> Bool = { true }
    private var adjusting = false

    init(window: NSWindow, splitView: NSSplitView, stage: @escaping () -> NSSize) {
        self.window = window
        self.stage = stage
        super.init()
        window.delegate = self
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: splitView,
                                               queue: .main) { [weak self] _ in
            // Out of the split view's layout pass: a window resize inside it left the content view at its old
            // height (867 pt in a 716 pt window once the sidebar folded), the picture pushed down.
            DispatchQueue.main.async { self?.follow() }
        }
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
        lastChromeWidth = chrome.width
        adjusting = true
        window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        adjusting = false
        didFit()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose() }

    func windowWillResize(_ sender: NSWindow, to size: NSSize) -> NSSize {
        let chrome = chromeSize()
        return NSSize(width: size.width, height: ((size.width - chrome.width) / aspect).rounded() + chrome.height)
    }

    /// A column shown, hidden or dragged changes the viewer's width while the window's stays: the height
    /// follows, the top edge stays. A window resize leaves the columns' total alone, so it is ignored here
    /// (following it fed back into the resize and shrank the window).
    private func follow() {
        let chrome = chromeSize()
        guard !adjusting, !window.styleMask.contains(.fullScreen), let area = window.screen?.visibleFrame,
              abs(chrome.width - lastChromeWidth) > Self.tolerance else { return }
        lastChromeWidth = chrome.width
        let height = min(area.height, ((window.frame.width - chrome.width) / aspect).rounded() + chrome.height)
        guard abs(height - window.frame.height) > Self.tolerance else { return }
        var frame = window.frame
        frame.origin.y = max(area.minY, frame.maxY - height)
        frame.size.height = height
        adjusting = true
        window.setFrame(frame, display: true)
        adjusting = false
    }

    private func chromeSize() -> NSSize {
        window.contentView?.layoutSubtreeIfNeeded()
        // The height above the stage is read off the window: the stage's own height lags while a column
        // folds, and the fit fed that back into the window (338 pt tall for one file).
        return NSSize(width: window.frame.width - stage().width, height: window.frame.height - window.contentLayoutRect.height)
    }
}

