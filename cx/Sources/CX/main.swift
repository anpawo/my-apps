import AppKit
import SwiftUI

struct LaunchOptions {
    var cwd = FileManager.default.currentDirectoryPath
    var resume: String?
    var prompt = ""
    init(_ args: [String]) throws {
        var i = 0, words: [String] = []
        while i < args.count {
            switch args[i] {
            case "--cwd", "-C":
                i += 1; guard i < args.count else { throw CXError(message: "--cwd requires a folder.") }; cwd = (args[i] as NSString).expandingTildeInPath
            case "--resume", "-r":
                resume = "last"
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1; resume = args[i] }
            case "--": words += args.dropFirst(i + 1); i = args.count
            default:
                guard !args[i].hasPrefix("-") else { throw CXError(message: "Unknown option: " + args[i]) }
                words.append(args[i])
            }
            i += 1
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue else { throw CXError(message: "Working folder does not exist.") }
        prompt = words.joined(separator: " ")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    var session: Session?
    var options: LaunchOptions?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let options else { return }
        let session = Session(cwd: options.cwd)
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(session.folder) · Vibe Code X"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 780, height: 560)
        window.contentView = NSHostingView(rootView: CXView(session: session))
        window.backgroundColor = NSColor(white: 0.035, alpha: 1)
        window.delegate = self; window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VCXWindow")
        window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        NSApp.activate(ignoringOtherApps: true)
        let menu = NSMenu(), appMenu = NSMenu(), fileMenu = NSMenu(), editMenu = NSMenu()
        let app = NSMenuItem(); app.submenu = appMenu; menu.addItem(app)
        appMenu.addItem(withTitle: "About Vibe Code X", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Quit Vibe Code X", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); file.submenu = fileMenu; menu.addItem(file)
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "N")
        fileMenu.addItem(withTitle: "Open Project…", action: #selector(openProject), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); edit.submenu = editMenu; menu.addItem(edit)
        for (name, selector, key) in [("Undo", #selector(UndoManager.undo), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(withTitle: name, action: selector, keyEquivalent: key) }
        NSApp.mainMenu = menu
        Task { await session.connect(resume: options.resume, prompt: options.prompt) }
    }
    @objc func openProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.begin { result in if result == .OK, let url = panel.url { self.openWindow(cwd: url.path) } }
    }
    @objc func newWindow() { openWindow(cwd: session?.cwd ?? NSHomeDirectory()) }
    func openWindow(cwd: String) {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let config = NSWorkspace.OpenConfiguration(); config.createsNewApplicationInstance = true; config.arguments = ["--cwd", cwd]
        NSWorkspace.shared.openApplication(at: bundle, configuration: config)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { session?.close() }
}

MainActor.assumeIsolated {
signal(SIGPIPE, SIG_IGN)
let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--version") { print("vcx 0.2.0 (Vibe Code X)"); exit(0) }
if args.contains("--help") { print("vcx [--cwd FOLDER] [--resume [ID]] [PROMPT]\nEach launch opens an independent Vibe Code X window. Use cx --terminal for the previous terminal interface."); exit(0) }
if args.contains("--check") || args.contains("--render") || args.contains("--icon") {
    setenv("VCX_CONFIG_HOME", (NSTemporaryDirectory() + "vcx-preview-" + UUID().uuidString), 1)
}
let app = NSApplication.shared
if let index = args.firstIndex(of: "--icon"), index + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    Render.write(AppIcon(), size: CGSize(width: 1024, height: 1024), path: args[index + 1]); exit(0)
}
if let index = args.firstIndex(of: "--render"), index + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    Render.run(directory: args[index + 1]); exit(0)
}
if let index = args.firstIndex(of: "--live-check"), index + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    Task { let ok = await Check.live(settings: args[index + 1]); exit(ok ? 0 : 1) }
    RunLoop.main.run()
} else if args.contains("--check") {
    app.setActivationPolicy(.prohibited)
    Task { let ok = await Check.run(); exit(ok ? 0 : 1) }
    RunLoop.main.run()
} else {
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    do { delegate.options = try LaunchOptions(args) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(2) }
    app.delegate = delegate
    app.run()
}

}
