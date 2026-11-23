import XCTest
@testable import Core

final class StreetsTests: XCTestCase {
    /// A way through (node, north, east) points, offsets in metres from (52, 5).
    func way(_ id: Int64, _ pts: [(Int64, Double, Double)], oneway: Bool = false) -> Way {
        Way(id: id, kind: .road, name: nil, oneway: oneway, nodes: pts.map(\.0),
            coords: pts.map { Geo.offset(lat: 52, lon: 5, north: $0.1, east: $0.2) })
    }

    /// 3 x 3 blocks of 100 m: horizontal ways 100...103, vertical ways 200...203; node id = row * 10 + col.
    var grid: RoadGraph {
        var ways: [Way] = []
        for r in 0...3 { ways.append(way(100 + Int64(r), (0...3).map { (Int64(r * 10 + $0), Double(r) * 100, Double($0) * 100) })) }
        for c in 0...3 { ways.append(way(200 + Int64(c), (0...3).map { (Int64($0 * 10 + c), Double($0) * 100, Double(c) * 100) })) }
        return RoadGraph(ways: ways)
    }

    let json = """
    {"version":0.6,"elements":[
     {"type":"way","id":1,"nodes":[11,12,13],"geometry":[{"lat":52.0,"lon":5.0},{"lat":52.0,"lon":5.001},{"lat":52.001,"lon":5.001}],"tags":{"highway":"footway","name":"Parkpad"}},
     {"type":"way","id":2,"nodes":[21,22],"geometry":[{"lat":52.0,"lon":5.0},{"lat":52.0,"lon":5.002}],"tags":{"highway":"residential","oneway":"yes","name":"Dorpsstraat"}},
     {"type":"way","id":3,"nodes":[31,32],"geometry":[{"lat":52.1,"lon":5.0},{"lat":52.1,"lon":5.1}],"tags":{"railway":"rail"}},
     {"type":"way","id":4,"nodes":[41,42],"geometry":[{"lat":52.2,"lon":5.0},{"lat":52.2,"lon":5.1}],"tags":{"route":"ferry","name":"Veer"}},
     {"type":"way","id":5,"nodes":[51,52],"geometry":[{"lat":52.3,"lon":5.0},{"lat":52.3,"lon":5.1}],"tags":{"highway":"primary","junction":"roundabout"}},
     {"type":"way","id":6,"nodes":[61,62],"geometry":[{"lat":52.4,"lon":5.0},{"lat":52.4,"lon":5.1}],"tags":{"railway":"platform"}}
    ]}
    """

    func testParseOverpassJSON() throws {
        let ways = try OSM.parse(Data(json.utf8)).ways
        XCTAssertEqual(ways.map(\.id), [1, 2, 3, 4, 5])  // platform dropped
        XCTAssertEqual(ways.map(\.kind), [.foot, .road, .rail, .ferry, .road])
        XCTAssertEqual(ways.map(\.name), ["Parkpad", "Dorpsstraat", nil, "Veer", nil])
        XCTAssertEqual(ways.map(\.oneway), [false, true, false, false, true])  // oneway=yes, roundabout
        XCTAssertEqual(ways[0].nodes, [11, 12, 13])
        XCTAssertEqual(ways[0].coords.count, 3)
        XCTAssertEqual(ways[0].coords[2].lat, 52.001, accuracy: 1e-9)
        XCTAssertEqual(ways[0].coords[1].lon, 5.001, accuracy: 1e-9)
        XCTAssertThrowsError(try OSM.parse(Data("nope".utf8)))
        XCTAssertTrue(OSM.query(minLat: 52, minLon: 5, maxLat: 52.1, maxLon: 5.1).contains("(52.0,5.0,52.1,5.1)"))
    }

    func testParseStopsAndCycleways() throws {
        let j = """
        {"elements":[
         {"type":"way","id":1,"nodes":[1,2],"geometry":[{"lat":52.0,"lon":5.0},{"lat":52.0,"lon":5.001}],"tags":{"highway":"cycleway"}},
         {"type":"way","id":2,"nodes":[3,4],"geometry":[{"lat":52.0,"lon":5.0},{"lat":52.0,"lon":5.001}],"tags":{"highway":"path","bicycle":"designated"}},
         {"type":"way","id":3,"nodes":[5,6],"geometry":[{"lat":52.0,"lon":5.0},{"lat":52.0,"lon":5.001}],"tags":{"highway":"path"}},
         {"type":"node","id":10,"lat":52.1,"lon":5.1,"tags":{"highway":"bus_stop"}},
         {"type":"node","id":11,"lat":52.2,"lon":5.2,"tags":{"railway":"tram_stop"}},
         {"type":"node","id":12,"lat":52.3,"lon":5.3,"tags":{"railway":"station"}},
         {"type":"node","id":13,"lat":52.4,"lon":5.4,"tags":{"amenity":"ferry_terminal"}},
         {"type":"node","id":14,"lat":52.5,"lon":5.5,"tags":{"railway":"halt"}},
         {"type":"node","id":15,"lat":52.6,"lon":5.6,"tags":{"public_transport":"platform"}},
         {"type":"node","id":16,"lat":52.7,"lon":5.7}
        ]}
        """
        let r = try OSM.parse(Data(j.utf8))
        XCTAssertEqual(r.ways.map(\.kind), [.cycle, .cycle, .foot])
        XCTAssertEqual(WayKind.cycle.rawValue, "cycle")
        XCTAssertEqual(r.stops.map(\.id), [10, 11, 12, 13, 14])
        XCTAssertEqual(r.stops.map(\.kind), [.bus, .tram, .rail, .ferry, .rail])
        XCTAssertEqual(r.stops[3].lat, 52.4, accuracy: 1e-9); XCTAssertEqual(r.stops[3].lon, 5.4, accuracy: 1e-9)
        XCTAssertEqual(OSM.version, 3)
    }

    func testCountableWays() throws {
        func w(_ id: Int, _ tags: String) -> String {
            "{\"type\":\"way\",\"id\":\(id),\"nodes\":[1,2],\"geometry\":[{\"lat\":52.0,\"lon\":5.0},{\"lat\":52.0,\"lon\":5.001}],\"tags\":{\(tags)}}"
        }
        let j = "{\"elements\":[" + [
            w(1, "\"highway\":\"residential\",\"name\":\"Dorpsstraat\""),
            w(2, "\"highway\":\"motorway\""),
            w(3, "\"highway\":\"service\""),
            w(4, "\"highway\":\"footway\",\"footway\":\"sidewalk\""),
            w(5, "\"highway\":\"residential\",\"access\":\"private\",\"foot\":\"yes\""),
            w(6, "\"highway\":\"trunk\",\"foot\":\"no\""),
            w(7, "\"railway\":\"rail\""),
        ].joined(separator: ",") + "]}"
        let ways = try OSM.parse(Data(j.utf8)).ways
        XCTAssertEqual(ways.map(\.id), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(ways.map(\.countable), [true, false, false, false, true, false, false])
        XCTAssertNotEqual(ways[0], { var x = ways[0]; x.countable = false; return x }())
    }

    func testQueryAsksForStops() {
        let q = OSM.query(minLat: 52, minLon: 5, maxLat: 52.1, maxLon: 5.1)
        for s in ["bus_stop", "tram_stop", "ferry_terminal"] { XCTAssertTrue(q.contains(s), s) }
    }

    func testCandidatesWithinRadius() throws {
        let p = Geo.offset(lat: 52, lon: 5, north: 110, east: 150)  // 10 m north of horizontal way 101
        let c = grid.candidates(lat: p.lat, lon: p.lon, radius: 20)
        XCTAssertEqual(c.map(\.wayId), [101])
        XCTAssertEqual(c[0].segment, 1)
        XCTAssertEqual(c[0].t, 0.5, accuracy: 0.01)
        XCTAssertEqual(c[0].distance, 10, accuracy: 0.5)
        XCTAssertEqual(grid.candidates(lat: p.lat, lon: p.lon, radius: 5).count, 0)
        XCTAssertEqual(Set(grid.candidates(lat: p.lat, lon: p.lon, radius: 60).map(\.wayId)), [101, 201, 202])
    }

    func testGraphHoldsMoreThan32768Ways() {
        // A tile in a city holds tens of thousands of ways; a 32-bit packed segment key trapped past 32,767.
        let ways: [Way] = (0..<33_000).map { (k: Int) -> Way in
            let lat: Double = 52 + Double(k) * 1e-5
            let coords: [(lat: Double, lon: Double)] = [(lat, 5), (lat + 5e-6, 5)]
            return Way(id: Int64(k), kind: .road, name: nil, oneway: false, nodes: [Int64(2 * k), Int64(2 * k + 1)], coords: coords)
        }
        let g = RoadGraph(ways: ways)
        let last: Double = 52 + 32_999 * 1e-5
        XCTAssertEqual(g.candidates(lat: last, lon: 5, radius: 0.1).map { (c: Candidate) -> Int64 in c.wayId }, [32_999])
    }

    /// Two parallel 200 m streets 30 m apart, joined only at the west end.
    var ladder: RoadGraph {
        RoadGraph(ways: [way(1, [(1, 0, 0), (2, 0, 200)]), way(2, [(3, 30, 0), (4, 30, 200)]), way(3, [(1, 0, 0), (3, 30, 0)])])
    }

    func cand(_ g: RoadGraph, north: Double, east: Double) throws -> Candidate {
        let p = Geo.offset(lat: 52, lon: 5, north: north, east: east)
        return try XCTUnwrap(g.candidates(lat: p.lat, lon: p.lon, radius: 5).first)
    }

    func testRouteDistanceFollowsNetwork() throws {
        let g = ladder
        let a = try cand(g, north: 0, east: 100), b = try cand(g, north: 30, east: 100), c = try cand(g, north: 0, east: 160)
        XCTAssertEqual(try XCTUnwrap(g.routeDistance(from: a, to: b, limit: 1000)), 230, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(g.routeDistance(from: a, to: c, limit: 1000)), 60, accuracy: 1)  // same segment
    }

    func testRouteRespectsLimit() throws {
        let g = ladder
        let a = try cand(g, north: 0, east: 100), b = try cand(g, north: 30, east: 100)
        XCTAssertNil(g.routeDistance(from: a, to: b, limit: 200))
        // A one-way street cannot be driven backwards, and nothing leads round.
        let one = RoadGraph(ways: [way(1, [(1, 0, 0), (2, 0, 200)], oneway: true)])
        let x = try cand(one, north: 0, east: 50), y = try cand(one, north: 0, east: 150)
        XCTAssertNotNil(one.routeDistance(from: x, to: y, limit: 1000))
        XCTAssertNil(one.routeDistance(from: y, to: x, limit: 1000))
        XCTAssertEqual(try XCTUnwrap(one.routeDistance(from: y, to: x, limit: 1000, oneway: false)), 100, accuracy: 1)  // on foot
    }

    func testBatchRouteDistancesMatchPairwise() {
        // 4×4 grid, 100 m apart: rows are 3-segment ways (rows 1 and 3 one-way east), columns two-way.
        let node = { (r: Int, c: Int) -> (Int64, Double, Double) in (Int64(r * 4 + c), Double(r) * 100, Double(c) * 100) }
        let rows: [Way] = (0..<4).map { (r: Int) -> Way in way(Int64(10 + r), (0..<4).map { (c: Int) in node(r, c) }, oneway: r % 2 == 1) }
        let cols: [Way] = (0..<4).map { (c: Int) -> Way in way(Int64(20 + c), (0..<4).map { (r: Int) in node(r, c) }) }
        let g = RoadGraph(ways: rows + cols)
        let spots: [(n: Double, e: Double)] = [(0, 40), (0, 70), (100, 30), (100, 80), (100, 250), (200, 150), (300, 10), (300, 290), (150, 100), (50, 300)]
        let cands: [Candidate] = spots.flatMap { (s: (n: Double, e: Double)) -> [Candidate] in
            let p = Geo.offset(lat: 52, lon: 5, north: s.n, east: s.e)
            return g.candidates(lat: p.lat, lon: p.lon, radius: 5)
        }
        XCTAssertEqual(cands.count, spots.count)
        for limit in [60.0, 250, 10_000] { for oneway in [true, false] { for a in cands {
            let pair: [Double?] = cands.map { (b: Candidate) -> Double? in g.routeDistance(from: a, to: b, limit: limit, oneway: oneway) }
            XCTAssertEqual(g.routeDistances(from: a, to: cands, limit: limit, oneway: oneway), pair)
        } } }
    }

    func testSliceBothDirectionsAndPartialSegments() {
        let w = way(1, [(1, 0, 0), (2, 0, 100), (3, 100, 100)])   // 100 m east, then 100 m north
        let fwd = w.slice(fromM: 50, toM: 150)
        XCTAssertEqual(fwd.count, 3)   // partial start, corner, partial end
        XCTAssertEqual(fwd[1].lat, w.coords[1].lat, accuracy: 1e-9); XCTAssertEqual(fwd[1].lon, w.coords[1].lon, accuracy: 1e-9)
        XCTAssertEqual(Geo.distance(fwd[0].lat, fwd[0].lon, fwd[1].lat, fwd[1].lon), 50, accuracy: 1)
        XCTAssertEqual(Geo.distance(fwd[1].lat, fwd[1].lon, fwd[2].lat, fwd[2].lon), 50, accuracy: 1)
        let back = w.slice(fromM: 150, toM: 50)
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[0].lat, fwd[2].lat, accuracy: 1e-9); XCTAssertEqual(back[2].lon, fwd[0].lon, accuracy: 1e-9)
        XCTAssertEqual(w.slice(fromM: 20, toM: 60).count, 2)   // inside one segment
    }

    func testTileKeyAndBounds() {
        let t = Tile(lat: 52.0, lon: 5.0)
        XCTAssertEqual(t, Tile(x: 166, y: 2888))
        let b = t.bounds
        XCTAssertEqual(b.minLon, 4.98, accuracy: 1e-9); XCTAssertEqual(b.maxLon, 5.01, accuracy: 1e-9)
        XCTAssertEqual(b.minLat, 51.984, accuracy: 1e-9); XCTAssertEqual(b.maxLat, 52.002, accuracy: 1e-9)
        XCTAssertEqual(Tile(lat: -0.001, lon: -0.001), Tile(x: -1, y: -1))
    }

    /// A roundabout: a closed 400 m square whose node list starts at one corner. Crossing that corner goes the short way.
    func testClosedWayIsCrossedTheShortWay() {
        let c = [(0.0, 0.0), (0, 100), (100, 100), (100, 0), (0, 0)].map { Geo.offset(lat: 52, lon: 5, north: $0.0, east: $0.1) }
        func length(_ s: [(lat: Double, lon: Double)]) -> Double { zip(s, s.dropFirst()).map { Geo.distance($0.lat, $0.lon, $1.lat, $1.lon) }.reduce(0, +) }
        let ring = Way(id: 1, kind: .cycle, name: nil, oneway: false, nodes: [1, 2, 3, 4, 1], coords: c)
        XCTAssertEqual(length(ring.slice(fromM: 350, toM: 50)), 100, accuracy: 1, "forward across the start")
        XCTAssertEqual(length(ring.slice(fromM: 50, toM: 350)), 100, accuracy: 1, "backward across the start")
        XCTAssertEqual(length(ring.slice(fromM: 100, toM: 250)), 150, accuracy: 1, "no seam: as before")
        let oneway = Way(id: 2, kind: .road, name: nil, oneway: true, nodes: [1, 2, 3, 4, 1], coords: c)
        XCTAssertEqual(length(oneway.slice(fromM: 50, toM: 350)), 300, accuracy: 1, "one-way: forward, even the long way")
        XCTAssertEqual(length(oneway.slice(fromM: 350, toM: 50)), 100, accuracy: 1)
        // Fixes along the far side (a walk round the pond the long way): the long way is drawn, not the short one.
        let far = [(100.0, 50.0), (100, 100), (50, 100)].map { Geo.offset(lat: 52, lon: 5, north: $0.0, east: $0.1) }
        XCTAssertEqual(length(ring.slice(fromM: 350, toM: 50, near: far)), 300, accuracy: 1)
    }
}
