import AppKit

/// The one window: open files in the sidebar, the selected one on the right.
final class MainWindow: NSObject, NSWindowDelegate, NSTextViewDelegate, NSLayoutManagerDelegate, NSToolbarDelegate {
    static let size = NSSize(width: 960, height: 620)
    static let sidebarWidth: CGFloat = 230
    static let sidebarRange: ClosedRange<CGFloat> = 170...380
    static let inset = NSSize(width: 6, height: 8)

    let window: NSWindow
    let sidebar = Sidebar()
    let textView = CodeView(usingTextLayoutManager: false)
    let scroll = NSScrollView()
    private lazy var gutter = Gutter(scrollView: scroll, textView: textView)
    let emptyState = EmptyState()
    private let blank = NSTextStorage()
    private(set) var docs: [Document] = []
    private(set) var current: Document?

    override init() {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "Viewer Text"
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The editor is always VS Code's dark theme, so the chrome around it is dark too.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background
        window.toolbarStyle = .unified
        window.contentViewController = layOut()
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setContentSize(Self.size)
        window.setFrameAutosaveName("main")
        sidebar.onSelect = { [weak self] in self?.select($0) }
        show(nil)
    }

    private func layOut() -> NSSplitViewController {
        let split = NSSplitViewController()
        let drop = DropSplitView()
        drop.onDrop = { [weak self] in self?.open($0) }
        textView.onDrop = drop.onDrop
        split.splitView = drop
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = Self.sidebarRange.lowerBound
        side.maximumThickness = Self.sidebarRange.upperBound
        let editor = NSViewController()
        editor.view = editorView()
        let main = NSSplitViewItem(viewController: editor)
        main.titlebarSeparatorStyle = .line
        split.addSplitViewItem(side)
        split.addSplitViewItem(main)
        split.view.frame = NSRect(origin: .zero, size: Self.size)
        split.splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
        return split
    }

    private func editorView() -> NSView {
        let right = Backdrop(frame: NSRect(origin: .zero, size: Self.size))
        scroll.frame = right.bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        scroll.documentView = textView
        setUpTextView()
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(scroll)
        right.addSubview(emptyState)
        NSLayoutConstraint.activate([emptyState.centerXAnchor.constraint(equalTo: right.centerXAnchor),
                                     emptyState.centerYAnchor.constraint(equalTo: right.centerYAnchor)])
        return right
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

    // MARK: Files

    func open(_ urls: [URL]) {
        var last: Document?
        for url in urls.map(\.standardizedFileURL) {
            if let doc = docs.first(where: { $0.url == url }) { last = doc; continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            do {
                let doc = try Document(url: url)
                hook(doc)
                docs.append(doc)
                last = doc
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let last { show(last) }
    }

    private func hook(_ doc: Document) {
        doc.onChange = { [weak self] in self?.refreshSidebar() }
        var keep: (NSRange, NSPoint, Bool)?
        doc.willReload = { [weak self, weak doc] in
            guard let self, doc === current else { return }
            let atEnd = textView.visibleRect.maxY >= textView.bounds.maxY - 1
            keep = (textView.selectedRange(), scroll.contentView.bounds.origin, atEnd)
        }
        doc.didReload = { [weak self, weak doc] in
            guard let self, doc === current, let (sel, origin, atEnd) = keep, let doc else { return }
            textView.setSelectedRange(NSRange(location: min(sel.location, doc.storage.length), length: 0))
            // A log that was followed to its end keeps following it.
            if atEnd { textView.scrollToEndOfDocument(nil) } else { scroll.contentView.scroll(to: origin) }
            keep = nil
            gutter.textChanged()
        }
    }

    func show(_ doc: Document?) {
        current = doc
        textView.layoutManager?.replaceTextStorage(doc?.storage ?? blank)
        textView.typingAttributes = Theme.base
        textView.isEditable = doc != nil
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        scroll.isHidden = doc == nil
        emptyState.isHidden = doc != nil
        window.title = doc?.name ?? "Viewer Text"
        window.subtitle = doc?.folder ?? ""
        window.representedURL = doc?.url
        gutter.textChanged()
        refreshSidebar()
        if doc != nil { window.makeFirstResponder(textView) }
    }

    private func select(_ index: Int) {
        if docs.indices.contains(index), docs[index] !== current { show(docs[index]) }
    }

    private func refreshSidebar() {
        sidebar.reload(docs, selected: current.flatMap { c in docs.firstIndex { $0 === c } })
    }

    func cycle(_ step: Int) {
        guard let current, let i = docs.firstIndex(where: { $0 === current }) else { return }
        show(docs[(i + step + docs.count) % docs.count])
    }

    func saveCurrent() {
        guard let current else { return }
        do { try current.save() } catch { NSAlert(error: error).runModal() }
    }

    /// Asks about unsaved edits first; false when the user cancels.
    @discardableResult
    func close(_ doc: Document) -> Bool {
        if doc.dirty {
            show(doc)
            let alert = NSAlert()
            alert.messageText = "Save changes to \u{201C}\(doc.name)\u{201D}?"
            alert.informativeText = "Your changes are lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do { try doc.save() } catch { NSAlert(error: error).runModal(); return false }
            case .alertSecondButtonReturn: return false
            default: break
            }
        }
        guard let i = docs.firstIndex(where: { $0 === doc }) else { return true }
        docs.remove(at: i)
        if doc === current { show(docs.isEmpty ? nil : docs[min(i, docs.count - 1)]) } else { refreshSidebar() }
        return true
    }

    func closeCurrent() {
        if let current { close(current) } else { window.performClose(nil) }
    }

    func closeAll() -> Bool {
        for doc in docs where doc.dirty { if !close(doc) { return false } }
        return true
    }

    // MARK: Delegates

    func windowShouldClose(_ sender: NSWindow) -> Bool { closeAll() }

    func undoManager(for view: NSTextView) -> UndoManager? { current?.undo }

    func textDidChange(_ notification: Notification) { current?.dirty = true }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.setNeedsDisplay(textView.visibleRect)
        gutter.needsDisplay = true
    }

    /// VS Code's line height: every line 18 pt, the glyphs centered in it.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let extra = Theme.lineHeight - lineFragmentRect.pointee.height
        guard extra > 0 else { return false }
        lineFragmentRect.pointee.size.height = Theme.lineHeight
        lineFragmentUsedRect.pointee.size.height = Theme.lineHeight
        baselineOffset.pointee += extra / 2
        return true
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
}
