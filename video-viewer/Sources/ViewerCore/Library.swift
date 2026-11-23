import Foundation

public struct Entry: Equatable {
    public let url: URL
    public let kind: Kind
    public let modified: Date

    public init(url: URL, kind: Kind, modified: Date) {
        self.url = url.standardizedFileURL
        self.kind = kind
        self.modified = modified
    }
}

/// Every file loaded, the search filtering them, and the one shown.
public struct Library {
    public private(set) var entries: [Entry] = []
    public private(set) var current: URL?
    public private(set) var query = ""

    public init() {}

    /// What the list shows, in the order the files were opened: the order ↑/↓ walk.
    public var shown: [Entry] {
        entries.filter { query.isEmpty || $0.url.lastPathComponent.localizedStandardContains(query) }
    }

    public var currentEntry: Entry? { entries.first { $0.url == current } }

    /// Appends the files not listed yet and shows the first one passed; when the search hides it,
    /// the search is cleared so it can be seen.
    public mutating func add(_ new: [Entry]) {
        for entry in new where !entries.contains(where: { $0.url == entry.url }) { entries.append(entry) }
        guard let first = new.first else { return }
        current = first.url
        if !shown.contains(where: { $0.url == first.url }) { query = "" }
    }

    public mutating func filter(query: String) {
        self.query = query
        if !shown.contains(where: { $0.url == current }) { current = shown.first?.url }
    }

    public mutating func select(_ url: URL) {
        if shown.contains(where: { $0.url == url }) { current = url }
    }

    public mutating func move(by delta: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        guard let index = list.firstIndex(where: { $0.url == current }) else { current = list.first?.url; return }
        current = list[min(max(index + delta, 0), list.count - 1)].url
    }

    /// Shows the item that takes the removed one's place in the list, or the one before at the end.
    public mutating func removeCurrent() {
        let list = shown
        guard let index = list.firstIndex(where: { $0.url == current }) else { return }
        entries.removeAll { $0.url == current }
        let rest = shown
        current = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].url
    }
}

/// The files opened last, newest first, kept across launches: the sidebar's Recent section.
public enum Recent {
    /// More are kept than shown, so the files open in the window do not empty the list.
    public static let kept = 20
    public static let shown = 3

    public static func adding(_ path: String, to list: [String]) -> [String] {
        Array(([path] + list.filter { $0 != path }).prefix(kept))
    }

    public static func shown(_ list: [String], open: Set<String>) -> [String] {
        Array(list.filter { !open.contains($0) }.prefix(shown))
    }
}

/// The dimmed part of a row's second line.
public enum Details {
    private static let secondsPerMinute = 60
    private static let secondsPerHour = 3600

    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / secondsPerHour, total % secondsPerHour / secondsPerMinute, total % secondsPerMinute)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func pixels(_ width: Int, _ height: Int) -> String { "\(width) × \(height)" }

    public static func pages(_ count: Int) -> String { count == 1 ? "1 page" : "\(count) pages" }

    public static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }
}
