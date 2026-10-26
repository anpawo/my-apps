import AppKit
import Carbon.HIToolbox
import ScreenshotCore

@MainActor
final class App: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        // An agent with no window is a candidate for automatic termination; that is how it
        // "crashed" without a crash report.
        ProcessInfo.processInfo.disableAutomaticTermination("hotkey listener")
        ProcessInfo.processInfo.disableSuddenTermination()
        if let i = CommandLine.arguments.firstIndex(of: "--render-docs") {
            Docs.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-demo") {
            Docs.demo(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
        Capture.prefetch()
        if let i = CommandLine.arguments.firstIndex(of: "--render-bar") {
            // The bar as a PNG, never shown: how its look gets checked without a window.
            Session.shared.selection = CGRect(x: 0, y: 0, width: 10, height: 10)
            let bar = Bar(session: Session.shared, on: NSScreen.main!)
            try? bar.render()?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
        if CommandLine.arguments.contains("--screen") {
            // Headless check: every display to the folder, then exit.
            Task {
                for s in NSScreen.screens {
                    do { print(try Output.save(try await Capture.screen(s), scale: s.backingScaleFactor).path) }
                    catch { print("error: \(error.localizedDescription)"); exit(1) }
                }
                exit(0)
            }
            return
        }
        // Two copies (a login item next to the LaunchAgent) both take ⌘⇧5 and stack two overlays:
        // a click closes the top one and uncovers the other. The newer one leaves.
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me && ($0.launchDate ?? .distantPast) <= (me.launchDate ?? .now) }) {
            NSLog("screenshot: already running")
            exit(0)
        }
        HotKey.register(key: kVK_ANSI_5, modifiers: cmdKey | shiftKey, id: 1) {
            Task { @MainActor in Session.shared.toggle() }
        }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { App() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
