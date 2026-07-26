import XCTest
@testable import ClocktopusCore

final class SessionRecoveryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let grace: Double = 600

    // Brief downtime after the last observation: keep the timer running.
    func testBriefDowntimeKeepsRunning() {
        let start = t0
        let lastSeen = t0.addingTimeInterval(3000)
        let now = lastSeen.addingTimeInterval(60)
        XCTAssertEqual(
            SessionRecovery.decide(runningStart: start, lastSeen: lastSeen, now: now, graceSeconds: grace),
            .keepRunning)
    }

    // Exactly at the grace boundary still counts as brief (<=).
    func testDowntimeAtGraceKeepsRunning() {
        let lastSeen = t0.addingTimeInterval(3000)
        let now = lastSeen.addingTimeInterval(grace)
        XCTAssertEqual(
            SessionRecovery.decide(runningStart: t0, lastSeen: lastSeen, now: now, graceSeconds: grace),
            .keepRunning)
    }

    // Beyond the grace window: close at the last-seen time (honest end).
    func testLongDowntimeClosesAtLastSeen() {
        let lastSeen = t0.addingTimeInterval(3000)
        let now = lastSeen.addingTimeInterval(grace + 1)
        XCTAssertEqual(
            SessionRecovery.decide(runningStart: t0, lastSeen: lastSeen, now: now, graceSeconds: grace),
            .close(at: lastSeen))
    }

    // No observations yet, but the entry just started: keep running.
    func testNoObservationsRecentStartKeepsRunning() {
        let now = t0.addingTimeInterval(60)
        XCTAssertEqual(
            SessionRecovery.decide(runningStart: t0, lastSeen: nil, now: now, graceSeconds: grace),
            .keepRunning)
    }

    // No observations and an old entry: close at now (nothing to trim to).
    func testNoObservationsOldEntryClosesAtNow() {
        let now = t0.addingTimeInterval(5000)
        XCTAssertEqual(
            SessionRecovery.decide(runningStart: t0, lastSeen: nil, now: now, graceSeconds: grace),
            .close(at: now))
    }
}
