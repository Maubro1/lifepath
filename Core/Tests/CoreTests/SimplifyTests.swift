import XCTest
@testable import Core

final class SimplifyTests: XCTestCase {
    func testDPKeepsCornerDropsStraight() {
        // Straight line north with ±1 m sideways noise collapses at 5 m.
        let straight = (0...20).map { i in
            Geo.offset(lat: 50, lon: 4, north: Double(i) * 10, east: i % 2 == 0 ? 1 : -1)
        }
        XCTAssertEqual(Simplify.douglasPeucker(straight, tolerance: 5), [0, 20])
        // 90 degree corner: 100 m north, then 100 m east.
        let l = (0...10).map { Geo.offset(lat: 50, lon: 4, north: Double($0) * 10, east: 0) }
            + (1...10).map { Geo.offset(lat: 50, lon: 4, north: 100, east: Double($0) * 10) }
        XCTAssertEqual(Simplify.douglasPeucker(l, tolerance: 5), [0, 10, 20])
    }

    func testStepSnapsToPowersOfTwoFromThree() {
        XCTAssertEqual([0, 3, 3.1, 6, 7, 15, 100].map(Simplify.step), [3, 3, 6, 6, 12, 24, 192])
    }

    func testDPEndpointsKept() {
        XCTAssertEqual(Simplify.douglasPeucker([], tolerance: 5), [])
        XCTAssertEqual(Simplify.douglasPeucker([(50, 4)], tolerance: 5), [0])
        XCTAssertEqual(Simplify.douglasPeucker([(50, 4), (50.001, 4)], tolerance: 5), [0, 1])
        // Closed loop: first == last, interior point far away is kept.
        XCTAssertEqual(Simplify.douglasPeucker([(50, 4), (50.01, 4), (50, 4)], tolerance: 5), [0, 1, 2])
    }

    func testFitRaisesToleranceNeverDropsLines() {
        // Three 1 km zigzags (±20 m) of 101 points each.
        let zig = (0...100).map { i in Geo.offset(lat: 50, lon: 4, north: Double(i) * 10, east: i % 2 == 0 ? 20 : -20) }
        let lines = [zig, zig, zig]
        XCTAssertEqual(Simplify.fit(lines, tolerance: 5, budget: 10_000), lines.map { Simplify.douglasPeucker($0, tolerance: 5) })
        let fitted = Simplify.fit(lines, tolerance: 5, budget: 60)
        XCTAssertEqual(fitted.count, 3)
        XCTAssertLessThanOrEqual(fitted.reduce(0) { $0 + $1.count }, 60)
        XCTAssertTrue(fitted.allSatisfy { $0.first == 0 && $0.last == 100 })
        // A budget below two vertices per line still keeps every line, each at its endpoints.
        XCTAssertEqual(Simplify.fit(lines, tolerance: 0, budget: 1), [[0, 100], [0, 100], [0, 100]])
    }
}
