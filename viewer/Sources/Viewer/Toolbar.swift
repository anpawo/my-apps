import AppKit
import ViewerCore

/// Notes' unified toolbar: glass capsule groups over the viewer and the search field;
/// playback sits on the video itself (Controls).
/// The speaker drawn for a volume: crossed out at zero, then one to three waves.
func volumeSymbol(_ volume: Float) -> String {
    let symbols = ["speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]
    return volume == 0 ? "speaker.slash.fill" : symbols[min(Int(volume * Float(symbols.count)), symbols.count - 1)]
}

@MainActor final class Toolbar: NSObject, NSToolbarDelegate {
    private static let sidebar = NSToolbarItem.Identifier("sidebar")
    private static let volume = NSToolbarItem.Identifier("volume")
    private static let more = NSToolbarItem.Identifier("more")
    private static let search = NSToolbarItem.Identifier("search")

    let toolbar = NSToolbar(identifier: "viewer")
    private let splitView: NSSplitView
    private let perform: (Action) -> Void
    private let onSearch: (String) -> Void
    private var actions: [NSToolbarItem.Identifier: Action] = [:]
    private lazy var volumeItem = button(Self.volume.rawValue, "speaker.wave.3.fill", "Volume", .mute)
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

    func update(volume: Float, hasFile: Bool, plays: Bool) {
        volumeItem.isEnabled = hasFile
        volumeItem.isHidden = !plays
        volumeItem.image = symbol(volumeSymbol(volume))
    }

    func clearSearch() { searchItem.searchField.stringValue = "" }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.volume, Self.more, Self.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.sidebar: return sidebarItem(id)
        case Self.volume: return volumeItem
        case Self.more: return moreItem(id)
        case Self.search: return searchItem
        default: return nil
        }
    }

    private func moreItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let menu = NSMenu()
        for (title, action) in [("Reveal in Finder", Action.reveal), ("Remove from List", .remove), ("Settings\u{2026}", .settings)] {
            let item = menu.addItem(withTitle: title, action: #selector(menuChose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
        }
        menu.insertItem(.separator(), at: 2)
        let more = NSMenuToolbarItem(itemIdentifier: id)
        more.menu = menu
        more.image = symbol("ellipsis")
        more.label = "More"
        more.showsIndicator = false
        return more
    }

    /// AppKit's own toggle is drawn bare over the sidebar and in a glass circle beside it, so it changed
    /// size on each click; unbordered, it stays bare in both places.
    private func sidebarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = symbol("sidebar.left")
        item.label = "Sidebar"
        item.toolTip = "Show or hide the sidebar"
        item.isBordered = false
        item.action = #selector(NSSplitViewController.toggleSidebar(_:))
        return item
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
