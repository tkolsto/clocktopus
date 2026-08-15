import XCTest
@testable import ClocktopusCore

final class ExporterTests: XCTestCase {
    let initech = Project(name: "Initech", xledgerProject: "10432", xledgerActivity: "DEV")
    let ops = Project(name: "CanopyOps", xledgerProject: "10440", xledgerActivity: "DEV")
    let oslo = TimeZone(identifier: "Europe/Oslo")!
    // 2026-07-20 08:00 Oslo (06:00 UTC)
    let mondayMorning = Date(timeIntervalSince1970: 1_784_534_400)

    static let pm10Header = "Employee;Project;Customer;Assignment;Action;Activity;"
        + "Position;ObjectValue;TimeType;AssignmentDate;StartTime;EndTime;"
        + "WorkingHours;InvoiceHours;Value;Text;Comment;Product;Unit;UnitPrice;"
        + "Quantity;Dummy22;Dummy23;Dummy24"

    func entry(_ project: String, startOffset: TimeInterval, hours: Double) -> TimeEntry {
        TimeEntry(projectId: project, start: mondayMorning.addingTimeInterval(startOffset),
                  end: mondayMorning.addingTimeInterval(startOffset + hours * 3600),
                  source: .manual)
    }

    func testGroupsByDayAndProjectAndRounds() {
        let exporter = XledgerExporter(employee: "TK", incrementHours: 0.25, includeExact: false)
        let csv = exporter.csv(
            entries: [entry("initech", startOffset: 0, hours: 3.4),          // 3.40 -> 3.50
                      entry("canopyops", startOffset: 4 * 3600, hours: 4.1)], // 4.10 -> 4.00
            projects: [initech, ops], timeZone: oslo, asOf: mondayMorning.addingTimeInterval(86_400))
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], Self.pm10Header)
        XCTAssertEqual(lines[1], "TK;10432;;;;DEV;;;;20260720;;;3.5;3.5;;;;;;;;;;x")
        XCTAssertEqual(lines[2], "TK;10440;;;;DEV;;;;20260720;;;4;4;;;;;;;;;;x")
    }

    func testExactHoursGoInComment() {
        let exporter = XledgerExporter(employee: "TK", incrementHours: 0.25, includeExact: true)
        let csv = exporter.csv(entries: [entry("initech", startOffset: 0, hours: 3.4)],
                               projects: [initech], timeZone: oslo,
                               asOf: mondayMorning.addingTimeInterval(86_400))
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[1], "TK;10432;;;;DEV;;;;20260720;;;3.5;3.5;;;exact 3.4h;;;;;;;x")
    }

    func testMultipleDaysSortedAndSeparatelyRounded() {
        let exporter = XledgerExporter(employee: "TK", incrementHours: 0.25, includeExact: false)
        let csv = exporter.csv(
            entries: [entry("initech", startOffset: 86_400, hours: 2.0),   // Tuesday
                      entry("initech", startOffset: 0, hours: 1.0)],       // Monday
            projects: [initech], timeZone: oslo,
            asOf: mondayMorning.addingTimeInterval(3 * 86_400))
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[1], "TK;10432;;;;DEV;;;;20260720;;;1;1;;;;;;;;;;x")
        XCTAssertEqual(lines[2], "TK;10432;;;;DEV;;;;20260721;;;2;2;;;;;;;;;;x")
    }

    func testRunningEntryClippedAtNow() {
        var running = TimeEntry(projectId: "initech", start: mondayMorning, source: .manual)
        running.end = nil
        let exporter = XledgerExporter(employee: "TK", incrementHours: 0.25, includeExact: false)
        let csv = exporter.csv(entries: [running], projects: [initech], timeZone: oslo,
                               asOf: mondayMorning.addingTimeInterval(7200))  // 2h in
        XCTAssertTrue(csv.contains("TK;10432;;;;DEV;;;;20260720;;;2;2;"), csv)
    }

    func testUnknownProjectSkippedAndZeroRowsOmitted() {
        let exporter = XledgerExporter(employee: "TK", incrementHours: 0.25, includeExact: false)
        let csv = exporter.csv(
            entries: [entry("ghost", startOffset: 0, hours: 2.0),
                      entry("initech", startOffset: 0, hours: 0.05)],   // rounds to 0 -> omitted
            projects: [initech], timeZone: oslo,
            asOf: mondayMorning.addingTimeInterval(86_400))
        XCTAssertEqual(csv.split(separator: "\n").count, 1, "header only: \(csv)")
    }

    // PM10 file rules: every line has exactly 24 fields, and the file must not
    // end with a newline (xledger rejects a blank last line).
    func testPM10FileShape() {
        let exporter = XledgerExporter(employee: "TK", incrementHours: 0.25, includeExact: false)
        let csv = exporter.csv(
            entries: [entry("initech", startOffset: 0, hours: 3.4),
                      entry("canopyops", startOffset: 4 * 3600, hours: 4.1)],
            projects: [initech, ops], timeZone: oslo, asOf: mondayMorning.addingTimeInterval(86_400))
        XCTAssertFalse(csv.hasSuffix("\n"))
        for line in csv.split(separator: "\n") {
            XCTAssertEqual(line.filter { $0 == ";" }.count, 23, String(line))
        }
    }
}
