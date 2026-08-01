import XCTest
@testable import ClocktopusCore

final class WorkdayCalendarTests: XCTestCase {
    let oslo = TimeZone(identifier: "Europe/Oslo")!

    // 2026-07-26 02:00 Oslo = 2026-07-26T00:00Z (Oslo is UTC+2 in July)
    private func osloDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = oslo
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testTimeBeforeDayStartBelongsToPreviousDay() {
        let cal = WorkdayCalendar(dayStartHour: 4, timeZone: oslo)
        // 02:00 on the 26th, with a 04:00 start, is still the 25th.
        let midnight = cal.logicalDayMidnight(for: osloDate(2026, 7, 26, 2))
        XCTAssertEqual(midnight, osloDate(2026, 7, 25, 0))
    }

    func testTimeAfterDayStartBelongsToSameDay() {
        let cal = WorkdayCalendar(dayStartHour: 4, timeZone: oslo)
        let midnight = cal.logicalDayMidnight(for: osloDate(2026, 7, 26, 5))
        XCTAssertEqual(midnight, osloDate(2026, 7, 26, 0))
    }

    func testDayIntervalRunsStartHourToStartHour() {
        let cal = WorkdayCalendar(dayStartHour: 4, timeZone: oslo)
        let interval = cal.dayInterval(for: osloDate(2026, 7, 26, 2))   // belongs to the 25th
        XCTAssertEqual(interval.start, osloDate(2026, 7, 25, 4))
        XCTAssertEqual(interval.end, osloDate(2026, 7, 26, 4))
    }

    func testDayStartZeroIsPlainMidnight() {
        let cal = WorkdayCalendar(dayStartHour: 0, timeZone: oslo)
        XCTAssertEqual(cal.logicalDayMidnight(for: osloDate(2026, 7, 26, 2)),
                       osloDate(2026, 7, 26, 0))
        let interval = cal.dayInterval(for: osloDate(2026, 7, 26, 2))
        XCTAssertEqual(interval.start, osloDate(2026, 7, 26, 0))
        XCTAssertEqual(interval.end, osloDate(2026, 7, 27, 0))
    }

    func testExportGroupsCrossMidnightSessionIntoOneDay() {
        let initech = Project(name: "Initech", xledgerProject: "10432", xledgerActivity: "DEV")
        // 22:00–24:00 the 25th and 01:00–02:00 the 26th. With a 04:00 start,
        // both belong to the 25th and sum into one day-row.
        let e1 = TimeEntry(projectId: "initech", start: osloDate(2026, 7, 25, 22),
                           end: osloDate(2026, 7, 26, 0), source: .manual)
        let e2 = TimeEntry(projectId: "initech", start: osloDate(2026, 7, 26, 1),
                           end: osloDate(2026, 7, 26, 2), source: .manual)
        let exporter = XledgerExporter(employee: "TK", incrementHours: 0.25, includeExact: false)
        let csv = exporter.csv(entries: [e1, e2], projects: [initech], timeZone: oslo,
                               asOf: osloDate(2026, 7, 26, 12), dayStartHour: 4)
        let rows = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.count, 2, "header + one merged row: \(csv)")
        XCTAssertTrue(rows[1].hasPrefix("20260725;TK;10432;DEV;3.00"), rows[1])
    }

    func testWeekIntervalStartsAtDayStartHour() {
        let cal = WorkdayCalendar(dayStartHour: 4, timeZone: oslo)
        // 2026-07-26 is a Sunday; a 02:00 timestamp belongs to Saturday the 25th.
        let interval = cal.weekInterval(for: osloDate(2026, 7, 26, 2))
        XCTAssertEqual(cal.calendar.component(.hour, from: interval.start), 4)
        XCTAssertEqual(interval.duration, 7 * 24 * 3600, accuracy: 3600)  // ~7 days (DST tolerance)
        XCTAssertTrue(interval.contains(osloDate(2026, 7, 25, 4)))
    }

    func testWeeksAreISOMondayStart() {
        let cal = WorkdayCalendar(dayStartHour: 4, timeZone: oslo)
        // Sat 2026-07-25 (via a 02:00 Sunday timestamp) is in ISO week 30:
        // Mon Jul 20 – Sun Jul 26. A Sunday-start (US) calendar would put it
        // in a Jul 19–25 week instead.
        let interval = cal.weekInterval(for: osloDate(2026, 7, 26, 2))
        XCTAssertEqual(interval.start, osloDate(2026, 7, 20, 4))
        XCTAssertEqual(interval.end, osloDate(2026, 7, 27, 4))
        XCTAssertEqual(cal.calendar.component(.weekOfYear, from: interval.start), 30)
    }

    func testISOWeekNumberingAtYearBoundary() {
        let cal = WorkdayCalendar(dayStartHour: 0, timeZone: oslo)
        // 2027-01-01 is a Friday → ISO week 53 of 2026 (Mon Dec 28 – Sun Jan 3).
        let interval = cal.weekInterval(for: osloDate(2027, 1, 1, 12))
        XCTAssertEqual(interval.start, osloDate(2026, 12, 28, 0))
        XCTAssertEqual(cal.calendar.component(.weekOfYear, from: interval.start), 53)
    }
}
