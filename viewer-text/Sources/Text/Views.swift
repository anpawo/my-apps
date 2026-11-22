import AppKit

/// The open files, one row each: the language's symbol, the name (a dot after it while
/// unsaved), its folder dimmed below.
final class Sidebar: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 40
    var onSelect: ((Int) -> Void)?
    private let table = NSTableView()
    private var docs: [Document] = []
    private var syncing = false

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        view = scroll
    }

    func reload(_ docs: [Document], selected: Int?) {
        self.docs = docs
        syncing = true
        table.reloadData()
        table.selectRowIndexes(selected.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        if let selected { table.scrollRowToVisible(selected) }
        syncing = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { docs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell ?? FileCell()
        cell.show(docs[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !syncing, table.selectedRow >= 0 { onSelect?(table.selectedRow) }
    }
}

final class FileCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("FileCell")
    static let padding: CGFloat = 8
    static let iconSize: CGFloat = 18
    static let iconPointSize: CGFloat = 14
    static let dotSize: CGFloat = 7
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let folder = NSTextField(labelWithString: "")
    let dot = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        name.textColor = Theme.sidebarForeground
        name.lineBreakMode = .byTruncatingMiddle
        folder.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        folder.textColor = Theme.secondary
        // The end of a path tells two folders apart, its start (`~/`) never does.
        folder.lineBreakMode = .byTruncatingHead
        icon.symbolConfiguration = .init(pointSize: Self.iconPointSize, weight: .medium)
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unsaved")
        dot.symbolConfiguration = .init(pointSize: Self.dotSize, weight: .regular)
        dot.contentTintColor = Theme.sidebarForeground
        textField = name
        imageView = icon
        for view in [icon, name, folder, dot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for field in [name, folder] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.padding),
                field.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -Self.padding / 2),
            ])
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding / 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            folder.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ doc: Document) {
        icon.image = NSImage(systemSymbolName: doc.language.symbol, accessibilityDescription: nil)
        icon.contentTintColor = doc.language.tint
        name.stringValue = doc.name
        folder.stringValue = doc.folder
        dot.isHidden = !doc.dirty
        toolTip = doc.url.path
    }
}

/// Draws its own selection, VS Code's list selection: the source list's selection material draws
/// black offscreen, so `--render` would not show what the screen does.
final class RowView: NSTableRowView {
    static let radius: CGFloat = 6
    static let inset = NSSize(width: 10, height: 1)

    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? Theme.sidebarSelection : Theme.sidebarInactiveSelection).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Self.inset.width, dy: Self.inset.height),
                     xRadius: Self.radius, yRadius: Self.radius).fill()
    }
}

/// What the editor shows with no file open.
final class EmptyState: NSStackView {
    static let symbolSize: CGFloat = 44
    static let symbolGap: CGFloat = 14
    static let lineGap: CGFloat = 6

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        spacing = Self.lineGap
        let image = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: Self.symbolSize, weight: .ultraLight)
        image.contentTintColor = Theme.secondary
        let title = NSTextField(labelWithString: "No File Open")
        title.font = .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .semibold)
        title.textColor = Theme.sidebarForeground
        let hint = NSTextField(labelWithString: "Drop a file here, or press \u{2318}O")
        hint.font = .systemFont(ofSize: NSFont.systemFontSize)
        hint.textColor = Theme.secondary
        addArrangedSubview(image)
        setCustomSpacing(Self.symbolGap, after: image)
        addArrangedSubview(title)
        addArrangedSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
    info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
}

/// The window's split view: takes files dropped anywhere outside the text.
final class DropSplitView: NSSplitView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = true
        dividerStyle = .thin
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var dividerColor: NSColor { Theme.border }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileURLs(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        onDrop?(urls)
        return !urls.isEmpty
    }
}

/// A file dropped on the text opens it instead of pasting its path; the cursor's line is lit.
final class CodeView: NSTextView {
    var onDrop: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onDrop?(urls)
        return true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard isEditable, selectedRange().length == 0, var line = currentLineRect() else { return }
        line.origin.x = 0
        line.size.width = bounds.width
        Theme.lineHighlight.setFill()
        line.intersection(rect).fill()
    }

    /// The whole of the cursor's line, all its wrapped rows.
    private func currentLineRect() -> NSRect? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let text = string as NSString
        let location = selectedRange().location
        var rect: NSRect
        if location >= text.length, text.length == 0 || text.character(at: text.length - 1) == 0x0A {
            rect = layout.extraLineFragmentRect
            rect.size.height = Theme.lineHeight
        } else {
            let paragraph = text.paragraphRange(for: NSRange(location: min(location, text.length), length: 0))
            let glyphs = layout.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        }
        return rect.offsetBy(dx: 0, dy: textContainerOrigin.y)
    }
}

/// The editor side's backdrop, so the empty state sits on the editor's color.
final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        dirtyRect.fill()
    }
}
