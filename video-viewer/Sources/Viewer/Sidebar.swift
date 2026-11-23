import AppKit
import QuickLookThumbnailing

// Shared by Video Viewer and Text Viewer (text-viewer links to this file), so both sidebars stay one design.

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

/// The files open in this window, in the order they were opened, and under them the last three opened ever.
final class ListPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let itemHeight: CGFloat = 58
    private static let recentTitleInset: CGFloat = 18
    private static let moveDuration: TimeInterval = 0.3
    private static let reducedDuration: TimeInterval = 0.15
    var onSelect: (URL) -> Void = { _ in }
    var onOpenRecent: (URL) -> Void = { _ in }
    /// A row's dimmed second line (a duration, a size, a folder), handed back once known.
    var describe: (URL, @escaping (String) -> Void) -> Void = { _, _ in }
    /// Rows with unsaved edits get a dot after their name.
    var isEdited: (URL) -> Bool = { _ in false }
    private let table = NSTableView()
    private let recentTable = NSTableView()
    private let recentTitle = label("Recent", size: 11, weight: .semibold, color: .secondaryLabelColor)
    private var recentHeight: NSLayoutConstraint!
    private var rows: [URL] = []
    private var recent: [URL] = []
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
        recentTable.style = .inset
        recentTable.intercellSpacing = .zero
        recentTable.backgroundColor = .clear
        recentTable.rowHeight = Self.itemHeight
        recentTable.addTableColumn(NSTableColumn(identifier: .init("column")))
        recentTable.headerView = nil
        recentTable.dataSource = self
        recentTable.delegate = self
        recentTable.focusRingType = .none
        recentTable.translatesAutoresizingMaskIntoConstraints = false
        let scroll = scrolling(table)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.wantsLayer = true
        for view in [scroll, recentTitle, recentTable] as [NSView] { root.addSubview(view) }
        recentHeight = recentTable.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: recentTitle.topAnchor, constant: -8),
            recentTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.recentTitleInset),
            recentTitle.bottomAnchor.constraint(equalTo: recentTable.topAnchor, constant: -4),
            recentTable.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            recentTable.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            recentTable.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            recentHeight,
        ])
        view = root
    }

    func showRecent(_ urls: [URL]) {
        loadViewIfNeeded()
        let old = recent
        recent = urls
        let kept = old.filter { urls.contains($0) }
        if kept == urls && kept.count < old.count {
            recentTable.removeRows(at: IndexSet(old.indices.filter { !urls.contains(old[$0]) }), withAnimation: .effectFade)
        } else {
            recentTable.reloadData()
        }
        fetch(urls)
        // The inset style puts a margin above the first row: the same below keeps the last one whole.
        let margin = recent.isEmpty ? 0 : recentTable.rect(ofRow: 0).minY
        let height = CGFloat(recent.count) * Self.itemHeight + 2 * margin
        animate {
            self.recentTitle.animator().alphaValue = self.recent.isEmpty ? 0 : 1
            self.recentHeight.animator().constant = height
            self.view.layoutSubtreeIfNeeded()
        }
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

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Instant while the window is not on screen yet (the first fill at launch).
    private func animate(_ changes: @escaping () -> Void, then done: @escaping () -> Void = {}) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = view.window?.isVisible == true ? (reduceMotion ? Self.reducedDuration : Self.moveDuration) : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: done)
    }

    /// A picture of a recent row, laid over the sidebar where the row is, to fly it into the list.
    private func flyingCopy(of row: Int) -> NSView? {
        guard let rowView = recentTable.rowView(atRow: row, makeIfNecessary: false),
              let bitmap = rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds) else { return nil }
        rowView.cacheDisplay(in: rowView.bounds, to: bitmap)
        let image = NSImage(size: rowView.bounds.size)
        image.addRepresentation(bitmap)
        let copy = NSImageView(image: image)
        copy.imageScaling = .scaleNone
        copy.frame = view.convert(rowView.bounds, from: rowView)
        view.addSubview(copy)
        return copy
    }

    /// The copy glides onto the row the file now has in the list, which shows once it lands.
    private func land(_ copy: NSView?, on url: URL) {
        guard let copy else { return }
        view.layoutSubtreeIfNeeded()
        guard let row = index(of: url), let target = table.rowView(atRow: row, makeIfNecessary: true) else {
            copy.removeFromSuperview()
            return
        }
        target.alphaValue = 0
        let end = view.convert(target.bounds, from: target)
        animate({
            if self.reduceMotion { copy.animator().alphaValue = 0; target.animator().alphaValue = 1 } else { copy.animator().frame = end }
        }, then: {
            target.alphaValue = 1
            copy.removeFromSuperview()
        })
    }

    private func index(of url: URL?) -> Int? { rows.firstIndex { $0 == url } }

    func reloadRow(of url: URL) {
        if let row = index(of: url) { table.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
        if let row = recent.firstIndex(of: url) { recentTable.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }

    private func requestThumbnail(_ url: URL) {
        thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)
        Thumbnail.request(url, side: ItemCell.thumbnailSide) { [weak self] image in
            self?.thumbnails[url] = image
            self?.reloadRow(of: url)
        }
    }

    private func urls(of tableView: NSTableView) -> [URL] { tableView === recentTable ? recent : rows }

    func numberOfRows(in tableView: NSTableView) -> Int { urls(of: tableView).count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ListRowView()
        view.separatorInset = row == urls(of: tableView).count - 1 ? 0 : ItemCell.textInset
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ItemCell.id, owner: nil) as? ItemCell ?? ItemCell()
        let url = urls(of: tableView)[row]
        cell.fill(name: url.lastPathComponent, details: details[url] ?? "", thumbnail: thumbnails[url],
                  edited: tableView === table && isEdited(url))
        cell.toolTip = url.path
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === recentTable {
            guard recentTable.selectedRow >= 0 else { return }
            let url = recent[recentTable.selectedRow]
            let copy = flyingCopy(of: recentTable.selectedRow)
            recentTable.deselectAll(nil)
            onOpenRecent(url)
            land(copy, on: url)
            return
        }
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
