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

public struct Section: Equatable {
    public let title: String
    public let entries: [Entry]
}

/// Every file loaded, the search filtering them, and the one shown.
public struct Library {
    public private(set) var entries: [Entry] = []
    public private(set) var current: URL?
    public private(set) var query = ""

    public init() {}

    /// What the list shows, newest first: the order ↑/↓ walk.
    public var shown: [Entry] {
        entries.filter { query.isEmpty || $0.url.lastPathComponent.localizedStandardContains(query) }
            .sorted { $0.modified != $1.modified ? $0.modified > $1.modified
                : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    public func sections(now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        var sections: [Section] = []
        for entry in shown {
            let title = DateGroup.title(for: entry.modified, now: now, calendar: calendar)
            if sections.last?.title == title {
                sections[sections.count - 1] = Section(title: title, entries: sections[sections.count - 1].entries + [entry])
            } else {
                sections.append(Section(title: title, entries: [entry]))
            }
        }
        return sections
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

/// Notes' date sections and row dates.
public enum DateGroup {
    static let weekDays = 7
    static let monthDays = 30
    private static let english = Locale(identifier: "en_US_POSIX")

    public static func title(for date: Date, now: Date, calendar: Calendar) -> String {
        let days = daysBetween(date, now, calendar)
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < weekDays { return "Previous 7 Days" }
        if days < monthDays { return "Previous 30 Days" }
        let year = calendar.component(.year, from: date)
        guard year == calendar.component(.year, from: now) else { return String(year) }
        return DateFormatter().with(english).standaloneMonthSymbols[calendar.component(.month, from: date) - 1]
    }

    /// The time today, "Yesterday", the weekday within a week, else the short date.
    public static func rowDate(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = daysBetween(date, now, calendar)
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        if days <= 0 { format.timeStyle = .short; return format.string(from: date) }
        if days == 1 { return "Yesterday" }
        if days < weekDays {
            return format.with(english).weekdaySymbols[calendar.component(.weekday, from: date) - 1]
        }
        format.dateStyle = .short
        return format.string(from: date)
    }

    private static func daysBetween(_ date: Date, _ now: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    }
}

private extension DateFormatter {
    func with(_ locale: Locale) -> DateFormatter {
        self.locale = locale
        return self
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
