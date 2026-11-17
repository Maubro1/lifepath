import XCTest
@testable import Core

final class DayStoryTests: XCTestCase {
    // 2027-01-15 00:00 UTC; the tests use UTC days.
    let day = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86_400))
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func place(_ id: Int64, _ name: String?) -> Place {
        Place(id: id, name: name, cells: [PlaceGrid.cell(lat: 52, lon: 5): 3600], updatedAt: day, lastVisit: day,
              totalSeconds: 3600, visits: 1, isCandidate: false)
    }

    func line(_ a: Double, _ b: Double, _ metres: Double) -> TripLine {
        TripLine(start: day + a, end: day + b, minLat: 52, maxLat: 52, minLon: 5, maxLon: 5.01, distance: metres,
                 coords: [(52, 5, 1), (52, 5.01, 1)])
    }

    func testStoryOrderAndNaming() {
        let h = 3600.0
        let visits = [Visit(start: day, end: day + 8 * h, placeId: 1), Visit(start: day + 9 * h, end: day + 16 * h, placeId: 2)]
        let modes = [ModeStretch(seq: 0, mode: .walk, confidence: 0.9, start: day + 8 * h, end: day + 8.25 * h),
                     ModeStretch(seq: 1, mode: .bus, confidence: 0.9, start: day + 8.25 * h, end: day + 9 * h)]
        let story = DayStory.build(day: day, calendar: cal, visits: visits, places: [place(1, "Home"), place(2, nil)], modes: modes,
                                   lines: [line(8 * h, 9 * h, 4000)], nearestStreet: { _, _ in "Leuvenlaan" })
        XCTAssertEqual(story, [
            .stay(name: "Home", placeId: 1, start: day, end: day + 8 * h),
            .trip(mode: .walk, start: day + 8 * h, end: day + 8.25 * h, distance: 1000),
            .trip(mode: .bus, start: day + 8.25 * h, end: day + 9 * h, distance: 3000),
            .stay(name: "near Leuvenlaan", placeId: 2, start: day + 9 * h, end: day + 16 * h),
        ])
    }

    func testUnclassifiedTripAndUnknownPlace() {
        let story = DayStory.build(day: day, calendar: cal, visits: [Visit(start: day + 100, end: day + 200, placeId: nil)], places: [],
                                   modes: [], lines: [line(300, 900, 500)], nearestStreet: { _, _ in nil })
        XCTAssertEqual(story, [.stay(name: "A place", placeId: nil, start: day + 100, end: day + 200),
                               .trip(mode: nil, start: day + 300, end: day + 900, distance: 500)])
    }

    func testStayCrossingMidnightClipped() {
        let story = DayStory.build(day: day, calendar: cal, visits: [Visit(start: day - 3600, end: day + 3600, placeId: 1),
                                                                     Visit(start: day + 82_800, end: day + 90_000, placeId: 1)],
                                   places: [place(1, "Home")], modes: [], lines: [], nearestStreet: { _, _ in nil })
        XCTAssertEqual(story, [.stay(name: "Home", placeId: 1, start: day, end: day + 3600),
                               .stay(name: "Home", placeId: 1, start: day + 82_800, end: day + 86_400)])
    }
}
