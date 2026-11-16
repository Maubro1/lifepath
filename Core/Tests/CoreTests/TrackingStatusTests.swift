import XCTest
@testable import Core

final class TrackingStatusTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func eval(auth: Authorization = .always, precise: Bool = true, state: MotionState = .moving,
              stillSince: Date? = nil, checkIn: Date? = nil, expiry: Date? = nil,
              notSaving: Date? = nil) -> TrackingStatus {
        TrackingStatus.evaluate(authorization: auth, preciseLocation: precise, state: state, stillSince: stillSince,
                                lastCheckIn: checkIn ?? now.addingTimeInterval(-60), notSavingSince: notSaving,
                                signingExpiry: expiry ?? now.addingTimeInterval(86400 * 5), now: now)
    }

    func testHealthyWhenAllGood() {
        XCTAssertEqual(eval().level, .healthy)
    }

    func testDowngradedPermissionIsProblem() {
        let s = eval(auth: .whenInUse)
        XCTAssertEqual(s.level, .problem)
        XCTAssertEqual(s.headline, "Location access isn't set to Always")
        XCTAssertEqual(s.hint, "Settings → LifePath → Location → Always")
        XCTAssertEqual(eval(precise: false).level, .problem)
    }

    func testStillIsResting() {
        let since = Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 9, minute: 5))!
        let s = eval(state: .still, stillSince: since)
        XCTAssertEqual(s.level, .resting)
        XCTAssertEqual(s.headline, "Resting: you've been still since 09:05")
    }

    func testStaleCheckInIsProblem() {
        let s = eval(checkIn: now.addingTimeInterval(-61 * 60))
        XCTAssertEqual(s.level, .problem)
        XCTAssertNotNil(s.hint)
        XCTAssertEqual(eval(checkIn: now.addingTimeInterval(-59 * 60)).level, .healthy)
    }

    func testRestingStillNeedsCheckIns() {
        // Deep sleep keeps the keep-alive and a spot check every 15 min, so an hour of silence is a dead recorder.
        XCTAssertEqual(eval(state: .still, checkIn: now.addingTimeInterval(-3 * 3600)).level, .problem)
    }

    func testFailedWritesAreProblemFirst() {
        let since = Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 9, minute: 5))!
        let s = eval(auth: .whenInUse, notSaving: since)
        XCTAssertEqual(s.level, .problem)
        XCTAssertEqual(s.headline, "Not saving since 09:05")
    }

    func testSigningExpirySoonIsProblem() {
        XCTAssertEqual(eval(expiry: now.addingTimeInterval(23 * 3600)).level, .problem)
        XCTAssertEqual(eval(expiry: now.addingTimeInterval(23 * 3600)).hint, "Open SideStore and tap Refresh All, then open LifePath once.")
        XCTAssertEqual(eval(expiry: now.addingTimeInterval(25 * 3600)).level, .healthy)
    }
}
