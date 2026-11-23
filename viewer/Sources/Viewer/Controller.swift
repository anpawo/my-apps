import AppKit
import Carbon.HIToolbox
import ViewerCore

enum Action {
    case previous, next, slower, faster, playPause, volumeUp, volumeDown, mute
    case toStart, toEnd, back, forward, remove, reveal, settings, fullscreen, zoomIn, zoomOut, toggleControls
}

private let inAppKeys: [(key: Int, modifiers: NSEvent.ModifierFlags, action: Action)] = [
    (kVK_UpArrow, [], .previous), (kVK_DownArrow, [], .next),
    (kVK_LeftArrow, [], .slower), (kVK_RightArrow, [], .faster),
    (kVK_Space, [], .playPause),
    (kVK_UpArrow, .option, .volumeUp), (kVK_DownArrow, .option, .volumeDown),
    (kVK_LeftArrow, .option, .toStart), (kVK_RightArrow, .option, .toEnd),
    (kVK_LeftArrow, .shift, .back), (kVK_RightArrow, .shift, .forward),
    (kVK_Delete, [], .remove), (kVK_ForwardDelete, [], .remove),
    (kVK_ANSI_F, [], .fullscreen), (kVK_Escape, [], .toggleControls),
    (kVK_ANSI_Equal, .command, .zoomIn), (kVK_ANSI_Equal, [.command, .shift], .zoomIn),
    (kVK_ANSI_Minus, .command, .zoomOut),
    (kVK_Tab, .control, .next), (kVK_Tab, [.control, .shift], .previous),
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

let initialWindowSize = NSSize(width: 1180, height: 740)

@MainActor
final class Controller: NSObject {
    private static let seekStep = 5.0
    private static let listWidth: (min: CGFloat, max: CGFloat) = (260, 420)
    private static let viewerMinWidth: CGFloat = 360

    let window: DropWindow
    private var library = Library()
    private let split = NSSplitViewController()
    private let list = ListPane()
    private let viewer = ViewerPane()
    private var toolbar: Toolbar!
    private(set) var fit: StageFit!
    private var media: Media?
    /// Each open text file's text, undo and unsaved edits, kept while another file is shown.
    private var documents: [URL: Document] = [:]
    private var shown: URL?
    private var volume: Float = 1
    private var unmutedVolume: Float = 1
    private var speedLabel = Speed.label(1)

    override init() {
        window = DropWindow(contentRect: NSRect(origin: .zero, size: initialWindowSize),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.onDrop = { [weak self] urls in self?.add(urls) }
        buildSplit()
        toolbar = Toolbar(splitView: split.splitView, perform: { [weak self] in self?.perform($0) },
                          onSearch: { [weak self] in self?.search($0) })
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unified
        fit = StageFit(window: window, splitView: split.splitView) { [weak self] in self?.viewer.stageSize ?? .zero }
        fit.didFit = { [weak self] in
            self?.viewer.view.layoutSubtreeIfNeeded()
            self?.media?.fit()
        }
        viewer.controls.perform = { [weak self] in self?.perform($0) }
        viewer.controls.setVolume = { [weak self] in self?.setVolume($0); self?.updateToolbar() }
        list.onSelect = { [weak self] url in self?.library.select(url); self?.refresh() }
        list.isEdited = { [weak self] url in self?.documents[url]?.dirty == true }
        fit.shouldClose = { [weak self] in self?.closeAll() ?? true }
        list.describe = { url, done in
            if let kind = Kind(url: url) { Thumbnails.details(of: Entry(url: url, kind: kind, modified: Date()), done: done) }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
        refresh()
    }

    func showSidebar() { split.splitViewItems[0].isCollapsed = false }

    private func buildSplit() {
        let side = NSSplitViewItem(sidebarWithViewController: list)
        side.minimumThickness = Self.listWidth.min
        side.maximumThickness = Self.listWidth.max
        // Hidden until asked for, as in Preview; the toolbar's sidebar button shows it.
        side.isCollapsed = true
        let content = NSSplitViewItem(viewController: viewer)
        content.minimumThickness = Self.viewerMinWidth
        for item in [side, content] {
            item.titlebarSeparatorStyle = .none
            split.addSplitViewItem(item)
        }
        window.contentViewController = split
        window.setContentSize(initialWindowSize)
    }

    func registerGlobalKeys() {
        for binding in globalKeys {
            HotKey.register(key: binding.key, modifiers: binding.modifiers) { [weak self] in self?.perform(binding.action) }
        }
    }

    func add(_ urls: [URL]) {
        let entries = mediaFiles(in: urls).compactMap { url -> Entry? in
            guard let kind = Kind(url: url), kind != .text || openDocument(url.standardizedFileURL) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return Entry(url: url, kind: kind, modified: modified ?? Date())
        }
        guard !entries.isEmpty else { return }
        library.add(entries)
        if library.query.isEmpty { toolbar.clearSearch() }
        refresh()
    }

    /// False when the file cannot be read as text: it stays out of the list.
    private func openDocument(_ url: URL) -> Bool {
        guard documents[url] == nil else { return true }
        do {
            let doc = try Document(url: url)
            doc.onChange = { [weak self] in self?.list.reloadRow(of: url) }
            documents[url] = doc
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    func saveCurrent() {
        guard let url = library.current, let doc = documents[url] else { return }
        do { try doc.save() } catch { NSAlert(error: error).runModal() }
        refresh()
    }

    /// ⌘W: the shown file leaves the list (asking about unsaved edits); with none, the window closes.
    func closeCurrent() {
        guard library.current != nil else { return window.performClose(nil) }
        perform(.remove)
    }

    /// Asks about unsaved edits first; false when the user cancels. The file's Document goes with it.
    private func close(_ url: URL?) -> Bool {
        guard let url, let doc = documents[url] else { return true }
        if doc.dirty {
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
        documents[url] = nil
        return true
    }

    /// Before quitting or closing the window: each unsaved file is shown, then asked about.
    func closeAll() -> Bool {
        for entry in library.entries where documents[entry.url]?.dirty == true {
            library.select(entry.url)
            refresh()
            if !close(entry.url) { return false }
        }
        return true
    }

    private func search(_ text: String) {
        library.filter(query: text)
        refresh()
    }

    // MARK: Keys

    /// True when the key was ours and must not reach the focused view (AVPlayerView eats arrows).
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard let binding = inAppKeys.first(where: { $0.key == Int(event.keyCode) && $0.modifiers == modifiers })
        else { return false }
        // The editor keeps its keys (arrows move the cursor, Delete deletes) but ⌃Tab, which walks the files.
        if window.firstResponder is CodeView, !modifiers.contains(.control) { return false }
        // Typing in the search field keeps its keys, but ↑/↓ still walk the list.
        if window.firstResponder is NSText, binding.action != .previous, binding.action != .next { return false }
        perform(binding.action)
        return true
    }

    func perform(_ action: Action) {
        switch action {
        case .previous: library.move(by: -1); refresh()
        case .next: library.move(by: 1); refresh()
        case .slower, .faster:
            let label = media?.changeSpeed(by: action == .faster ? 1 : -1)
            if library.currentEntry?.kind.plays == true, let label { speedLabel = label }
            viewer.hud.show(label)
        case .playPause: media?.togglePlay(); viewer.controlsHidden = false
        case .volumeUp, .volumeDown: setVolume(Volume.step(volume, by: action == .volumeUp ? 1 : -1))
        case .mute: setVolume(volume == 0 ? unmutedVolume : 0)
        case .toStart: media?.jump(toEnd: false)
        case .toEnd: media?.jump(toEnd: true)
        case .back: media?.seek(by: -Self.seekStep)
        case .forward: media?.seek(by: Self.seekStep)
        case .remove: if close(library.current) { library.removeCurrent(); refresh() }
        case .reveal: if let url = library.current { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .settings: Openers.show(commonExtensions)
        case .fullscreen: window.toggleFullScreen(nil)
        case .zoomIn: media?.zoom(in: true)
        case .zoomOut: media?.zoom(in: false)
        case .toggleControls: viewer.controlsHidden.toggle()
        }
        updateToolbar()
    }

    private func setVolume(_ level: Float) {
        if level > 0 { unmutedVolume = level }
        volume = level
        media?.setVolume(volume)
        viewer.hud.show(Volume.label(volume))
    }

    // MARK: Display

    private func refresh() {
        list.reload(library.shown.map(\.url), current: library.current)
        window.title = "All Files"
        // The shown file's date sits in the title bar, not over the picture; a text file's follows its saves.
        let modified = library.currentEntry.map { documents[$0.url]?.modified ?? $0.modified }
        window.subtitle = ([Details.items(library.shown.count)] + [modified.map(longDate)].compactMap { $0 })
            .joined(separator: " · ")
        showCurrent()
        fitStage()
        updateToolbar()
    }

    /// A file open alone gives the window its shape; a list keeps 16:9.
    private func fitStage() {
        guard library.entries.count == 1, let media else { return fit.setAspect(nil) }
        media.loadAspect { [weak self, weak media] aspect in
            guard let self, let media, media === self.media else { return }
            fit.setAspect(aspect)
        }
    }

    private func updateToolbar() {
        toolbar.update(volume: volume, hasFile: library.current != nil, plays: library.currentEntry?.kind.plays == true)
        viewer.controls.update(playing: media?.isPlaying == true, speed: speedLabel, volume: volume)
    }

    private func showCurrent() {
        let entry = library.currentEntry
        guard entry?.url != shown else { return }
        shown = entry?.url
        media?.stop()
        media = entry.map { entry in
            if let doc = documents[entry.url] {
                return TextMedia(doc, onDrop: { [weak self] in self?.add($0) }, onReload: { [weak self] in self?.refresh() })
            }
            return makeMedia(entry.url, kind: entry.kind, volume: volume) { [weak self] in self?.updateToolbar() }
        }
        speedLabel = Speed.label(1)
        viewer.show(media, plays: entry?.kind.plays == true)
        (media as? TextMedia)?.focus()
    }

    private func longDate(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = englishInRegion
        format.dateStyle = .long
        format.timeStyle = .short
        return format.string(from: date)
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
final class DropWindow: NSWindow {
    var onDrop: ([URL]) -> Void = { _ in }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        registerForDraggedTypes([.fileURL])
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDrop(urls)
        return !urls.isEmpty
    }
}
