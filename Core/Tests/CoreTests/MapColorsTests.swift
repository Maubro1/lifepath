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
        func d(_ i: Int) -> Date { Date(timeIntervalSince1970: Double(i) * 10) }
        let s = [ModeStretch(seq: 0, mode: .walk, confidence: 0.9, start: d(0), end: d(1)),
                 ModeStretch(seq: 1, mode: .car, confidence: 0.3, start: d(2), end: d(3)),
                 ModeStretch(seq: 2, mode: .bike, confidence: 0.8, start: d(4), end: d(9))]
        XCTAssertEqual(MapColors.pointModes(s, times: (0..<5).map(d)), [.walk, .walk, nil, nil, .bike])
        XCTAssertEqual(MapColors.pointModes(s, times: (4..<10).map(d)), [TravelMode?](repeating: .bike, count: 6))   // a part of the trip lines up
        XCTAssertEqual(MapColors.dominantMode(s), .bike)
        XCTAssertNil(MapColors.dominantMode([s[1]]))
    }
}
