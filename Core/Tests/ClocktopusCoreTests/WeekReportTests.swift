import XCTest
@testable import ClocktopusCore

final class WeekReportTests: XCTestCase {
    private let oslo = TimeZone(identifier: "Europe/Oslo")!
    private let mondayMorning = Date(timeIntervalSince1970: 1_784_534_400)

    func testSeparatesBillablePersonalAndTrackedTotals() {
        let billable = Project(name: "Initech", xledgerProject: "10432",
                               xledgerActivity: "DEV")
        let personal = Project(name: "Priv", xledgerProject: "0",
                               xledgerActivity: "PRIV", isPrivate: true)
        let workday = WorkdayCalendar(dayStartHour: 4, timeZone: oslo)
        let day = workday.logicalDayMidnight(for: mondayMorning)
        let entries = [
            entry(projectId: billable.id, start: mondayMorning, hours: 0.13),
            entry(projectId: personal.id, start: mondayMorning, hours: 0.13),
        ]

        let report = WeekReport(entries: entries, projects: [billable, personal],
                                days: [day], workday: workday,
                                incrementHours: 0.25,
                                asOf: mondayMorning.addingTimeInterval(3600))

        XCTAssertEqual(report.visibleProjects.map(\.id), [billable.id, personal.id])
        XCTAssertEqual(report.rounded[billable.id]?[day], 0.25)
        XCTAssertEqual(report.rounded[personal.id]?[day], 0.25)
        XCTAssertEqual(report.billableDayTotal[day], 0.25)
        XCTAssertEqual(report.personalDayTotal[day], 0.25)
        XCTAssertEqual(report.trackedDayTotal[day], 0.5)
        XCTAssertEqual(report.billableTotal, 0.25)
        XCTAssertEqual(report.personalTotal, 0.25)
        XCTAssertEqual(report.trackedTotal, 0.5)
        XCTAssertEqual(report.projectTotals.map(\.project.id), [billable.id, personal.id])
    }

    func testRunningPrivateEntryUsesAsOf() {
        let personal = Project(name: "Priv", xledgerProject: "0",
                               xledgerActivity: "PRIV", isPrivate: true)
        let workday = WorkdayCalendar(dayStartHour: 4, timeZone: oslo)
        let day = workday.logicalDayMidnight(for: mondayMorning)
        let running = TimeEntry(projectId: personal.id, start: mondayMorning,
                                source: .manual)

        let report = WeekReport(entries: [running], projects: [personal],
                                days: [day], workday: workday,
                                incrementHours: 0.25,
                                asOf: mondayMorning.addingTimeInterval(2 * 3600))

        XCTAssertEqual(report.exact[personal.id]?[day], 2)
        XCTAssertEqual(report.billableTotal, 0)
        XCTAssertEqual(report.personalTotal, 2)
        XCTAssertEqual(report.trackedTotal, 2)
    }

    func testExportStatusIgnoresPrivateEntries() {
        let billable = Project(name: "Initech", xledgerProject: "10432",
                               xledgerActivity: "DEV")
        let personal = Project(name: "Priv", xledgerProject: "0",
                               xledgerActivity: "PRIV", isPrivate: true)
        let workday = WorkdayCalendar(dayStartHour: 4, timeZone: oslo)
        let monday = workday.logicalDayMidnight(for: mondayMorning)
        let tuesdayMorning = mondayMorning.addingTimeInterval(86_400)
        let wednesdayMorning = mondayMorning.addingTimeInterval(2 * 86_400)
        let tuesday = workday.logicalDayMidnight(for: tuesdayMorning)
        let wednesday = workday.logicalDayMidnight(for: wednesdayMorning)
        let exportedAt = mondayMorning.addingTimeInterval(4 * 3600)
        let entries = [
            entry(projectId: billable.id, start: mondayMorning,
                  hours: 1, exportedAt: exportedAt),
            entry(projectId: personal.id, start: mondayMorning, hours: 2),
            entry(projectId: personal.id, start: tuesdayMorning, hours: 2),
            entry(projectId: billable.id, start: wednesdayMorning, hours: 1),
        ]

        let report = WeekReport(entries: entries, projects: [billable, personal],
                                days: [monday, tuesday, wednesday], workday: workday,
                                incrementHours: 0.25,
                                asOf: wednesdayMorning.addingTimeInterval(4 * 3600))

        XCTAssertEqual(report.dayExported[monday], true)
        XCTAssertNil(report.dayExported[tuesday])
        XCTAssertEqual(report.dayExported[wednesday], false)
    }

    func testChartClipsAndDistributesEntriesAtWorkdayAndWeekEdges() {
        let project = Project(name: "Initech", xledgerProject: "1", xledgerActivity: "DEV")
        let workday = WorkdayCalendar(dayStartHour: 4, timeZone: TimeZone(secondsFromGMT: 0)!)
        let monday = workday.calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let days = (0..<7).map { workday.calendar.date(byAdding: .day, value: $0, to: monday)! }
        let entries = [
            entry(projectId: project.id, start: monday.addingTimeInterval(3.5 * 3600), hours: 1),
            entry(projectId: project.id, start: monday.addingTimeInterval(27.5 * 3600), hours: 1),
            TimeEntry(projectId: project.id, start: monday.addingTimeInterval((7 * 24 + 3.5) * 3600), source: .manual),
        ]
        let report = WeekReport(entries: entries, projects: [project], days: days, workday: workday,
                                incrementHours: 0.25, asOf: monday.addingTimeInterval((7 * 24 + 4.5) * 3600),
                                splitAtDayBoundaries: true)
        XCTAssertEqual(report.exact[project.id]?[days[0]], 1)
        XCTAssertEqual(report.exact[project.id]?[days[1]], 0.5)
        XCTAssertEqual(report.exact[project.id]?[days[6]], 0.5)
        XCTAssertEqual(report.trackedTotal, 2)
    }

    private func entry(projectId: String, start: Date, hours: Double,
                       exportedAt: Date? = nil) -> TimeEntry {
        TimeEntry(projectId: projectId, start: start,
                  end: start.addingTimeInterval(hours * 3600),
                  source: .manual, exportedAt: exportedAt)
    }
}
