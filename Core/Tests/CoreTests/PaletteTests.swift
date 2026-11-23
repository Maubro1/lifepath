import XCTest
@testable import Core

final class PaletteTests: XCTestCase {
    func testSpeedRampEndsAndOrder() {
        XCTAssertEqual(Palette.speedRamp(0).light, Palette.speedStops[0].colour.light)        // standing still: the slow end
        XCTAssertEqual(Palette.speedRamp(25).dark, Palette.mustard.dark)                        // on a stop exactly
        XCTAssertEqual(Palette.speedRamp(400).light, Palette.speedStops.last!.colour.light)   // past 160 km/h: the fast end
        XCTAssertNotEqual(Palette.speedRamp(30).light, Palette.speedRamp(45).light)            // between stops: blended
    }

    func testTextContrast() {
        for bg in [Palette.page, Palette.card, Palette.inset] {
            XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.text.light, bg.light), 7)
            XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.text.dark, bg.dark), 7)
            XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.muted.light, bg.light), 4.5)
            XCTAssertGreaterThanOrEqual(Palette.contrast(Palette.muted.dark, bg.dark), 4.5)
        }
    }

    func testLinesVisibleOnFogAndMap() {
        let lines = TravelMode.allCases.map(Palette.mode) + [Palette.satsuma]
            + stride(from: 0.0, through: 1, by: 0.05).map { f in let r = Palette.dateRamp(f); return Hex(light: r.light, dark: r.dark) }
        for c in lines {
            XCTAssertGreaterThanOrEqual(Palette.contrast(c.light, Palette.page.light), 3, String(c.light, radix: 16))
            XCTAssertGreaterThanOrEqual(Palette.contrast(c.dark, Palette.page.dark), 3, String(c.dark, radix: 16))
        }
    }

    func testRampEnds() {
        XCTAssertEqual(Palette.dateRamp(0).light, Palette.mustard.light)
        XCTAssertEqual(Palette.dateRamp(1).light, Palette.navy.light)
        XCTAssertEqual(Palette.dateRamp(0).dark, Palette.mustard.dark)
        XCTAssertEqual(Palette.dateRamp(1).dark, Palette.navy.dark)
        XCTAssertEqual(Palette.dateRamp(0.5).light, Palette.cherry.light, "stops are evenly spaced")
    }

    /// Oklab blending: each tenth of age moves the colour a similar perceptual distance (no flat stretch, no jump).
    func testAgeStepsAreEven() {
        func lab(_ c: UInt32) -> (Double, Double, Double) {
            let r = Double((c >> 16) & 0xFF), g = Double((c >> 8) & 0xFF), b = Double(c & 0xFF); return (r, g, b)
        }
        let steps = stride(from: 0.0, to: 1, by: 0.1).map { f -> Double in
            let a = lab(Palette.dateRamp(f).light), b = lab(Palette.dateRamp(f + 0.1).light)
            return ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
        }
        XCTAssertGreaterThan(steps.min()!, 8, "every step visible: \(steps)")
        XCTAssertLessThan(steps.max()! / steps.min()!, 4, "no step dwarfs another: \(steps)")
    }
}
