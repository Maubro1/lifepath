import XCTest
@testable import Core

final class HealthReportTests: XCTestCase {
    // Same calendar the report uses (gregorian + current time zone), so dates built here bucket identically.
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone.current; return c }

    func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2027, month: 1, day: d, hour: h, minute: m))!
    }
    func ev(_ t: Date, _ k: String, _ d: String) -> LoggedEvent { LoggedEvent(t: t, kind: k, detail: d) }
    func pt(_ t: Date, acc: Double = 8, kind: PointKind = .moving) -> FilteredPoint {
        FilteredPoint(t: t, lat: 52, lon: 4, rawLat: 52, rawLon: 4, hAcc: acc, speed: 1, kind: kind)
    }
    func render(events: [LoggedEvent] = [], points: [FilteredPoint] = [], settings: [String: String] = [:]) -> String {
        HealthReport.render(HealthInput(now: at(15, 12), events: events, points: points, settings: settings))
    }
    func row(_ out: String, _ hour: String) -> String {
        out.split(separator: "\n").first { $0.hasPrefix(hour + " ") }.map(String.init) ?? "MISSING \(hour)\n\(out)"
    }

    func testReportListsGapWithLastEvent() {
        let out = render(events: [ev(at(15, 8, 5), "wake", "significantChange")],
                         points: [pt(at(15, 8, 10)), pt(at(15, 9))])
        XCTAssertTrue(out.contains("08:10 → 09:00 (50 min), last event: 08:05 wake significantChange"), out)
    }

    func testReportRestingPercentPerHour() {
        let out = render(events: [ev(at(15, 10), "state", "still"), ev(at(15, 10, 30), "state", "moving")])
        XCTAssertTrue(row(out, "10:00").contains("50%"), row(out, "10:00"))
        XCTAssertTrue(row(out, "11:00").contains(" 0%"), row(out, "11:00"))
    }

    func testReportAccuracyHistogram() {
        let pts = [3, 6, 9, 15, 30, 60, 80].map { pt(at(15, 9), acc: Double($0)) } + [pt(at(15, 9), acc: 1, kind: .still)]
        let out = render(points: pts)
        for line in ["<5 m: 1", "5–10 m: 2", "10–20 m: 1", "20–50 m: 1", "≥50 m: 2"] {
            XCTAssertTrue(out.contains(line), "\(line)\n\(out)")
        }
    }

    func testReportGpsOnHours() {
        let out = render(events: [ev(at(15, 8), "gps", "on"), ev(at(15, 9, 30), "gps", "off")])
        XCTAssertTrue(out.contains("GPS on: 1.5 h"), out)
    }

    func testReportPerHourMedianAccuracyAndDrops() {
        let out = render(events: [ev(at(15, 9, 5), "drops", "accuracy=3,stale=1,teleport=2"),
                                  ev(at(15, 9, 40), "drops", "accuracy=1,future=0")],
                         points: [pt(at(15, 9, 1), acc: 4), pt(at(15, 9, 2), acc: 20), pt(at(15, 9, 3), acc: 6),
                                  pt(at(15, 9, 4), acc: 1, kind: .still)])
        let r9 = row(out, "09:00")
        XCTAssertTrue(r9.contains("acc 6.0"), r9)
        XCTAssertTrue(r9.contains("drops accuracy=4,stale=1,teleport=2"), r9)
        let r10 = row(out, "10:00")
        XCTAssertTrue(r10.contains("acc -") && r10.contains("drops -"), r10)
    }

    func testReportThermalCarriesIntoHour() {
        let out = render(events: [ev(at(15, 9, 10), "thermal", "serious"), ev(at(15, 10, 20), "thermal", "nominal")])
        XCTAssertTrue(row(out, "10:00").contains("serious"), row(out, "10:00"))
        XCTAssertTrue(row(out, "11:00").contains("nominal"), row(out, "11:00"))
    }
}
