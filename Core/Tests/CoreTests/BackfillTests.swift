import XCTest
@testable import Core

final class BackfillTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // stands in for 10:00
    func at(_ t: TimeInterval) -> Date { t0.addingTimeInterval(t) }

    func testStillPointsEveryFiveMinutes() {
        let fence = Fence(lat: 52.37, lon: 4.90, radius: 35)
        let points = Backfill.stillPoints(fence: fence, from: t0, to: at(17 * 60))
        XCTAssertEqual(points.map(\.t), [at(300), at(600), at(900)])
        for p in points {
            XCTAssertEqual(p.kind, .still)
            XCTAssertEqual(p.hAcc, 35)
            XCTAssertEqual(p.lat, 52.37)
            XCTAssertEqual(p.lon, 4.90)
        }
    }

    func testDepartureFromActivity() {
        let activities: [(Date, Activity)] = [(at(-100), .walking),     // before Still began: ignored
                                              (at(50), .stationary), (at(600), .automotive), (at(900), .walking)]
        XCTAssertEqual(Backfill.departure(stillSince: t0, activities: activities, stepTimes: [at(100), at(200)]), at(600))
    }

    func testDepartureFromStepBurst() {
        let scattered = stride(from: 100.0, to: 900, by: 60).map(at)            // one step a minute: no burst
        let burst = (0..<20).map { at(1000 + Double($0)) }                       // 20 steps in 20 s
        let activities: [(Date, Activity)] = [(at(1100), .walking)]
        XCTAssertEqual(Backfill.departure(stillSince: t0, activities: activities, stepTimes: scattered + burst), at(1000))
    }

    func testDepartureAfterLastRest() {
        // Still from 23:00 (t0); a 02:00 bathroom trip, stationary from 02:05, then out the door at 08:30.
        let h: TimeInterval = 3600
        let steps = Array(repeating: at(3 * h), count: 20) + Array(repeating: at(9.5 * h), count: 40)
        var activities: [(Date, Activity)] = [(at(3 * h), .walking), (at(3 * h + 300), .stationary), (at(9.5 * h), .walking)]
        XCTAssertEqual(Backfill.departure(stillSince: t0, activities: activities, stepTimes: steps), at(9.5 * h))
        // Standing at the tram stop after the walk does not hide it.
        activities.append((at(9.5 * h + 600), .stationary))
        XCTAssertEqual(Backfill.departure(stillSince: t0, activities: activities, stepTimes: steps), at(9.5 * h))
    }

    func testDepartureNilWithoutEvidence() {
        let fourteen = (0..<14).map { at(500 + Double($0)) }                     // one short of a burst
        let spread = (0..<15).map { at(2000 + Double($0) * 5) }                  // 15 steps over 70 s
        let activities: [(Date, Activity)] = [(at(10), .stationary), (at(20), .unknown)]
        XCTAssertNil(Backfill.departure(stillSince: t0, activities: activities, stepTimes: fourteen + spread))
    }
}
