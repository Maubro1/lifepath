import XCTest
@testable import Core

final class DaysTests: XCTestCase {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }()

    func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func point(_ t: Date, north: Double = 0, east: Double, kind: PointKind = .moving) -> FilteredPoint {
        let p = Geo.offset(lat: 52.37, lon: 4.90, north: north, east: east)
        return FilteredPoint(t: t, lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon, hAcc: 5, speed: 1.4, kind: kind)
    }

    /// A straight walk east, a point every 10 s for `seconds`, `metres` long.
    func straight(_ start: Date, seconds: Int, metres: Double) -> [FilteredPoint] {
        let n = seconds / 10
        return (0...n).map { (i: Int) -> FilteredPoint in point(start.addingTimeInterval(Double(i * 10)), east: metres * Double(i) / Double(n)) }
    }

    func tally(_ pts: [FilteredPoint], modes: [ModeStretch] = [], smoothed: [Date: (lat: Double, lon: Double)] = [:],
               from: Date = .distantPast) -> [String: DaySummary] {
        var days: [String: DaySummary] = [:]
        Days.tally(points: pts, trips: Trips.split(pts), modes: modes, smoothed: smoothed, from: from, calendar: cal, into: &days)
        return days
    }

    func testKey() {
        XCTAssertEqual(Days.key(local(2026, 11, 17, 23, 30), cal), "2026-11-17")
        XCTAssertEqual(Days.key(local(2026, 11, 18, 0, 30), cal), "2026-11-18")
        XCTAssertEqual(Days.key(local(2026, 3, 29, 23, 30), cal), "2026-03-29")
        XCTAssertEqual(Days.key(local(2026, 3, 29, 0, 30), cal), "2026-03-29")
        var japanese = Calendar(identifier: .japanese); japanese.timeZone = cal.timeZone
        XCTAssertEqual(Days.key(local(2026, 11, 17, 12), japanese), "2026-11-17")
    }

    func testHomeDayHasNoMovingTime() {
        let start = local(2026, 11, 17)
        let pts = (0..<288).map { (i: Int) -> FilteredPoint in point(start.addingTimeInterval(Double(i * 300)), east: 0, kind: .still) }
        XCTAssertEqual(tally(pts), ["2026-11-17": DaySummary(day: "2026-11-17", distance: 0, movingTime: 0, walked: 0, points: 288)])
    }

    func testTripDistanceAndTime() {
        let pts = straight(local(2026, 11, 17, 12), seconds: 720, metres: 1000)
        XCTAssertEqual(pts.count, 73)
        let d = tally(pts)["2026-11-17"]!
        XCTAssertEqual(d.distance, 1000, accuracy: 1)
        XCTAssertEqual(d.movingTime, 720)
        XCTAssertEqual(d.walked, 0)
        XCTAssertEqual(d.points, 73)
    }

    func testWalkedOnlyInsideConfidentWalkOrRun() {
        let t0 = local(2026, 11, 17, 12)
        let pts = straight(t0, seconds: 720, metres: 1000)
        func modes(_ first: TravelMode, _ c: Double) -> [ModeStretch] {
            [ModeStretch(seq: 0, mode: first, confidence: c, start: t0, end: t0.addingTimeInterval(300)),
             ModeStretch(seq: 1, mode: .bus, confidence: 0.9, start: t0.addingTimeInterval(300), end: t0.addingTimeInterval(720))]
        }
        let first300 = 1000.0 * 300 / 720
        let walk = tally(pts, modes: modes(.walk, 0.9))["2026-11-17"]!
        XCTAssertEqual(walk.walked, first300, accuracy: 15)
        XCTAssertEqual(walk.distance, 1000, accuracy: 1)
        XCTAssertEqual(tally(pts, modes: modes(.walk, 0.3))["2026-11-17"]!.walked, 0)
        XCTAssertEqual(tally(pts, modes: modes(.run, 0.9))["2026-11-17"]!.walked, first300, accuracy: 15)
        XCTAssertEqual(tally(pts, modes: modes(.bike, 0.9))["2026-11-17"]!.walked, 0)
    }

    func testTripOverMidnightSplits() {
        let pts = straight(local(2026, 11, 17, 23, 50), seconds: 1200, metres: 1500)
        let days = tally(pts)
        let a = days["2026-11-17"]!, b = days["2026-11-18"]!
        XCTAssertEqual(a.movingTime, 600)
        XCTAssertEqual(b.movingTime, 600)
        XCTAssertEqual(a.distance + b.distance, Trips.split(pts)[0].distance, accuracy: 0.001)
        XCTAssertEqual(a.points + b.points, pts.count)
    }

    func testFromSkipsEarlierDays() {
        let pts = straight(local(2026, 11, 17, 23, 50), seconds: 1200, metres: 1500)
        let days = tally(pts, from: local(2026, 11, 18))
        XCTAssertNil(days["2026-11-17"])
        XCTAssertEqual(days["2026-11-18"]!.movingTime, 600)
        XCTAssertEqual(days.count, 1)
    }

    func testRoughSkippedInDistance() {
        let t0 = local(2026, 11, 17, 12)
        let pts = [point(t0, east: 0), point(t0.addingTimeInterval(10), north: 1000, east: 0, kind: .rough),
                   point(t0.addingTimeInterval(20), east: 50)]
        let d = tally(pts)["2026-11-17"]!
        XCTAssertEqual(d.distance, 50, accuracy: 0.5)
        XCTAssertEqual(d.movingTime, 20)
    }

    func testSmoothedPositionsUsed() {
        let t0 = local(2026, 11, 17, 12)
        // Zig-zag 20 m either side of a 1 km line east; the smoothed line is straight.
        let pts = (0...20).map { (i: Int) -> FilteredPoint in
            point(t0.addingTimeInterval(Double(i * 10)), north: i % 2 == 0 ? 20 : -20, east: Double(i) * 50)
        }
        var smoothed: [Date: (lat: Double, lon: Double)] = [:]
        for (i, p) in pts.enumerated() { smoothed[p.t] = Geo.offset(lat: 52.37, lon: 4.90, north: 0, east: Double(i) * 50) }
        XCTAssertGreaterThan(tally(pts)["2026-11-17"]!.distance, 1250)
        XCTAssertEqual(tally(pts, smoothed: smoothed)["2026-11-17"]!.distance, 1000, accuracy: 1)
    }
}
