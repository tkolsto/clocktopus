import Foundation

/// Groups timestamps into "work days" that begin at a configurable hour rather
/// than midnight, so a session running past midnight stays on a single day.
/// `dayStartHour == 0` reproduces the plain calendar-midnight boundary.
public struct WorkdayCalendar: Sendable {
    public let dayStartHour: Int          // 0...23
    public let calendar: Calendar

    public init(dayStartHour: Int, timeZone: TimeZone) {
        self.dayStartHour = max(0, min(23, dayStartHour))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        // ISO 8601 weeks (Monday start, week 1 holds Jan 4) regardless of the
        // system locale — a bare gregorian Calendar defaults to US Sunday-start
        // weeks, which mislabels week numbers for Norwegian payroll/xledger.
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        self.calendar = cal
    }

    /// Midnight of the calendar day this timestamp logically belongs to.
    /// Times before `dayStartHour` belong to the previous calendar day.
    public func logicalDayMidnight(for date: Date) -> Date {
        let shifted = calendar.date(byAdding: .hour, value: -dayStartHour, to: date)!
        return calendar.startOfDay(for: shifted)
    }

    /// The `[start, end)` interval of the work day containing `date`.
    public func dayInterval(for date: Date) -> DateInterval {
        let start = calendar.date(byAdding: .hour, value: dayStartHour,
                                  to: logicalDayMidnight(for: date))!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    /// Exact durations inside the requested logical days, clipping both edges
    /// and splitting spans at each workday boundary (also for chart ghosts).
    public func durations(from start: Date, to end: Date, days: [Date]) -> [Date: TimeInterval] {
        var result: [Date: TimeInterval] = [:]
        for day in days {
            let dayStart = calendar.date(byAdding: .hour, value: dayStartHour, to: day)!
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            let duration = min(end, dayEnd).timeIntervalSince(max(start, dayStart))
            if duration > 0 { result[day] = duration }
        }
        return result
    }

    /// The `[start, end)` interval of the work week (the calendar week of the
    /// logical day, shifted to `dayStartHour`) containing `date`.
    public func weekInterval(for date: Date) -> DateInterval {
        let week = calendar.dateInterval(of: .weekOfYear, for: logicalDayMidnight(for: date))!
        let start = calendar.date(byAdding: .hour, value: dayStartHour, to: week.start)!
        let end = calendar.date(byAdding: .day, value: 7, to: start)!
        return DateInterval(start: start, end: end)
    }
}
