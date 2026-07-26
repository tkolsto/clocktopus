import XCTest
@testable import ClocktopusCore

final class PrivateProjectTests: XCTestCase {
    func testTeamConfigParsesPrivateFlag() throws {
        let team = try ConfigLoader.team(fromTOML: """
        [[project]]
        name = "Priv"
        xledger_project = "0"
        xledger_activity = "PRIV"
        private = true

        [[project]]
        name = "Initech"
        xledger_project = "10432"
        xledger_activity = "DEV"
        """)
        XCTAssertTrue(team.projects[0].isPrivate)
        XCTAssertFalse(team.projects[1].isPrivate)   // defaults false
    }

    func testPrivateProjectExcludedFromExport() {
        let initech = Project(name: "Initech", xledgerProject: "10432", xledgerActivity: "DEV")
        let priv = Project(name: "Priv", xledgerProject: "9999", xledgerActivity: "PRIV",
                           isPrivate: true)
        let oslo = TimeZone(identifier: "Europe/Oslo")!
        let monday = Date(timeIntervalSince1970: 1_784_534_400)   // 2026-07-20 08:00 Oslo
        func entry(_ id: String, hours: Double) -> TimeEntry {
            TimeEntry(projectId: id, start: monday,
                      end: monday.addingTimeInterval(hours * 3600), source: .manual)
        }
        let exporter = XledgerExporter(employee: "TK", incrementHours: 0.25, includeExact: false)
        let csv = exporter.csv(entries: [entry("initech", hours: 2.0), entry("priv", hours: 3.0)],
                               projects: [initech, priv], timeZone: oslo,
                               asOf: monday.addingTimeInterval(86_400))
        XCTAssertTrue(csv.contains("10432"), "initech should be exported: \(csv)")
        XCTAssertFalse(csv.contains("9999"), "private project code should be excluded: \(csv)")
        XCTAssertFalse(csv.contains("PRIV"), csv)
    }
}
