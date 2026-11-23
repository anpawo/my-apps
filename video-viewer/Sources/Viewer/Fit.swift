import AppKit

/// Keeps the viewer area 16:9 whatever the window's width and whichever columns show, so a 16:9 video
/// fills it with no black bars: at launch at the usual width, then on every resize or column toggle.
@MainActor
final class StageFit: NSObject, NSWindowDelegate {
    private static let aspect: CGFloat = 16.0 / 9.0
    /// Below this a height difference is rounding, not a change to follow.
    private static let tolerance: CGFloat = 1

    private let window: NSWindow
    private let stage: () -> NSSize
    private var lastChromeWidth: CGFloat = 0
    private var adjusting = false

    init(window: NSWindow, splitView: NSSplitView, stage: @escaping () -> NSSize) {
        self.window = window
        self.stage = stage
        super.init()
        window.delegate = self
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: splitView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
    }

    /// The window at its usual width (or narrower when the screen is), its height making the viewer 16:9, centred.
    func fillScreen() {
        guard let area = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let chrome = chromeSize()
        let width = min(initialWindowSize.width, area.width) - chrome.width
        let fitted = min(width, (area.height - chrome.height) * Self.aspect)
        let size = NSSize(width: fitted + chrome.width, height: (fitted / Self.aspect).rounded() + chrome.height)
        lastChromeWidth = chrome.width
        adjusting = true
        window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        adjusting = false
    }

    func windowWillResize(_ sender: NSWindow, to size: NSSize) -> NSSize {
        let chrome = chromeSize()
        return NSSize(width: size.width, height: ((size.width - chrome.width) / Self.aspect).rounded() + chrome.height)
    }

    /// A column shown, hidden or dragged changes the viewer's width while the window's stays: the height
    /// follows, the top edge stays. A window resize leaves the columns' total alone, so it is ignored here
    /// (following it fed back into the resize and shrank the window).
    private func follow() {
        let chrome = chromeSize()
        guard !adjusting, !window.styleMask.contains(.fullScreen), let area = window.screen?.visibleFrame,
              abs(chrome.width - lastChromeWidth) > Self.tolerance else { return }
        lastChromeWidth = chrome.width
        let height = min(area.height, ((window.frame.width - chrome.width) / Self.aspect).rounded() + chrome.height)
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
        let inner = stage()
        return NSSize(width: window.frame.width - inner.width, height: window.frame.height - inner.height)
    }
}
