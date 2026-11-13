import Foundation

public enum Target: String, CaseIterable, Codable {
    case screen, window, area
}

/// What the bar offers and how ⌘← ⌘→ move through it: the system's three stills.
public struct BarState: Equatable {
    public var target: Target

    public init(target: Target = .area) {
        self.target = target
    }

    /// Every button, left to right.
    public static let all: [BarState] = Target.allCases.map { BarState(target: $0) }

    public mutating func step(_ delta: Int) {
        let i = Self.all.firstIndex(of: self) ?? 0
        self = Self.all[(i + delta + Self.all.count) % Self.all.count]
    }

    /// Whether this target needs a rectangle before it can commit.
    public var needsSelection: Bool { target == .area }
}
