import XCTest
@testable import Core

final class ResidualsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    // A straight street running north from (52, 4), 500 m long.
    let way = Way(id: 7, kind: .foot, name: nil, oneway: false, nodes: [1, 2],
                  coords: [(52, 4), (52 + 500 / 111_320.0, 4)], countable: true)

    /// Walking north at 1.4 m/s, a fix every 7 s, `east(i)` metres east of the street.
    func walk(_ east: (Int) -> Double) -> [FilteredPoint] {
        (0..<40).map { i in
            let p = Geo.offset(lat: 52, lon: 4, north: 10 * Double(i), east: east(i))
            return FilteredPoint(t: t0.addingTimeInterval(7 * Double(i)), lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon,
                                 hAcc: 5, speed: 1.4, kind: .moving)
        }
    }
    func stretch(_ ps: [FilteredPoint], confidence: Double = 0.9) -> MatchedStretch {
        MatchedStretch(seq: 0, wayId: 7, fromM: 0, toM: 400, confidence: confidence, start: ps[0].t, end: ps[ps.count - 1].t)
    }

    func testOffsetsAreSignedAcrossTheStreet() throws {
        let ps = walk { _ in 3 }
        let runs = Residuals.offsets(ps, matches: [stretch(ps)], ways: [7: way])
        let r = try XCTUnwrap(runs.first)
        XCTAssertEqual(r.count, 40)
        XCTAssertEqual(r[5].d, -3, accuracy: 0.05, "east of a street walked north is right of it")
        XCTAssertTrue(Residuals.offsets(ps, matches: [stretch(ps, confidence: 0.3)], ways: [7: way]).isEmpty, "unsure stretches are skipped")
    }

    func testSummaryMedianAndFade() {
        // Alternating ±4 m: correlation is negative from the first lag, so the offsets fade within 10 s.
        let ps = walk { $0 % 2 == 0 ? 4 : -4 }
        let s = Residuals.summary(Residuals.offsets(ps, matches: [stretch(ps)], ways: [7: way]))
        XCTAssertTrue(s.hasPrefix("median 4.0 m from the street, 90% within 4.0 m, offsets fade after 0-10 s, 40 fixes on 1 stretches"), s)
        // A slow drift (one sine wave over the walk) keeps fixes 7-20 s apart correlated.
        let slow = walk { 5 * sin(Double($0) / 40 * 2 * .pi) }
        XCTAssertFalse(Residuals.summary(Residuals.offsets(slow, matches: [stretch(slow)], ways: [7: way])).contains("fade after 0-10 s"))
        XCTAssertEqual(Residuals.summary([]), "not enough matched walking yet")
    }
}
