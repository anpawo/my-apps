import AppKit
import ViewerCore

/// Dates in English, in the order and clock of the Mac's region.
let englishInRegion = Locale(languageCode: .english, languageRegion: Locale.current.region)

private func label(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingMiddle
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
}

private func scrolling(_ table: NSTableView) -> NSScrollView {
    table.addTableColumn(NSTableColumn(identifier: .init("column")))
    table.headerView = nil
    table.floatsGroupRows = false
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    return scroll
}

// MARK: Sidebar

/// "All Media" and one row per kind loaded, each with its count.
@MainActor final class SidebarPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 30
    private static let iconSide: CGFloat = 18
    var onSelect: (Kind?) -> Void = { _ in }
    private let table = NSTableView()
    private var rows: [(kind: Kind?, count: Int)] = []
    private var syncing = false

    override func loadView() {
        table.style = .sourceList
        table.rowHeight = Self.rowHeight
        table.dataSource = self
        table.delegate = self
        view = scrolling(table)
    }

    func reload(_ library: Library) {
        rows = [(nil, library.count(of: nil))] + library.kinds.map { ($0, library.count(of: $0)) }
        syncing = true
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.kind == library.kind }) {
            table.selectRowIndexes([index + 1], byExtendingSelection: false)
        }
        syncing = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count + 1 }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { row == 0 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { row > 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        guard row > 0 else {
            let title = label("Library", size: 11, weight: .bold, color: .secondaryLabelColor)
            cell.addSubview(title)
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
            return cell
        }
        let (kind, count) = rows[row - 1]
        let icon = NSImageView(image: NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = label(kind?.title ?? "All Media", size: 13)
        let number = label(String(count), size: 13, color: .secondaryLabelColor)
        for view in [icon, name, number] {
            cell.addSubview(view)
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            number.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            number.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, table.selectedRow > 0 else { return }
        onSelect(rows[table.selectedRow - 1].kind)
    }
}

extension Optional where Wrapped == Kind {
    var symbol: String {
        switch self {
        case nil: "square.grid.2x2"
        case .video: "film"
        case .gif: "square.stack.3d.forward.dottedline"
        case .image: "photo"
        case .music: "music.note"
        case .pdf: "doc.richtext"
        }
    }
}

// MARK: List

/// The files of the sidebar's kind under date section titles, newest first, like Notes' list.
@MainActor final class ListPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case header(String)
        case item(Entry, lastInSection: Bool)
    }

    private static let itemHeight: CGFloat = 58
    private static let headerHeight: CGFloat = 36
    var onSelect: (URL) -> Void = { _ in }
    private let table = NSTableView()
    private var rows: [Row] = []
    private var thumbnails: [URL: NSImage] = [:]
    private var details: [URL: String] = [:]
    private var syncing = false

    override func loadView() {
        table.style = .inset
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        view = scrolling(table)
    }

    func reload(_ library: Library) {
        rows = library.sections().flatMap { section in
            [Row.header(section.title)] + section.entries.enumerated().map {
                Row.item($0.element, lastInSection: $0.offset == section.entries.count - 1)
            }
        }
        for entry in library.entries where thumbnails[entry.url] == nil { requestThumbnail(entry.url) }
        for entry in library.entries where details[entry.url] == nil {
            details[entry.url] = ""
            Thumbnails.details(of: entry) { [weak self] text in self?.details[entry.url] = text; self?.reloadRow(of: entry.url) }
        }
        syncing = true
        table.reloadData()
        if let row = index(of: library.current) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        syncing = false
    }

    private func index(of url: URL?) -> Int? {
        rows.firstIndex { if case .item(let entry, _) = $0 { entry.url == url } else { false } }
    }

    private func reloadRow(of url: URL) {
        if let row = index(of: url) { table.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }

    private func requestThumbnail(_ url: URL) {
        thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)
        Thumbnails.request(url, side: ItemCell.thumbnailSide) { [weak self] image in
            self?.thumbnails[url] = image
            self?.reloadRow(of: url)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { Self.headerHeight } else { Self.itemHeight }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { false } else { true }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ListRowView()
        if case .item(_, let last) = rows[row] { view.separatorInset = last ? 0 : ItemCell.textInset }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = NSTableCellView()
            let text = label(title, size: 15, weight: .bold)
            cell.addSubview(text)
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: ItemCell.padding).isActive = true
            text.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6).isActive = true
            return cell
        case .item(let entry, _):
            let cell = tableView.makeView(withIdentifier: ItemCell.id, owner: nil) as? ItemCell ?? ItemCell()
            let date = DateGroup.rowDate(entry.modified, now: Date(), calendar: .current)
            cell.fill(name: entry.url.lastPathComponent, date: date, details: details[entry.url] ?? "",
                      thumbnail: thumbnails[entry.url])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, table.selectedRow >= 0, case .item(let entry, _) = rows[table.selectedRow] else { return }
        onSelect(entry.url)
    }
}

/// The accent pill of the selected row and the thin inset line between rows.
final class ListRowView: NSTableRowView {
    private static let pillRadius: CGFloat = 10
    private static let pillInset: CGFloat = 8
    var separatorInset: CGFloat = 0

    // The pill keeps its color while the list is not focused, as in Notes.
    override var isEmphasized: Bool { get { true } set {} }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        let pill = bounds.insetBy(dx: Self.pillInset, dy: 0)
        NSBezierPath(roundedRect: pill, xRadius: Self.pillRadius, yRadius: Self.pillRadius).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard separatorInset > 0, !isSelected, !isNextRowSelected else { return }
        let line = 1 / (window?.backingScaleFactor ?? 1)
        NSColor.separatorColor.setFill()
        NSRect(x: separatorInset, y: bounds.maxY - line, width: bounds.width - separatorInset - ItemCell.padding,
               height: line).fill()
    }
}

final class ItemCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("item")
    static let thumbnailSide: CGFloat = 40
    static let padding: CGFloat = 10
    static let textInset = padding + thumbnailSide + 10
    private static let thumbnailRadius: CGFloat = 6
    private static let selectedDetailAlpha = 0.75
    private let thumbnail = NSImageView()
    private let name = label(size: 13, weight: .bold)
    private let date = label(size: 12)
    private let detail = label(size: 12, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = Self.thumbnailRadius
        thumbnail.layer?.masksToBounds = true
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        let second = NSStackView(views: [date, detail])
        second.spacing = 6
        let lines = NSStackView(views: [name, second])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnail)
        addSubview(lines)
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: Self.thumbnailSide),
            thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSide),
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.padding),
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func fill(name: String, date: String, details: String, thumbnail: NSImage?) {
        self.name.stringValue = name
        self.date.stringValue = date
        detail.stringValue = details
        self.thumbnail.image = thumbnail
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            name.textColor = selected ? .white : .labelColor
            date.textColor = selected ? .white : .labelColor
            detail.textColor = selected ? .white.withAlphaComponent(Self.selectedDetailAlpha) : .secondaryLabelColor
        }
    }
}

// MARK: Viewer

/// The file shown, under its modified date.
@MainActor final class ViewerPane: NSViewController {
    let hud = HUD()
    private let date = label(size: 11, weight: .medium, color: .tertiaryLabelColor)
    private let empty = label("Drop images, videos, GIFs, music or PDFs", size: 18, color: .secondaryLabelColor)
    private let stage = NSView()
    var stageSize: NSSize { stage.frame.size }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: initialWindowSize))
        stage.translatesAutoresizingMaskIntoConstraints = false
        hud.translatesAutoresizingMaskIntoConstraints = false
        for view in [stage, date, empty, hud] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            date.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            date.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stage.topAnchor.constraint(equalTo: date.bottomAnchor, constant: 6),
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            hud.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hud.topAnchor.constraint(equalTo: stage.topAnchor, constant: 16),
        ])
        view = root
    }

    func show(_ media: Media?, modified: Date?) {
        stage.subviews.forEach { $0.removeFromSuperview() }
        date.stringValue = modified.map {
            let format = DateFormatter()
            format.locale = englishInRegion
            format.dateStyle = .long
            format.timeStyle = .short
            return format.string(from: $0)
        } ?? ""
        empty.isHidden = media != nil
        guard let media else { return }
        view.layoutSubtreeIfNeeded()
        media.view.frame = stage.bounds
        media.view.autoresizingMask = [.width, .height]
        stage.addSubview(media.view)
        media.fit()
    }
}
