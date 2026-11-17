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
            .map { pts[$0.last].t.timeIntervalSince(pts[$0.first].t) }.reduce(0, +) / total
    }

    func testCanyonWalkOnCorrectStreet() {
        let pts = canyonWalk()
        let m = MapMatcher.match(pts, graph: canyon)
        let s = share(m, pts, on: 1)
        print("MEAS canyon share on true street", s, m.map { ($0.wayId, $0.first, $0.last, $0.confidence) })
        XCTAssertGreaterThanOrEqual(s, 0.95)
    }

    func testParallelStreetAndAlleyNotChosen() {
        let m = MapMatcher.match(canyonWalk(), graph: canyon)
        XCTAssertFalse(m.contains { $0.wayId == 2 || $0.wayId == 9 }, "\(m.map { ($0.wayId, $0.first, $0.last) })")
    }

    func testRoughTrainMatchesRailNotMotorway() {
        // 30 min at 25 m/s; rail (1) and motorway (2) 150 m apart; fixes every 10 s, hAcc 700–1500, error ≤ 300 m toward the motorway.
        let rail = way(1, .rail, (0...100).map { (Int64($0), 0, Double($0) * 500 - 2000) })
        let road = way(2, .road, (0...100).map { (Int64($0 + 1000), 150, Double($0) * 500 - 2000) })
        var rng = SeededRandom(seed: 3)
        let pts = (0..<180).map { i -> FilteredPoint in
            let a = Double.random(in: 0...Double.pi, using: &rng), r = Double.random(in: 0...300, using: &rng)
            let p = Geo.offset(lat: 52.37, lon: 4.90, north: r * sin(a), east: Double(i) * 250 + r * cos(a))
            return FilteredPoint(t: t0.addingTimeInterval(Double(i) * 10), lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon,
                                 hAcc: .random(in: 700...1500, using: &rng), speed: -1, kind: .rough)
        }
        let m = MapMatcher.match(pts, graph: RoadGraph(ways: [rail, road]))
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
        XCTAssertFalse(m.contains { $0.wayId != 1 }, "\(m.map { ($0.wayId, $0.first, $0.last) })")
        XCTAssertFalse(m.contains { (150..<210).contains($0.first) || (150..<210).contains($0.last) })
        print("MEAS still share", share(m, pts, on: 1), m.map { ($0.wayId, $0.first, $0.last, $0.confidence) })
        XCTAssertGreaterThanOrEqual(share(m, pts, on: 1), 0.95)
    }
}
