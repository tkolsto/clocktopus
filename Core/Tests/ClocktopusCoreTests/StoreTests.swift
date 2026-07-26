import XCTest
@testable import ClocktopusCore

final class StoreTests: XCTestCase {
    var store: Store!
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        store = try Store.inMemory()
    }

    func testSaveAndFetchEntryRoundTrip() throws {
        let entry = TimeEntry(projectId: "initech", start: t0,
                              end: t0.addingTimeInterval(3600), source: .manual, note: "deep work")
        try store.save(entry)
        let fetched = try store.entries(in: DateInterval(start: t0.addingTimeInterval(-10),
                                                         duration: 7200))
        XCTAssertEqual(fetched, [entry])
    }

    func testRunningEntryFetch() throws {
        try store.save(TimeEntry(projectId: "initech", start: t0, source: .manual))
        XCTAssertEqual(try store.runningEntry()?.projectId, "initech")
    }

    func testUpsertUpdatesInPlace() throws {
        var entry = TimeEntry(projectId: "initech", start: t0, source: .manual)
        try store.save(entry)
        entry.end = t0.addingTimeInterval(100)
        try store.save(entry)
        XCTAssertNil(try store.runningEntry())
        XCTAssertEqual(try store.entries(in: DateInterval(start: t0, duration: 200)).count, 1)
    }

    func testEntriesOverlappingRange() throws {
        // entry spans the range boundary — must still be returned
        try store.save(TimeEntry(projectId: "initech", start: t0.addingTimeInterval(-1800),
                                 end: t0.addingTimeInterval(1800), source: .manual))
        let hits = try store.entries(in: DateInterval(start: t0, duration: 600))
        XCTAssertEqual(hits.count, 1)
    }

    func testPendingBlocksAutoExpireAfterSevenDays() throws {
        let old = ProvisionalBlock(guessedProjectId: "initech", start: t0, end: t0.addingTimeInterval(600),
                                   confidence: 0.8, evidence: "old")
        let fresh = ProvisionalBlock(guessedProjectId: "initech",
                                     start: t0.addingTimeInterval(8 * 86_400),
                                     end: t0.addingTimeInterval(8 * 86_400 + 600),
                                     confidence: 0.8, evidence: "fresh")
        try store.save(old)
        try store.save(fresh)
        let now = t0.addingTimeInterval(8 * 86_400 + 3600)
        let pending = try store.pendingBlocks(asOf: now)
        XCTAssertEqual(pending.map(\.id), [fresh.id])
    }

    func testObservationPruning() throws {
        try store.append(Observation(timestamp: t0))
        try store.append(Observation(timestamp: t0.addingTimeInterval(86_400)))
        try store.pruneObservations(olderThan: t0.addingTimeInterval(3600))
        // no getter needed beyond count for pruning verification
        XCTAssertEqual(try store.observationCount(), 1)
    }

    func testConfigCacheRoundTrip() throws {
        XCTAssertNil(try store.lastKnownGoodTeamConfigTOML())
        try store.cacheTeamConfigTOML("[[project]]\nname = \"Initech\"")
        XCTAssertEqual(try store.lastKnownGoodTeamConfigTOML(), "[[project]]\nname = \"Initech\"")
    }

    func testCloseDanglingEntry() throws {
        try store.save(TimeEntry(projectId: "initech", start: t0, source: .manual))
        let closed = try store.closeDanglingEntry(at: t0.addingTimeInterval(500))
        XCTAssertEqual(closed?.end, t0.addingTimeInterval(500))
        XCTAssertNil(try store.runningEntry())
    }

    func testCloseDanglingEntryClampsEndToStart() throws {
        try store.save(TimeEntry(projectId: "initech", start: t0, source: .manual))
        let closed = try store.closeDanglingEntry(at: t0.addingTimeInterval(-100))
        XCTAssertEqual(closed?.end, t0)
    }

    func testLastObservationTimestamp() throws {
        XCTAssertNil(try store.lastObservationTimestamp())
        try store.append(Observation(timestamp: t0))
        try store.append(Observation(timestamp: t0.addingTimeInterval(60)))
        XCTAssertEqual(try store.lastObservationTimestamp(), t0.addingTimeInterval(60))
    }
}
