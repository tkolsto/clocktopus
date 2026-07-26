import XCTest
@testable import ClocktopusCore

final class ModelsTests: XCTestCase {
    func testTimeEntryDurationRunningEntryUsesNow() {
        let start = Date(timeIntervalSince1970: 1_000)
        let entry = TimeEntry(projectId: "initech", start: start, source: .manual)
        XCTAssertNil(entry.end)
        XCTAssertEqual(entry.duration(asOf: start.addingTimeInterval(90)), 90)
    }

    func testTimeEntryDurationClosed() {
        let start = Date(timeIntervalSince1970: 1_000)
        var entry = TimeEntry(projectId: "initech", start: start, source: .manual)
        entry.end = start.addingTimeInterval(3600)
        // asOf far later must not matter for a closed entry
        XCTAssertEqual(entry.duration(asOf: start.addingTimeInterval(99_999)), 3600)
    }

    func testProjectIdIsSlugOfName() {
        let p = Project(name: "Internal/Admin", xledgerProject: "10001", xledgerActivity: "ADM")
        XCTAssertEqual(p.id, "internal-admin")
    }
}
