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
}
