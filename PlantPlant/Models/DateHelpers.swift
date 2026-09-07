import Foundation

extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    /// True when this date's calendar day is today or earlier — i.e. a task due then is due now.
    /// Comparing whole calendar days (rather than against a fixed end-of-day instant) avoids
    /// missing the final second of the day when the date carries a time-of-day component.
    var isDueByToday: Bool { daysFromToday <= 0 }

    /// Number of whole days from today (00:00) to this date's day. Negative = in the past.
    var daysFromToday: Int {
        let cal = Calendar.current
        let from = cal.startOfDay(for: .now)
        let to = cal.startOfDay(for: self)
        return cal.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// A short, human friendly relative description ("Today", "Tomorrow", "in 3 days", "2 days ago").
    var relativeDueDescription: String {
        let days = daysFromToday
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        case -1: return String(localized: "Yesterday")
        case let d where d < 0: return String(localized: "\(-d) days ago")
        default: return String(localized: "in \(days) days")
        }
    }
}
