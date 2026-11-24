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

    func testVisvalingamEndsInfinite() {
        let line = (0...20).map { i in Geo.offset(lat: 50, lon: 4, north: Double(i) * 10, east: i % 2 == 0 ? 5 : -5) }
        let a = Simplify.visvalingam(line)
        XCTAssertEqual(a.count, line.count)
        XCTAssertEqual(a.first, .infinity); XCTAssertEqual(a.last, .infinity)
        XCTAssertTrue(a.dropFirst().dropLast().allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertEqual(Simplify.visvalingam([(50, 4), (50.001, 4)]), [.infinity, .infinity])
    }

    func testVisvalingamMonotoneNesting() {
        // Any two thresholds keep nested vertex sets: zooming out only removes vertices.
        var rng = SeededRandom(seed: 7)
        let line = (0..<200).map { i in Geo.offset(lat: 50, lon: 4, north: Double(i) * 8 + rng.gaussian() * 3, east: rng.gaussian() * 12) }
        let a = Simplify.visvalingam(line)
        for (lo, hi) in [(1.0, 10.0), (10.0, 100.0), (100.0, 1000.0), (0.5, 5000.0)] {
            let small = Set(a.indices.filter { a[$0] >= hi }), large = Set(a.indices.filter { a[$0] >= lo })
            XCTAssertTrue(small.isSubset(of: large))
        }
    }

    func testVisvalingamDropsCollinearFirst() {
        // A straight run with one corner: the straight interior vertices go first, the corner last.
        let line = [(0.0, 0.0), (0, 50), (0, 100), (100, 100), (100, 150)].map { Geo.offset(lat: 50, lon: 4, north: $0.0, east: $0.1) }
        let a = Simplify.visvalingam(line)
        XCTAssertLessThan(a[1], 1)                 // collinear
        XCTAssertGreaterThan(a[2], 1000)            // the corner
    }

    func testDropSpikesRemovesOutAndBackKeepsCorners() {
        func at(_ e: Double, _ n: Double) -> (lat: Double, lon: Double) { Geo.offset(lat: 52, lon: 5, north: n, east: e) }
        // A walk east every 10 m with one fix 60 m north and straight back, and a two-fix wander of 40 m at the end.
        var c = (0...10).map { at(Double($0) * 10, 0) }
        c.insert(at(50, 60), at: 6)
        c += [at(100, 40), at(110, 35), at(105, 2)]
        XCTAssertEqual(Simplify.dropSpikes(c).map { c[$0].lat }, ((0...10).map { at(Double($0) * 10, 0) } + [at(105, 2)]).map(\.lat))
        // A real corner (east 100 m, then north 100 m) stays whole.
        let corner = (0...10).map { at(Double($0) * 10, 0) } + (1...10).map { at(100, Double($0) * 10) }
        XCTAssertEqual(Simplify.dropSpikes(corner).count, corner.count)
    }
}
