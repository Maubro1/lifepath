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

    /// Visits on day offsets `days` (several per day allowed).
    func onDays(_ days: [Double], east: Double = 0, hAcc: Double = 5) -> [V] {
        days.enumerated().map { i, d in visit(at: day0 + d * day + Double(i % 3) * 3600, east: east, hAcc: hAcc) }
    }
    let week: [Double] = [0, 2, 4, 6, 8]   // 5 days, first and last 8 days apart

    func testFiveDaysOverAWeekPromote() throws {
        let four = fold([], onDays(Array(week.prefix(4))))
        XCTAssertEqual(four.map(\.isCandidate), [true])
        let five = fold(four, onDays([8]))
        XCTAssertEqual(five.map(\.isCandidate), [false])
        XCTAssertEqual(five.first?.visits, 5)
        XCTAssertEqual(five.first?.lastVisit, onDays([8])[0].end)
    }

    func testFiveVisitsOnFourDaysStaysCandidate() {
        let ps = fold([], onDays([0, 3, 3, 6, 9]))
        XCTAssertEqual(ps.map(\.isCandidate), [true])
        XCTAssertEqual(ps.first?.visits, 5)
    }

    func testOneLongStayStaysCandidate() {
        let ps = fold([], [visit(at: day0 - 3600, minutes: 360)])
        XCTAssertEqual(ps.map(\.isCandidate), [true])
    }

    func testFiveDaysInSixDaysStaysCandidate() {
        XCTAssertEqual(fold([], onDays([0, 1, 2, 3, 6])).map(\.isCandidate), [true])
    }

    func testFiveDaysExactlySevenApartPromote() {
        XCTAssertEqual(fold([], onDays([0, 1, 2, 3, 7])).map(\.isCandidate), [false])
    }

    func testFarCandidatesDoNotChangeResult() throws {
        // 2 000 one-cell candidates 1 km apart, far from home, must not affect learning there.
        let far = (0..<2000).map { i -> Place in
            let p = Geo.offset(lat: 52.0, lon: 5.0, north: 5000 + Double(i / 50) * 1000, east: Double(i % 50) * 1000)
            return Place(id: Int64(1000 + i), name: nil, cells: [PlaceGrid.cell(lat: p.lat, lon: p.lon): 1], updatedAt: day0, lastVisit: day0,
                         totalSeconds: 600, visits: 1, isCandidate: true)
        }
        let alone = try XCTUnwrap(fold([], onDays(week)).first)
        let crowd = fold(far, onDays(week))
        XCTAssertEqual(crowd.count, 2001)
        var home = try XCTUnwrap(crowd.last)
        home.id = alone.id
        XCTAssertEqual(home, alone)
    }

    func testSevenDaysApartButOnlyThreeDaysStaysCandidate() {
        let ps = fold([], onDays([0, 0, 4, 7, 7, 7]))
        XCTAssertEqual(ps.map(\.isCandidate), [true])
    }

    func testNeighbourSixtyMetresStaysSeparate() {
        let home = fold([], onDays(week, hAcc: 10))
        let ps = fold(home, onDays(week.map { $0 + 10 }, east: 60, hAcc: 10))
        XCTAssertEqual(ps.count, 2)
        XCTAssertEqual(ps.map(\.isCandidate), [false, false])
        XCTAssertEqual(ps.map(\.visits), [5, 5])
    }

    func testGardenJoinsHouse() throws {
        let house = fold([], onDays(week, hAcc: 8))
        let r = Places.learn(house, visit: visit(at: day0 + 9 * day, north: 20, hAcc: 8), now: day0 + 9 * day + 1800, nextId: 99)
        let p = try XCTUnwrap(r.places.first)
        XCTAssertEqual(r.places.count, 1)
        XCTAssertEqual(r.visit.placeId, p.id); XCTAssertEqual(p.visits, 6)
        let garden = pt(day0, north: 20, east: 0)
        XCTAssertTrue(p.region().contains(PlaceGrid.cell(lat: garden.lat, lon: garden.lon)))
    }

    func testDecayFollowsMove() throws {
        let a = (0..<56).map { visit(at: day0 + Double($0) * day, minutes: 540) }   // more time at A: only decay can move the pin to B
        let b = (56..<112).map { visit(at: day0 + Double($0) * day, east: -15, minutes: 480) }   // west, so pin ties without decay pick A
        let atA = fold([], a)
        let pinA = try XCTUnwrap(atA.first?.pin)
        XCTAssertEqual(PlaceGrid.cell(lat: pinA.lat, lon: pinA.lon), PlaceGrid.cell(lat: a[0].points[0].lat, lon: a[0].points[0].lon))
        let ps = fold(atA, b)
        XCTAssertEqual(ps.count, 1)
        let pin = try XCTUnwrap(ps.first?.pin), deskB = b[0].points[0]
        XCTAssertEqual(PlaceGrid.cell(lat: pin.lat, lon: pin.lon), PlaceGrid.cell(lat: deskB.lat, lon: deskB.lon))
    }

    func testOldHomeFadesNotDeleted() throws {
        let home = fold([], onDays(week))
        let before = try XCTUnwrap(home.first).cells.values.reduce(0, +)
        let later = day0 + 365 * day
        let ps = Places.learn(home, visit: visit(at: later, north: 2000), now: later + 1800, nextId: 2).places
        XCTAssertEqual(ps.count, 2)
        let old = try XCTUnwrap(ps.first { $0.id == home[0].id })
        XCTAssertFalse(old.isCandidate)
        XCTAssertEqual(old.visits, 5)
        XCTAssertEqual(old.lastVisit, home[0].lastVisit)
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

    func testSettle() {
        let now = day0 + 10 * day
        let tail = visit(at: day0, minutes: 120)                     // 10:00-12:00, stored
        let stored = [Visit(start: tail.start, end: tail.end, placeId: 1)]
        let later = visit(at: day0 + 3 * day, minutes: 30)
        // overlap tail: re-reading from 11:30 finds 11:30-12:00 again; it is skipped, a new one is kept
        let reread = tail.points.filter { $0.t >= day0 + 5400 } + [pt(day0 + 7500, north: 500, east: 0, kind: .moving)] + later.points + [pt(later.end + 60, north: 900, east: 0, kind: .moving)]
        var s = Places.settle(visits: Places.visits(from: reread), first: reread[0].t, lastT: reread.last!.t, now: now, isLast: true, stored: stored)
        XCTAssertEqual(s.finished.map(\.start), [later.start]); XCTAssertEqual(s.next, reread.last!.t); XCTAssertFalse(s.stalled)
        // open run at a chunk end is held back; the cursor goes to its start
        let openRun = tail.points
        s = Places.settle(visits: Places.visits(from: openRun), first: openRun[0].t + 1, lastT: openRun.last!.t, now: now, isLast: false, stored: [])
        XCTAssertTrue(s.finished.isEmpty); XCTAssertEqual(s.next, tail.start); XCTAssertFalse(s.stalled)
        // last chunk: a run ending within 30 min of now is open, older than that it is finished
        s = Places.settle(visits: Places.visits(from: openRun), first: openRun[0].t - 1, lastT: openRun.last!.t, now: tail.end + 1800, isLast: true, stored: [])
        XCTAssertTrue(s.finished.isEmpty)
        s = Places.settle(visits: Places.visits(from: openRun), first: openRun[0].t - 1, lastT: openRun.last!.t, now: tail.end + 1801, isLast: true, stored: [])
        XCTAssertEqual(s.finished.map(\.start), [tail.start]); XCTAssertEqual(s.next, tail.end)
        // a run filling the whole chunk stalls: the caller must widen
        s = Places.settle(visits: Places.visits(from: openRun), first: openRun[0].t, lastT: openRun.last!.t, now: now, isLast: false, stored: [])
        XCTAssertTrue(s.stalled); XCTAssertEqual(s.next, tail.start)
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

    func testLongGapBetweenStillPointsSplitsRest() {
        let a = visit(at: day0, minutes: 15).points, b = visit(at: day0 + 15 * 60 + 1801, minutes: 15).points
        XCTAssertEqual(Places.visits(from: a + b).map(\.start), [day0, b[0].t])
    }

    func testEmptyPlaceHasNoPin() {
        XCTAssertNil(Place(id: 1, name: nil, cells: [:], updatedAt: day0, lastVisit: day0, totalSeconds: 0, visits: 0, isCandidate: true).pin)
    }
}
