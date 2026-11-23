import Foundation

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
