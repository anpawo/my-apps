import AppKit
import ViewerCore

/// Notes' unified toolbar: the sidebar toggle, then glass capsule groups over the viewer and the search field;
/// playback sits on the video itself (Controls).
@MainActor final class Toolbar: NSObject, NSToolbarDelegate {
    private static let file = NSToolbarItem.Identifier("file")
    private static let more = NSToolbarItem.Identifier("more")
    private static let search = NSToolbarItem.Identifier("search")
    private static let volumeSymbols = ["speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]

    let toolbar = NSToolbar(identifier: "viewer")
    private let splitView: NSSplitView
    private let perform: (Action) -> Void
    private let onSearch: (String) -> Void
    private var actions: [NSToolbarItem.Identifier: Action] = [:]
    private var fileItems: [NSToolbarItem] = []
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
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.searchField.target = self
        searchItem.searchField.action = #selector(searched(_:))
    }

    func update(volume: Float, hasFile: Bool) {
        fileItems.forEach { $0.isEnabled = hasFile }
        let level = min(Int(volume * Float(Self.volumeSymbols.count)), Self.volumeSymbols.count - 1)
        volumeItem.image = symbol(volume == 0 ? "speaker.slash.fill" : Self.volumeSymbols[level])
    }

    func clearSearch() { searchItem.searchField.stringValue = "" }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.file, Self.more, Self.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
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
