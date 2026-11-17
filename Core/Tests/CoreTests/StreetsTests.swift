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
        let ways = try OSM.parse(Data(json.utf8))
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

    func testTileKeyAndBounds() {
        let t = Tile(lat: 52.0, lon: 5.0)
        XCTAssertEqual(t, Tile(x: 166, y: 2888))
        let b = t.bounds
        XCTAssertEqual(b.minLon, 4.98, accuracy: 1e-9); XCTAssertEqual(b.maxLon, 5.01, accuracy: 1e-9)
        XCTAssertEqual(b.minLat, 51.984, accuracy: 1e-9); XCTAssertEqual(b.maxLat, 52.002, accuracy: 1e-9)
        XCTAssertEqual(Tile(lat: -0.001, lon: -0.001), Tile(x: -1, y: -1))
    }
}
