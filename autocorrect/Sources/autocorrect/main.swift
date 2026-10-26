import AppKit

let args = CommandLine.arguments
// In the app, the bundle's copy; from `swift run`, the package's.
let wordsFile = Bundle.main.url(forResource: "words", withExtension: "tsv")
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/words.tsv").standardized
let learnedFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/autocorrect/learned.json")

if args.contains("--selftest") { exit(SelfCheck.run(wordsFile) == 0 ? 0 : 1) }

// `--fix`: stdin as it would read once typed, a line at a time. Learns nothing on disk.
if args.contains("--fix") {
    var typist = Typist(Words(file: wordsFile, learned: nil))
    while let line = readLine() { print(typist.fix(line)) }
    exit(0)
}

final class App: NSObject, NSApplicationDelegate {
    var words: Words!
    var tap: Tap!

    func applicationDidFinishLaunching(_ note: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("key listener")
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me && ($0.launchDate ?? .distantPast) <= (me.launchDate ?? .now) }) {
            NSLog("autocorrect: already running")
            exit(0)
        }
        words = Words(file: wordsFile, learned: learnedFile)
        tap = Tap(words)
        // ponytail: what he typed in the last minute is lost if the app is killed; save on SIGTERM if that matters.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.words.save() }
        // The first launch asks for Accessibility; the tap starts as soon as it is granted.
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted(), let self else { return }
            timer.invalidate()
            NSLog(self.tap.start() ? "autocorrect: listening (\(self.words.count) words)" : "autocorrect: the key tap was refused")
        }
    }

    func applicationWillTerminate(_ note: Notification) { words?.save() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
