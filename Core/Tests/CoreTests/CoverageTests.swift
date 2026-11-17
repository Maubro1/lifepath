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
}
