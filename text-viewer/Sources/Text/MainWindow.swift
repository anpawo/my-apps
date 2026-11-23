import AppKit
import TextCore

/// The one window, laid out as Video Viewer: the open files in the order they were opened, with
/// Recent under them, and the selected file.
final class MainWindow: NSObject, NSWindowDelegate, NSTextViewDelegate, NSLayoutManagerDelegate, NSToolbarDelegate {
    static let size = NSSize(width: 1100, height: 660)
    static let sidebarWidth: CGFloat = 280
    static let sidebarRange: ClosedRange<CGFloat> = 260...420
    static let inset = NSSize(width: 6, height: 8)
    static let recentKey = "recentFiles"

    let window: NSWindow
    let split = NSSplitViewController()
    let list = ListPane()
    let textView = CodeView(usingTextLayoutManager: false)
    let scroll = NSScrollView()
    private lazy var gutter = Gutter(scrollView: scroll, textView: textView)
    let emptyState = EmptyState()
    private let blank = NSTextStorage()
    private(set) var docs: [Document] = []
    private(set) var current: Document?
    /// Off for `--render`, whose test files must not land in his Recent.
    var remembersFiles = true

    override init() {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "All Files"
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The editor is always VS Code's dark theme, so the chrome around it is dark too.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.contentViewController = layOut()
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setContentSize(Self.size)
        window.setFrameAutosaveName("main")
        list.onSelect = { [weak self] url in self?.show(self?.docs.first { $0.url == url }) }
        list.onOpenRecent = { [weak self] in self?.open([$0]) }
        list.describe = { url, done in done((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) }
        list.isEdited = { [weak self] url in self?.docs.first { $0.url == url }?.dirty == true }
        show(nil)
    }

    private func layOut() -> NSSplitViewController {
        let drop = DropSplitView()
        drop.onDrop = { [weak self] in self?.open($0) }
        textView.onDrop = drop.onDrop
        split.splitView = drop
        let side = NSSplitViewItem(sidebarWithViewController: list)
        side.minimumThickness = Self.sidebarRange.lowerBound
        side.maximumThickness = Self.sidebarRange.upperBound
        side.canCollapse = false
        let editor = NSViewController()
        editor.view = editorView()
        let main = NSSplitViewItem(viewController: editor)
        for item in [side, main] {
            item.titlebarSeparatorStyle = .none
            split.addSplitViewItem(item)
        }
        split.view.frame = NSRect(origin: .zero, size: Self.size)
        split.splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
        return split
    }

    private func editorView() -> NSView {
        let right = Backdrop(frame: NSRect(origin: .zero, size: Self.size))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.automaticallyAdjustsContentInsets = false
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
        for view in [scroll, emptyState] { right.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: right.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: right.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: right.centerYAnchor),
        ])
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
            if let doc = docs.first(where: { $0.url == url }) { last = doc; remember(url); continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            do {
                let doc = try Document(url: url)
                hook(doc)
                docs.append(doc)
                last = doc
                remember(url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let last { show(last) }
    }

    private func hook(_ doc: Document) {
        doc.onChange = { [weak self, weak doc] in if let doc { self?.list.reloadRow(of: doc.url) } }
        var keep: (NSRange, NSPoint, Bool)?
        doc.willReload = { [weak self, weak doc] in
            guard let self, doc === current else { return }
            let atEnd = textView.visibleRect.maxY >= textView.bounds.maxY - 1
            keep = (textView.selectedRange(), scroll.contentView.bounds.origin, atEnd)
        }
        doc.didReload = { [weak self, weak doc] in
            self?.refreshList()
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
        gutter.textChanged()
        refreshList()
        if doc != nil { window.makeFirstResponder(textView) }
    }

    /// The newest goes first, so the file shown, opened last, tops Recent.
    private func remember(_ url: URL) {
        guard remembersFiles else { return }
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        UserDefaults.standard.set(Recent.adding(url.path, to: paths), forKey: Self.recentKey)
    }

    private func recentFiles() -> [URL] {
        // A render shows none of his files.
        guard remembersFiles else { return [] }
        let paths = (UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
        return Recent.shown(paths, open: Set(docs.map(\.url.path))).map { URL(fileURLWithPath: $0) }
    }

    private func refreshList() {
        list.reload(docs.map(\.url), current: current?.url)
        list.showRecent(recentFiles())
        // The shown file's date sits in the title bar, as in Video Viewer.
        window.subtitle = ([docs.count == 1 ? "1 file" : "\(docs.count) files"] + [current.map { longDate($0.modified) }].compactMap { $0 })
            .joined(separator: " · ")
    }

    private func longDate(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(languageCode: .english, languageRegion: Locale.current.region)
        format.dateStyle = .long
        format.timeStyle = .short
        return format.string(from: date)
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
        guard doc === current else { refreshList(); return true }
        // The file below it in the list takes its place, as in Video Viewer.
        show(docs.isEmpty ? nil : docs[min(i, docs.count - 1)])
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
}
