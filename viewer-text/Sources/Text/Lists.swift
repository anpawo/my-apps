import AppKit
import TextCore

/// A table in a borderless scroll view, the way both list columns hold theirs.
private func scrolling(_ table: NSTableView, style: NSTableView.Style) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let column = NSTableColumn(identifier: .init("main"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.style = style
    table.backgroundColor = .clear
    table.intercellSpacing = .zero
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    scroll.documentView = table
    return scroll
}

private func label(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
}

/// One sidebar row: the folder the open files come from (no path: all of them).
struct Folder: Equatable {
    let path: String?
    let name: String
    let count: Int
}

/// The sidebar, as Notes lists its folders: an accent folder symbol, the name, the count.
final class FolderList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 32
    var onSelect: ((Int) -> Void)?
    private let table = NSTableView()
    private var folders: [Folder] = []
    private var syncing = false

    override func loadView() {
        table.rowHeight = Self.rowHeight
        table.dataSource = self
        table.delegate = self
        view = scrolling(table, style: .sourceList)
    }

    func reload(_ folders: [Folder], selected: Int) {
        self.folders = folders
        syncing = true
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        syncing = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { folders.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: FolderCell.id, owner: nil) as? FolderCell ?? FolderCell()
        cell.show(folders[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !syncing, table.selectedRow >= 0 { onSelect?(table.selectedRow) }
    }
}

final class FolderCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("FolderCell")
    static let padding: CGFloat = 8
    static let iconSize: CGFloat = 20
    static let iconPointSize: CGFloat = 14
    let icon = NSImageView()
    let name = label(NSFont.systemFontSize, .regular, Theme.sidebarForeground)
    let count = label(NSFont.systemFontSize, .regular, Theme.secondary)

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.symbolConfiguration = .init(pointSize: Self.iconPointSize, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, name, count] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding / 2),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.padding),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -Self.padding),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ folder: Folder) {
        icon.image = NSImage(systemSymbolName: folder.path == nil ? "tray.full" : "folder", accessibilityDescription: nil)
        name.stringValue = folder.name
        count.stringValue = String(folder.count)
        toolTip = folder.path
    }
}

/// A row of the file list: a section title, or a file.
enum Entry {
    case section(String)
    case file(Document)
}

/// The middle column, as Notes lists notes: newest first, under sections by date.
final class FileList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let fileHeight: CGFloat = 54
    static let sectionHeight: CGFloat = 30
    var onSelect: ((Document) -> Void)?
    private let table = NSTableView()
    private var entries: [Entry] = []
    private var syncing = false

    override func loadView() {
        table.dataSource = self
        table.delegate = self
        table.floatsGroupRows = false
        view = scrolling(table, style: .plain)
    }

    func reload(_ entries: [Entry], selected: Document?) {
        self.entries = entries
        syncing = true
        table.reloadData()
        let row = entries.firstIndex { if case .file(let doc) = $0 { return doc === selected } else { return false } }
        table.selectRowIndexes(row.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        if let row { table.scrollRowToVisible(row) }
        syncing = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = entries[row] { return true } else { return false }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = entries[row] { return Self.sectionHeight } else { return Self.fileHeight }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .file = entries[row] { return true } else { return false }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch entries[row] {
        case .section(let title):
            let cell = tableView.makeView(withIdentifier: SectionCell.id, owner: nil) as? SectionCell ?? SectionCell()
            cell.title.stringValue = title
            return cell
        case .file(let doc):
            let cell = tableView.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell ?? FileCell()
            cell.show(doc)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FileRowView()
        if case .section = entries[row] { view.isSection = true }
        let next = row + 1
        view.lastInSection = next == entries.count || { if case .section = entries[next] { true } else { false } }()
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, entries.indices.contains(table.selectedRow), case .file(let doc) = entries[table.selectedRow] else { return }
        onSelect?(doc)
    }
}

final class SectionCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("SectionCell")
    let title = label(NSFont.systemFontSize, .bold, Theme.sidebarForeground)

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FileRowView.textInset),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -FileRowView.textInset),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -FileRowView.inset.height * 4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The name in bold, then the date and the file's first line, as Notes shows a note.
final class FileCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("FileCell")
    static let gap: CGFloat = 6
    static let dotSize: CGFloat = 7
    let name = label(NSFont.systemFontSize, .bold, Theme.sidebarForeground)
    let stamp = label(NSFont.smallSystemFontSize, .regular, Theme.sidebarForeground)
    let preview = label(NSFont.smallSystemFontSize, .regular, Theme.secondary)
    let dot = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unsaved")
        dot.symbolConfiguration = .init(pointSize: Self.dotSize, weight: .regular)
        dot.contentTintColor = Theme.sidebarForeground
        dot.translatesAutoresizingMaskIntoConstraints = false
        stamp.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [name, stamp, preview, dot] { addSubview(view) }
        let inset = FileRowView.textInset
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            name.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -Self.gap),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            dot.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            stamp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stamp.topAnchor.constraint(equalTo: centerYAnchor, constant: 3),
            preview.leadingAnchor.constraint(equalTo: stamp.trailingAnchor, constant: Self.gap),
            preview.firstBaselineAnchor.constraint(equalTo: stamp.firstBaselineAnchor),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ doc: Document) {
        name.stringValue = doc.name
        stamp.stringValue = Recency.stamp(of: doc.modified)
        preview.stringValue = doc.preview
        dot.isHidden = !doc.dirty
        toolTip = doc.url.path
    }

    /// On the accent pill every line reads white.
    var selected = false {
        didSet {
            for field in [name, stamp] { field.textColor = selected ? .white : Theme.sidebarForeground }
            preview.textColor = selected ? NSColor.white.withAlphaComponent(Theme.dimmed) : Theme.secondary
            dot.contentTintColor = name.textColor
        }
    }
}

/// The selected file is a filled accent pill; the others are split by thin inset lines, none
/// touching the pill and none under a section's last file.
final class FileRowView: NSTableRowView {
    static let radius: CGFloat = 8
    static let inset = NSSize(width: 10, height: 2)
    static let textInset: CGFloat = 22
    var isSection = false
    var lastInSection = false

    override var isSelected: Bool { didSet { syncCell() } }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        syncCell()
    }

    private func syncCell() {
        for case let cell as FileCell in subviews { cell.selected = isSelected }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Self.inset.width, dy: Self.inset.height),
                     xRadius: Self.radius, yRadius: Self.radius).fill()
    }

    // Here rather than in drawSeparator, which the table calls only with grid lines on.
    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSection, !lastInSection, !isSelected, !isNextRowSelected else { return }
        Theme.border.setFill()
        let y = isFlipped ? bounds.maxY - 1 : 0
        NSRect(x: Self.textInset, y: y, width: bounds.width - Self.textInset - Self.inset.width, height: 1).fill()
    }
}
