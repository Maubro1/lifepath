import XCTest
@testable import Core

final class TripsTests: XCTestCase {
    // ~11 m per 0.0001 deg lat; points every 10 s.
    func pt(_ i: Int, dt: Double? = nil, dLat: Double? = nil, kind: PointKind = .moving) -> FilteredPoint {
        let lat = 50 + (dLat ?? Double(i) * 0.0001)
        return FilteredPoint(t: Date(timeIntervalSince1970: dt ?? Double(i) * 10), lat: lat, lon: 4, rawLat: lat, rawLon: 4, hAcc: 5, speed: 1, kind: kind)
    }

    func testGapSplitsTrip() {
        let pts = (0..<3).map { pt($0) } + (0..<3).map { pt($0, dt: 2000 + Double($0) * 10, dLat: 0.0003 + Double($0) * 0.0001) }
        XCTAssertEqual(Trips.split(pts).map(\.points.count), [3, 3])
    }

    func testJumpSplitsTrip() {
        let pts = (0..<3).map { pt($0) } + (3..<6).map { pt($0, dLat: 0.1 + Double($0) * 0.0001) }
        XCTAssertEqual(Trips.split(pts).map(\.points.count), [3, 3])
    }

    func testStillPointsAreNotTrips() {
        XCTAssertTrue(Trips.split((0..<5).map { pt($0, kind: .still) }).isEmpty)
        let pts = [pt(0), pt(1), pt(2, kind: .still), pt(3), pt(4)]
        XCTAssertEqual(Trips.split(pts).map(\.points.count), [2, 2])
        XCTAssertTrue(Trips.split([pt(0), pt(1, kind: .still), pt(2)]).isEmpty)  // single points dropped
    }

    func testDistanceAndMovingTime() throws {
        let pts = (0..<4).map { pt($0) }
        let t = try XCTUnwrap(Trips.split(pts).first)
        let expected = Geo.distance(pts[0].lat, 4, pts[3].lat, 4)
        XCTAssertEqual(t.distance, expected, accuracy: 0.01)
        XCTAssertEqual(t.movingTime, 30, accuracy: 0.001)
        XCTAssertEqual(t.start, pts[0].t)
        XCTAssertEqual(t.end, pts[3].t)
    }
}
