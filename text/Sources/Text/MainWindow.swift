import AppKit

/// The one window: open files on the left, the selected one on the right.
final class MainWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let size = NSSize(width: 960, height: 620)
    static let sidebarWidth: CGFloat = 220
    static let inset = NSSize(width: 10, height: 10)

    let window: NSWindow
    let sidebar = Sidebar()
    let textView = CodeView(usingTextLayoutManager: false)
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "Open or drop a text file")
    private let blank = NSTextStorage()
    private(set) var docs: [Document] = []
    private(set) var current: Document?

    override init() {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "Text"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("main")
        let drop = DropView(frame: NSRect(origin: .zero, size: Self.size))
        drop.onDrop = { [weak self] in self?.open($0) }
        textView.onDrop = drop.onDrop
        window.contentView = drop
        layOut(in: drop)
        sidebar.onSelect = { [weak self] in self?.select($0) }
        show(nil)
    }

    private func layOut(in root: NSView) {
        let split = NSSplitView(frame: root.bounds)
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        let right = Backdrop(frame: NSRect(x: 0, y: 0, width: Self.size.width - Self.sidebarWidth, height: Self.size.height))
        scroll.frame = right.bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        setUpTextView()
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        empty.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(scroll)
        right.addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: right.centerXAnchor),
                                     empty.centerYAnchor.constraint(equalTo: right.centerYAnchor)])
        sidebar.view.frame = NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: Self.size.height)
        split.addArrangedSubview(sidebar.view)
        split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        root.addSubview(split)
        split.adjustSubviews()
        split.setPosition(Self.sidebarWidth, ofDividerAt: 0)
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
        tv.font = Style.font
        tv.textContainerInset = Self.inset
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.frame = scroll.contentView.bounds
        tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.layoutManager?.allowsNonContiguousLayout = true
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
        }
    }

    func show(_ doc: Document?) {
        current = doc
        textView.layoutManager?.replaceTextStorage(doc?.storage ?? blank)
        textView.typingAttributes = Style.base
        textView.isEditable = doc != nil
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        scroll.isHidden = doc == nil
        empty.isHidden = doc != nil
        window.title = doc?.name ?? "Text"
        window.representedURL = doc?.url
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
}
