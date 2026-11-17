import XCTest
@testable import Core

final class MapMatcherTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A way through (node, north, east) points, offsets in metres from (52.37, 4.90), the origin of `walk`.
    func way(_ id: Int64, _ kind: WayKind, _ pts: [(Int64, Double, Double)]) -> Way {
        Way(id: id, kind: kind, name: nil, oneway: false, nodes: pts.map(\.0),
            coords: pts.map { Geo.offset(lat: 52.37, lon: 4.90, north: $0.1, east: $0.2) })
    }

    /// The true street (1) runs north along east = 0; a parallel street (2) 50 m east; cross streets every 200 m;
    /// an alley (9, footway) joins them at north 300.
    var canyon: RoadGraph {
        let ns: [Double] = [0, 200, 300, 400, 600]
        var ways = [way(1, .road, ns.enumerated().map { (Int64($0.offset + 1), $0.element, 0) }),
                    way(2, .road, ns.enumerated().map { (Int64($0.offset + 11), $0.element, 50) }),
                    way(9, .foot, [(3, 300, 0), (13, 300, 50)])]
        for (k, n) in [(1, 0.0), (2, 200), (4, 400), (5, 600)] {
            ways.append(way(Int64(k + 2), .road, [(Int64(k + 20), n, -60), (Int64(k), n, 0), (Int64(k + 10), n, 50)]))
        }
        return RoadGraph(ways: ways)
    }

    /// 600 m walk along the true street with five 25–35 m multipath bursts toward the parallel street (one at the alley),
    /// through the live filter as in the app.
    func canyonWalk() -> [FilteredPoint] {
        let w = walk(path: [(0, 0), (600, 0)], speed: 1.4, every: 1, noise: 3, seed: 7, start: t0, doppler: .foot)
        var rng = SeededRandom(seed: 99)
        var s = w.samples
        for start in [60, 140, 208, 280, 350] {
            s = multipath(s, range: start..<start + 10, east: .random(in: 25...35, using: &rng), hAcc: 8, course: .invalid)
        }
        var f = TrackFilter(quality: .balanced)
        return s.compactMap { f.process($0, receivedAt: $0.t, activity: .walking) }
    }

    /// Share of the trip's time (constant speed, so distance) inside confident stretches on `wayId`.
    func share(_ m: [MatchedStretch], _ pts: [FilteredPoint], on wayId: Int64) -> Double {
        let total = pts.last!.t.timeIntervalSince(pts.first!.t)
        return m.filter { $0.wayId == wayId && $0.confidence >= MapMatcher.confident }
            .map { $0.end.timeIntervalSince($0.start) }.reduce(0, +) / total
    }

    func testCanyonWalkOnCorrectStreet() {
        let pts = canyonWalk()
        let m = MapMatcher.match(pts, graph: canyon)
        let s = share(m, pts, on: 1)
        print("MEAS canyon share on true street", s, m.map { ($0.wayId, $0.start, $0.end, $0.confidence) })
        XCTAssertGreaterThanOrEqual(s, 0.95)
    }

    func testParallelStreetAndAlleyNotChosen() {
        let m = MapMatcher.match(canyonWalk(), graph: canyon)
        XCTAssertFalse(m.contains { $0.wayId == 2 || $0.wayId == 9 }, "\(m.map { ($0.wayId, $0.start, $0.end) })")
    }

    /// 30 min of rough fixes at `speed` beside rail (1) and a motorway (2) 150 m apart; fixes every 10 s, hAcc 700–1500,
    /// error ≤ 300 m toward the motorway.
    func roughRide(speed: Double) -> (pts: [FilteredPoint], graph: RoadGraph) {
        let railNodes = (0...120).map { i -> (Int64, Double, Double) in (Int64(i), 0, Double(i) * 500 - 2000) }
        let roadNodes = (0...120).map { i -> (Int64, Double, Double) in (Int64(i + 1000), 150, Double(i) * 500 - 2000) }
        let rail = way(1, .rail, railNodes), road = way(2, .road, roadNodes)
        var rng = SeededRandom(seed: 3)
        let pts = (0..<180).map { i -> FilteredPoint in
            let a = Double.random(in: 0...Double.pi, using: &rng), r = Double.random(in: 0...300, using: &rng)
            let p = Geo.offset(lat: 52.37, lon: 4.90, north: r * sin(a), east: Double(i) * speed * 10 + r * cos(a))
            return FilteredPoint(t: t0.addingTimeInterval(Double(i) * 10), lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon,
                                 hAcc: .random(in: 700...1500, using: &rng), speed: -1, kind: .rough)
        }
        return (pts, RoadGraph(ways: [rail, road]))
    }

    func testRoughCarBesideRailwayStaysUnsure() {
        // 20 m/s: without a confident mode a car in struggle mode is as likely as a train, so never drawn solid on the rail;
        // inside a confident car stretch rough fixes are not matched at all.
        let (pts, g) = roughRide(speed: 20)
        let m = MapMatcher.match(pts, graph: g)
        XCTAssertFalse(m.isEmpty)
        XCTAssertFalse(m.contains { $0.confidence >= MapMatcher.confident })
        XCTAssertTrue(MapMatcher.match(pts, graph: g, modes: [whole(.car, pts)]).isEmpty)
    }

    /// One stretch of `mode` over all of `pts`.
    func whole(_ mode: TravelMode, _ pts: [FilteredPoint], confidence: Double = 0.9) -> ModeStretch {
        ModeStretch(seq: 0, mode: mode, confidence: confidence, first: 0, last: pts.count - 1)
    }

    func testTrainStretchNeverMatchesRoad() {
        // Rail (1) along east 0, road (2) along east 30; fixes along east 40 at 25 m/s.
        let g = RoadGraph(ways: [way(1, .rail, [(1, 0, 0), (2, 3000, 0)]), way(2, .road, [(11, 0, 30), (12, 3000, 30)])])
        let pts = ride(path: [(0, 40), (3000, 40)], speed: 25, every: 1, noise: 3, seed: 21, start: t0).map { p -> FilteredPoint in
            var p = p; p.hAcc = 25; return p
        }
        XCTAssertTrue(MapMatcher.match(pts, graph: g).contains { $0.wayId == 2 })   // without modes the road wins
        let m = MapMatcher.match(pts, graph: g, modes: [whole(.train, pts)])
        XCTAssertFalse(m.isEmpty)
        XCTAssertTrue(m.allSatisfy { $0.wayId == 1 }, "\(m.map { ($0.wayId, $0.start, $0.end) })")
    }

    func testBikePrefersCyclePath() {
        // Road (1) along east 0, cycle way (2) along east 8; fixes centred between them.
        let g = RoadGraph(ways: [way(1, .road, [(1, 0, 0), (2, 1000, 0)]), way(2, .cycle, [(11, 0, 8), (12, 1000, 8)])])
        let pts = ride(path: [(0, 4), (1000, 4)], speed: 5, every: 1, noise: 4, seed: 23, start: t0)
        let m = MapMatcher.match(pts, graph: g, modes: [whole(.bike, pts)])
        let s = share(m, pts, on: 2)
        print("MEAS bike cycle share", s)
        XCTAssertGreaterThanOrEqual(s, 0.9)
    }

    func testSlowRoughTrainStillMatchesRail() {
        let (pts, g) = roughRide(speed: 8)
        XCTAssertTrue(MapMatcher.match(pts, graph: g).isEmpty)   // 3a: slow rough fixes stay unmatched
        let m = MapMatcher.match(pts, graph: g, modes: [whole(.train, pts)])
        let s = share(m, pts, on: 1)
        print("MEAS slow rough train rail share", s)
        XCTAssertFalse(m.isEmpty)
        XCTAssertTrue(m.allSatisfy { $0.wayId == 1 })
        XCTAssertGreaterThanOrEqual(s, 0.9)
    }

    func testUnsureModeKeepsOldRules() {
        let pts = canyonWalk()
        XCTAssertEqual(MapMatcher.match(pts, graph: canyon, modes: [whole(.car, pts, confidence: 0.3)]), MapMatcher.match(pts, graph: canyon))
    }

    func testRoughTrainMatchesRailNotMotorway() {
        let (pts, g) = roughRide(speed: 30)
        let m = MapMatcher.match(pts, graph: g)
        let s = share(m, pts, on: 1)
        print("MEAS rough train rail share", s, "stretches", m.count)
        XCTAssertFalse(m.isEmpty)
        XCTAssertTrue(m.allSatisfy { $0.wayId == 1 })
        XCTAssertGreaterThanOrEqual(s, 0.9)
    }

    func testParkWalkUnmatched() {
        // Paths round a 400 m park; the walk crosses its middle, at least 100 m from any way.
        let g = RoadGraph(ways: [way(1, .foot, [(1, 0, 0), (2, 0, 400), (3, 400, 400), (4, 400, 0), (1, 0, 0)])])
        let w = walk(path: [(100, 100), (300, 300)], speed: 1.4, every: 1, noise: 3, seed: 5, start: t0)
        let pts = w.samples.map { FilteredPoint(t: $0.t, lat: $0.lat, lon: $0.lon, rawLat: $0.lat, rawLon: $0.lon, hAcc: $0.hAcc, speed: $0.speed, kind: .moving) }
        XCTAssertFalse(MapMatcher.match(pts, graph: g).contains { $0.confidence >= MapMatcher.confident })
    }

    func testStillPointsSkipped() {
        // A pause on the true street whose still fixes wander onto the parallel street.
        let w = walk(path: [(0, 0), (600, 0)], speed: 1.4, every: 1, noise: 3, seed: 11, start: t0)
        let pts = w.samples.enumerated().map { i, s -> FilteredPoint in
            let still = (150..<210).contains(i)
            let p = still ? Geo.offset(lat: s.lat, lon: s.lon, north: 0, east: 48) : (s.lat, s.lon)
            return FilteredPoint(t: s.t, lat: p.0, lon: p.1, rawLat: p.0, rawLon: p.1, hAcc: s.hAcc, speed: still ? 0 : s.speed, kind: still ? .still : .moving)
        }
        let m = MapMatcher.match(pts, graph: canyon)
        XCTAssertFalse(m.contains { $0.wayId != 1 }, "\(m.map { ($0.wayId, $0.start, $0.end) })")
        let still = Set(pts[150..<210].map { $0.t })
        XCTAssertFalse(m.contains { still.contains($0.start) || still.contains($0.end) })
        print("MEAS still share", share(m, pts, on: 1), m.map { ($0.wayId, $0.start, $0.end, $0.confidence) })
        XCTAssertGreaterThanOrEqual(share(m, pts, on: 1), 0.95)
    }
}
