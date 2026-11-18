import XCTest
@testable import Core

final class HeatRampTests: XCTestCase {
    func testRampTransparentAtZero() {
        XCTAssertEqual(HeatRamp.colour(0).a, 0)
        XCTAssertGreaterThan(HeatRamp.colour(0.05).a, 0)
    }

    func testRampEndsLight() {
        // The most-walked routes glow with a light core, lighter than cherry.
        let top = HeatRamp.colour(1)
        XCTAssertEqual(top.a, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(top.r + top.g + top.b, Double(0xB2 + 0x36 + 0x2C) / 255)
    }

    func testRampPassesThroughPalette() {
        let mid = HeatRamp.colour(0.5)
        XCTAssertGreaterThan(mid.r, mid.b)   // warm all the way
    }

    func testLevelLog() {
        XCTAssertEqual(HeatRamp.level(count: 0, max: 50), 0)
        XCTAssertEqual(HeatRamp.level(count: 50, max: 50), 1, accuracy: 1e-9)
        XCTAssertLessThan(HeatRamp.level(count: 5, max: 50), HeatRamp.level(count: 6, max: 50))
        XCTAssertGreaterThan(HeatRamp.level(count: 5, max: 50), 0.4)   // one walk already shows clearly (log, not linear)
        XCTAssertEqual(HeatRamp.level(count: 80, max: 50), 1)        // clamped
        XCTAssertEqual(HeatRamp.level(count: 3, max: 0), 0)
    }

    func testOneWalkStaysFaint() {
        // A young diary: the busiest spot has one pass, yet that pass must not saturate.
        let one = HeatRamp.level(count: 1, max: 1)
        XCTAssertLessThan(one, 0.25)
        XCTAssertLessThan(HeatRamp.colour(one).a, 0.4)
        XCTAssertLessThan(one, HeatRamp.level(count: 5, max: 5))
        XCTAssertLessThan(HeatRamp.level(count: 5, max: 5), HeatRamp.level(count: 40, max: 40))
        XCTAssertEqual(HeatRamp.level(count: 40, max: 40), 1, accuracy: 1e-9)
    }
}
