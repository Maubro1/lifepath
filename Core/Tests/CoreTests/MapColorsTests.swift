import XCTest
@testable import Core

final class MapColorsTests: XCTestCase {
    func testDateGradientEndsAndClamps() {
        let a = MapColors.byDate(0), b = MapColors.byDate(1), mid = MapColors.byDate(0.5)
        XCTAssertEqual(a.r, 0x2F / 255, accuracy: 1e-9); XCTAssertEqual(a.b, 0xDE / 255, accuracy: 1e-9)
        XCTAssertEqual(b.r, 0xF2 / 255, accuracy: 1e-9); XCTAssertEqual(b.g, 0x8C / 255, accuracy: 1e-9)
        XCTAssertEqual(mid.r, (0x2F + 0xF2) / 510, accuracy: 1e-9)
        XCTAssertEqual(MapColors.byDate(-3).r, a.r); XCTAssertEqual(MapColors.byDate(7).r, b.r)
    }

    func testSpeedBands() {
        XCTAssertEqual(SpeedBand(speed: 1.4), .walk)
        XCTAssertEqual(SpeedBand(speed: 2.5), .bike)
        XCTAssertEqual(SpeedBand(speed: 6.99), .bike)
        XCTAssertEqual(SpeedBand(speed: 7), .drive)
    }

    func testUnknownSpeedsTakeMedian() {
        XCTAssertEqual(MapColors.filledSpeeds([-1, 1, 5, 3, -1]), [3, 1, 5, 3, 3])
        XCTAssertEqual(MapColors.filledSpeeds([-1, -1]), [0, 0])
    }

    func testHeatAlpha() {
        XCTAssertEqual(MapColors.heatAlpha(0, max: 100), 0.15, accuracy: 1e-9)
        XCTAssertEqual(MapColors.heatAlpha(100, max: 100), 0.85, accuracy: 1e-9)
        XCTAssertEqual(MapColors.heatAlpha(5, max: 0), 0.85, accuracy: 1e-9)
    }

    func testPointModesAndDominant() {
        let s = [ModeStretch(seq: 0, mode: .walk, confidence: 0.9, first: 0, last: 1),
                 ModeStretch(seq: 1, mode: .car, confidence: 0.3, first: 2, last: 3),
                 ModeStretch(seq: 2, mode: .bike, confidence: 0.8, first: 4, last: 9)]
        XCTAssertEqual(MapColors.pointModes(s, count: 5), [.walk, .walk, nil, nil, nil])   // bike reaches past the points: ignored
        XCTAssertEqual(MapColors.pointModes(s, count: 10)[9], .bike)
        XCTAssertEqual(MapColors.dominantMode(s), .bike)
        XCTAssertNil(MapColors.dominantMode([s[1]]))
    }
}
