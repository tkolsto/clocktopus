import XCTest
@testable import ClocktopusCore

final class OverlapTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ min: Double) -> Date { t0.addingTimeInterval(min * 60) }
    private func entry(_ s: Double, _ e: Double?, id: UUID = UUID()) -> TimeEntry {
        TimeEntry(id: id, projectId: "p", start: at(s), end: e.map(at), source: .manual, note: "n")
    }
    private func block(_ s: Double, _ e: Double) -> ProvisionalBlock {
        ProvisionalBlock(guessedProjectId: "p", start: at(s), end: at(e), confidence: 1, evidence: "")
    }
    private var saved: DateInterval { DateInterval(start: at(60), end: at(120)) }

    // MARK: entries

    func testEntryFullyCoveredIsDeleted() {
        let e = entry(70, 110)
        XCTAssertEqual(Overlap.clipEntries([e], around: saved), [.delete(e.id)])
    }

    func testEntryOverlappingTailIsClipped() {
        let e = entry(30, 90)
        guard case .save(let clipped)? = Overlap.clipEntries([e], around: saved).first else { return XCTFail() }
        XCTAssertEqual(clipped.id, e.id)
        XCTAssertEqual(clipped.end, at(60))
    }

    func testEntryOverlappingHeadIsClipped() {
        let e = entry(100, 150)
        guard case .save(let clipped)? = Overlap.clipEntries([e], around: saved).first else { return XCTFail() }
        XCTAssertEqual(clipped.start, at(120))
    }

    func testEntryStraddlingIsSplitKeepingNote() {
        let e = entry(0, 180)
        let actions = Overlap.clipEntries([e], around: saved)
        XCTAssertEqual(actions.count, 2)
        guard case .save(let head) = actions[0], case .save(let tail) = actions[1] else { return XCTFail() }
        XCTAssertEqual(head.id, e.id)
        XCTAssertEqual(head.end, at(60))
        XCTAssertEqual(tail.start, at(120)); XCTAssertEqual(tail.end, at(180))
        XCTAssertEqual(tail.note, "n"); XCTAssertNotEqual(tail.id, e.id)
    }

    func testEntriesNotTouchingAndTheSavedEntryItselfAreIgnored() {
        let own = entry(60, 120)
        let before = entry(0, 60), after = entry(120, 200)
        XCTAssertEqual(Overlap.clipEntries([own, before, after], excluding: own.id, around: saved), [])
    }

    func testRunningEntryIsLeftAlone() {
        let running = entry(90, nil)
        XCTAssertEqual(Overlap.clipEntries([running], around: saved), [])
    }

    // MARK: blocks

    func testBlockFullyCoveredIsDismissed() {
        let b = block(70, 110)
        XCTAssertEqual(Overlap.clipBlocks([b], around: saved), [.dismiss(b.id)])
    }

    func testBlockStraddlingIsSplit() {
        let b = block(0, 180)
        let actions = Overlap.clipBlocks([b], around: saved)
        guard actions.count == 2, case .save(let head) = actions[0], case .save(let tail) = actions[1]
        else { return XCTFail("\(actions)") }
        XCTAssertEqual(head.id, b.id); XCTAssertEqual(head.end, at(60))
        XCTAssertEqual(tail.start, at(120)); XCTAssertEqual(tail.end, at(180))
        XCTAssertEqual(tail.guessedProjectId, "p")
    }

    func testBlockOverlappingEdgesAreClipped() {
        let a = block(30, 90), c = block(100, 150)
        let actions = Overlap.clipBlocks([a, c], around: saved)
        guard actions.count == 2, case .save(let a2) = actions[0], case .save(let c2) = actions[1]
        else { return XCTFail("\(actions)") }
        XCTAssertEqual(a2.end, at(60)); XCTAssertEqual(c2.start, at(120))
    }
}
