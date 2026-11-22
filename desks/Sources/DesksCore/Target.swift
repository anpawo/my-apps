/// Which desktop a command names: a number counted from 1 as Mission Control shows them, or a
/// step from the current one.
public enum Target: Equatable {
    case number(Int)
    case next
    case previous

    public init?(_ word: String) {
        switch word {
        case "next": self = .next
        case "prev", "previous": self = .previous
        default:
            guard let n = Int(word), n >= 1 else { return nil }
            self = .number(n)
        }
    }

    /// The 0-based index to go to, or nil when there is nowhere to go. Never past either end:
    /// a swipe beyond the last desktop wedges the Dock on recent macOS (InstantSpaceSwitcher).
    public func index(from current: Int, count: Int) -> Int? {
        let wanted: Int
        switch self {
        case .number(let n): wanted = min(n - 1, count - 1)
        case .next: wanted = current + 1
        case .previous: wanted = current - 1
        }
        guard wanted >= 0, wanted < count, wanted != current else { return nil }
        return wanted
    }
}
