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
        // Mercator metres stretch by 1/cos(lat); at 52 N a 25 m cell is ~15.4 m on the ground.
        let a = Heat.center(of: HeatCell(x: 0, y: 0)), b = Heat.center(of: HeatCell(x: 1, y: 0))
        XCTAssertEqual((b.lon - a.lon) * .pi / 180 * 6_378_137, 25, accuracy: 0.001)
        let c = Heat.center(of: HeatCell(x: 0, y: 1))
        XCTAssertEqual(Heat.cell(lat: c.lat, lon: c.lon), HeatCell(x: 0, y: 1))
    }
}
