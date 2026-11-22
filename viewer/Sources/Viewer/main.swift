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
            controller.add(render.files)
            DispatchQueue.main.asyncAfter(deadline: .now() + renderSettleDelay) { [self] in
                exit(draw(controller.window, to: render.out) ? 0 : 1)
            }
            return
        }
        controller.registerGlobalKeys()
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard render == nil else { return }
        controller.add(urls)
        controller.window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func draw(_ window: NSWindow, to out: URL) -> Bool {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: out)) != nil
    }

    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Viewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for menu in [appMenu, windowMenu] {
            main.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        NSApp.windowsMenu = windowMenu
        return main
    }
}

// `Viewer --render out.png file...`: lays the window out offscreen with the files loaded (the
// first one selected), draws it into a PNG and exits. Nothing appears on screen.
let arguments = CommandLine.arguments
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
