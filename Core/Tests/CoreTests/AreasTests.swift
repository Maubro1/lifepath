import XCTest
@testable import Core

final class AreasTests: XCTestCase {
    typealias C = (lat: Double, lon: Double)

    func square(_ lat: Double, _ lon: Double, _ size: Double) -> [C] {
        [(lat, lon), (lat, lon + size), (lat + size, lon + size), (lat + size, lon), (lat, lon)]
    }

    func area(_ id: Int64, _ level: Int, _ ring: [C], holes: [[C]] = []) -> Area {
        Area(id: id, level: level, name: "a\(id)", rings: [ring], holes: holes)
    }

    func testAssembleOutOfOrderReversedWays() {
        // A 1x1 square cut into four ways; two reversed, order shuffled.
        let a: [C] = [(0, 0), (0, 1)], b: [C] = [(0, 1), (1, 1)], c: [C] = [(1, 1), (1, 0)], d: [C] = [(1, 0), (0, 0)]
        let r = Areas.assemble([("outer", c), ("outer", Array(a.reversed())), ("outer", d), ("outer", Array(b.reversed()))])
        XCTAssertEqual(r.outer.count, 1)
        XCTAssertEqual(r.outer[0].count, 5)
        XCTAssertTrue(r.outer[0].first! == r.outer[0].last!)
        XCTAssertTrue(r.inner.isEmpty)
    }

    func testUnclosedChainDropped() {
        let r = Areas.assemble([("outer", [(0, 0), (0, 1)]), ("outer", [(0, 1), (1, 1)])])
        XCTAssertTrue(r.outer.isEmpty)
    }

    func testHoleExcluded() {
        let a = area(1, 8, square(0, 0, 10), holes: [square(4, 4, 2)])
        XCTAssertTrue(a.contains(lat: 1, lon: 1))
        XCTAssertFalse(a.contains(lat: 5, lon: 5))
        XCTAssertFalse(a.contains(lat: 11, lon: 1))
    }

    func testLocatePicksSmallest() {
        let city = area(1, 8, square(0, 0, 10)), big = area(2, 10, square(1, 1, 6)), small = area(3, 12, square(2, 2, 2))
        let r = Areas.locate(lat: 3, lon: 3, in: [big, small, city])
        XCTAssertEqual(r.city?.id, 1)
        XCTAssertEqual(r.neighbourhood?.id, 3)
        XCTAssertEqual(Areas.locate(lat: 6, lon: 6, in: [big, small, city]).neighbourhood?.id, 2)
    }

    func testNoNeighbourhoodFallsBackToCity() {
        let city = area(1, 8, square(0, 0, 10))
        let r = Areas.locate(lat: 3, lon: 3, in: [city])
        XCTAssertEqual(r.city?.id, 1)
        XCTAssertEqual(r.neighbourhood?.id, 1)
        XCTAssertNil(Areas.locate(lat: 30, lon: 3, in: [city]).city)
    }

    func testNeighbourhoodOutsideCityIgnored() {
        // A neighbourhood of the next town that overlaps the point's city edge is not this city's.
        let city = area(1, 8, square(0, 0, 10)), other = area(2, 10, square(9, 9, 5))
        XCTAssertEqual(Areas.locate(lat: 9.5, lon: 9.5, in: [city, other]).neighbourhood?.id, 1)
    }

    func testParseIndexAndGeometry() throws {
        let index = """
        {"elements":[
          {"type":"relation","id":10,"tags":{"boundary":"administrative","admin_level":"8","name":"Utrecht"}},
          {"type":"relation","id":11,"tags":{"boundary":"place","place":"quarter","name":"Oost"}},
          {"type":"way","id":7,"tags":{"place":"neighbourhood","name":"Uithof"},
           "geometry":[{"lat":0,"lon":0},{"lat":0,"lon":1},{"lat":1,"lon":1},{"lat":0,"lon":0}]}
        ]}
        """
        let r = try OSM.parseAreas(Data(index.utf8))
        XCTAssertEqual(Set(r.missing), [10, 11])
        XCTAssertEqual(r.areas.map(\.id), [-7])
        XCTAssertEqual(r.areas.first?.level, 12)
        XCTAssertEqual(r.areas.first?.name, "Uithof")

        let geom = """
        {"elements":[{"type":"relation","id":10,"tags":{"boundary":"administrative","admin_level":"8","name":"Utrecht"},
          "members":[
            {"type":"way","role":"outer","geometry":[{"lat":0,"lon":0},{"lat":0,"lon":2},{"lat":2,"lon":2}]},
            {"type":"way","role":"outer","geometry":[{"lat":2,"lon":2},{"lat":2,"lon":0},{"lat":0,"lon":0}]},
            {"type":"node","role":"admin_centre","lat":1,"lon":1}]}]}
        """
        let g = try OSM.parseAreas(Data(geom.utf8))
        XCTAssertTrue(g.missing.isEmpty)
        XCTAssertEqual(g.areas.count, 1)
        XCTAssertEqual(g.areas[0].level, 8)
        XCTAssertEqual(g.areas[0].name, "Utrecht")
        XCTAssertTrue(g.areas[0].contains(lat: 1, lon: 1))
        XCTAssertTrue(OSM.areaGeometryQuery(ids: [10, 11]).contains("rel(id:10,11)"))
        XCTAssertTrue(OSM.areaIndexQuery(minLat: 52, minLon: 5, maxLat: 52.1, maxLon: 5.1).contains("(52.0,5.0,52.1,5.1)"))
    }
}
