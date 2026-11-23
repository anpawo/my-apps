import AppKit

/// Starts a test copy of an app on a desktop he is not looking at: the copy has its own bundle id
/// (its settings and history stay apart from his copy) and takes as many instances as asked.
enum Launch {
    private static let windowWait: TimeInterval = 10
    private static let unhideSettle: useconds_t = 300_000

    /// Prints the window id of the new instance and returns true once it sits on that desktop.
    static func test(_ app: URL, files: [URL], on space: UInt64) -> Bool {
        guard let copy = testCopy(of: app) else { return false }
        let before = Set(instances(of: copy).map(\.processIdentifier))
        guard shell("/usr/bin/open", ["-g", "-j", "-n", "-a", copy.path] + files.map(\.path)) else { return false }
        let deadline = Date().addingTimeInterval(windowWait)
        while Date() < deadline {
            if let process = instances(of: copy).first(where: { !before.contains($0.processIdentifier) }),
               let window = mainWindow(of: process.processIdentifier) {
                guard Spaces.move(window, to: space) else { return false }
                process.unhide()
                usleep(unhideSettle)
                print(window)
                return true
            }
            usleep(50_000)
        }
        return false
    }

    /// `<Name> Test.app` beside the other test copies, rebuilt from the app each time.
    private static func testCopy(of app: URL) -> URL? {
        let name = app.deletingPathExtension().lastPathComponent
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("desks", isDirectory: true)
        let copy = folder.appendingPathComponent("\(name) Test.app")
        let plist = copy.appendingPathComponent("Contents/Info.plist").path
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: copy)
        guard (try? FileManager.default.copyItem(at: app, to: copy)) != nil,
              let info = NSMutableDictionary(contentsOfFile: plist),
              let id = info["CFBundleIdentifier"] as? String else { return nil }
        info["CFBundleIdentifier"] = id + ".test"
        info["CFBundleName"] = name + " Test"
        info["CFBundleDisplayName"] = name + " Test"
        info.removeObject(forKey: "LSMultipleInstancesProhibited")
        guard info.write(toFile: plist, atomically: true),
              shell("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", copy.path]) else { return nil }
        return copy
    }

    private static func instances(of copy: URL) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == copy.standardizedFileURL }
    }

    private static func mainWindow(of pid: pid_t) -> CGWindowID? {
        (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
            .first { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
                && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 100 }
            .flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    private static func shell(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
