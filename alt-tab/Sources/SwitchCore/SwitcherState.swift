import CoreGraphics

/// What the trigger can say. Deliberately without an `.open` case: `.next` on an idle
/// machine opens, `.next` on an open one advances. All the state lives here, so the trigger
/// is stateless and cannot tell the first Tab from the third — which is what lets ⌘Tab and a
/// rebound chord emit identical streams.
public enum SwitchCommand: Equatable {
    case next
    /// One step back. Only meaningful while open: nothing opens the panel backwards.
    case previous
    /// A whole row, up or down, by however many tiles the panel puts on one. Clamped rather
    /// than wrapped: the last row is short, so a row down from the one above it has to land on
    /// its last tile rather than on nothing.
    case jump(Int)
    /// A window named outright rather than stepped to — the pointer clicking a tile. It commits
    /// in the same breath, because a click is the whole gesture and there is no modifier left
    /// to release afterwards.
    case pick(CGWindowID)
    /// A letter typed with the modifier still held: narrows the list to the windows it names.
    case type(Character)
    /// The last typed letter taken back.
    case erase
    case commit
    case cancel
    case abort
}

/// What the shell must do about it. `.raise` closes the panel and hands focus to the chosen
/// window; `.hide` closes it and gives focus back to where it came from. Cancel emits
/// `.hide`, never `.raise` — an invariant that holds whether or not the panel activates.
public enum Effect: Equatable {
    case show([WindowInfo], Int)
    case move(Int)
    case hide
    case raise(WindowInfo)
    /// The typed letters, the windows they leave out, and the selection among those left.
    case filter(String, Set<CGWindowID>, Int)
    /// A letter that would have left no window: shown as refused, and not kept.
    case reject(Character)
}

public struct SwitcherState {

    /// Selection is a window id, never an index. An index goes stale the moment the list
    /// moves under it, and then the *default* pick silently re-derives while the *user's*
    /// pick does not — which is the shape of the bug, not a crash.
    private var selected: CGWindowID?
    /// Where the selection sat before the list changed, so a closed window hands its place to
    /// the one that takes it rather than sending the selection back to the start.
    private var previousIndex = 0
    public private(set) var query = ""

    public init() {}

    public var isOpen: Bool { selected != nil }

    /// A window fits when one word of its application name or title starts with the letters.
    public static func matches(_ window: WindowInfo, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        return (window.appName + " " + window.title)
            .split { !$0.isLetter && !$0.isNumber }
            .contains { $0.lowercased().hasPrefix(needle) }
    }

    public func dimmed(in windows: [WindowInfo]) -> Set<CGWindowID> {
        Set(windows.filter { !Self.matches($0, query) }.map(\.id))
    }

    /// The indices Tab can land on.
    private func allowed(_ windows: [WindowInfo]) -> [Int] {
        windows.indices.filter { Self.matches(windows[$0], query) }
    }

    /// Re-states the panel over a list that has changed underneath it — a window closed, or
    /// simply gone.
    ///
    /// The selection is kept by identity when the window is still there and falls back to the
    /// same position otherwise, which is what makes closing several in a row feel like a list
    /// and not like a reset.
    public mutating func refresh(_ windows: [WindowInfo]) -> Effect? {
        guard let current = selected else { return nil }
        guard !windows.isEmpty else {
            selected = nil
            return .hide
        }
        if let index = windows.firstIndex(where: { $0.id == current }) {
            return .show(windows, index)
        }
        if allowed(windows).isEmpty { query = "" }
        let open = allowed(windows)
        let start = min(previousIndex, windows.count - 1)
        let index = open.first(where: { $0 >= start }) ?? open.last!
        selected = windows[index].id
        return .show(windows, index)
    }

    public mutating func handle(_ command: SwitchCommand, windows: [WindowInfo]) -> Effect? {
        switch command {
        case .next:
            guard !windows.isEmpty else { return nil }
            guard let current = selected else {
                // Opening. Landing on index 1 is the product: one ⌘Tab goes to the window you
                // were on before this one, and a second brings you back.
                let start = min(1, windows.count - 1)
                query = ""
                selected = windows[start].id
                previousIndex = start
                return .show(windows, start)
            }
            let open = allowed(windows)
            let at = open.firstIndex(of: windows.firstIndex(where: { $0.id == current }) ?? 0) ?? 0
            let next = open[(at + 1) % open.count]
            selected = windows[next].id
            previousIndex = next
            return .move(next)

        case .previous:
            guard let current = selected, !windows.isEmpty else { return nil }
            let open = allowed(windows)
            let at = open.firstIndex(of: windows.firstIndex(where: { $0.id == current }) ?? 0) ?? 0
            let prev = open[(at - 1 + open.count) % open.count]
            selected = windows[prev].id
            previousIndex = prev
            return .move(prev)

        case let .jump(stride):
            guard let current = selected, !windows.isEmpty else { return nil }
            let i = windows.firstIndex(where: { $0.id == current }) ?? 0
            // Clamped to the end rather than wrapped, so the column lands on the short last
            // row's last tile instead of on nothing. Guarded on the row actually changing: from
            // the top row up, or the bottom row down, the clamp would slide sideways.
            let target = min(max(i + stride, 0), windows.count - 1)
            guard i / abs(stride) != target / abs(stride),
                  Self.matches(windows[target], query) else { return nil }
            selected = windows[target].id
            previousIndex = target
            return .move(target)

        case let .pick(id):
            // Unguarded by `isOpen`: a tile can only be clicked while the panel is up, and the
            // click is answered by the window it named, not by whatever the keyboard had.
            guard let window = windows.first(where: { $0.id == id }),
                  Self.matches(window, query) else { return nil }
            selected = nil
            return .raise(window)

        case let .type(letter):
            guard isOpen else { return nil }
            let candidate = query + String(letter).lowercased()
            guard let first = windows.firstIndex(where: { Self.matches($0, candidate) }) else {
                return .reject(letter)
            }
            query = candidate
            selected = windows[first].id
            previousIndex = first
            return .filter(query, dimmed(in: windows), first)

        case .erase:
            guard let current = selected, !query.isEmpty else { return nil }
            query.removeLast()
            return .filter(query, dimmed(in: windows),
                           windows.firstIndex(where: { $0.id == current }) ?? 0)

        case .commit:
            // A modifier released while nothing is open is the common case, not an error:
            // every ⌘ press in normal typing arrives here.
            guard let current = selected else { return nil }
            selected = nil
            guard let window = windows.first(where: { $0.id == current }) else { return .hide }
            return .raise(window)

        case .cancel, .abort:
            guard selected != nil else { return nil }
            selected = nil
            return .hide
        }
    }
}
