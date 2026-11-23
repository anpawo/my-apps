import AppKit
import QuickLookThumbnailing

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

/// The files open in this window, in the order they were opened.
final class ListPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let itemHeight: CGFloat = 58
    var onSelect: (URL) -> Void = { _ in }
    /// A row's dimmed second line (a duration, a size, a folder), handed back once known.
    var describe: (URL, @escaping (String) -> Void) -> Void = { _, _ in }
    /// Rows with unsaved edits get a dot after their name.
    var isEdited: (URL) -> Bool = { _ in false }
    private let table = NSTableView()
    private var rows: [URL] = []
    private var thumbnails: [URL: NSImage] = [:]
    private var details: [URL: String] = [:]
    private var syncing = false

    override func loadView() {
        table.style = .inset
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.rowHeight = Self.itemHeight
        table.dataSource = self
        table.delegate = self
        view = scrolling(table)
    }

    func reload(_ urls: [URL], current: URL?) {
        loadViewIfNeeded()
        rows = urls
        syncing = true
        table.reloadData()
        // After the reload: a row's details can come back at once, and reload a row the table must already have.
        fetch(urls)
        if let row = index(of: current) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        syncing = false
    }

    /// Asks again for a row's second line, after its file changed.
    func refreshDetails(of url: URL) {
        details[url] = nil
        fetch([url])
    }

    private func fetch(_ urls: [URL]) {
        for url in urls where thumbnails[url] == nil { requestThumbnail(url) }
        for url in urls where details[url] == nil {
            details[url] = ""
            describe(url) { [weak self] text in self?.details[url] = text; self?.reloadRow(of: url) }
        }
    }

    private func index(of url: URL?) -> Int? { rows.firstIndex { $0 == url } }

    func reloadRow(of url: URL) {
        if let row = index(of: url) { table.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }

    private func requestThumbnail(_ url: URL) {
        thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)
        Thumbnail.request(url, side: ItemCell.thumbnailSide) { [weak self] image in
            self?.thumbnails[url] = image
            self?.reloadRow(of: url)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ListRowView()
        view.separatorInset = row == rows.count - 1 ? 0 : ItemCell.textInset
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ItemCell.id, owner: nil) as? ItemCell ?? ItemCell()
        let url = rows[row]
        cell.fill(name: url.lastPathComponent, details: details[url] ?? "", thumbnail: thumbnails[url], edited: isEdited(url))
        cell.toolTip = url.path
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, table.selectedRow >= 0 else { return }
        onSelect(rows[table.selectedRow])
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
    private static let dotSize: CGFloat = 7
    private let thumbnail = NSImageView()
    private let name = label(size: 13, weight: .bold)
    private let dot = NSImageView()
    private let detail = label(size: 12, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = Self.thumbnailRadius
        thumbnail.layer?.masksToBounds = true
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unsaved")
        dot.symbolConfiguration = .init(pointSize: Self.dotSize, weight: .regular)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        let title = NSStackView(views: [name, dot])
        title.spacing = 6
        let lines = NSStackView(views: [title, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnail)
        addSubview(lines)
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

    func fill(name: String, details: String, thumbnail: NSImage?, edited: Bool = false) {
        self.name.stringValue = name
        detail.stringValue = details
        self.thumbnail.image = thumbnail
        dot.isHidden = !edited
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            name.textColor = selected ? .white : .labelColor
            dot.contentTintColor = name.textColor
            detail.textColor = selected ? .white.withAlphaComponent(Self.selectedDetailAlpha) : .secondaryLabelColor
        }
    }
}

@MainActor enum Thumbnail {
    /// QuickLook fits the long side: asked bigger, the cropped short side stays sharp.
    private static let cropRoom: CGFloat = 2

    static func request(_ url: URL, side: CGFloat, done: @escaping @MainActor (NSImage) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side * cropRoom, height: side * cropRoom),
                                                   scale: 2, representationTypes: .thumbnail)
        request.iconMode = false
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            guard let image = thumbnail?.cgImage else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(squared(image, side: side)) } }
        }
    }

    /// Filled to a square as Notes' thumbnails are: the middle of a landscape, the top of a portrait (a page's title).
    private static func squared(_ image: CGImage, side: CGFloat) -> NSImage {
        let short = min(image.width, image.height)
        let crop = CGRect(x: (image.width - short) / 2, y: 0, width: short, height: short)
        return NSImage(cgImage: image.cropping(to: crop) ?? image, size: NSSize(width: side, height: side))
    }
}
