import XCTest
@testable import ClocktopusCore

final class BlockMergingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func block(_ guess: String?, _ startMin: Double, _ endMin: Double,
                       evidence: String = "", signals: Set<SignalKind> = []) -> ProvisionalBlock {
        ProvisionalBlock(guessedProjectId: guess,
                         start: t0.addingTimeInterval(startMin * 60),
                         end: t0.addingTimeInterval(endMin * 60),
                         confidence: 0.5, evidence: evidence, signals: signals)
    }

    func testClippedGhostsDoNotMergeAcrossLoggedTime() {
        let original = block("initech", 0, 60)
        let logged = DateInterval(start: t0.addingTimeInterval(20 * 60),
                                  end: t0.addingTimeInterval(40 * 60))
        let clipped = Overlap.clipBlocks([original], around: logged).compactMap { action -> ProvisionalBlock? in
            if case .save(let block) = action { return block }; return nil
        }
        let runs = BlockMerging.runs(clipped, maxGap: 30 * 60, excluding: [logged])
        XCTAssertEqual(runs.map(\.count), [1, 1])
    }

    func testRunningEntryPreventsMergeButTouchingEntryDoesNot() {
        let a = block("initech", 0, 10), b = block("initech", 20, 30)
        let running = DateInterval(start: t0.addingTimeInterval(15 * 60), end: .distantFuture)
        XCTAssertEqual(BlockMerging.runs([a, b], maxGap: 30 * 60, excluding: [running]).count, 2)
        let earlier = DateInterval(start: t0.addingTimeInterval(-600), end: a.start)
        XCTAssertEqual(BlockMerging.runs([a, b], maxGap: 30 * 60, excluding: [earlier]).count, 1)
    }

    func testRunsGroupSameProjectBlocksWithinGap() {
        let a = block("initech", 0, 10), b = block("initech", 25, 35), c = block("initech", 90, 100)
        let runs = BlockMerging.runs([c, a, b], maxGap: 30 * 60)
        XCTAssertEqual(runs.map { $0.map(\.id) }, [[a.id, b.id], [c.id]])
    }

    func testRunsBreakOnDifferentGuess() {
        let a = block("initech", 0, 10), u = block(nil, 12, 20), b = block("initech", 22, 30)
        let runs = BlockMerging.runs([a, u, b], maxGap: 30 * 60)
        XCTAssertEqual(runs.map { $0.map(\.id) }, [[a.id], [u.id], [b.id]])
    }

    func testRunsGroupUnknownBlocksTogether() {
        let a = block(nil, 0, 10), b = block(nil, 15, 20)
        XCTAssertEqual(BlockMerging.runs([a, b], maxGap: 30 * 60).count, 1)
    }

    func testMergedSpansRunAndUnionsEvidence() {
        let a = block("initech", 0, 10, evidence: "terminal in ~/x · Slack", signals: [.terminal])
        let b = block("initech", 25, 35, evidence: "Slack · browser initech.example", signals: [.browser])
        let m = BlockMerging.merged([a, b])
        XCTAssertEqual(m.guessedProjectId, "initech")
        XCTAssertEqual(m.start, a.start)
        XCTAssertEqual(m.end, b.end)
        XCTAssertEqual(m.evidence, "terminal in ~/x · Slack · browser initech.example")
        XCTAssertEqual(m.signals, [.terminal, .browser])
        XCTAssertEqual(m.status, .pending)
        XCTAssertNotEqual(m.id, a.id)
    }

    func testMergeableCountsOnlyRunsOfTwoOrMore() {
        let a = block("initech", 0, 10), b = block("initech", 12, 20), c = block("globex", 30, 40)
        let runs = BlockMerging.runs([a, b, c], maxGap: 30 * 60).filter { $0.count > 1 }
        XCTAssertEqual(runs.count, 1)
    }
}
