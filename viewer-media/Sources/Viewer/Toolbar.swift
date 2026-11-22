import AppKit
import ViewerCore

/// Notes' unified toolbar: the sidebar toggle, then glass capsule groups over the viewer and the search field.
@MainActor final class Toolbar: NSObject, NSToolbarDelegate {
    private static let listSeparator = NSToolbarItem.Identifier("listSeparator")
    private static let playback = NSToolbarItem.Identifier("playback")
    private static let file = NSToolbarItem.Identifier("file")
    private static let more = NSToolbarItem.Identifier("more")
    private static let search = NSToolbarItem.Identifier("search")
    private static let volumeSymbols = ["speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]

    let toolbar = NSToolbar(identifier: "viewer")
    private let splitView: NSSplitView
    private let perform: (Action) -> Void
    private let onSearch: (String) -> Void
    private var actions: [NSToolbarItem.Identifier: Action] = [:]
    private var playbackItems: [NSToolbarItem] = []
    private var fileItems: [NSToolbarItem] = []
    private let speedItem = NSToolbarItem(itemIdentifier: .init("speed"))
    private lazy var playItem = button("play", "play.fill", "Play", .playPause)
    private lazy var volumeItem = button("volume", "speaker.wave.3.fill", "Volume", .mute)
    private let searchItem = NSSearchToolbarItem(itemIdentifier: search)

    init(splitView: NSSplitView, perform: @escaping (Action) -> Void, onSearch: @escaping (String) -> Void) {
        self.splitView = splitView
        self.perform = perform
        self.onSearch = onSearch
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // A titled bordered item, not a label view: only those sit inside the group's glass capsule.
        speedItem.label = "Speed"
        speedItem.isBordered = true
        speedItem.autovalidates = false
        speedItem.target = self
        speedItem.action = #selector(clicked(_:))
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.searchField.target = self
        searchItem.searchField.action = #selector(searched(_:))
    }

    func update(plays: Bool, playing: Bool, speed label: String, volume: Float, hasFile: Bool) {
        playbackItems.forEach { $0.isEnabled = plays }
        fileItems.forEach { $0.isEnabled = hasFile }
        speedItem.title = plays ? label : Speed.label(1)
        playItem.image = symbol(playing ? "pause.fill" : "play.fill")
        playItem.label = playing ? "Pause" : "Play"
        let level = min(Int(volume * Float(Self.volumeSymbols.count)), Self.volumeSymbols.count - 1)
        volumeItem.image = symbol(volume == 0 ? "speaker.slash.fill" : Self.volumeSymbols[level])
    }

    func clearSearch() { searchItem.searchField.stringValue = "" }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.listSeparator, Self.playback, .flexibleSpace,
         Self.file, Self.more, Self.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.listSeparator: return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView, dividerIndex: 1)
        case Self.playback:
            playbackItems = [button("slower", "backward.fill", "Slower", .slower), playItem,
                             button("faster", "forward.fill", "Faster", .faster), speedItem]
            return group(id, "Playback", playbackItems)
        case Self.file:
            fileItems = [volumeItem, button("reveal", "folder", "Reveal in Finder", .reveal)]
            return group(id, "File", fileItems)
        case Self.more: return moreItem(id)
        case Self.search: return searchItem
        default: return nil
        }
    }

    private func moreItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let menu = NSMenu()
        for (title, action) in [("Remove from List", Action.remove), ("Settings\u{2026}", .settings)] {
            let item = menu.addItem(withTitle: title, action: #selector(menuChose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
        }
        menu.insertItem(.separator(), at: 1)
        let more = NSMenuToolbarItem(itemIdentifier: id)
        more.menu = menu
        more.image = symbol("ellipsis")
        more.label = "More"
        more.showsIndicator = false
        return more
    }

    private func group(_ id: NSToolbarItem.Identifier, _ label: String, _ items: [NSToolbarItem]) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.subitems = items
        group.label = label
        return group
    }

    private func button(_ id: String, _ symbolName: String, _ label: String, _ action: Action) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .init(id))
        item.image = symbol(symbolName)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.autovalidates = false
        item.target = self
        item.action = #selector(clicked(_:))
        actions[item.itemIdentifier] = action
        return item
    }

    private func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    @objc private func clicked(_ sender: NSToolbarItem) {
        if let action = actions[sender.itemIdentifier] { perform(action) }
    }

    @objc private func menuChose(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? Action { perform(action) }
    }

    @objc private func searched(_ sender: NSSearchField) { onSearch(sender.stringValue) }
}
