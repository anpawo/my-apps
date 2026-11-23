import AppKit

/// Time for thumbnails and the first frames to arrive before `--render` draws.
private let renderSettleDelay = 2.0

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: Controller!
    private let render: (out: URL, files: [URL])?

    init(render: (out: URL, files: [URL])?) {
        self.render = render
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        controller = Controller()
        NSApp.mainMenu = mainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let render {
            // The README picture shows the list.
            controller.showSidebar()
            controller.add(render.files)
            DispatchQueue.main.asyncAfter(deadline: .now() + renderSettleDelay) { [self] in
                exit(Render.draw(controller.window, to: render.out) ? 0 : 1)
            }
            return
        }
        // Launched hidden (`open -j`, how `desks launch` starts a test copy on another desktop): no
        // activation, which would pull him to that desktop, and the global keys stay with his copy.
        let background = NSApp.isHidden
        if !background { controller.registerGlobalKeys() }
        controller.window.makeKeyAndOrderFront(nil)
        // After one run-loop turn: before it the columns have no width yet and the viewer reads as empty.
        DispatchQueue.main.async { [self] in controller.fit.fillScreen() }
        if !background { NSApp.activate() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard render == nil else { return }
        controller.add(urls)
        controller.window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.closeAll() ? .terminateNow : .terminateCancel
    }

    @objc private func showSettings(_ sender: Any?) { Openers.show(commonExtensions) }
    @objc private func saveDocument(_ sender: Any?) { controller.saveCurrent() }
    @objc private func closeFile(_ sender: Any?) { controller.closeCurrent() }

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { controller.add(panel.urls) }
    }

    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = menu("Viewer", [
            item("Settings\u{2026}", #selector(showSettings(_:)), ","), .separator(),
            item("Hide Viewer", #selector(NSApplication.hide(_:)), "h"), .separator(),
            item("Quit Viewer", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let fileMenu = menu("File", [
            item("Open\u{2026}", #selector(openDocument(_:)), "o"),
            item("Save", #selector(saveDocument(_:)), "s"),
            item("Close File", #selector(closeFile(_:)), "w"),
        ])
        let editMenu = menu("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "Z"), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            find("Find\u{2026}", .showFindInterface, "f"),
            find("Find and Replace\u{2026}", .showReplaceInterface, "f", [.command, .option]),
            find("Find Next", .nextMatch, "g"), find("Find Previous", .previousMatch, "G"),
            find("Use Selection for Find", .setSearchString, "e"),
        ])
        let windowMenu = menu("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        for menu in [appMenu, fileMenu, editMenu, windowMenu] {
            main.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        NSApp.windowsMenu = windowMenu
        return main
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        return menu
    }

    /// Items with no target go up the responder chain (the text view, the window); ours come here.
    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if responds(to: action) { item.target = self }
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func find(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                      _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, modifiers)
        item.tag = action.rawValue
        return item
    }
}

// `Viewer --render out.png file...`: lays the window out offscreen with the files loaded (the
// first one selected), draws it into a PNG and exits. Nothing appears on screen.
let arguments = CommandLine.arguments
/// What the Settings window checks besides the extensions Info.plist names.
let commonExtensions = ("png jpg jpeg heic heif gif webp tiff tif bmp ico svg dng cr2 nef psd mp4 mov m4v avi 3gp mpg mpeg "
    + "mkv webm mp3 m4a wav flac aac aiff pdf txt md markdown log csv tsv json yaml yml xml plist swift py js mjs ts c h "
    + "cpp hpp m mm java sh bash zsh rb php pl lua css html tex bib diff patch").split(separator: " ").map(String.init)
if arguments.count > 2 && arguments[1] == "--render-settings" {
    exit(MainActor.assumeIsolated { Openers.render(commonExtensions, to: URL(fileURLWithPath: arguments[2])) } ? 0 : 1)
}
let render = arguments.count > 2 && arguments[1] == "--render"
    ? (out: URL(fileURLWithPath: arguments[2]), files: arguments.dropFirst(3).map { URL(fileURLWithPath: $0) })
    : nil
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(render == nil ? .regular : .prohibited)
    let delegate = AppDelegate(render: render)
    app.delegate = delegate
    app.run()
}
