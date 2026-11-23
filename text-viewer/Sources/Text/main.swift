import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let tabKeyCode: UInt16 = 48
    lazy var main = MainWindow()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Menu.build(target: self)
        // ⌃Tab never reaches a menu item: the text view takes it as a focus move first.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let self, event.keyCode == Self.tabKeyCode, flags.contains(.control) else { return event }
            main.cycle(flags.contains(.shift) ? -1 : 1)
            return nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        main.window.makeKeyAndOrderFront(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        main.open(urls)
        main.window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        main.closeAll() ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { main.open(panel.urls) }
    }

    @objc func showSettings(_ sender: Any?) { Openers.show(commonExtensions) }
    @objc func saveDocument(_ sender: Any?) { main.saveCurrent() }
    @objc func closeFile(_ sender: Any?) { main.closeCurrent() }
    @objc func nextFile(_ sender: Any?) { main.cycle(1) }
    @objc func previousFile(_ sender: Any?) { main.cycle(-1) }
}

enum Menu {
    static func build(target: AppDelegate) -> NSMenu {
        let bar = NSMenu()
        add(to: bar, "Text Viewer", [
            item("About Text Viewer", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(),
            item("Settings\u{2026}", #selector(AppDelegate.showSettings(_:)), ",", target), .separator(),
            item("Hide Text Viewer", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Text Viewer", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add(to: bar, "File", [
            item("Open\u{2026}", #selector(AppDelegate.openDocument(_:)), "o", target),
            item("Save", #selector(AppDelegate.saveDocument(_:)), "s", target),
            item("Close File", #selector(AppDelegate.closeFile(_:)), "w", target),
        ])
        add(to: bar, "Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "Z"), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"), .separator(),
            find("Find\u{2026}", .showFindInterface, "f"), find("Find and Replace\u{2026}", .showReplaceInterface, "f", [.command, .option]),
            find("Find Next", .nextMatch, "g"), find("Find Previous", .previousMatch, "G"),
            find("Use Selection for Find", .setSearchString, "e"),
        ])
        add(to: bar, "Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Next File", #selector(AppDelegate.nextFile(_:)), "\t", target, [.control]),
            item("Previous File", #selector(AppDelegate.previousFile(_:)), "\t", target, [.control, .shift]),
        ])
        return bar
    }

    static func add(to bar: NSMenu, _ title: String, _ items: [NSMenuItem]) {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        bar.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
    }

    static func item(_ title: String, _ action: Selector, _ key: String = "", _ target: AnyObject? = nil,
                     _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    static func find(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                     _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, nil, modifiers)
        item.tag = action.rawValue
        return item
    }
}

/// What the Settings window checks besides the extensions Info.plist names.
let commonExtensions = ("txt md markdown log csv tsv json yaml yml xml plist swift py js mjs ts c h cpp hpp m mm java "
    + "sh bash zsh rb php pl lua css html tex bib diff patch").split(separator: " ").map(String.init)

let app = NSApplication.shared
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-settings"), args.count > i + 1 {
    exit(MainActor.assumeIsolated { Openers.render(commonExtensions, to: URL(fileURLWithPath: args[i + 1])) } ? 0 : 1)
}
if let i = args.firstIndex(of: "--render"), args.count > i + 1 {
    Render.run(out: URL(fileURLWithPath: args[i + 1]), files: args[(i + 2)...].map { URL(fileURLWithPath: $0) })
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
