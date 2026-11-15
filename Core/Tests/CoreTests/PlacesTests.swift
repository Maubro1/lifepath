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
    func onDays(_ days: [Double], east: Double = 0, minutes: Int = 30, hAcc: Double = 5) -> [V] {
        days.enumerated().map { i, d in visit(at: day0 + d * day + Double(i % 3) * 3600, east: east, minutes: minutes, hAcc: hAcc) }
    }
    let week: [Double] = [0, 2, 4, 6, 8]   // 5 days of 18 h each: 110 points, a pin

    func homeDays(_ days: [Double], east: Double = 0, hAcc: Double = 5) -> [V] { onDays(days, east: east, minutes: 1080, hAcc: hAcc) }

    func testHomeBecomesPinInAboutSixDays() throws {
        let five = fold([], onDays([0, 1, 2, 3, 4], minutes: 840))   // 5 × 18 = 90
        XCTAssertEqual(five.map(\.isCandidate), [true])
        let six = fold(five, onDays([5], minutes: 840))
        XCTAssertEqual(six.map(\.isCandidate), [false])
        XCTAssertEqual(six.first?.points ?? 0, 108, accuracy: 0.01)
        XCTAssertEqual(six.first?.lastVisit, onDays([5], minutes: 840)[0].end)
    }

    func testSchoolTwoWeeks() {
        let d = [0, 1, 2, 3, 4, 7, 8, 9, 10, 11].map(Double.init)   // 6 h × 10 days = 100
        XCTAssertEqual(fold([], onDays(Array(d.prefix(9)), minutes: 360)).map(\.isCandidate), [true])
        XCTAssertEqual(fold([], onDays(d, minutes: 360)).map(\.isCandidate), [false])
    }

    func testOneLongStayNeverPins() {
        XCTAssertEqual(fold([], [visit(at: day0 - 3600, minutes: 600)]).map(\.isCandidate), [true])
    }

    func testBenchNeverPins() {
        let ps = fold([], onDays([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], minutes: 15))   // 10 × 4.25
        XCTAssertEqual(ps.map(\.isCandidate), [true])
    }

    /// 6 days of 14 h at home, then one stay elsewhere `gap` days later (so decay and time pass).
    func homeThen(_ visits: [V]) -> [Place] { fold(fold([], onDays([0, 1, 2, 3, 4, 5], minutes: 840)), visits) }

    func testHiddenAfterSixMonthsWithoutRealVisit() throws {
        let ps = homeThen([visit(at: day0 + 300 * day, north: 2000, minutes: 600)])
        let h = try XCTUnwrap(ps.first { $0.pin != nil && $0.visits == 6 })
        let last = try XCTUnwrap(h.realDays.max())
        XCTAssertEqual(h.hideAfterDays, 180)
        XCTAssertTrue(h.isVisible(at: day0 + (6 + 180) * day))
        XCTAssertFalse(h.isVisible(at: day0 + (6 + 181) * day))
        XCTAssertEqual(last, Places.day(day0 + 6 * day))   // the 14 h stay on day 5 runs past midnight
        XCTAssertFalse(h.isVisible(at: day0 + 300 * day))
    }

    func testOneRealVisitBringsItBack() throws {
        let back = day0 + 300 * day
        let ps = homeThen([visit(at: back, minutes: 600)])
        let h = try XCTUnwrap(ps.first)
        XCTAssertEqual(ps.count, 1)
        XCTAssertFalse(h.isCandidate)
        XCTAssertTrue(h.isVisible(at: back + 11 * 3600))
        XCTAssertEqual(h.realDays.max(), Places.day(back))
    }

    func testShortGymVisitsKeepGymVisible() throws {
        let weekly = (0..<30).map { visit(at: day0 + Double($0) * 7 * day, minutes: 90) }
        let gym = try XCTUnwrap(fold([], weekly).first)
        XCTAssertFalse(gym.isCandidate)   // 30 × 5.5 = 165
        XCTAssertTrue(gym.isVisible(at: weekly.last!.end + 7 * day))
        XCTAssertEqual(gym.realDays.max(), Places.day(weekly.last!.start))
    }

    func testShortDropInDoesNotCount() throws {
        let away = day0 + 213 * day
        let ps = homeThen([visit(at: away, minutes: 10)])
        let h = try XCTUnwrap(ps.first)
        XCTAssertEqual(ps.count, 1); XCTAssertEqual(h.visits, 7)
        XCTAssertFalse(h.isVisible(at: away + 700))
    }

    // Hiding time from synthetic real-visit day sets (day numbers; visitDays = realDays).
    func known(_ days: some Sequence<Int>, hole: Range<Int> = 0..<0) -> Place {
        let d = Set(days).subtracting(hole)
        return Place(id: 1, name: nil, cells: [:], visitDays: d, updatedAt: day0, lastVisit: day0, totalSeconds: 0, visits: d.count,
                     isCandidate: false, realDays: d)
    }
    /// `stay`-day stays whose starts are `every` days apart, `count` of them.
    func stays(_ count: Int, every: Int, stay: Int = 1) -> [Int] { (0..<count).flatMap { k in (0..<stay).map { k * every + $0 } } }

    func testHideAfterDays() {
        let holidays = (0..<2920).filter { $0 % 365 < 340 || $0 % 365 > 350 }   // ~11 days off a year
        XCTAssertEqual(known(holidays).hideAfterDays, 360, "home, 8 years")
        XCTAssertEqual(known(0..<1826).hideAfterDays, 330, "former home, 5 years")
        let school = (0..<1465).filter { $0 % 7 < 5 }
        XCTAssertEqual(known(school).hideAfterDays, 300, "school, weekends")
        XCTAssertEqual(known(school, hole: 1400..<1449).hideAfterDays, 300, "school with a 49-day break in the last gaps")
        let gym = (0..<731).filter { [0, 2, 4].contains($0 % 7) }
        XCTAssertEqual(known(gym).hideAfterDays, 240, "gym 3 a week")
        XCTAssertEqual(known(stays(76, every: 30, stay: 2)).hideAfterDays, 360, "parents monthly")
        XCTAssertEqual(known(stays(11, every: 121, stay: 2)).hideAfterDays, 450, "grandparents 3 a year")
        XCTAssertEqual(known(stays(3, every: 365, stay: 14)).hideAfterDays, 730, "holiday home, year 2+")
        XCTAssertEqual(known(stays(74, every: 15)).hideAfterDays, 270, "café twice a month")
        XCTAssertEqual(known(0..<92).hideAfterDays, 180, "internship")
        XCTAssertEqual(known(0..<14).hideAfterDays, 180, "holiday home, first year")
        XCTAssertEqual(known([]).hideAfterDays, 180)
    }

    /// Single-day stays with the given gaps (next start − previous end) between them.
    func gapped(_ gaps: [Int]) -> Place { known(gaps.reduce(into: [0]) { $0.append($0.last! + $1) }) }

    func testTypicalGapIsTheLowerMedianOfTheLastEight() {
        XCTAssertEqual(gapped(Array(repeating: 30, count: 7) + [200]).hideAfterDays, 210, "one long gap is not the typical one")
        XCTAssertEqual(gapped([100, 30, 100, 30, 100, 30, 100, 30]).hideAfterDays, 210, "even count takes the lower middle")
        XCTAssertEqual(gapped(Array(repeating: 200, count: 9) + Array(repeating: 30, count: 8)).hideAfterDays, 330, "only the last 8 gaps count")
        XCTAssertEqual(gapped([70, 200]).hideAfterDays, 210, "two gaps: the smaller")
        XCTAssertEqual(known([5, 6, 7]).hideAfterDays, 180, "one stay has no gap")
    }

    func testRealVisitTouchesEveryDayItCovers() throws {
        let fri = day0 + 4 * day + 10 * 3600   // Friday 20:00 to Sunday 10:00, one visit
        let away = visit(at: fri, minutes: 38 * 60)
        let a = Places.learn([], visit: away, now: away.end, nextId: 1).places
        XCTAssertEqual(a[0].realDays, Set(Places.day(fri)...Places.day(away.end)))
        XCTAssertEqual(a[0].realDays.count, 3)
        let later = visit(at: day0 + 86 * day, minutes: 360)   // 80 days after Sunday
        let b = Places.learn(a, visit: later, now: later.end, nextId: 2).places
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].hideAfterDays, 240)   // gap 80, not 82
        let night = visit(at: day0 + 11 * 3600, minutes: 360)   // 21:00 to 3:00 the next morning
        XCTAssertEqual(Places.learn([], visit: night, now: night.end, nextId: 1).places[0].realDays.count, 2)
    }

    func testBreaksDoNotHideAndARealVisitBringsItBack() {
        let t = day0, today = Places.day(t)
        func at(_ p: Place, after n: Int) -> Bool { p.isVisible(at: t + Double(n - today + (p.realDays.max() ?? 0)) * day) }
        let school = known((0..<1465).filter { $0 % 7 < 5 })
        XCTAssertTrue(at(school, after: 49)); XCTAssertTrue(at(school, after: 300)); XCTAssertFalse(at(school, after: 301))
        let gym = known((0..<731).filter { [0, 2, 4].contains($0 % 7) })
        XCTAssertTrue(at(gym, after: 120)); XCTAssertFalse(at(gym, after: 241))
        let holiday = known(stays(4, every: 365, stay: 14))
        XCTAssertTrue(at(holiday, after: 717)); XCTAssertTrue(at(holiday, after: 730)); XCTAssertFalse(at(holiday, after: 731))
        var back = known(stays(11, every: 121, stay: 2))   // hides after 450 days
        let late = back.realDays.max()! + 500
        XCTAssertFalse(back.isVisible(at: t + Double(late - today) * day))
        back.realDays.insert(late)
        XCTAssertTrue(back.isVisible(at: t + Double(late - today) * day))
    }

    func testMergeReevaluatesPoints() throws {
        let a = onDays((0..<12).map(Double.init), minutes: 60)
        let b = onDays((12..<24).map(Double.init), east: 30, minutes: 60)
        let two = fold(fold([], a), b)
        XCTAssertEqual(two.map(\.isCandidate), [true, true])   // 60 points each
        let bridge = Places.learn(two, visit: visit(at: day0 + 24 * day, east: 15, minutes: 180), now: day0 + 24 * day + 3 * 3600, nextId: 9).places
        XCTAssertEqual(bridge.count, 1)
        XCTAssertFalse(bridge[0].isCandidate)
        XCTAssertEqual(bridge[0].points, 127, accuracy: 0.01)
        XCTAssertEqual(bridge[0].recentDurations.count, 20)
        XCTAssertEqual(bridge[0].realDays.count, 23)   // 11 + 11 + the bridge: first visits are not real
    }

    func testFarCandidatesDoNotChangeResult() throws {
        // 2 000 one-cell candidates 1 km apart, far from home, must not affect learning there.
        let far = (0..<2000).map { i -> Place in
            let p = Geo.offset(lat: 52.0, lon: 5.0, north: 5000 + Double(i / 50) * 1000, east: Double(i % 50) * 1000)
            return Place(id: Int64(1000 + i), name: nil, cells: [PlaceGrid.cell(lat: p.lat, lon: p.lon): 1], updatedAt: day0, lastVisit: day0,
                         totalSeconds: 600, visits: 1, isCandidate: true)
        }
        let alone = try XCTUnwrap(fold([], homeDays(week)).first)
        let crowd = fold(far, homeDays(week))
        XCTAssertEqual(crowd.count, 2001)
        var home = try XCTUnwrap(crowd.last)
        home.id = alone.id
        XCTAssertEqual(home, alone)
    }

    func testNeighbourSixtyMetresStaysSeparate() {
        let home = fold([], homeDays(week, hAcc: 10))
        let ps = fold(home, homeDays(week.map { $0 + 10 }, east: 60, hAcc: 10))
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
        let home = fold([], homeDays(week))
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
