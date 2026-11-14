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
        XCTAssertEqual(Trips.split(pts).map(\.points.count), [3, 2])  // first trip ends at the still point
        XCTAssertEqual(Trips.split([pt(0), pt(1, kind: .still), pt(2)]).map(\.points.count), [2])  // lone point + still dot
        XCTAssertTrue(Trips.split([pt(0, kind: .still), pt(1)]).isEmpty)  // single point dropped
    }

    func at(_ t: Double, _ lat: Double, _ lon: Double, kind: PointKind = .moving, hAcc: Double = 5) -> FilteredPoint {
        FilteredPoint(t: Date(timeIntervalSince1970: t), lat: lat, lon: lon, rawLat: lat, rawLon: lon, hAcc: hAcc, speed: 1, kind: kind)
    }

    func testSettlingTailIsTrimmed() throws {
        // Walk north toward a still point at lat 50.003, then 120 fixes wandering within ~26 m of it at <= 3 m steps, then the still point.
        let walk = (0...26).map { at(Double($0) * 10, 50 + Double($0) * 0.0001, 4) }   // last fix ~44 m short
        let settle = (0..<120).map { k in
            at(270 + Double(k + 1) * 10, 50.003 + 0.0002 * sin(Double(k) * 0.1), 4 + 0.0002 * cos(Double(k) * 0.1))
        }
        let still = at(1500, 50.003, 4, kind: .still, hAcc: 40)
        let trip = try XCTUnwrap(Trips.split(walk + settle + [still]).first)
        XCTAssertEqual(trip.points.count, walk.count + 2)  // walk, first settle fix (46 m jump, kept), still
        XCTAssertEqual(trip.points[walk.count - 1], walk.last)
        XCTAssertEqual(trip.points.last?.lat, still.lat)
        XCTAssertEqual(trip.points.last?.lon, still.lon)
    }

    func testShortWalkToShopSurvives() throws {
        let walk = (0..<8).map { at(Double($0) * 10, 50 + Double($0) * 0.00008, 4) }   // ~60 m
        let still = at(100, 50.00064, 4, kind: .still, hAcc: 80)
        let trip = try XCTUnwrap(Trips.split(walk + [still]).first)
        XCTAssertEqual(trip.points.count, 9)
        XCTAssertEqual(trip.points.last?.lat, still.lat)
    }

    func testFinalApproachKept() throws {
        let walk = (0..<20).map { at(Double($0) * 10, 50 + Double($0) * 0.000063, 4) }   // ~7 m steps
        let still = at(200, 50 + 20 * 0.000063, 4, kind: .still, hAcc: 100)
        let trip = try XCTUnwrap(Trips.split(walk + [still]).first)
        XCTAssertEqual(Array(trip.points.dropLast()), walk)
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
