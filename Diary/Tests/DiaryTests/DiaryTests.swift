import XCTest
import Core
@testable import Diary

final class DiaryTests: XCTestCase {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("diary-\(UUID().uuidString).sqlite").path
    }
    private func pt(_ t: Double, lat: Double = 1) -> FilteredPoint {
        FilteredPoint(t: Date(timeIntervalSince1970: t), lat: lat, lon: 2, rawLat: 3, rawLon: 4, hAcc: 5, speed: 6, kind: .still)
    }
    private func d(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }

    func testAppendAndReadBack() throws {
        let diary = try Diary(path: tempPath())
        let pts = [pt(100), pt(200), pt(300)]
        try diary.append(pts)
        XCTAssertEqual(try diary.points(from: d(100), to: d(250)), [pts[0], pts[1]])
        let e = LoggedEvent(t: d(150), kind: "state", detail: "moving")
        try diary.log([e])
        XCTAssertEqual(try diary.events(from: d(0), to: d(1000)), [e])
    }

    func testDuplicateTimestampIgnored() throws {
        let diary = try Diary(path: tempPath())
        try diary.append([pt(100, lat: 1)])
        try diary.append([pt(100, lat: 9)])
        let got = try diary.points(from: d(0), to: d(1000))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.lat, 1)
    }

    func testLastPoint() throws {
        let diary = try Diary(path: tempPath())
        XCTAssertNil(try diary.lastPoint())
        try diary.append([pt(300), pt(100), pt(200)])
        XCTAssertEqual(try diary.lastPoint(), pt(300))
    }

    func testPruneEvents() throws {
        let diary = try Diary(path: tempPath())
        try diary.log([LoggedEvent(t: d(10), kind: "a", detail: ""), LoggedEvent(t: d(20), kind: "b", detail: "")])
        try diary.pruneEvents(olderThan: d(15))
        XCTAssertEqual(try diary.events(from: d(0), to: d(100)).map(\.kind), ["b"])
    }

    func testReopenKeepsData() throws {
        let path = tempPath()
        do {
            let diary = try Diary(path: path)
            try diary.append([pt(100)])
        }
        let reopened = try Diary(path: path)
        XCTAssertEqual(try reopened.lastPoint(), pt(100))
    }
}
