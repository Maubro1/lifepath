import XCTest
@testable import Core

final class CoverageTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A way through (node, north, east) points, offsets in metres from (52, 5).
    func way(_ id: Int64, _ pts: [(Int64, Double, Double)], name: String? = "Dorpsstraat", kind: WayKind = .road, countable: Bool = true) -> Way {
        Way(id: id, kind: kind, name: name, oneway: false, nodes: pts.map(\.0),
            coords: pts.map { (p: (Int64, Double, Double)) -> (lat: Double, lon: Double) in Geo.offset(lat: 52, lon: 5, north: p.1, east: p.2) },
            countable: countable)
    }

    func mode(_ m: TravelMode, _ a: Double, _ b: Double, _ conf: Double = 0.9) -> ModeStretch {
        ModeStretch(seq: 0, mode: m, confidence: conf, start: t0 + a, end: t0 + b)
    }

    func matched(_ wayId: Int64, _ fromM: Double, _ toM: Double, _ a: Double, _ b: Double, _ conf: Double = 0.9) -> MatchedStretch {
        MatchedStretch(seq: 0, wayId: wayId, fromM: fromM, toM: toM, confidence: conf, start: t0 + a, end: t0 + b)
    }

    func segs(_ h: Set<SegmentHit>, _ wayId: Int64) -> Set<Int> {
        Set(h.filter { (x: SegmentHit) -> Bool in x.wayId == wayId }.map { (x: SegmentHit) -> Int in x.seg })
    }

    func testSegments() {
        XCTAssertEqual(Coverage.segments(5), 1)
        XCTAssertEqual(Coverage.segments(29), 1)
        XCTAssertEqual(Coverage.segments(31), 2)
        XCTAssertEqual(Coverage.segments(1000), 50)
    }

    func testWalkHitsStreet() {
        let w = way(1, [(1, 0, 0), (2, 0, 200)])
        let h = Coverage.hits([matched(1, 0, 200, 0, 140)], modes: [mode(.walk, 0, 140)], graph: RoadGraph(ways: [w]))
        XCTAssertEqual(segs(h, 1), Set(0..<10))
        let r = Coverage.streets(ways: [w], hits: Array(h))
        XCTAssertEqual(r.onFoot, 1); XCTAssertEqual(r.total, 1); XCTAssertEqual(r.ways, [1: false])
    }

    func testBusPartNeverCounts() {
        let w = way(1, [(1, 0, 0), (2, 0, 400)])
        let h = Coverage.hits([matched(1, 0, 400, 0, 400)], modes: [mode(.walk, 0, 100), mode(.bus, 100, 400)], graph: RoadGraph(ways: [w]))
        XCTAssertTrue(Set(0...4).isSubset(of: segs(h, 1)))
        XCTAssertTrue(segs(h, 1).isSubset(of: Set(0...5)))
    }

    func testUnsureNeverCounts() {
        let g = RoadGraph(ways: [way(1, [(1, 0, 0), (2, 0, 200)])])
        XCTAssertTrue(Coverage.hits([matched(1, 0, 200, 0, 140)], modes: [mode(.walk, 0, 140, 0.3)], graph: g).isEmpty)
        XCTAssertTrue(Coverage.hits([matched(1, 0, 200, 0, 140, 0.3)], modes: [mode(.walk, 0, 140)], graph: g).isEmpty)
    }

    func testSidewalkCreditsStreet() {
        let road = way(1, [(1, 0, 0), (2, 0, 200)])
        let sidewalk = way(2, [(3, 8, 0), (4, 8, 200)], name: nil, kind: .foot, countable: false)
        let h = Coverage.hits([matched(2, 0, 200, 0, 140)], modes: [mode(.walk, 0, 140)], graph: RoadGraph(ways: [road, sidewalk]))
        XCTAssertEqual(segs(h, 1), Set(0..<10))
        XCTAssertTrue(segs(h, 2).isEmpty)
        let r = Coverage.streets(ways: [road, sidewalk], hits: Array(h))
        XCTAssertEqual(r.total, 1); XCTAssertEqual(r.onFoot, 1)
    }

    func testNinetyPercentRule() {
        let long = way(1, [(1, 0, 0), (2, 0, 1000)])
        let hits = { (n: Int) -> [SegmentHit] in (0..<n).map { (s: Int) -> SegmentHit in SegmentHit(wayId: 1, seg: s, bike: false) } }
        XCTAssertEqual(Coverage.streets(ways: [long], hits: hits(45)).onFoot, 1)
        XCTAssertEqual(Coverage.streets(ways: [long], hits: hits(44)).onFoot, 0)
        let short = way(1, [(1, 0, 0), (2, 0, 200)])
        XCTAssertEqual(Coverage.streets(ways: [short], hits: hits(9)).onFoot, 0)
        XCTAssertEqual(Coverage.streets(ways: [short], hits: hits(10)).onFoot, 1)
    }

    func testSameNameApartAreTwoStreets() {
        let a = way(1, [(1, 0, 0), (2, 0, 200)], name: "Kerkstraat"), b = way(2, [(3, 5000, 0), (4, 5000, 200)], name: "Kerkstraat")
        XCTAssertEqual(Coverage.streets(ways: [a, b], hits: []).total, 2)
        let joined = way(2, [(2, 0, 200), (4, 0, 400)], name: "Kerkstraat")
        XCTAssertEqual(Coverage.streets(ways: [a, joined], hits: []).total, 1)
        let h = Coverage.hits([matched(1, 0, 200, 0, 140)], modes: [mode(.walk, 0, 140)], graph: RoadGraph(ways: [a, b]))
        let r = Coverage.streets(ways: [a, b], hits: Array(h))
        XCTAssertEqual(r.onFoot, 1); XCTAssertEqual(r.total, 2); XCTAssertEqual(r.ways, [1: false])
    }

    func testCyclingCountsOnlyWithBike() {
        let w = way(1, [(1, 0, 0), (2, 0, 200)])
        let h = Coverage.hits([matched(1, 0, 200, 0, 40)], modes: [mode(.bike, 0, 40)], graph: RoadGraph(ways: [w]))
        let r = Coverage.streets(ways: [w], hits: Array(h))
        XCTAssertEqual(r.onFoot, 0); XCTAssertEqual(r.withBike, 1); XCTAssertEqual(r.ways[1], true)
    }

    func testZeroLengthWayDoesNotTrap() {
        let real = way(1, [(1, 0, 0), (2, 0, 200)])
        let dot = way(2, [(3, 0, 100), (4, 0, 100)], name: "Punt")
        let h = Coverage.hits([matched(1, 0, 200, 0, 140)], modes: [mode(.walk, 0, 140)], graph: RoadGraph(ways: [real, dot]))
        XCTAssertEqual(segs(h, 1), Set(0..<10))
        XCTAssertEqual(segs(h, 2), [])
    }

    // MARK: progress per place

    /// A square area from (south, west) to (north, east), offsets in metres from (52, 5).
    func area(_ id: Int64, _ level: Int, _ s: Double, _ w: Double, _ n: Double, _ e: Double) -> Area {
        let c = [(s, w), (s, e), (n, e), (n, w), (s, w)].map { Geo.offset(lat: 52, lon: 5, north: $0.0, east: $0.1) }
        return Area(id: id, level: level, name: "a\(id)", rings: [c], holes: [])
    }

    func hit(_ wayId: Int64, _ seg: Int, _ at: Double, bike: Bool = false) -> (hit: SegmentHit, tripStart: Date) {
        (SegmentHit(wayId: wayId, seg: seg, bike: bike), t0 + at)
    }

    func testStreetCountedInMidpointArea() {
        // One 200 m street from east 0 to 200; the border between neighbourhoods 2 and 3 is at east 150, so its midpoint (100) is in 2.
        let w = way(1, [(1, 0, 0), (2, 0, 200)])
        let areas = [area(1, 8, -500, -500, 500, 500), area(2, 10, -500, -500, 500, 150), area(3, 10, -500, 150, 500, 500)]
        let r = Coverage.progress(ways: [w], hits: (0..<10).map { hit(1, $0, 0) }, areas: areas, bike: false)
        XCTAssertEqual(r.areas, [AreaProgress(areaId: 1, covered: 1, total: 1), AreaProgress(areaId: 2, covered: 1, total: 1)])
    }

    func testCityTotalsAddUp() {
        let a = way(1, [(1, 0, 0), (2, 0, 100)], name: "A"), b = way(2, [(3, 300, 0), (4, 300, 100)], name: "B"), c = way(3, [(5, 0, 300), (6, 0, 400)], name: "C")
        let areas = [area(1, 8, -500, -500, 500, 500), area(2, 10, -500, -500, 200, 200), area(3, 10, 200, -500, 500, 200)]
        let r = Coverage.progress(ways: [a, b, c], hits: [], areas: areas, bike: false)
        let total = { (id: Int64) in r.areas.first { $0.areaId == id }?.total ?? 0 }
        XCTAssertEqual(total(1), 3)
        XCTAssertEqual(total(2) + total(3), 2)   // street C lies in no neighbourhood: counted for the city only
    }

    func testCoveredDateIsTripThatCompletedIt() {
        let w = way(1, [(1, 0, 0), (2, 0, 200)])   // 10 segments: every one needed
        let hits = (0..<4).map { hit(1, $0, 0) } + (4..<10).map { hit(1, $0, 100) } + [hit(1, 0, 200)]
        let r = Coverage.progress(ways: [w], hits: hits, areas: [area(1, 8, -500, -500, 500, 500)], bike: false)
        XCTAssertEqual(r.covered, ["1": t0 + 100])
    }

    func testBikeOnlyExcludedOnFoot() {
        let w = way(1, [(1, 0, 0), (2, 0, 200)])
        let hits = (0..<10).map { hit(1, $0, 0, bike: true) }
        let areas = [area(1, 8, -500, -500, 500, 500)]
        XCTAssertEqual(Coverage.progress(ways: [w], hits: hits, areas: areas, bike: false).areas, [AreaProgress(areaId: 1, covered: 0, total: 1)])
        XCTAssertEqual(Coverage.progress(ways: [w], hits: hits, areas: areas, bike: true).covered, ["1": t0])
    }

    func testStreetOutsideAnyCityHasNoArea() {
        let w = way(1, [(1, 0, 0), (2, 0, 200)])
        let r = Coverage.progress(ways: [w], hits: (0..<10).map { hit(1, $0, 0) }, areas: [], bike: false)
        XCTAssertTrue(r.areas.isEmpty)
        XCTAssertEqual(r.covered, ["1": t0])   // still a new street for the day counts
    }
}
