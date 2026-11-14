import XCTest
@testable import Core

final class PlacesTests: XCTestCase {
    typealias V = (start: Date, end: Date, points: [FilteredPoint])
    // Day 0 = 2026-03-02 10:00 local time, so "same day" and "different days" hold in any time zone.
    let day0 = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 10))!
    let day: TimeInterval = 86_400

    func pt(_ t: Date, north: Double, east: Double, hAcc: Double = 5, kind: PointKind = .still) -> FilteredPoint {
        let p = Geo.offset(lat: 52.0, lon: 5.0, north: north, east: east)
        return FilteredPoint(t: t, lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon, hAcc: hAcc, speed: 0, kind: kind)
    }
    /// A rest of `minutes` with a still fix every 5 min.
    func visit(at start: Date, north: Double = 0, east: Double = 0, minutes: Int = 30, hAcc: Double = 5) -> V {
        let pts = stride(from: 0, through: minutes * 60, by: 300).map { pt(start.addingTimeInterval(Double($0)), north: north, east: east, hAcc: hAcc) }
        return (start, pts.last!.t, pts)
    }
    func fold(_ places: [Place], _ visits: [V]) -> [Place] {
        visits.reduce(places) { ps, v in Places.learn(ps, visit: v, now: v.end, nextId: (ps.map(\.id).max() ?? 0) + 1).places }
    }

    func testFirstVisitIsCandidate() throws {
        let r = Places.learn([], visit: visit(at: day0), now: day0, nextId: 7)
        let p = try XCTUnwrap(r.places.first)
        XCTAssertEqual(r.places.count, 1)
        XCTAssertTrue(p.isCandidate)
        XCTAssertEqual(p.id, 7); XCTAssertEqual(r.visit.placeId, 7); XCTAssertEqual(p.visits, 1)
        XCTAssertEqual(p.totalSeconds, 1800)
    }

    func testThreeDaysPromote() {
        let two = fold([], [visit(at: day0), visit(at: day0 + day)])
        XCTAssertEqual(two.map(\.isCandidate), [true])
        let three = fold(two, [visit(at: day0 + 2 * day)])
        XCTAssertEqual(three.map(\.isCandidate), [false])
        XCTAssertEqual(three.first?.visits, 3)
    }

    func testOneLongStayStaysCandidate() {
        let ps = fold([], [visit(at: day0 - 3600, minutes: 360)])
        XCTAssertEqual(ps.map(\.isCandidate), [true])
    }

    func testThreeVisitsSameDayStaysCandidate() {
        let ps = fold([], [visit(at: day0 - 3600), visit(at: day0 + 3600), visit(at: day0 + 3 * 3600)])
        XCTAssertEqual(ps.map(\.isCandidate), [true])
        XCTAssertEqual(ps.first?.visits, 3)
    }

    func testNeighbourSixtyMetresStaysSeparate() {
        let home = fold([], (0..<3).map { visit(at: day0 + Double($0) * day, hAcc: 10) })
        let ps = fold(home, (3..<6).map { visit(at: day0 + Double($0) * day, east: 60, hAcc: 10) })
        XCTAssertEqual(ps.count, 2)
        XCTAssertEqual(ps.map(\.isCandidate), [false, false])
        XCTAssertEqual(ps.map(\.visits), [3, 3])
    }

    func testGardenJoinsHouse() throws {
        let house = fold([], (0..<3).map { visit(at: day0 + Double($0) * day, hAcc: 8) })
        let r = Places.learn(house, visit: visit(at: day0 + 3 * day, north: 20, hAcc: 8), now: day0 + 3 * day + 1800, nextId: 99)
        let p = try XCTUnwrap(r.places.first)
        XCTAssertEqual(r.places.count, 1)
        XCTAssertEqual(r.visit.placeId, p.id); XCTAssertEqual(p.visits, 4)
        let garden = pt(day0, north: 20, east: 0)
        XCTAssertTrue(p.region().contains(PlaceGrid.cell(lat: garden.lat, lon: garden.lon)))
    }

    func testDecayFollowsMove() throws {
        let a = (0..<56).map { visit(at: day0 + Double($0) * day, minutes: 480) }
        let b = (56..<112).map { visit(at: day0 + Double($0) * day, east: 15, minutes: 480) }
        let atA = fold([], a)
        let pinA = try XCTUnwrap(atA.first?.pin)
        XCTAssertEqual(PlaceGrid.cell(lat: pinA.lat, lon: pinA.lon), PlaceGrid.cell(lat: a[0].points[0].lat, lon: a[0].points[0].lon))
        let ps = fold(atA, b)
        XCTAssertEqual(ps.count, 1)
        let pin = try XCTUnwrap(ps.first?.pin), deskB = b[0].points[0]
        XCTAssertEqual(PlaceGrid.cell(lat: pin.lat, lon: pin.lon), PlaceGrid.cell(lat: deskB.lat, lon: deskB.lon))
    }

    func testOldHomeFadesNotDeleted() throws {
        let home = fold([], (0..<3).map { visit(at: day0 + Double($0) * day) })
        let before = try XCTUnwrap(home.first).cells.values.reduce(0, +)
        let later = day0 + 365 * day
        let ps = Places.learn(home, visit: visit(at: later, north: 2000), now: later + 1800, nextId: 2).places
        XCTAssertEqual(ps.count, 2)
        let old = try XCTUnwrap(ps.first { $0.id == home[0].id })
        XCTAssertFalse(old.isCandidate)
        XCTAssertEqual(old.visits, 3)
        XCTAssertLessThan(old.cells.values.reduce(0, +), 0.02 * before)   // 0.5^(365/60) ≈ 1.5%
        XCTAssertEqual(old.region(), home[0].region())   // fading keeps the shape
    }

    func testLearnIsIdempotentPerVisit() {
        // learn itself counts every call; the caller (PlaceService) skips visits it already stored, keyed by start.
        // Reading the same points again with an overlap must give the same visit starts so that guard works.
        let pts = visit(at: day0, minutes: 60).points + [pt(day0 + 3700, north: 200, east: 0, kind: .moving)]
        let first = Places.visits(from: pts), again = Places.visits(from: Array(pts.dropFirst(3)))
        XCTAssertEqual(first.map(\.start), [day0])
        var stored = Set<Date>(), places: [Place] = []
        for v in first + Places.visits(from: pts) where stored.insert(v.start).inserted {
            places = Places.learn(places, visit: v, now: v.end, nextId: 1).places
        }
        XCTAssertEqual(places.first?.visits, 1)
        XCTAssertEqual(again.map(\.end), first.map(\.end))   // a partial re-read finds the same rest end
    }

    func testVisitsNeedTenMinutes() throws {
        var pts: [FilteredPoint] = []
        var t = day0
        func add(_ n: Int, every: TimeInterval, north: Double, kind: PointKind, hAcc: Double = 5) {
            for _ in 0..<n { pts.append(pt(t, north: north, east: 0, hAcc: hAcc, kind: kind)); t += every }
        }
        add(5, every: 10, north: 0, kind: .moving)
        add(10, every: 60, north: 100, kind: .still, hAcc: 30)   // 9 minutes: not a visit
        add(3, every: 10, north: 500, kind: .moving)              // far away: not settling
        let settleStart = t
        add(2, every: 10, north: 1015, kind: .moving)             // settling within the still fix's 30 m
        add(13, every: 60, north: 1000, kind: .still, hAcc: 30)   // 12 minutes
        add(2, every: 10, north: 1300, kind: .moving)
        let v = try XCTUnwrap(Places.visits(from: pts).first)
        XCTAssertEqual(Places.visits(from: pts).count, 1)
        XCTAssertEqual(v.start, settleStart)
        XCTAssertEqual(v.end, settleStart + 20 + 12 * 60)
        XCTAssertEqual(v.points.count, 15)
    }
}
