import XCTest
@testable import Core

final class PointBufferTests: XCTestCase {
    private func pt(_ t: Double) -> FilteredPoint {
        FilteredPoint(t: Date(timeIntervalSince1970: t), lat: 1, lon: 2, rawLat: 1, rawLon: 2, hAcc: 5, speed: 0, kind: .moving)
    }

    func testDueAfterThirtySeconds() {
        var b = PointBuffer()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(b.isDue(at: t0.addingTimeInterval(100)), "empty buffer is never due")
        b.add(pt(1000), at: t0)
        XCTAssertFalse(b.isDue(at: t0.addingTimeInterval(29)))
        XCTAssertTrue(b.isDue(at: t0.addingTimeInterval(30)))
    }

    func testFailedFlushKeepsPoints() {
        var b = PointBuffer()
        let t0 = Date(timeIntervalSince1970: 1000)
        b.add(pt(1000), at: t0)
        b.add(LoggedEvent(t: t0, kind: "k", detail: "d"))
        b.add(pt(1005), at: t0.addingTimeInterval(5))
        let first = b.take()
        XCTAssertEqual(first.points.count, 2)
        XCTAssertFalse(b.isDue(at: t0.addingTimeInterval(100)), "taken buffer is empty")
        b.add(pt(1010), at: t0.addingTimeInterval(10))
        b.putBack(points: first.points, events: first.events)
        let second = b.take()
        XCTAssertEqual(second.points.map(\.t.timeIntervalSince1970), [1000, 1005, 1010])
        XCTAssertEqual(second.events, first.events)
    }
}
