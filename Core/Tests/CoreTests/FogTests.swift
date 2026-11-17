import XCTest
@testable import Core

final class FogTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A straight line east from (52, 5), one coord every 100 m, travelled at constant speed over `seconds`.
    func line(_ metres: Double, _ seconds: Double) -> TripLine {
        let c = stride(from: 0.0, through: metres, by: 100).map { e -> (lat: Double, lon: Double, speed: Double) in
            let p = Geo.offset(lat: 52, lon: 5, north: 0, east: e); return (p.lat, p.lon, metres / seconds)
        }
        return TripLine(start: t0, end: t0 + seconds, minLat: 52, maxLat: 52, minLon: 5, maxLon: c.last!.lon, distance: metres, coords: c)
    }

    func mode(_ m: TravelMode, _ a: Double, _ b: Double, _ conf: Double = 0.9) -> ModeStretch {
        ModeStretch(seq: 0, mode: m, confidence: conf, start: t0 + a, end: t0 + b)
    }

    func testWalkIs15mCarIs6m() {
        let s = Fog.strokes(line: line(1000, 1000), modes: [mode(.walk, 0, 500), mode(.car, 500, 1000)])
        XCTAssertEqual(s.map(\.halfWidth), [15, 6])
        XCTAssertEqual(s[0].coords.count, 6)   // 0...500 m
        XCTAssertEqual(s[1].coords.count, 6)   // 500...1000 m, sharing the boundary
    }

    func testTrainClearsOnlyEnds() {
        let s = Fog.strokes(line: line(1000, 100), modes: [mode(.train, 0, 100)])
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s.allSatisfy { $0.coords.count == 1 && $0.halfWidth == 25 })
    }

    func testUnsureAndUnclassifiedAre6m() {
        XCTAssertEqual(Fog.strokes(line: line(500, 500), modes: [mode(.walk, 0, 500, 0.3)]).map(\.halfWidth), [6])
        XCTAssertEqual(Fog.strokes(line: line(500, 500), modes: []).map(\.halfWidth), [6])
    }

    func testPlaceIsCircle() {
        var p = Place(id: 1, name: "Home", cells: [PlaceGrid.cell(lat: 52, lon: 5): 3600], recent: [:], visitDays: [1], updatedAt: t0,
                      lastVisit: t0, totalSeconds: 3600, visits: 1, isCandidate: false)
        p.realDays = [1]
        let c = Fog.circles(places: [p])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].coords.count, 1)
        XCTAssertEqual(c[0].halfWidth, 25)
    }
}
