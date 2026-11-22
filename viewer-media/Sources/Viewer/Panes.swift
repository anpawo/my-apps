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

// MARK: List

/// The files open in this window, in the order they were opened.
@MainActor final class ListPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let itemHeight: CGFloat = 58
    var onSelect: (URL) -> Void = { _ in }
    private let table = NSTableView()
    private var rows: [Entry] = []
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

    func reload(_ library: Library) {
        rows = library.shown
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

    private func index(of url: URL?) -> Int? { rows.firstIndex { $0.url == url } }

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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ListRowView()
        view.separatorInset = row == rows.count - 1 ? 0 : ItemCell.textInset
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ItemCell.id, owner: nil) as? ItemCell ?? ItemCell()
        let entry = rows[row]
        cell.fill(name: entry.url.lastPathComponent, details: details[entry.url] ?? "", thumbnail: thumbnails[entry.url])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, table.selectedRow >= 0 else { return }
        onSelect(rows[table.selectedRow].url)
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
    private let detail = label(size: 12, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = Self.thumbnailRadius
        thumbnail.layer?.masksToBounds = true
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        let lines = NSStackView(views: [name, detail])
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

    func fill(name: String, details: String, thumbnail: NSImage?) {
        self.name.stringValue = name
        detail.stringValue = details
        self.thumbnail.image = thumbnail
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            name.textColor = selected ? .white : .labelColor
            detail.textColor = selected ? .white.withAlphaComponent(Self.selectedDetailAlpha) : .secondaryLabelColor
        }
    }
}

// MARK: Viewer

/// The file shown, under its modified date, with the playback bar over its bottom when it plays.
@MainActor final class ViewerPane: NSViewController {
    private static let controlsMargin: CGFloat = 16
    let hud = HUD()
    let controls = Controls()
    /// Esc hides the bar for every file until pressed again.
    var controlsHidden = false { didSet { showControls() } }
    private let date = label(size: 11, weight: .medium, color: .tertiaryLabelColor)
    private let empty = label("Drop images, videos, GIFs, music or PDFs", size: 18, color: .secondaryLabelColor)
    private let stage = NSView()
    var stageSize: NSSize { stage.frame.size }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: initialWindowSize))
        for view in [stage, hud, controls] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [stage, date, empty, hud, controls] as [NSView] { root.addSubview(view) }
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
            controls.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -Self.controlsMargin),
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: stage.leadingAnchor, constant: Self.controlsMargin),
        ])
        controls.isHidden = true
        view = root
    }

    func show(_ media: Media?, plays: Bool, modified: Date?) {
        stage.subviews.forEach { $0.removeFromSuperview() }
        date.stringValue = modified.map {
            let format = DateFormatter()
            format.locale = englishInRegion
            format.dateStyle = .long
            format.timeStyle = .short
            return format.string(from: $0)
        } ?? ""
        empty.isHidden = media != nil
        controls.media = plays ? media : nil
        showControls()
        guard let media else { return }
        view.layoutSubtreeIfNeeded()
        media.view.frame = stage.bounds
        media.view.autoresizingMask = [.width, .height]
        stage.addSubview(media.view)
        media.fit()
    }

    private func showControls() { controls.isHidden = controlsHidden || controls.media == nil }
}

/// Slower, play or pause, faster, the speed, then the time and a slider to seek, in a dark capsule.
@MainActor final class Controls: NSVisualEffectView {
    private static let refreshInterval = 0.25
    private static let width: CGFloat = 520
    private static let height: CGFloat = 40
    private static let padding: CGFloat = 14
    var perform: (Action) -> Void = { _ in }
    weak var media: Media? { didSet { refresh() } }
    private lazy var playButton = button("play.fill", .playPause)
    private let speed = NSTextField(labelWithString: Speed.label(1))
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var timer: Timer?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.masksToBounds = true
        for field in [speed, elapsed, total] {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            field.textColor = .white
        }
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(seek)
        let row = NSStackView(views: [button("backward.fill", .slower), playButton, button("forward.fill", .faster),
                                      speed, elapsed, slider, total])
        row.spacing = 10
        row.setCustomSpacing(18, after: speed)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width).withPriority(.defaultHigh),
            heightAnchor.constraint(equalToConstant: Self.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(playing: Bool, speed label: String) {
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        speed.stringValue = label
    }

    private func refresh() {
        guard !isHidden, let progress = media?.progress else { return }
        elapsed.stringValue = Details.duration(progress.current)
        total.stringValue = Details.duration(progress.total)
        // A drag in progress owns the knob.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        slider.maxValue = max(progress.total, 0.01)
        slider.doubleValue = progress.current
    }

    private func button(_ symbol: String, _ action: Action) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                              target: self, action: #selector(clicked(_:)))
        button.isBordered = false
        button.contentTintColor = .white
        button.tag = actions.count
        actions.append(action)
        return button
    }

    private var actions: [Action] = []
    @objc private func clicked(_ sender: NSButton) { perform(actions[sender.tag]) }
    @objc private func seek() { media?.seek(to: slider.doubleValue) }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
