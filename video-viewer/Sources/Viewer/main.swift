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
            controller.remembersFiles = false
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

    @objc private func showSettings(_ sender: Any?) { Openers.show(commonExtensions) }

    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings\u{2026}", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Video Viewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Video Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
/// What the Settings window checks besides the extensions Info.plist names.
let commonExtensions = ("png jpg jpeg heic heif gif webp tiff tif bmp ico svg dng cr2 nef psd mp4 mov m4v avi 3gp mpg mpeg "
    + "mkv webm mp3 m4a wav flac aac aiff pdf").split(separator: " ").map(String.init)
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
