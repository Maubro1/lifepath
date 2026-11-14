import XCTest
@testable import Core

final class HeatTests: XCTestCase {
    private func pt(_ s: Double, lat: Double = 52.0, lon: Double = 5.0, _ k: PointKind) -> FilteredPoint {
        FilteredPoint(t: Date(timeIntervalSince1970: 1_700_000_000 + s), lat: lat, lon: lon,
                      rawLat: lat, rawLon: lon, hAcc: 5, speed: 0, kind: k)
    }

    func testNightAsleepCountsTimeNotPoints() {
        let pts = (0...96).map { pt(Double($0) * 300, .still) }   // 8 h, last point gets 0
        let g = Heat.grid(pts)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.values.first!, 8 * 3600, accuracy: 0.001)
    }

    func testMovingCappedAt60s() {
        let g = Heat.grid([pt(0, .moving), pt(600, .moving)])
        XCTAssertEqual(g[Heat.cell(lat: 52, lon: 5)]!, 60, accuracy: 0.001)
    }

    func testCellRoundTrip() {
        let c = Heat.cell(lat: 52.0, lon: 5.0)
        let m = Heat.center(of: c)
        XCTAssertEqual(Heat.cell(lat: m.lat, lon: m.lon), c)
    }

    func testCellsAre25m() {
        let c0 = Heat.cell(lat: 52, lon: 5)
        let a = Heat.center(of: c0)
        let e = Heat.center(of: HeatCell(x: c0.x + 1, y: c0.y)), n = Heat.center(of: HeatCell(x: c0.x, y: c0.y + 1))
        XCTAssertEqual(Geo.distance(a.lat, a.lon, e.lat, e.lon), 25, accuracy: 2)
        XCTAssertEqual(Geo.distance(a.lat, a.lon, n.lat, n.lon), 25, accuracy: 2)
    }

    func testGridAcrossChunksMatchesWhole() {
        let pts = (0..<10).map { pt(Double($0) * 40, lat: 52 + Double($0) * 0.001, $0 % 3 == 0 ? .still : .moving) }
        var g = Heat.grid(Array(pts[..<4]), previous: nil)
        g.merge(Heat.grid(Array(pts[4...]), previous: pts[3]), uniquingKeysWith: +)
        XCTAssertEqual(g, Heat.grid(pts))
    }
}
