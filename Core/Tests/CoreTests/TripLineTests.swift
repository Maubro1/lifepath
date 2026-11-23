import XCTest
@testable import Core

final class TripLineTests: XCTestCase {
    func trip(_ xy: [(Double, Double)], speed: Double = 1) -> Trip {
        let pts = xy.enumerated().map { i, c in
            FilteredPoint(t: Date(timeIntervalSince1970: Double(i) * 10), lat: c.0, lon: c.1, rawLat: c.0, rawLon: c.1, hAcc: 5, speed: speed, kind: .moving)
        }
        return Trip(points: pts, start: pts[0].t, end: pts[pts.count - 1].t, distance: 123, movingTime: 10)
    }

    /// Points at times `ts` (s) with Doppler `speeds` (m/s); kind rough where speed is nil.
    func points(_ ts: [Double], _ speeds: [Double?], north: [Double]? = nil) -> [FilteredPoint] {
        zip(ts, speeds).enumerated().map { i, x in
            let p = Geo.offset(lat: 52, lon: 4, north: north?[i] ?? 0, east: 0)
            return FilteredPoint(t: Date(timeIntervalSince1970: x.0), lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon,
                                 hAcc: x.1 == nil ? 900 : 5, speed: x.1 ?? -1, kind: x.1 == nil ? .rough : .moving)
        }
    }

    func testTopSpeedIgnoresSpikeAndShortStretches() {
        // A 20 min bike ride at 5 m/s with one 24 m/s (87 km/h) spike: despiked, top speed stays a bike's.
        let ts = (0...1200).map(Double.init)
        var v: [Double?] = ts.map { _ in 5 }; v[600] = 24
        XCTAssertEqual(TripLines.topSpeed(points(ts, v)), 5, accuracy: 0.01)
        // A walk to the station (10 min at 1.4) then 20 min of train at 30 m/s: the train decides.
        let walk = (0..<600).map { _ in 1.4 } as [Double?], train = (0..<1200).map { _ in 30.0 } as [Double?]
        XCTAssertEqual(TripLines.topSpeed(points((0..<1800).map(Double.init), walk + train)), 30, accuracy: 0.01)
    }

    func testTopSpeedIsHeldFor15sAndWeighsTime() {
        // Walking with a point every 7 s, then 2 min cycling at 6 m/s with a point every second: 6, whatever the point counts.
        let w = stride(from: 0.0, to: 600, by: 7).map { $0 }, c = (0..<120).map { 600 + Double($0) }
        XCTAssertEqual(TripLines.topSpeed(points(w + c, w.map { _ in 1.4 } + c.map { _ in 6 })), 6, accuracy: 0.01)
        // A city bus: 5 min at 6 m/s with one 20 s run at 14 m/s (50 km/h) between lights counts as 14.
        let ts = (0..<300).map(Double.init)
        XCTAssertEqual(TripLines.topSpeed(points(ts, ts.map { $0 >= 100 && $0 < 120 ? 14 : 6 })), 14, accuracy: 0.01)
        // 8 s at 14 is too short to hold for 15 s: (8 × 14 + 7 × 6) / 15.
        XCTAssertEqual(TripLines.topSpeed(points(ts, ts.map { $0 >= 100 && $0 < 108 ? 14 : 6 })), (8 * 14 + 7 * 6) / 15.0, accuracy: 0.01)
        // A 10 s trip: its mean.
        XCTAssertEqual(TripLines.topSpeed(points((0...10).map(Double.init), (0...10).map { _ in 2 })), 2, accuracy: 0.01)
    }

    func testTopSpeedOfRoughTrainRunIsEndToEnd() {
        // Only rough fixes, 10 km in 300 s: 33.3 m/s; no known speed at all is -1.
        XCTAssertEqual(TripLines.topSpeed(points([0, 150, 300], [nil, nil, nil], north: [0, 5000, 10_000])), 10_000 / 300, accuracy: 0.5)
        XCTAssertEqual(TripLines.topSpeed(points([0, 10], [-1, -1])), -1)
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
