import XCTest
import GRDB
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

    private func sum(_ day: String, _ dist: Double = 100) -> DaySummary {
        DaySummary(day: day, distance: dist, movingTime: 60, walked: dist / 2, points: 10)
    }

    func testSaveDaysReplacesFromDay() throws {
        let diary = try Diary(path: tempPath())
        try diary.saveDays([sum("2026-11-01"), sum("2026-11-02"), sum("2026-11-03")], from: "2026-11-01")
        try diary.saveDays([sum("2026-11-02", 999)], from: "2026-11-02")
        XCTAssertEqual(try diary.days().map(\.summary), [sum("2026-11-02", 999), sum("2026-11-01")])
    }

    func testDaysJoinSteps() throws {
        let diary = try Diary(path: tempPath())
        try diary.saveDays([sum("2026-11-01"), sum("2026-11-02")], from: "2026-11-01")
        try diary.saveSteps([DaySteps(day: "2026-11-02", steps: 777, distance: nil, floorsUp: nil)])
        let days = try diary.days()
        XCTAssertEqual(days.map(\.summary.day), ["2026-11-02", "2026-11-01"])
        XCTAssertEqual(days.map(\.steps), [777, nil])
    }

    func testStepsNeverLowered() throws {
        let path = tempPath()
        let diary = try Diary(path: path)
        func row() throws -> Row {
            try DatabaseQueue(path: path).read { try Row.fetchOne($0, sql: "SELECT * FROM daySteps")! }
        }
        try diary.saveSteps([DaySteps(day: "2026-11-01", steps: 5000, distance: 3000, floorsUp: 4)])
        try diary.saveSteps([DaySteps(day: "2026-11-01", steps: 4000, distance: nil, floorsUp: nil)])
        var r = try row()
        XCTAssertEqual(r["steps"] as Int, 5000)
        XCTAssertEqual(r["distance"] as Double?, 3000)
        XCTAssertEqual(r["floorsUp"] as Int?, 4)
        try diary.saveSteps([DaySteps(day: "2026-11-01", steps: 6000, distance: nil, floorsUp: nil)])
        r = try row()
        XCTAssertEqual(r["steps"] as Int, 6000)
    }

    func testLifeStats() throws {
        let diary = try Diary(path: tempPath())
        let empty = try diary.lifeStats()
        XCTAssertNil(empty.steps)
        XCTAssertEqual(empty.days, 0)
        try diary.saveDays([sum("2026-11-01", 100), sum("2026-11-02", 300)], from: "2026-11-01")
        try diary.saveSteps([DaySteps(day: "2026-11-02", steps: 10, distance: nil, floorsUp: 2),
                             DaySteps(day: "2026-11-01", steps: 20, distance: nil, floorsUp: nil)])
        XCTAssertEqual(try diary.lifeStats(),
                       LifeStats(distance: 400, walked: 200, days: 2, points: 20, steps: 30, floorsUp: 2, stepsSince: "2026-11-01"))
    }

    func testTripLinesByDay() throws {
        let diary = try Diary(path: tempPath())
        let day = 10.0 * 86400
        let a = line(day - 3 * 86400 + 100, day - 3 * 86400 + 200)
        let b = line(day - 600, day + 600)
        let c = line(day + 43200, day + 43300)
        try diary.saveTripLines([a, b, c], replacingFrom: d(0))
        XCTAssertEqual(try diary.tripLines(from: d(day), to: d(day + 86400)), [b, c])
    }

    func testV8DiaryMigrates() throws {
        let path = tempPath()
        do { let diary = try Diary(path: path); try diary.append([pt(100)]) }
        let reopened = try Diary(path: path)
        XCTAssertEqual(try reopened.points(from: d(0), to: d(1000)), [pt(100)])
        XCTAssertEqual(try reopened.days().count, 0)
    }

    func testCourseRoundTrip() throws {
        let diary = try Diary(path: tempPath())
        var a = pt(100); a.course = 123.5
        let b = pt(200)   // default course -1
        try diary.append([a, b])
        XCTAssertEqual(try diary.points(from: d(0), to: d(1000)), [a, b])
    }

    func testOldRowsReadCourseAsInvalid() throws {
        let path = tempPath()
        do {   // a v1 database exactly as v1 created it
            let q = try DatabaseQueue(path: path)
            try q.write { db in
                try db.execute(sql: """
                    CREATE TABLE point(
                        t REAL PRIMARY KEY, lat REAL, lon REAL, rawLat REAL, rawLon REAL,
                        hAcc REAL, speed REAL, kind TEXT);
                    CREATE TABLE event(
                        id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL, kind TEXT, detail TEXT);
                    CREATE INDEX event_t ON event(t);
                    CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
                    INSERT INTO grdb_migrations VALUES ('v1');
                    INSERT INTO point VALUES (100, 1, 2, 3, 4, 5, 6, 'still');
                    """)
            }
        }
        let diary = try Diary(path: path)
        XCTAssertEqual(try diary.points(from: d(0), to: d(1000)), [pt(100)])
        XCTAssertEqual(try diary.lastPoint()?.course, -1)
    }

    func testPointsInBox() throws {
        let diary = try Diary(path: tempPath())
        func at(_ t: Double, _ lat: Double, _ lon: Double) -> FilteredPoint {
            FilteredPoint(t: d(t), lat: lat, lon: lon, rawLat: lat, rawLon: lon, hAcc: 5, speed: 0, kind: .moving)
        }
        let inside = at(100, 52.0, 4.0), late = at(500, 52.0, 4.0)
        try diary.append([inside, at(200, 53.0, 4.0), at(300, 52.0, 5.0), late])
        XCTAssertEqual(try diary.points(minLat: 51.5, maxLat: 52.5, minLon: 3.5, maxLon: 4.5, after: d(0), to: d(400), limit: 10), [inside])
    }

    func testPointsInBoxChunksByCursor() throws {
        let diary = try Diary(path: tempPath())
        let pts = (1...5).map { FilteredPoint(t: d(Double($0) * 100), lat: 52.0, lon: 4.0, rawLat: 52.0, rawLon: 4.0, hAcc: 5, speed: 0, kind: .moving) }
        try diary.append(pts + [FilteredPoint(t: d(250), lat: 53.0, lon: 4.0, rawLat: 53.0, rawLon: 4.0, hAcc: 5, speed: 0, kind: .moving)])
        func chunk(_ after: Double) throws -> [FilteredPoint] {
            try diary.points(minLat: 51.5, maxLat: 52.5, minLon: 3.5, maxLon: 4.5, after: d(after), to: d(1000), limit: 2)
        }
        XCTAssertEqual(try chunk(0), Array(pts[0..<2]))     // oldest first; the out-of-box point never counts
        XCTAssertEqual(try chunk(200), Array(pts[2..<4]))   // cursor is exclusive
        XCTAssertEqual(try chunk(400), [pts[4]])
    }

    func testStillPointsOnePerCell() throws {
        let diary = try Diary(path: tempPath())
        func at(_ t: Double, _ lat: Double, _ kind: PointKind) -> FilteredPoint {
            FilteredPoint(t: d(t), lat: lat, lon: 4.0, rawLat: lat, rawLon: 4.0, hAcc: 5, speed: 0, kind: kind)
        }
        // Three check-ins at one place (within a few metres), one 100 m away, one moving fix, one outside the time range.
        try diary.append([at(100, 52.0, .still), at(200, 52.00002, .still), at(300, 52.00001, .still),
                          at(400, 52.0009, .still), at(500, 52.0005, .moving), at(5000, 52.002, .still)])
        let got = try diary.stillPoints(minLat: 51.5, maxLat: 52.5, minLon: 3.5, maxLon: 4.5, from: d(0), to: d(1000), cell: 0.000225, lonCell: 0.000365)
        XCTAssertEqual(got.map { ($0.lat * 1000).rounded() }.sorted(), [52000, 52001])
    }

    func testSmoothedReplace() throws {
        let diary = try Diary(path: tempPath())
        XCTAssertNil(try diary.smoothedUntil())
        try diary.saveSmoothed([(d(100), 1, 2), (d(200), 3, 4)])
        try diary.saveSmoothed([(d(200), 5, 6)])   // replaces t=200
        let got = try diary.smoothed(from: d(0), to: d(1000))
        XCTAssertEqual(got.map(\.t), [d(100), d(200)])
        XCTAssertEqual(got.map(\.lat), [1, 5])
        XCTAssertEqual(try diary.smoothedUntil(), d(200))
        XCTAssertEqual(try diary.smoothed(from: d(150), to: d(1000)).count, 1)
    }

    private func line(_ start: Double, _ end: Double, lat: ClosedRange<Double> = 52...53, lon: ClosedRange<Double> = 4...5) -> TripLine {
        TripLine(start: d(start), end: d(end), minLat: lat.lowerBound, maxLat: lat.upperBound,
                 minLon: lon.lowerBound, maxLon: lon.upperBound, distance: 1234.5,
                 coords: [(lat.lowerBound, lon.lowerBound, 1.5), (lat.upperBound, lon.upperBound, -1)])
    }

    func testTripLineRoundTrip() throws {
        let diary = try Diary(path: tempPath())
        XCTAssertNil(try diary.tripLinesUntil())
        let a = line(100, 200), b = line(300, 400)
        try diary.saveTripLines([b, a], replacingFrom: d(0))
        XCTAssertEqual(try diary.tripLines(minLat: 0, maxLat: 90, minLon: 0, maxLon: 90, from: d(0), to: d(1000)), [a, b])
        XCTAssertEqual(try diary.tripLinesUntil(), d(400))
    }

    func testTripLineOverlapQueries() throws {
        let diary = try Diary(path: tempPath())
        try diary.saveTripLines([line(100, 200)], replacingFrom: d(0))
        func q(_ minLat: Double, _ maxLat: Double, _ minLon: Double, _ maxLon: Double, _ from: Double, _ to: Double) throws -> Int {
            try diary.tripLines(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon, from: d(from), to: d(to)).count
        }
        XCTAssertEqual(try q(53, 54, 4, 5, 0, 1000), 1)      // touches at max lat
        XCTAssertEqual(try q(51, 52, 4, 5, 0, 1000), 1)      // touches at min lat
        XCTAssertEqual(try q(52, 53, 5, 6, 0, 1000), 1)      // touches at max lon
        XCTAssertEqual(try q(52, 53, 3, 4, 0, 1000), 1)      // touches at min lon
        XCTAssertEqual(try q(53.1, 54, 4, 5, 0, 1000), 0)
        XCTAssertEqual(try q(50, 51.9, 4, 5, 0, 1000), 0)
        XCTAssertEqual(try q(52, 53, 5.1, 6, 0, 1000), 0)
        XCTAssertEqual(try q(52, 53, 3, 3.9, 0, 1000), 0)
        XCTAssertEqual(try q(52, 53, 4, 5, 200, 300), 1)     // touches at end
        XCTAssertEqual(try q(52, 53, 4, 5, 0, 100), 1)       // touches at start
        XCTAssertEqual(try q(52, 53, 4, 5, 201, 300), 0)
        XCTAssertEqual(try q(52, 53, 4, 5, 0, 99), 0)
    }

    func testReplacingTripLinesLeavesNoDuplicates() throws {
        let diary = try Diary(path: tempPath())
        try diary.saveTripLines([line(100, 200), line(300, 400)], replacingFrom: d(0))
        let newer = line(300, 450)
        try diary.saveTripLines([newer, line(500, 600)], replacingFrom: d(250))
        let got = try diary.tripLines(minLat: 0, maxLat: 90, minLon: 0, maxLon: 90, from: d(0), to: d(1000))
        XCTAssertEqual(got.map(\.start), [d(100), d(300), d(500)])
        XCTAssertEqual(got[1], newer)
        try diary.saveTripLines([newer], replacingFrom: d(300))   // same start again: still one row
        XCTAssertEqual(try diary.tripLines(minLat: 0, maxLat: 90, minLon: 0, maxLon: 90, from: d(0), to: d(1000)).count, 2)
    }

    func testV2UpgradeKeepsPointsAndSmoothed() throws {
        let path = tempPath()
        do {   // a v2 database exactly as v2 left it
            let q = try DatabaseQueue(path: path)
            try q.write { db in
                try db.execute(sql: """
                    CREATE TABLE point(
                        t REAL PRIMARY KEY, lat REAL, lon REAL, rawLat REAL, rawLon REAL,
                        hAcc REAL, speed REAL, kind TEXT, course REAL);
                    CREATE TABLE event(
                        id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL, kind TEXT, detail TEXT);
                    CREATE INDEX event_t ON event(t);
                    CREATE TABLE smoothedPoint(t REAL PRIMARY KEY, lat REAL, lon REAL);
                    CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
                    INSERT INTO grdb_migrations VALUES ('v1');
                    INSERT INTO grdb_migrations VALUES ('v2');
                    INSERT INTO point VALUES (100, 1, 2, 3, 4, 5, 6, 'still', -1);
                    INSERT INTO smoothedPoint VALUES (100, 7, 8);
                    """)
            }
        }
        let diary = try Diary(path: path)
        XCTAssertEqual(try diary.points(from: d(0), to: d(1000)), [pt(100)])
        XCTAssertEqual(try diary.smoothed(from: d(0), to: d(1000)).map(\.lat), [7])
        XCTAssertNil(try diary.tripLinesUntil())
        try diary.saveTripLines([line(1, 2)], replacingFrom: d(0))
        XCTAssertEqual(try diary.tripLinesUntil(), d(2))
    }

    private func place(_ id: Int64, name: String? = nil, cells: [PlaceCell: Double]) -> Place {
        var p = Place(id: id, name: name, cells: cells, recent: [PlaceCell(x: 1, y: 1): 0.5], visitDays: [20_000, 20_003],
                      updatedAt: d(500), lastVisit: d(400), totalSeconds: 900, visits: 3, isCandidate: false, realDays: [20_000, 20_003])
        p.recentDurations = [18_000.5, 0.1 + 0.2, 21_600]   // awkward doubles must survive the text column exactly
        return p
    }

    func testRewindMetaOnlyMovesBackAndBackupReopens() throws {
        let diary = try Diary(path: tempPath())
        try diary.setMeta("cursor", "1000.0")
        try diary.rewindMeta("cursor", to: d(2000))
        XCTAssertEqual(try diary.meta("cursor"), "1000.0")
        try diary.rewindMeta("cursor", to: Date(timeIntervalSince1970: 400))
        XCTAssertEqual(try diary.meta("cursor"), "400.0")
        try diary.rewindMeta("missing", to: d(0))
        XCTAssertNil(try diary.meta("missing"))

        let a = place(1, cells: [PlaceCell(x: 1, y: 1): 2])
        try diary.savePlaces([a], removing: [])
        let copy = URL(fileURLWithPath: tempPath())
        try diary.backup(to: copy)
        XCTAssertEqual(try Diary(path: copy.path).places(), [a])
    }

    func testPlacesRoundTripMergeRenameVisitsMeta() throws {
        let diary = try Diary(path: tempPath())
        let a = place(1, name: "Home", cells: [PlaceCell(x: 1, y: 1): 2, PlaceCell(x: 2, y: 1): 1])
        let b = place(2, cells: [PlaceCell(x: 9, y: 9): 4])
        try diary.savePlaces([a, b], removing: [])
        XCTAssertEqual(try diary.places(), [a, b])

        var merged = a
        merged.cells[PlaceCell(x: 9, y: 9)] = 4
        try diary.savePlaces([merged], removing: [2])   // survivor keeps all cells, loser gone
        XCTAssertEqual(try diary.places(), [merged])

        try diary.renamePlace(1, to: "Flat")
        XCTAssertEqual(try diary.places().first?.name, "Flat")
        try diary.savePlaces([merged], removing: [])   // a learning run with the copy from before the rename
        XCTAssertEqual(try diary.places().first?.name, "Flat")
        try diary.renamePlace(1, to: nil)
        XCTAssertNil(try diary.places().first?.name)

        try diary.saveVisits([Visit(start: d(10), end: d(20), placeId: 1), Visit(start: d(100), end: d(200), placeId: nil)])
        try diary.saveVisits([Visit(start: d(10), end: d(30), placeId: 1)])
        XCTAssertEqual(try diary.visits(from: d(0), to: d(50)), [Visit(start: d(10), end: d(30), placeId: 1)])
        XCTAssertEqual(try diary.visits(from: d(0), to: d(1000)).count, 2)

        XCTAssertNil(try diary.meta("k"))
        try diary.setMeta("k", "1"); try diary.setMeta("k", "2")
        XCTAssertEqual(try diary.meta("k"), "2")
    }

    func testSaveLearnedWritesPlacesVisitsAndCursorTogether() throws {
        let diary = try Diary(path: tempPath())
        let a = place(1, cells: [PlaceCell(x: 1, y: 1): 2]), b = place(2, cells: [PlaceCell(x: 9, y: 9): 4])
        try diary.savePlaces([a, b], removing: [])
        try diary.saveLearned(places: [a], removing: [2], visits: [Visit(start: d(10), end: d(20), placeId: 1)], meta: "placesProcessedUntil", "20")
        XCTAssertEqual(try diary.places(), [a])
        XCTAssertEqual(try diary.visits(from: d(0), to: d(50)), [Visit(start: d(10), end: d(20), placeId: 1)])
        XCTAssertEqual(try diary.meta("placesProcessedUntil"), "20")
    }

    func testV3UpgradeKeepsPointsSmoothedAndTripLines() throws {
        let path = tempPath()
        do {
            let q = try DatabaseQueue(path: path)
            try q.write { db in
                try db.execute(sql: """
                    CREATE TABLE point(
                        t REAL PRIMARY KEY, lat REAL, lon REAL, rawLat REAL, rawLon REAL,
                        hAcc REAL, speed REAL, kind TEXT, course REAL);
                    CREATE TABLE event(
                        id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL, kind TEXT, detail TEXT);
                    CREATE INDEX event_t ON event(t);
                    CREATE TABLE smoothedPoint(t REAL PRIMARY KEY, lat REAL, lon REAL);
                    CREATE TABLE tripLine(
                        start REAL PRIMARY KEY, end REAL, minLat REAL, maxLat REAL, minLon REAL, maxLon REAL,
                        distance REAL, coords BLOB);
                    CREATE INDEX tripLine_end ON tripLine(end);
                    CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
                    INSERT INTO grdb_migrations VALUES ('v1');
                    INSERT INTO grdb_migrations VALUES ('v2');
                    INSERT INTO grdb_migrations VALUES ('v3');
                    INSERT INTO point VALUES (100, 1, 2, 3, 4, 5, 6, 'still', -1);
                    INSERT INTO smoothedPoint VALUES (100, 7, 8);
                    INSERT INTO tripLine VALUES (1, 2, 0, 1, 0, 1, 5, x'');
                    """)
            }
        }
        let diary = try Diary(path: path)
        XCTAssertEqual(try diary.points(from: d(0), to: d(1000)), [pt(100)])
        XCTAssertEqual(try diary.smoothed(from: d(0), to: d(1000)).map(\.lat), [7])
        XCTAssertEqual(try diary.tripLinesUntil(), d(2))
        XCTAssertEqual(try diary.places(), [])
    }

    private func way(_ id: Int64, lat: Double = 50) -> Way {
        Way(id: id, kind: .foot, name: id == 1 ? "Lane" : nil, oneway: id == 2, nodes: [id * 10, id * 10 + 1],
            coords: [(lat, 4.1234567890123), (lat + 0.001, 4.2)])
    }

    func testTileSavedAtomicallyWithWays() throws {
        let diary = try Diary(path: tempPath())
        let tile = Tile(x: 1, y: 2)
        XCTAssertFalse(try diary.hasTile(tile, version: 1))
        try diary.saveTile(tile, ways: [way(1), way(2)], stops: [], version: 1)
        XCTAssertTrue(try diary.hasTile(tile, version: 1))
        XCTAssertFalse(try diary.hasTile(Tile(x: 1, y: 3), version: 1))
        try diary.saveTile(Tile(x: 2, y: 2), ways: [way(1)], stops: [], version: 1)   // a way shared by two tiles is stored once
        XCTAssertEqual(try diary.ways(minLat: 0, maxLat: 90, minLon: 0, maxLon: 90).count, 2)
    }

    func testWaysInBox() throws {
        let diary = try Diary(path: tempPath())
        try diary.saveTile(Tile(x: 0, y: 0), ways: [way(1, lat: 50), way(2, lat: 51)], stops: [], version: 1)
        let got = try diary.ways(minLat: 49.9, maxLat: 50.5, minLon: 4, maxLon: 5)
        XCTAssertEqual(got, [way(1, lat: 50)])
        XCTAssertEqual(got.first?.coords.first?.lon, 4.1234567890123)
        XCTAssertTrue(try diary.ways(minLat: 52, maxLat: 53, minLon: 4, maxLon: 5).isEmpty)
    }

    func testWaysByIdInChunks() throws {
        let diary = try Diary(path: tempPath())
        let ids: [Int64] = Array(1...600)
        try diary.saveTile(Tile(x: 0, y: 0), ways: ids.map { (id: Int64) -> Way in way(id) }, stops: [], version: 1)
        XCTAssertEqual(try diary.ways(ids: [3, 1, 999]).map { (w: Way) -> Int64 in w.id }, [1, 3])
        XCTAssertEqual(try diary.ways(ids: Array(ids.reversed())).count, 600)   // past one 500-id chunk
        XCTAssertTrue(try diary.ways(ids: []).isEmpty)
    }

    func testMatchesReplacePerTrip() throws {
        let diary = try Diary(path: tempPath())
        func s(_ seq: Int, _ way: Int64) -> MatchedStretch {
            MatchedStretch(seq: seq, wayId: way, fromM: 1.5, toM: 20, confidence: 0.9, start: d(Double(seq * 3)), end: d(Double(seq * 3 + 2)))
        }
        try diary.saveMatches(tripStart: d(100), [s(0, 7), s(1, 8)], modes: [])
        try diary.saveMatches(tripStart: d(200), [s(0, 9)], modes: [])
        try diary.saveMatches(tripStart: d(100), [s(0, 5)], modes: [])
        XCTAssertEqual(try diary.matches(tripStart: d(100)), [s(0, 5)])
        XCTAssertEqual(try diary.matches(tripStart: d(200)), [s(0, 9)])
    }

    func testCountableStored() throws {
        let diary = try Diary(path: tempPath())
        var w2 = way(2); w2.countable = false
        try diary.saveTile(Tile(x: 0, y: 0), ways: [way(1), w2], stops: [], version: 1)
        XCTAssertEqual(try diary.countableWays().map(\.id), [1])
    }

    func testHitsReplacedWithMatches() throws {
        let diary = try Diary(path: tempPath())
        let hits = Set((0..<3).map { SegmentHit(wayId: 1, seg: $0, bike: false) })
        try diary.saveMatches(tripStart: d(100), [], modes: [], hits: hits)
        XCTAssertEqual(try diary.segmentHits().count, 3)
        try diary.saveMatches(tripStart: d(100), [], modes: [], hits: [SegmentHit(wayId: 1, seg: 0, bike: false)])
        XCTAssertEqual(try diary.segmentHits().count, 1)
    }

    func testCoveredWaysRespectBike() throws {
        let diary = try Diary(path: tempPath())
        XCTAssertNil(try diary.streetsWalked(bike: false))
        try diary.saveTile(Tile(x: 0, y: 0), ways: [way(1), way(2)], stops: [], version: 1)
        try diary.saveCoverage(CoverageResult(ways: [1: false, 2: true], onFoot: 1, withBike: 2, total: 5))
        func ids(_ bike: Bool) throws -> [Int64] {
            try diary.coveredWays(minLat: 0, maxLat: 90, minLon: 0, maxLon: 90, bike: bike).map(\.id)
        }
        XCTAssertEqual(try ids(false), [1])
        XCTAssertEqual(try ids(true), [1, 2])
        XCTAssertEqual(try diary.streetsWalked(bike: false)?.covered, 1)
        XCTAssertEqual(try diary.streetsWalked(bike: true)?.covered, 2)
        XCTAssertEqual(try diary.streetsWalked(bike: true)?.total, 5)
    }

    func testStaleTileIsNotFresh() throws {
        let diary = try Diary(path: tempPath())
        try diary.saveTile(Tile(x: 1, y: 1), ways: [], stops: [], version: 1)
        XCTAssertFalse(try diary.hasTile(Tile(x: 1, y: 1), version: 2))
        try diary.saveTile(Tile(x: 1, y: 1), ways: [], stops: [], version: 2)
        XCTAssertTrue(try diary.hasTile(Tile(x: 1, y: 1), version: 2))
    }

    func testStopsInBox() throws {
        let diary = try Diary(path: tempPath())
        let stops = [Stop(id: 1, kind: .bus, lat: 50.1, lon: 4.1), Stop(id: 2, kind: .rail, lat: 50.2, lon: 4.2), Stop(id: 3, kind: .ferry, lat: 51, lon: 4.1)]
        try diary.saveTile(Tile(x: 0, y: 0), ways: [], stops: stops, version: 2)
        XCTAssertEqual(try diary.stops(minLat: 50, maxLat: 50.5, minLon: 4, maxLon: 5), Array(stops[0...1]))
    }

    func testActivitiesIncludeStateBeforeRange() throws {
        let diary = try Diary(path: tempPath())
        try diary.saveActivities([(d(10), .walking), (d(50), .automotive), (d(90), .stationary), (d(150), .cycling)])
        let got = try diary.activities(from: d(60), to: d(100))
        XCTAssertEqual(got.map(\.t), [d(50), d(90)])
        XCTAssertEqual(got.map(\.activity), [.automotive, .stationary])
    }

    func testModesSavedWithMatches() throws {
        let diary = try Diary(path: tempPath())
        func m(_ seq: Int, _ mode: TravelMode) -> ModeStretch { ModeStretch(seq: seq, mode: mode, confidence: 0.8, start: d(Double(seq * 5)), end: d(Double(seq * 5 + 4))) }
        try diary.saveMatches(tripStart: d(100), [], modes: [m(0, .walk), m(1, .bus)])
        try diary.saveMatches(tripStart: d(200), [], modes: [m(0, .car)])
        XCTAssertEqual(try diary.modes(tripStart: d(100)), [m(0, .walk), m(1, .bus)])
        try diary.saveMatches(tripStart: d(100), [], modes: [m(0, .train)])
        XCTAssertEqual(try diary.modes(tripStart: d(100)), [m(0, .train)])
        XCTAssertEqual(try diary.modes(tripStart: d(200)), [m(0, .car)])
    }

    func testV6DiaryMigrates() throws {
        let path = tempPath()
        do { let diary = try Diary(path: path); try diary.append([pt(100)]) }
        let diary = try Diary(path: path)
        XCTAssertEqual(try diary.points(from: d(0), to: d(1000)), [pt(100)])
    }

    func testV7DiaryMigrates() throws {
        let path = tempPath()
        let m = MatchedStretch(seq: 0, wayId: 7, fromM: 1, toM: 2, confidence: 0.9, start: d(1), end: d(2))
        do { let diary = try Diary(path: path); try diary.append([pt(100)]); try diary.saveMatches(tripStart: d(100), [m], modes: []) }
        let diary = try Diary(path: path)
        XCTAssertEqual(try diary.points(from: d(0), to: d(1000)), [pt(100)])
        XCTAssertEqual(try diary.matches(tripStart: d(100)), [m])
    }

    // MARK: Backup and merge

    /// A closed diary file at a new path, filled by `fill`.
    private func backupFile(_ fill: (Diary) throws -> Void) throws -> String {
        let path = tempPath()
        do { try fill(try Diary(path: path)) }
        return path
    }

    private var home: Place { place(1, name: "Home", cells: [PlaceCell(x: 1, y: 1): 2]) }

    private func fillRich(_ b: Diary) throws {
        try b.append([pt(100), pt(200), pt(300)])
        try b.saveSmoothed([(d(100), 7, 8)])
        try b.saveTripLines([line(100, 300)], replacingFrom: d(0))
        try b.saveLearned(places: [home], removing: [], visits: [Visit(start: d(100), end: d(300), placeId: 1)], meta: "placesProcessedUntil", "300.0")
        try b.saveSteps([DaySteps(day: "1970-01-01", steps: 4000, distance: nil, floorsUp: nil)])
        try b.saveActivities([(d(100), .walking)])
        try b.setMeta("smoothingVersion", "3")
        try b.log([LoggedEvent(t: d(100), kind: "a", detail: "")])
    }

    private func count(_ path: String, _ table: String) throws -> Int {
        try DatabaseQueue(path: path).read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \"\(table)\"")! }
    }

    func testSummary() throws {
        let path = try backupFile { try $0.append([pt(300), pt(100), pt(200)]) }
        XCTAssertEqual(try Diary.backupSummary(at: path), BackupSummary(points: 3, first: d(100), last: d(300)))
        XCTAssertEqual(try Diary.backupSummary(at: try backupFile { _ in }), BackupSummary(points: 0, first: nil, last: nil))
    }

    func testNotADatabaseThrows() throws {
        let path = tempPath()
        try Data((0..<1024).map { _ in UInt8.random(in: 0...255) }).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try Diary.backupSummary(at: path))
    }

    func testNewerBackupRefused() throws {
        let path = try backupFile { try $0.append([pt(100)]) }
        try DatabaseQueue(path: path).write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('v99')") }
        XCTAssertThrowsError(try Diary.backupSummary(at: path)) { XCTAssertEqual($0 as? DiaryError, .newerBackup) }
    }

    func testMergeRefusesNewerBackup() throws {
        let diary = try Diary(path: tempPath())
        try diary.append([pt(1)])
        let path = try backupFile { try $0.append([pt(100)]) }
        try DatabaseQueue(path: path).write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('v99')") }
        XCTAssertThrowsError(try diary.merge(backupAt: path)) { XCTAssertEqual($0 as? DiaryError, .newerBackup) }
        XCTAssertEqual(try diary.points(from: d(0), to: d(1000)), [pt(1)])
    }

    func testMergeIntoEmptyCopiesEverything() throws {
        let path = try backupFile(fillRich)
        let diary = try Diary(path: tempPath())
        XCTAssertEqual(try diary.merge(backupAt: path), MergeResult(addedPoints: 3, fresh: true))
        XCTAssertEqual(try diary.points(from: d(0), to: d(1000)), [pt(100), pt(200), pt(300)])
        XCTAssertEqual(try diary.smoothed(from: d(0), to: d(1000)).map(\.lat), [7])
        XCTAssertEqual(try diary.tripLines(minLat: 0, maxLat: 90, minLon: 0, maxLon: 90, from: d(0), to: d(1000)), [line(100, 300)])
        XCTAssertEqual(try diary.places(), [home])
        XCTAssertEqual(try diary.visits(from: d(0), to: d(1000)), [Visit(start: d(100), end: d(300), placeId: 1)])
        XCTAssertEqual(try diary.lifeStats().steps, 4000)
        XCTAssertEqual(try diary.activities(from: d(0), to: d(1000)).map(\.activity), [.walking])
        XCTAssertEqual(try diary.meta("smoothingVersion"), "3")
        XCTAssertEqual(try diary.meta("placesProcessedUntil"), "300.0")
        XCTAssertEqual(try diary.events(from: d(0), to: d(1000)), [])
    }

    func testMergeKeepsCurrentRows() throws {
        let diary = try Diary(path: tempPath())
        try diary.append((0...9).map { pt(Double($0), lat: 1) })
        let path = try backupFile { try $0.append((5...14).map { pt(Double($0), lat: 9) }) }
        XCTAssertEqual(try diary.merge(backupAt: path), MergeResult(addedPoints: 5, fresh: false))
        let got = try diary.points(from: d(0), to: d(100))
        XCTAssertEqual(got.map(\.t), (0...14).map { d(Double($0)) })
        XCTAssertEqual(got.map(\.lat), Array(repeating: 1, count: 10) + Array(repeating: 9, count: 5))
    }

    func testMergeMarksCachesStale() throws {
        let diary = try Diary(path: tempPath())
        try diary.append([pt(1)])
        try diary.saveTripLines([line(1, 2)], replacingFrom: d(0))
        for k in ["smoothingVersion", "matcherVersion", "daysVersion"] { try diary.setMeta(k, "1") }
        let path = try backupFile { try $0.append([pt(100)]); try $0.saveTripLines([line(100, 200)], replacingFrom: d(0)) }
        XCTAssertFalse(try diary.merge(backupAt: path).fresh)
        for k in ["smoothingVersion", "matcherVersion", "daysVersion"] { XCTAssertNil(try diary.meta(k)) }
        XCTAssertEqual(try diary.tripLines(minLat: 0, maxLat: 90, minLon: 0, maxLon: 90, from: d(0), to: d(1000)), [line(1, 2)])
    }

    func testMergePlacesOnlyIntoPlacelessDiary() throws {
        func backup() throws -> String {
            try backupFile { b in
                try b.append([pt(100), pt(200)])
                try b.saveLearned(places: [home], removing: [], visits: [Visit(start: d(100), end: d(200), placeId: 1)],
                                  meta: "placesProcessedUntil", "200.0")
            }
        }
        // (a) The current diary has a place: kept as it is, the backup's place is not taken, the cursor goes back to the backup's first point.
        let a = try Diary(path: tempPath())
        let flat = place(2, name: "Flat", cells: [PlaceCell(x: 5, y: 5): 1])
        try a.append([pt(1000)])
        try a.saveLearned(places: [flat], removing: [], visits: [], meta: "placesProcessedUntil", "1000.0")
        _ = try a.merge(backupAt: try backup())
        XCTAssertEqual(try a.places(), [flat])
        XCTAssertEqual(try a.meta("placesProcessedUntil").flatMap(Double.init), 100)
        // (b) Points but no place: the backup's named place and visits come in, the cursor is the earlier of the two.
        let b = try Diary(path: tempPath())
        try b.append([pt(1000)])
        try b.setMeta("placesProcessedUntil", "1000.0")
        _ = try b.merge(backupAt: try backup())
        XCTAssertEqual(try b.places(), [home])
        XCTAssertEqual(try b.visits(from: d(0), to: d(1000)), [Visit(start: d(100), end: d(200), placeId: 1)])
        XCTAssertEqual(try b.meta("placesProcessedUntil").flatMap(Double.init), 200)
    }

    func testMergeStepsNeverLowered() throws {
        let mainPath = tempPath()
        let diary = try Diary(path: mainPath)
        try diary.saveSteps([DaySteps(day: "2026-11-01", steps: 5000, distance: nil, floorsUp: nil)])
        let path = try backupFile {
            try $0.saveSteps([DaySteps(day: "2026-11-01", steps: 4000, distance: nil, floorsUp: nil),
                              DaySteps(day: "2026-11-02", steps: 3000, distance: nil, floorsUp: nil)])
        }
        _ = try diary.merge(backupAt: path)
        let rows = try DatabaseQueue(path: mainPath).read { try Row.fetchAll($0, sql: "SELECT day, steps FROM daySteps ORDER BY day") }
        XCTAssertEqual(rows.map { $0["day"] as String }, ["2026-11-01", "2026-11-02"])
        XCTAssertEqual(rows.map { $0["steps"] as Int }, [5000, 3000])
    }

    func testMergeTwiceAddsNothing() throws {
        let mainPath = tempPath()
        let diary = try Diary(path: mainPath)
        let path = try backupFile(fillRich)
        XCTAssertEqual(try diary.merge(backupAt: path).addedPoints, 3)
        try diary.setMeta("smoothingVersion", "3")
        let before = try Diary.mergedTables.map { try count(mainPath, $0) }
        XCTAssertEqual(try diary.merge(backupAt: path), MergeResult(addedPoints: 0, fresh: false))
        XCTAssertEqual(try diary.meta("smoothingVersion"), "3")
        XCTAssertEqual(try Diary.mergedTables.map { try count(mainPath, $0) }, before)
    }

    func testFailedMergeChangesNothing() throws {
        let diary = try Diary(path: tempPath())
        try diary.append([pt(1)])
        try diary.setMeta("smoothingVersion", "3")
        let path = try backupFile { try $0.append([pt(100), pt(200)]) }
        try DatabaseQueue(path: path).write { try $0.execute(sql: "DROP TABLE daySteps") }
        XCTAssertThrowsError(try diary.merge(backupAt: path))
        XCTAssertEqual(try diary.points(from: d(0), to: d(1000)), [pt(1)])
        XCTAssertEqual(try diary.meta("smoothingVersion"), "3")
    }

    func testOldBackupMigratesAndMerges() throws {
        let original = tempPath()
        do {   // a v4 database exactly as v0.3.0 left it
            let q = try DatabaseQueue(path: original)
            try q.write { db in
                try db.execute(sql: """
                    CREATE TABLE point(
                        t REAL PRIMARY KEY, lat REAL, lon REAL, rawLat REAL, rawLon REAL,
                        hAcc REAL, speed REAL, kind TEXT, course REAL);
                    CREATE TABLE event(
                        id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL, kind TEXT, detail TEXT);
                    CREATE INDEX event_t ON event(t);
                    CREATE TABLE smoothedPoint(t REAL PRIMARY KEY, lat REAL, lon REAL);
                    CREATE TABLE tripLine(
                        start REAL PRIMARY KEY, end REAL, minLat REAL, maxLat REAL, minLon REAL, maxLon REAL,
                        distance REAL, coords BLOB);
                    CREATE INDEX tripLine_end ON tripLine(end);
                    CREATE TABLE place(
                        id INTEGER PRIMARY KEY, name TEXT, updatedAt REAL, totalSeconds REAL, visits INTEGER, isCandidate INTEGER,
                        pinLat REAL, pinLon REAL, visitDays TEXT, lastVisit REAL);
                    CREATE TABLE placeCell(
                        placeId INTEGER, x INTEGER, y INTEGER, weight REAL, recent REAL, PRIMARY KEY(placeId, x, y));
                    CREATE TABLE visit(start REAL PRIMARY KEY, end REAL, placeId INTEGER);
                    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
                    CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
                    INSERT INTO grdb_migrations VALUES ('v1'), ('v2'), ('v3'), ('v4');
                    INSERT INTO point VALUES (100, 1, 2, 3, 4, 5, 6, 'still', -1), (200, 1, 2, 3, 4, 5, 6, 'still', -1);
                    """)
            }
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: original))
        let copy = tempPath()
        try FileManager.default.copyItem(atPath: original, toPath: copy)
        XCTAssertEqual(try Diary.backupSummary(at: copy).points, 2)
        let diary = try Diary(path: tempPath())
        XCTAssertEqual(try diary.merge(backupAt: copy).addedPoints, 2)
        XCTAssertEqual(try diary.points(from: d(0), to: d(1000)), [pt(100), pt(200)])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: original)), bytes)
    }

    func testMergeCoversEveryTable() throws {
        let path = tempPath()
        _ = try Diary(path: path)
        let tables = try DatabaseQueue(path: path).read { try String.fetchSet($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        // Borders and progress are caches: downloaded and recomputed again after a restore, never merged.
        let rebuilt = ["area", "areaTile", "areaProgress", "streetCovered"]
        XCTAssertEqual(tables.subtracting(Diary.mergedTables + rebuilt + ["event", "meta", "grdb_migrations", "sqlite_sequence"]), [])
    }

    func testAreasRoundTrip() throws {
        let diary = try Diary(path: tempPath())
        let ring: [(lat: Double, lon: Double)] = [(52, 5), (52, 5.1), (52.1, 5.1), (52, 5)]
        let hole: [(lat: Double, lon: Double)] = [(52.01, 5.01), (52.01, 5.02), (52.02, 5.02), (52.01, 5.01)]
        let a = Area(id: 10, level: 8, name: "Utrecht", rings: [ring], holes: [hole])
        let tile = Tile(lat: 52.05, lon: 5.05)
        XCTAssertFalse(try diary.hasAreas(tile))
        try diary.saveAreas([a], tile: tile)
        XCTAssertTrue(try diary.hasAreas(tile))
        XCTAssertEqual(try diary.areas(minLat: 52.04, maxLat: 52.06, minLon: 5.04, maxLon: 5.06), [a])
        XCTAssertTrue(try diary.areas(minLat: 53, maxLat: 54, minLon: 5, maxLon: 6).isEmpty)
        XCTAssertEqual(try diary.storedAreaIds([10, 11]), [10])
    }

    func testProgressRoundTrip() throws {
        let diary = try Diary(path: tempPath())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try diary.saveProgress([AreaProgress(areaId: 1, covered: 2, total: 5)], covered: ["7": t, "9": t + 86_400], bike: false)
        try diary.saveProgress([AreaProgress(areaId: 1, covered: 3, total: 5)], covered: ["7": t], bike: true)
        XCTAssertEqual(try diary.areaProgress(bike: false), [AreaProgress(areaId: 1, covered: 2, total: 5)])
        XCTAssertEqual(try diary.areaProgress(bike: true), [AreaProgress(areaId: 1, covered: 3, total: 5)])
        XCTAssertEqual(try diary.newStreets(from: t, to: t + 3600, bike: false), 1)
        XCTAssertEqual(try diary.newStreets(from: t, to: t + 2 * 86_400, bike: false), 2)
        try diary.saveProgress([], covered: [:], bike: false)
        XCTAssertTrue(try diary.areaProgress(bike: false).isEmpty)
    }
}
