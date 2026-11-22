import AppKit

/// The open files, one row each: the name (a dot before it while unsaved), its folder dimmed below.
final class Sidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 38
    let view: NSView
    var onSelect: ((Int) -> Void)?
    private let table = NSTableView()
    private var docs: [Document] = []
    private var syncing = false

    override init() {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        let scroll = NSScrollView(frame: effect.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        effect.addSubview(scroll)
        view = effect
        super.init()
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
        let doc = docs[row]
        cell.name.stringValue = (doc.dirty ? "\u{25CF} " : "") + doc.name
        cell.folder.stringValue = doc.folder
        cell.toolTip = doc.url.path
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !syncing, table.selectedRow >= 0 { onSelect?(table.selectedRow) }
    }
}

final class FileCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("FileCell")
    static let padding: CGFloat = 6
    let name = NSTextField(labelWithString: "")
    let folder = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.lineBreakMode = .byTruncatingMiddle
        folder.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        folder.textColor = .secondaryLabelColor
        // The end of a path tells two folders apart, its start (`~/`) never does.
        folder.lineBreakMode = .byTruncatingHead
        textField = name
        for field in [name, folder] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
                field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.padding),
            ])
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        NSLayoutConstraint.activate([
            name.bottomAnchor.constraint(equalTo: centerYAnchor),
            folder.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Draws its own selection: the source list's selection material draws black offscreen, so
/// `--render` would not show what the screen does.
final class RowView: NSTableRowView {
    static let radius: CGFloat = 6
    static let inset = NSSize(width: 10, height: 1)

    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? NSColor.selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Self.inset.width, dy: Self.inset.height),
                     xRadius: Self.radius, yRadius: Self.radius).fill()
    }
}

private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
    info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
}

/// The window's content: takes files dropped anywhere outside the text.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileURLs(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        onDrop?(urls)
        return !urls.isEmpty
    }
}

/// A file dropped on the text opens it instead of pasting its path.
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
}

/// The editor side's backdrop, so the empty state looks like an empty page.
final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
