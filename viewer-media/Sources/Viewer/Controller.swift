import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import ViewerCore

enum Action {
    case previous, next, slower, faster, playPause, volumeUp, volumeDown
    case toStart, toEnd, back, forward, remove, fullscreen, zoomIn, zoomOut
}

private let inAppKeys: [(key: Int, modifiers: NSEvent.ModifierFlags, action: Action)] = [
    (kVK_UpArrow, [], .previous), (kVK_DownArrow, [], .next),
    (kVK_LeftArrow, [], .slower), (kVK_RightArrow, [], .faster),
    (kVK_Space, [], .playPause),
    (kVK_UpArrow, .option, .volumeUp), (kVK_DownArrow, .option, .volumeDown),
    (kVK_LeftArrow, .option, .toStart), (kVK_RightArrow, .option, .toEnd),
    (kVK_LeftArrow, .shift, .back), (kVK_RightArrow, .shift, .forward),
    (kVK_Delete, [], .remove), (kVK_ForwardDelete, [], .remove),
    (kVK_ANSI_F, [], .fullscreen),
    (kVK_ANSI_Equal, .command, .zoomIn), (kVK_ANSI_Equal, [.command, .shift], .zoomIn),
    (kVK_ANSI_Minus, .command, .zoomOut),
]

// Plain ⌥←/→ stays out: it is word navigation in every app.
private let globalKeys: [(key: Int, modifiers: Int, action: Action)] = [
    (kVK_UpArrow, controlKey | optionKey, .previous), (kVK_DownArrow, controlKey | optionKey, .next),
    (kVK_LeftArrow, controlKey | optionKey, .slower), (kVK_RightArrow, controlKey | optionKey, .faster),
    (kVK_UpArrow, controlKey | optionKey | shiftKey, .volumeUp),
    (kVK_DownArrow, controlKey | optionKey | shiftKey, .volumeDown),
    (kVK_LeftArrow, controlKey | optionKey | shiftKey, .toStart),
    (kVK_RightArrow, controlKey | optionKey | shiftKey, .toEnd),
    (kVK_Space, controlKey | optionKey, .playPause),
]

let initialWindowSize = NSSize(width: 1100, height: 720)

@MainActor
final class Controller: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let seekStep = 5.0
    private static let sidebarWidth: CGFloat = 220
    private static let rowHeight: CGFloat = 44
    private static let thumbnailSide: CGFloat = 36
    private static let cellID = NSUserInterfaceItemIdentifier("item")

    let window: NSWindow
    private var playlist = Playlist()
    private let table = NSTableView()
    private let detail = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Drop images, videos, GIFs or PDFs")
    private let hud = HUD()
    private var media: Media?
    private var shown: URL?
    private var volume: Float = 1
    private var thumbnails: [URL: NSImage] = [:]
    private var syncingSelection = false

    override init() {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: initialWindowSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Viewer Media"
        window.isReleasedWhenClosed = false
        window.contentView = buildContent()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
    }

    func registerGlobalKeys() {
        for binding in globalKeys {
            HotKey.register(key: binding.key, modifiers: binding.modifiers) { [weak self] in self?.perform(binding.action) }
        }
    }

    func add(_ urls: [URL]) {
        let files = mediaFiles(in: urls)
        guard !files.isEmpty else { return }
        playlist.add(files)
        files.forEach(requestThumbnail)
        refresh()
    }

    private func buildContent() -> NSView {
        let root = DropView { [weak self] urls in self?.add(urls) }
        let split = NSSplitView(frame: root.bounds)
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        split.addArrangedSubview(buildSidebar())
        split.addArrangedSubview(buildDetail())
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        split.setPosition(Self.sidebarWidth, ofDividerAt: 0)
        root.addSubview(split)
        return root
    }

    private func buildSidebar() -> NSView {
        let column = NSTableColumn(identifier: Self.cellID)
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = Self.rowHeight
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: initialWindowSize.height))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.sizeLastColumnToFit()
        return scroll
    }

    private func buildDetail() -> NSView {
        detail.frame = NSRect(x: 0, y: 0, width: initialWindowSize.width - Self.sidebarWidth, height: initialWindowSize.height)
        for view in [emptyLabel, hud] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview(view)
            view.centerXAnchor.constraint(equalTo: detail.centerXAnchor).isActive = true
        }
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 18)
        emptyLabel.centerYAnchor.constraint(equalTo: detail.centerYAnchor).isActive = true
        hud.topAnchor.constraint(equalTo: detail.topAnchor, constant: 24).isActive = true
        return detail
    }

    // MARK: Keys

    /// True when the key was ours and must not reach the focused view (AVPlayerView eats arrows).
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard let binding = inAppKeys.first(where: { $0.key == Int(event.keyCode) && $0.modifiers == modifiers })
        else { return false }
        perform(binding.action)
        return true
    }

    func perform(_ action: Action) {
        switch action {
        case .previous: move(by: -1)
        case .next: move(by: 1)
        case .slower: hud.show(media?.changeSpeed(by: -1))
        case .faster: hud.show(media?.changeSpeed(by: 1))
        case .playPause: media?.togglePlay()
        case .volumeUp, .volumeDown:
            volume = Volume.step(volume, by: action == .volumeUp ? 1 : -1)
            media?.setVolume(volume)
            hud.show(Volume.label(volume))
        case .toStart: media?.jump(toEnd: false)
        case .toEnd: media?.jump(toEnd: true)
        case .back: media?.seek(by: -Self.seekStep)
        case .forward: media?.seek(by: Self.seekStep)
        case .remove:
            if let url = playlist.current { thumbnails[url] = nil }
            playlist.removeSelected()
            refresh()
        case .fullscreen: window.toggleFullScreen(nil)
        case .zoomIn: media?.zoom(in: true)
        case .zoomOut: media?.zoom(in: false)
        }
    }

    private func move(by delta: Int) {
        playlist.move(by: delta)
        refresh()
    }

    // MARK: List and display

    private func refresh() {
        syncingSelection = true
        table.reloadData()
        if let selected = playlist.selected {
            table.selectRowIndexes([selected], byExtendingSelection: false)
            table.scrollRowToVisible(selected)
        }
        syncingSelection = false
        showCurrent()
    }

    private func showCurrent() {
        let url = playlist.current
        guard url != shown else { return }
        shown = url
        media?.stop()
        media?.view.removeFromSuperview()
        media = nil
        window.title = url?.lastPathComponent ?? "Viewer Media"
        emptyLabel.isHidden = url != nil
        guard let url, let kind = Kind(url: url) else { return }
        let next = makeMedia(url, kind: kind, volume: volume)
        next.view.frame = detail.bounds
        next.view.autoresizingMask = [.width, .height]
        detail.addSubview(next.view, positioned: .below, relativeTo: hud)
        detail.layoutSubtreeIfNeeded()
        next.fit()
        media = next
    }

    func numberOfRows(in tableView: NSTableView) -> Int { playlist.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTableCellView ?? makeCell()
        let url = playlist.items[row]
        cell.textField?.stringValue = url.lastPathComponent
        cell.imageView?.image = thumbnails[url] ?? NSWorkspace.shared.icon(forFile: url.path)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, table.selectedRow >= 0 else { return }
        playlist.select(table.selectedRow)
        showCurrent()
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellID
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        for view in [image, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.widthAnchor.constraint(equalToConstant: Self.thumbnailSide),
            image.heightAnchor.constraint(equalToConstant: Self.thumbnailSide),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        ])
        cell.imageView = image
        cell.textField = text
        return cell
    }

    private func requestThumbnail(_ url: URL) {
        guard thumbnails[url.standardizedFileURL] == nil else { return }
        let side = Self.thumbnailSide
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let image = thumbnail?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, let row = self.playlist.items.firstIndex(of: url.standardizedFileURL) else { return }
                self.thumbnails[url.standardizedFileURL] = image
                self.table.reloadData(forRowIndexes: [row], columnIndexes: [0])
            }
        }
    }
}

/// The brief speed or volume overlay.
final class HUD: NSView {
    private static let visibleFor = 0.9
    private static let fadeDuration = 0.3
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        layer?.cornerRadius = 10
        label.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String?) {
        guard let text else { return }
        label.stringValue = text
        alphaValue = 1
        generation += 1
        let shownAs = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor) { [weak self] in
            guard let self, self.generation == shownAs else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = Self.fadeDuration; self.animator().alphaValue = 0 }
        }
    }
}

/// Files dropped anywhere on the window are added to the list.
final class DropView: NSView {
    private let onDrop: ([URL]) -> Void

    init(onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(frame: NSRect(origin: .zero, size: initialWindowSize))
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Drawn here, not left to the window: `--render` draws the content view alone.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDrop(urls)
        return !urls.isEmpty
    }
}
