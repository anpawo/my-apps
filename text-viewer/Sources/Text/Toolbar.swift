import AppKit

extension NSToolbarItem.Identifier {
    static let fileGroup = Self("fileGroup")
    static let finderGroup = Self("finderGroup")
    static let search = Self("search")
}

/// Video Viewer's toolbar: the title over the editor, then two glass capsules and the search field.
extension MainWindow {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace, .fileGroup, .finderGroup, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .fileGroup:
            return group(id, [
                button("Open", "folder", #selector(AppDelegate.openDocument(_:))),
                button("Save", "square.and.arrow.down", #selector(AppDelegate.saveDocument(_:))),
            ])
        case .finderGroup:
            let reveal = button("Reveal in Finder", "finder", #selector(revealCurrent(_:)))
            reveal.target = self
            let more = NSMenuToolbarItem(itemIdentifier: .init("more"))
            more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
            more.label = "More"
            more.showsIndicator = false
            more.menu = moreMenu()
            return group(id, [reveal, more])
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search"
            item.searchField.target = self
            item.searchField.action = #selector(search(_:))
            return item
        default:
            return nil
        }
    }

    private func group(_ id: NSToolbarItem.Identifier, _ items: [NSToolbarItem]) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.subitems = items
        return group
    }

    /// Sent up the responder chain (target nil), so the app delegate's actions answer.
    private func button(_ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .init(label))
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.isBordered = true
        return item
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Close File", action: #selector(AppDelegate.closeFile(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Settings\u{2026}", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: "")
        return menu
    }

    @objc func revealCurrent(_ sender: Any?) {
        if let current { NSWorkspace.shared.activateFileViewerSelecting([current.url]) }
    }

    /// The toolbar's field drives the current file's find bar through the shared find pasteboard,
    /// which the bar reads.
    @objc func search(_ field: NSSearchField) {
        guard current != nil else { return }
        let board = NSPasteboard(name: .find)
        board.clearContents()
        board.setString(field.stringValue, forType: .string)
        for action in [NSTextFinder.Action.showFindInterface, .nextMatch] {
            let sender = NSMenuItem()
            sender.tag = action.rawValue
            textView.performTextFinderAction(sender)
        }
    }
}
