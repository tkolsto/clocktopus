import XCTest
@testable import ClocktopusCore

final class RoundingTests: XCTestCase {
    func testSimpleQuartersPreserved() {
        let out = Rounding.allocate(exactHours: ["a": 4.25, "b": 2.5], incrementHours: 0.25)
        XCTAssertEqual(out, ["a": 4.25, "b": 2.5])
    }

    func testRowsSumToRoundedDayTotal() {
        // exact total 7.50 -> rounded total must stay 7.50 even though
        // naive per-row rounding gives 3.50 + 4.25 = 7.75
        let out = Rounding.allocate(exactHours: ["a": 3.40, "b": 4.10], incrementHours: 0.25)
        XCTAssertEqual(out.values.reduce(0, +), 7.50, accuracy: 0.0001)
        XCTAssertEqual(out["a"]!, 3.50, accuracy: 0.0001)   // larger remainder .40/.25=1.6 -> frac .6
        XCTAssertEqual(out["b"]!, 4.00, accuracy: 0.0001)
    }

    func testTinySliverDoesNotGoNegativeAndTotalHolds() {
        let out = Rounding.allocate(exactHours: ["a": 0.02, "b": 7.49], incrementHours: 0.25)
        XCTAssertGreaterThanOrEqual(out["a"]!, 0)
        XCTAssertEqual(out.values.reduce(0, +), 7.50, accuracy: 0.0001)
    }

    func testEmptyInput() {
        XCTAssertTrue(Rounding.allocate(exactHours: [:], incrementHours: 0.25).isEmpty)
    }

    func testPropertyStyleSweep() {
        // deterministic pseudo-random sweep: totals always preserved, all rows
        // non-negative multiples of the increment
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed % 1000) / 100.0   // 0.00 ..< 10.00
        }
        for _ in 0..<200 {
            let hours = ["a": next(), "b": next(), "c": next()]
            let inc = 0.25
            let out = Rounding.allocate(exactHours: hours, incrementHours: inc)
            let exactTotal = hours.values.reduce(0, +)
            let expectedTotal = (exactTotal / inc).rounded() * inc
            XCTAssertEqual(out.values.reduce(0, +), expectedTotal, accuracy: 0.0001)
            for v in out.values {
                XCTAssertGreaterThanOrEqual(v, -0.0001)
                let units = v / inc
                XCTAssertEqual(units, units.rounded(), accuracy: 0.0001)
            }
        }
    }
}
