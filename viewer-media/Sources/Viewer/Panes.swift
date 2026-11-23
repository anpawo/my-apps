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

/// The files open in this window, in the order they were opened, and under them the last three opened ever.
@MainActor final class ListPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let itemHeight: CGFloat = 58
    private static let recentTitleInset: CGFloat = 18
    private static let moveDuration: TimeInterval = 0.3
    private static let reducedDuration: TimeInterval = 0.15
    var onSelect: (URL) -> Void = { _ in }
    var onOpenRecent: (URL) -> Void = { _ in }
    private let table = NSTableView()
    private let recentTable = NSTableView()
    private let recentTitle = label("Recent", size: 11, weight: .semibold, color: .secondaryLabelColor)
    private var recentHeight: NSLayoutConstraint!
    private var rows: [Entry] = []
    private var recent: [Entry] = []
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
        let old = recent.map(\.url)
        recent = urls.compactMap { url in Kind(url: url).map { Entry(url: url, kind: $0, modified: Date()) } }
        for entry in recent where thumbnails[entry.url] == nil { requestThumbnail(entry.url) }
        for entry in recent where details[entry.url] == nil { requestDetails(entry) }
        let kept = old.filter { urls.contains($0) }
        if kept == urls && kept.count < old.count {
            recentTable.removeRows(at: IndexSet(old.indices.filter { !urls.contains(old[$0]) }), withAnimation: .effectFade)
        } else {
            recentTable.reloadData()
        }
        // The inset style puts a margin above the first row: the same below keeps the last one whole.
        let margin = recent.isEmpty ? 0 : recentTable.rect(ofRow: 0).minY
        let height = CGFloat(recent.count) * Self.itemHeight + 2 * margin
        animate {
            self.recentTitle.animator().alphaValue = self.recent.isEmpty ? 0 : 1
            self.recentHeight.animator().constant = height
            self.view.layoutSubtreeIfNeeded()
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

    private func requestDetails(_ entry: Entry) {
        details[entry.url] = ""
        Thumbnails.details(of: entry) { [weak self] text in self?.details[entry.url] = text; self?.reloadRow(of: entry.url) }
    }

    func reload(_ library: Library) {
        rows = library.shown
        for entry in library.entries where thumbnails[entry.url] == nil { requestThumbnail(entry.url) }
        for entry in library.entries where details[entry.url] == nil { requestDetails(entry) }
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
        if let row = recent.firstIndex(where: { $0.url == url }) {
            recentTable.reloadData(forRowIndexes: [row], columnIndexes: [0])
        }
    }

    private func requestThumbnail(_ url: URL) {
        thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)
        Thumbnails.request(url, side: ItemCell.thumbnailSide) { [weak self] image in
            self?.thumbnails[url] = image
            self?.reloadRow(of: url)
        }
    }

    private func entries(of tableView: NSTableView) -> [Entry] { tableView === recentTable ? recent : rows }

    func numberOfRows(in tableView: NSTableView) -> Int { entries(of: tableView).count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ListRowView()
        view.separatorInset = row == entries(of: tableView).count - 1 ? 0 : ItemCell.textInset
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ItemCell.id, owner: nil) as? ItemCell ?? ItemCell()
        let entry = entries(of: tableView)[row]
        cell.fill(name: entry.url.lastPathComponent, details: details[entry.url] ?? "", thumbnail: thumbnails[entry.url])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === recentTable {
            guard recentTable.selectedRow >= 0 else { return }
            let url = recent[recentTable.selectedRow].url
            let copy = flyingCopy(of: recentTable.selectedRow)
            recentTable.deselectAll(nil)
            onOpenRecent(url)
            land(copy, on: url)
            return
        }
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
    private let empty = label("Drop images, videos, GIFs, music or PDFs", size: 18, color: .secondaryLabelColor)
    private let stage = NSView()
    var stageSize: NSSize { stage.frame.size }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: initialWindowSize))
        for view in [stage, hud, controls] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [stage, empty, hud, controls] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
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

    func show(_ media: Media?, plays: Bool) {
        stage.subviews.forEach { $0.removeFromSuperview() }
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

/// QuickTime's layout: the volume on the left, slower, play or pause and faster centred, the speed on the right, then the
/// time on either side of the slider to seek, in a dark rounded box. The speed keeps one width, so a new
/// speed moves nothing.
@MainActor final class Controls: NSVisualEffectView {
    private static let refreshInterval = 0.25
    private static let width: CGFloat = 520
    private static let height: CGFloat = 72
    private static let cornerRadius: CGFloat = 18
    private static let padding: CGFloat = 14
    private static let rowInset: CGFloat = 12
    /// The widest label `Speed.steps` makes.
    private static let widestSpeed = "0.25×"
    private static let volumeSliderWidth: CGFloat = 72
    var perform: (Action) -> Void = { _ in }
    var setVolume: (Float) -> Void = { _ in }
    weak var media: Media? { didSet { refresh() } }
    private lazy var playButton = button("play.fill", .playPause)
    private lazy var muteButton = button("speaker.wave.3.fill", .mute)
    private let volume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
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
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        for field in [speed, elapsed, total] {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            field.textColor = .white
        }
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(seek)
        volume.controlSize = .small
        volume.target = self
        volume.action = #selector(volumeMoved)
        speed.alignment = .right
        let speedWidth = (Self.widestSpeed as NSString).size(withAttributes: [.font: speed.font!]).width
        let transport = NSStackView(views: [button("backward.fill", .slower), playButton, button("forward.fill", .faster)])
        transport.spacing = 18
        let time = NSStackView(views: [elapsed, slider, total])
        time.spacing = 10
        let sound = NSStackView(views: [muteButton, volume])
        sound.spacing = 6
        for view in [sound, transport, time, speed] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width).withPriority(.defaultHigh),
            heightAnchor.constraint(equalToConstant: Self.height),
            transport.centerXAnchor.constraint(equalTo: centerXAnchor),
            transport.topAnchor.constraint(equalTo: topAnchor, constant: Self.rowInset),
            sound.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            sound.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            volume.widthAnchor.constraint(equalToConstant: Self.volumeSliderWidth),
            speed.widthAnchor.constraint(equalToConstant: ceil(speedWidth)),
            speed.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding - 4),
            speed.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            time.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.rowInset),
            time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
        ])
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(playing: Bool, speed label: String, volume level: Float) {
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        speed.stringValue = label
        muteButton.image = NSImage(systemSymbolName: volumeSymbol(level), accessibilityDescription: nil)
        if NSEvent.pressedMouseButtons == 0 { volume.floatValue = level }
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
    @objc private func volumeMoved() { setVolume(volume.floatValue) }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

