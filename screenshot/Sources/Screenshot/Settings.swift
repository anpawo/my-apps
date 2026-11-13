import Foundation
import ScreenshotCore

/// `defaults write com.mr.screenshot <key> <value>` and the settings above the bar write the same keys.
enum Settings {
    private static let d = UserDefaults.standard

    /// Every folder a capture is written to; several at once is fine. Empty means the
    /// clipboard only (the file then lives in the history folder).
    static var folders: [URL] {
        get { (d.stringArray(forKey: "folders") ?? ["~/Desktop"]).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } }
        set { d.set(newValue.map(\.path), forKey: "folders") }
    }
    static var folder: URL { folders.first ?? history }
    /// A home that renamed Desktop and Downloads (desk, dwl) is offered those, not folders macOS would bring back.
    static var standardFolders: [(String, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [("Desktop", "desk"), ("Downloads", "dwl"), ("Documents", "Documents")].map { name, short in
            let own = home.appendingPathComponent(short)
            return FileManager.default.fileExists(atPath: own.path) ? (short, own) : (name, home.appendingPathComponent(name))
        }
    }
    static func toggle(folder dir: URL) {
        if let i = folders.firstIndex(where: { $0.path == dir.path }) { folders.remove(at: i) } else { folders.append(dir) }
    }
    /// Seconds before a timed capture; 0 is immediate.
    static var timer: Int {
        get { d.integer(forKey: "timer") }
        set { d.set(newValue, forKey: "timer") }
    }
    static var cursor: Bool {
        get { d.bool(forKey: "cursor") }
        set { d.set(newValue, forKey: "cursor") }
    }
    static var copies: Bool {
        get { d.object(forKey: "copy") as? Bool ?? true }
        set { d.set(newValue, forKey: "copy") }
    }
    static var thumbnail: Bool {
        get { d.object(forKey: "thumbnail") as? Bool ?? true }
        set { d.set(newValue, forKey: "thumbnail") }
    }

    /// The built-in panel's corner radius in points. No API reports it, 12 got cut: a calibration
    /// knob, `defaults write com.mr.screenshot screenCorner -float 20`.
    static var screenCorner: CGFloat { d.object(forKey: "screenCorner") as? CGFloat ?? 18 }

    static var bar: BarState {
        get { BarState(target: Target(rawValue: d.string(forKey: "target") ?? "") ?? .area) }
        set { d.set(newValue.target.rawValue, forKey: "target") }
    }
    /// The last rectangle, in AppKit global points.
    static var lastRect: CGRect? {
        get { d.string(forKey: "rect").map { NSRectFromString($0) }.flatMap { $0.isEmpty ? nil : $0 } }
        set { d.set(newValue.map { NSStringFromRect($0) }, forKey: "rect") }
    }

    static let history = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("screenshot")
    static let historySize = 20
}
