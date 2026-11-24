import AppKit
import TextCore

/// A text or code file in VS Code's dark editor: colored, numbered, editable. Its Document lives in the
/// Controller, so unsaved edits survive showing another file.
@MainActor final class TextMedia: NSObject, Media, NSTextViewDelegate, NSLayoutManagerDelegate {
    private static let inset = NSSize(width: 6, height: 8)
    let doc: Document
    private let scroll = NSScrollView()
    private let textView = CodeView(usingTextLayoutManager: false)
    private lazy var gutter = Gutter(scrollView: scroll, textView: textView)
    private var kept: (selection: NSRange, origin: NSPoint, atEnd: Bool)?
    private let container = NSView()
    private lazy var preview = MarkdownPreview(directory: doc.url.deletingLastPathComponent())
    private(set) var previewsMarkdown = false
    var view: NSView { container }

    init(_ doc: Document, onDrop: @escaping ([URL]) -> Void, onReload: @escaping () -> Void) {
        self.doc = doc
        super.init()
        scroll.autoresizingMask = [.width, .height]
        container.addSubview(scroll)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        scroll.documentView = textView
        setUpTextView()
        textView.onDrop = onDrop
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        textView.layoutManager?.replaceTextStorage(doc.storage)
        textView.typingAttributes = Theme.base
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        gutter.textChanged()
        doc.willReload = { [weak self] in self?.keepPlace() }
        doc.didReload = { [weak self] in
            guard let self else { return }
            restorePlace()
            if previewsMarkdown { preview.show(self.doc.storage.string) }
            onReload()
        }
    }

    private func setUpTextView() {
        let tv = textView
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = Theme.font
        tv.backgroundColor = Theme.background
        tv.insertionPointColor = Theme.foreground
        tv.selectedTextAttributes = [.backgroundColor: Theme.selection]
        tv.textContainerInset = Self.inset
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.frame = scroll.contentView.bounds
        tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.layoutManager?.delegate = self
    }

    /// Typing goes to the text once it is on screen.
    func focus() { container.window?.makeFirstResponder(previewsMarkdown ? preview : textView) }

    func showMarkdownPreview(_ show: Bool) {
        guard doc.language == .markdown else { return }
        if show {
            if preview.superview == nil {
                preview.frame = container.bounds
                preview.autoresizingMask = [.width, .height]
                container.addSubview(preview)
            }
            preview.show(doc.storage.string)
        }
        previewsMarkdown = show
        scroll.isHidden = show
        preview.isHidden = !show
        focus()
    }

    private func keepPlace() {
        let atEnd = textView.visibleRect.maxY >= textView.bounds.maxY - 1
        kept = (textView.selectedRange(), scroll.contentView.bounds.origin, atEnd)
    }

    private func restorePlace() {
        defer { kept = nil; gutter.textChanged() }
        guard let kept else { return }
        textView.setSelectedRange(NSRange(location: min(kept.selection.location, doc.storage.length), length: 0))
        // A log that was followed to its end keeps following it.
        if kept.atEnd { textView.scrollToEndOfDocument(nil) } else { scroll.contentView.scroll(to: kept.origin) }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { doc.undo }

    func textDidChange(_ notification: Notification) { doc.dirty = true }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.setNeedsDisplay(textView.visibleRect)
        gutter.needsDisplay = true
    }

    /// VS Code's line height: every line 18 pt, the glyphs centered in it.
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let extra = Theme.lineHeight - lineFragmentRect.pointee.height
        guard extra > 0 else { return false }
        lineFragmentRect.pointee.size.height = Theme.lineHeight
        lineFragmentUsedRect.pointee.size.height = Theme.lineHeight
        baselineOffset.pointee += extra / 2
        return true
    }
}
