import AppKit
import TextCore

/// The one window, laid out as Notes: the open files' folders, the files of the chosen one
/// newest first, the selected file.
final class MainWindow: NSObject, NSWindowDelegate, NSTextViewDelegate, NSLayoutManagerDelegate, NSToolbarDelegate {
    static let size = NSSize(width: 1100, height: 660)
    static let sidebarWidth: CGFloat = 200
    static let sidebarRange: ClosedRange<CGFloat> = 160...320
    static let listWidth: CGFloat = 280
    static let listRange: ClosedRange<CGFloat> = 220...420
    static let inset = NSSize(width: 6, height: 8)
    static let dateGap: CGFloat = 10

    let window: NSWindow
    let split = NSSplitViewController()
    let folderList = FolderList()
    let fileList = FileList()
    let dateLabel = NSTextField(labelWithString: "")
    let textView = CodeView(usingTextLayoutManager: false)
    let scroll = NSScrollView()
    private lazy var gutter = Gutter(scrollView: scroll, textView: textView)
    let emptyState = EmptyState()
    private let blank = NSTextStorage()
    private(set) var docs: [Document] = []
    private(set) var current: Document?
    /// The folder the middle column lists; nil lists every open file.
    private var folder: String?

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
        window.titlebarAppearsTransparent = true
        window.contentViewController = layOut()
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setContentSize(Self.size)
        window.setFrameAutosaveName("main")
        folderList.onSelect = { [weak self] in self?.selectFolder($0) }
        fileList.onSelect = { [weak self] in self?.show($0) }
        show(nil)
    }

    private func layOut() -> NSSplitViewController {
        let drop = DropSplitView()
        drop.onDrop = { [weak self] in self?.open($0) }
        textView.onDrop = drop.onDrop
        split.splitView = drop
        let side = NSSplitViewItem(sidebarWithViewController: folderList)
        side.minimumThickness = Self.sidebarRange.lowerBound
        side.maximumThickness = Self.sidebarRange.upperBound
        let list = NSSplitViewItem(contentListWithViewController: fileList)
        list.minimumThickness = Self.listRange.lowerBound
        list.maximumThickness = Self.listRange.upperBound
        let editor = NSViewController()
        editor.view = editorView()
        let main = NSSplitViewItem(viewController: editor)
        for item in [side, list, main] { split.addSplitViewItem(item) }
        split.view.frame = NSRect(origin: .zero, size: Self.size)
        split.splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
        split.splitView.setPosition(Self.sidebarWidth + Self.listWidth, ofDividerAt: 1)
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
        dateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        dateLabel.textColor = Theme.secondary
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        for view in [dateLabel, scroll, emptyState] { right.addSubview(view) }
        let top = right.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            dateLabel.topAnchor.constraint(equalTo: top, constant: Self.dateGap),
            dateLabel.centerXAnchor.constraint(equalTo: right.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: Self.dateGap),
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
        doc.onChange = { [weak self] in self?.refreshLists() }
        var keep: (NSRange, NSPoint, Bool)?
        doc.willReload = { [weak self, weak doc] in
            guard let self, doc === current else { return }
            let atEnd = textView.visibleRect.maxY >= textView.bounds.maxY - 1
            keep = (textView.selectedRange(), scroll.contentView.bounds.origin, atEnd)
        }
        doc.didReload = { [weak self, weak doc] in
            self?.refreshLists()
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
        if let doc, folder != nil, folder != doc.folder { folder = nil }
        gutter.textChanged()
        refreshLists()
        if doc != nil { window.makeFirstResponder(textView) }
    }

    /// The middle column's files, in its order: newest first.
    private var listed: [Document] {
        docs.filter { folder == nil || $0.folder == folder }.sorted { $0.modified > $1.modified }
    }

    private var folders: [Folder] {
        let all = Folder(path: nil, name: "All Files", count: docs.count)
        let paths = Set(docs.map(\.folder)).sorted {
            ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending
        }
        return [all] + paths.map { path in
            Folder(path: path, name: (path as NSString).lastPathComponent, count: docs.filter { $0.folder == path }.count)
        }
    }

    private func selectFolder(_ index: Int) {
        let all = folders
        guard all.indices.contains(index) else { return }
        folder = all[index].path
        if let current, listed.contains(where: { $0 === current }) { refreshLists() } else { show(listed.first) }
    }

    private func refreshLists() {
        let all = folders
        folderList.reload(all, selected: all.firstIndex { $0.path == folder } ?? 0)
        let files = listed
        var entries: [Entry] = [], last: String?
        for doc in files {
            let section = Recency.section(of: doc.modified)
            if section != last { entries.append(.section(section)); last = section }
            entries.append(.file(doc))
        }
        fileList.reload(entries, selected: current)
        window.title = all.first { $0.path == folder }?.name ?? "All Files"
        window.subtitle = files.count == 1 ? "1 file" : "\(files.count) files"
        dateLabel.stringValue = current.map { Recency.long($0.modified) } ?? ""
    }

    func cycle(_ step: Int) {
        let files = listed
        guard let current, let i = files.firstIndex(where: { $0 === current }) else { return }
        show(files[(i + step + files.count) % files.count])
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
        let files = listed
        guard let i = docs.firstIndex(where: { $0 === doc }) else { return true }
        docs.remove(at: i)
        guard doc === current else { refreshLists(); return true }
        // The file below it in the list takes its place, as in Notes.
        let rest = files.filter { $0 !== doc }
        let at = files.firstIndex { $0 === doc } ?? 0
        show(rest.isEmpty ? docs.first : rest[min(at, rest.count - 1)])
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
