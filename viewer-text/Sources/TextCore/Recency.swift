import Foundation

/// How Notes dates its list: the section a file falls in, and the stamp before its preview.
public enum Recency {
    public static let week = 7
    public static let month = 30

    public static func section(of date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = daysBetween(date, now, calendar)
        if days <= 0 { return "Today" }
        if days <= week { return "Previous 7 Days" }
        if days <= month { return "Previous 30 Days" }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return format(date, sameYear ? "LLLL" : "LLLL yyyy", calendar)
    }

    /// The time today, the weekday within the week, the date before that.
    public static func stamp(of date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = daysBetween(date, now, calendar)
        if days <= 0 { return format(date, "HH:mm", calendar) }
        if days < week { return format(date, "EEEE", calendar) }
        return format(date, "dd/MM/yyyy", calendar)
    }

    /// The editor's heading: "November 16, 2026 at 14:48".
    public static func long(_ date: Date, calendar: Calendar = .current) -> String {
        format(date, "MMMM d, yyyy 'at' HH:mm", calendar)
    }

    private static func daysBetween(_ date: Date, _ now: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    }

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        // Everything the app shows is English, whatever the Mac's language.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
