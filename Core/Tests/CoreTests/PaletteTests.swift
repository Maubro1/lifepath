import XCTest
@testable import Core

final class PaletteTests: XCTestCase {
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
            + [0, 0.5, 1].map { f in let r = Palette.dateRamp(f); return Hex(light: r.light, dark: r.dark) }
        for c in lines {
            XCTAssertGreaterThanOrEqual(Palette.contrast(c.light, Palette.page.light), 3, String(c.light, radix: 16))
            XCTAssertGreaterThanOrEqual(Palette.contrast(c.dark, Palette.page.dark), 3, String(c.dark, radix: 16))
        }
    }

    func testRampEnds() {
        XCTAssertEqual(Palette.dateRamp(0).light, Palette.mustard.light)
        XCTAssertEqual(Palette.dateRamp(1).light, Palette.cherry.light)
        XCTAssertEqual(Palette.dateRamp(0).dark, Palette.mustard.dark)
        XCTAssertEqual(Palette.dateRamp(1).dark, Palette.cherry.dark)
    }
}
