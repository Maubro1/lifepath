import XCTest
@testable import Core

final class GeoTests: XCTestCase {
    func testDistanceKnownPair() {
        // Amsterdam Centraal to Dam Square.
        XCTAssertEqual(Geo.distance(52.3791, 4.9003, 52.3731, 4.8926), 832, accuracy: 5)
    }

    func testOffsetRoundTrip() {
        let p = Geo.offset(lat: 52.37, lon: 4.90, north: 100, east: 50)
        XCTAssertEqual(Geo.distance(52.37, 4.90, p.lat, p.lon), 111.8, accuracy: 0.5)
    }

    func testQualityLowerChain() {
        XCTAssertEqual(Quality.max.lower, .precise)
        XCTAssertEqual(Quality.precise.lower, .balanced)
        XCTAssertEqual(Quality.balanced.lower, .saver)
        XCTAssertEqual(Quality.saver.lower, .saver)
    }
}
