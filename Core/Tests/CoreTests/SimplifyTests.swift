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

    func testDPEndpointsKept() {
        XCTAssertEqual(Simplify.douglasPeucker([], tolerance: 5), [])
        XCTAssertEqual(Simplify.douglasPeucker([(50, 4)], tolerance: 5), [0])
        XCTAssertEqual(Simplify.douglasPeucker([(50, 4), (50.001, 4)], tolerance: 5), [0, 1])
        // Closed loop: first == last, interior point far away is kept.
        XCTAssertEqual(Simplify.douglasPeucker([(50, 4), (50.01, 4), (50, 4)], tolerance: 5), [0, 1, 2])
    }
}
