import XCTest
@testable import Core

final class TripLineTests: XCTestCase {
    func trip(_ xy: [(Double, Double)], speed: Double = 1) -> Trip {
        let pts = xy.enumerated().map { i, c in
            FilteredPoint(t: Date(timeIntervalSince1970: Double(i) * 10), lat: c.0, lon: c.1, rawLat: c.0, rawLon: c.1, hAcc: 5, speed: speed, kind: .moving)
        }
        return Trip(points: pts, start: pts[0].t, end: pts[pts.count - 1].t, distance: 123, movingTime: 10)
    }

    func testBoundingBoxCoversAllPoints() {
        let line = TripLines.make(trip([(50, 4), (50.001, 4.002), (49.999, 4.001), (50.0005, 3.999)]))
        XCTAssertEqual(line.minLat, 49.999); XCTAssertEqual(line.maxLat, 50.001)
        XCTAssertEqual(line.minLon, 3.999); XCTAssertEqual(line.maxLon, 4.002)
        XCTAssertEqual(line.distance, 123)
    }

    func testCoarseLineKeepsCorners() {
        // north 0.01 deg (~1.1 km) then east, corner every point-step 0.0001
        let up = (0...100).map { (50 + Double($0) * 0.0001, 4.0) }
        let right = (1...100).map { (50.01, 4 + Double($0) * 0.0001) }
        let line = TripLines.make(trip(up + right))
        XCTAssertTrue(line.coords.contains { Geo.distance($0.lat, $0.lon, 50.01, 4.0) < 15 })
    }

    func testVertexCountShrinks() {
        let pts = (0..<1000).map { (50 + Double($0) * 0.00001, 4 + sin(Double($0)) * 0.000001) }
        XCTAssertLessThan(TripLines.make(trip(pts)).coords.count, 20)
    }

    func testShortTripKeepsTwoPoints() {
        XCTAssertEqual(TripLines.make(trip([(50, 4), (50.0001, 4)])).coords.count, 2)
    }

    func testUnknownSpeedTakesTripMedian() {
        var t = trip([(50, 4), (50.01, 4), (50.01, 4.01)], speed: 3)
        t.points[0].speed = -1
        XCTAssertEqual(TripLines.make(t).coords[0].speed, 3)
        var u = trip([(50, 4), (50.01, 4)]); for i in u.points.indices { u.points[i].speed = -1 }
        XCTAssertEqual(TripLines.make(u).coords[0].speed, -1)
    }

    func testSnappedFollowsWay() {
        // Points wobble 6 m north of a straight way; a confident stretch over all of them draws the way instead.
        let pts = (0...10).map { i -> (Double, Double) in let p = Geo.offset(lat: 50, lon: 4, north: 6, east: Double(i) * 20); return (p.lat, p.lon) }
        let t = trip(pts)
        let way = Way(id: 1, kind: .road, name: nil, oneway: false, nodes: [1, 2],
                      coords: [Geo.offset(lat: 50, lon: 4, north: 0, east: 0), Geo.offset(lat: 50, lon: 4, north: 0, east: 200)])
        let m = MatchedStretch(seq: 0, wayId: 1, fromM: 0, toM: 200, confidence: 0.9, start: t.start, end: t.end)
        let line = TripLines.snapped(t, smoothed: [:], matches: [m], ways: [1: way])
        XCTAssertTrue(line.coords.allSatisfy { Geo.distance($0.lat, $0.lon, 50, $0.lon) < 1 }, "\(line.coords)")
    }

    func testSnappedKeepsUnmatched() {
        let pts = (0...10).map { i -> (Double, Double) in let p = Geo.offset(lat: 50, lon: 4, north: 6, east: Double(i) * 20); return (p.lat, p.lon) }
        let t = trip(pts)
        XCTAssertEqual(TripLines.snapped(t, smoothed: [:], matches: [], ways: [:]), TripLines.make(t))
    }
}
