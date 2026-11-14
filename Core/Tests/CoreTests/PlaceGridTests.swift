import XCTest
@testable import Core

final class PlaceGridTests: XCTestCase {
    let base = PlaceGrid.cell(lat: 52.0, lon: 5.0)
    func c(_ dx: Int, _ dy: Int) -> PlaceCell { PlaceCell(x: base.x + dx, y: base.y + dy) }
    func place(_ cells: [PlaceCell: Double]) -> Place {
        Place(id: 1, name: nil, cells: cells, updatedAt: Date(timeIntervalSince1970: 0), lastVisit: Date(timeIntervalSince1970: 0), totalSeconds: 0, visits: 1, isCandidate: false)
    }

    func testCellSizeIs5m() {
        let mid = PlaceGrid.center(of: base)
        XCTAssertEqual(PlaceGrid.cell(lat: mid.lat, lon: mid.lon), base)
        let east = Geo.offset(lat: mid.lat, lon: mid.lon, north: 0, east: 5)
        let north = Geo.offset(lat: mid.lat, lon: mid.lon, north: 5, east: 0)
        XCTAssertEqual(PlaceGrid.cell(lat: east.lat, lon: east.lon), c(1, 0))
        XCTAssertEqual(PlaceGrid.cell(lat: north.lat, lon: north.lon), c(0, 1))
        let next = PlaceGrid.center(of: c(1, 0))
        XCTAssertEqual(Geo.distance(mid.lat, mid.lon, next.lat, next.lon), 5, accuracy: 0.05)
    }

    func testRegionHolds90PercentAndFillsHoles() {
        var cells: [PlaceCell: Double] = [c(20, 20): 1]   // far outlier, 1 of 81
        for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 { cells[c(dx, dy)] = 10 } }   // ring with a hole
        let region = place(cells).region()
        XCTAssertEqual(region, Set((-1...1).flatMap { dx in (-1...1).map { c(dx, $0) } }))   // hole filled, outlier out
        XCTAssertGreaterThanOrEqual(region.reduce(0) { $0 + (cells[$1] ?? 0) }, 0.9 * 81)
    }

    func testPinIsDensityPeakNotMean() throws {
        // L of one-cell-wide arms, with the desk near the end of one arm.
        var cells: [PlaceCell: Double] = [:]
        for i in 0...9 { cells[c(i, 0)] = 1; cells[c(0, i)] = 1 }
        cells[c(8, 0)] = 10; cells[c(7, 0)] = 4; cells[c(9, 0)] = 4
        let p = place(cells)
        XCTAssertEqual(PlaceGrid.cell(lat: p.pin.lat, lon: p.pin.lon), c(8, 0))
        let total = cells.values.reduce(0, +)
        let mx = cells.reduce(0) { $0 + $1.value * Double($1.key.x - base.x) } / total
        let my = cells.reduce(0) { $0 + $1.value * Double($1.key.y - base.y) } / total
        XCTAssertFalse(p.region(share: 1).contains(c(Int(mx.rounded()), Int(my.rounded()))))   // the mean falls outside the L
    }

    func testContainsAllowsAccuracy() {
        var cells: [PlaceCell: Double] = [:]
        for dx in -1...1 { for dy in -1...1 { cells[c(dx, dy)] = 1 } }
        let p = place(cells), mid = PlaceGrid.center(of: base)
        XCTAssertTrue(p.contains(lat: mid.lat, lon: mid.lon, hAcc: 5))
        let out = Geo.offset(lat: mid.lat, lon: mid.lon, north: 0, east: 30)
        XCTAssertFalse(p.contains(lat: out.lat, lon: out.lon, hAcc: 5))
        XCTAssertTrue(p.contains(lat: out.lat, lon: out.lon, hAcc: 30))
        let far = Geo.offset(lat: mid.lat, lon: mid.lon, north: 0, east: 100)
        XCTAssertFalse(p.contains(lat: far.lat, lon: far.lon, hAcc: 1000))   // widening capped at 50 m
    }
}
