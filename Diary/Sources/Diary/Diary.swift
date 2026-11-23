import Foundation
import GRDB
import Core

public struct BackupSummary: Sendable, Equatable {
    public var points: Int
    public var first: Date?
    public var last: Date?
}

public struct MergeResult: Sendable, Equatable {
    public var addedPoints: Int
    public var fresh: Bool
}

public enum DiaryError: Error, Equatable, LocalizedError {
    case newerBackup

    public var errorDescription: String? {
        "This backup was made by a newer version of LifePath. Update the app, then restore it again."
    }
}

public final class Diary: Sendable {
    private let pool: DatabasePool

    public init(path: String) throws {
        pool = try DatabasePool(path: path)   // WAL
        try Self.migrator().migrate(pool)
    }

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE point(
                    t REAL PRIMARY KEY, lat REAL, lon REAL, rawLat REAL, rawLon REAL,
                    hAcc REAL, speed REAL, kind TEXT);
                CREATE TABLE event(
                    id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL, kind TEXT, detail TEXT);
                CREATE INDEX event_t ON event(t);
                """)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                ALTER TABLE point ADD COLUMN course REAL;
                CREATE TABLE smoothedPoint(t REAL PRIMARY KEY, lat REAL, lon REAL);
                """)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE tripLine(
                    start REAL PRIMARY KEY, end REAL, minLat REAL, maxLat REAL, minLon REAL, maxLon REAL,
                    distance REAL, coords BLOB);
                CREATE INDEX tripLine_end ON tripLine(end);
                """)
        }
        migrator.registerMigration("v4") { db in
            // weight / recent are NULL when the cell is absent from that map.
            try db.execute(sql: """
                CREATE TABLE place(
                    id INTEGER PRIMARY KEY, name TEXT, updatedAt REAL, totalSeconds REAL, visits INTEGER, isCandidate INTEGER,
                    pinLat REAL, pinLon REAL, visitDays TEXT, lastVisit REAL);
                CREATE TABLE placeCell(
                    placeId INTEGER, x INTEGER, y INTEGER, weight REAL, recent REAL, PRIMARY KEY(placeId, x, y));
                CREATE TABLE visit(start REAL PRIMARY KEY, end REAL, placeId INTEGER);
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
                """)
        }
        migrator.registerMigration("v5") { db in
            // Additive: places saved before v5 load with no real days and are refilled by the next real visit.
            try db.execute(sql: "ALTER TABLE place ADD COLUMN realDays TEXT; ALTER TABLE place ADD COLUMN recentDurations TEXT;")
        }
        migrator.registerMigration("v6") { db in
            // Streets cache: recomputable from OSM and the stored points.
            try db.execute(sql: """
                CREATE TABLE way(
                    id INTEGER PRIMARY KEY, kind TEXT, name TEXT, oneway INTEGER, nodes BLOB, coords BLOB,
                    minLat REAL, maxLat REAL, minLon REAL, maxLon REAL);
                CREATE INDEX way_lat ON way(minLat, maxLat);
                CREATE TABLE tile(x INTEGER, y INTEGER, fetchedAt REAL, PRIMARY KEY(x, y));
                CREATE TABLE matchedStretch(
                    tripStart REAL, seq INTEGER, wayId INTEGER, fromM REAL, toM REAL, confidence REAL, start REAL, end REAL,
                    PRIMARY KEY(tripStart, seq));
                """)
        }
        migrator.registerMigration("v7") { db in
            // Additive. activity is kept like points (CoreMotion history lasts only 7 days); stop and modeStretch are recomputable caches.
            // tile.version NULL marks a tile stored before stops and cycle ways existed.
            try db.execute(sql: """
                CREATE TABLE activity(t REAL PRIMARY KEY, kind TEXT);
                CREATE TABLE stop(id INTEGER PRIMARY KEY, kind TEXT, lat REAL, lon REAL);
                CREATE INDEX stop_lat ON stop(lat);
                CREATE TABLE modeStretch(
                    tripStart REAL, seq INTEGER, mode TEXT, confidence REAL, start REAL, end REAL,
                    PRIMARY KEY(tripStart, seq));
                ALTER TABLE tile ADD COLUMN version INTEGER;
                """)
        }
        migrator.registerMigration("v8") { db in
            // Additive. NULL countable reads as false, so a pre-v8 way never counts. Hits and covered ways are recomputable caches.
            try db.execute(sql: """
                ALTER TABLE way ADD COLUMN countable INTEGER;
                CREATE TABLE segmentHit(tripStart REAL, wayId INTEGER, seg INTEGER, bike INTEGER, PRIMARY KEY(tripStart, wayId, seg, bike));
                CREATE TABLE coveredWay(wayId INTEGER PRIMARY KEY, bike INTEGER);
                """)
        }
        migrator.registerMigration("v9") { db in
            // Additive. day is a recomputable cache; daySteps is permanent (CoreMotion keeps only 7 days).
            try db.execute(sql: """
                CREATE TABLE day(day TEXT PRIMARY KEY, distance REAL, movingTime REAL, walked REAL, points INTEGER);
                CREATE TABLE daySteps(day TEXT PRIMARY KEY, steps INTEGER, distance REAL, floorsUp INTEGER);
                """)
        }
        migrator.registerMigration("v10") { db in
            // Additive, and a cache: borders are downloaded again when missing, so a backup never carries them.
            try db.execute(sql: """
                CREATE TABLE area(id INTEGER PRIMARY KEY, level INTEGER, name TEXT, minLat REAL, maxLat REAL, minLon REAL, maxLon REAL,
                                  rings BLOB, holes BLOB);
                CREATE TABLE areaTile(x INTEGER, y INTEGER, PRIMARY KEY(x, y));
                """)
        }
        migrator.registerMigration("v11") { db in
            // Additive caches, recomputed after every matching run.
            try db.execute(sql: """
                CREATE TABLE areaProgress(areaId INTEGER, bike INTEGER, covered INTEGER, total INTEGER, PRIMARY KEY(areaId, bike));
                CREATE TABLE streetCovered(key TEXT, bike INTEGER, at REAL, PRIMARY KEY(key, bike));
                """)
        }
        migrator.registerMigration("v12") { db in
            // Additive cache of public-transport routes (downloaded again when missing, never merged from a backup).
            try db.execute(sql: """
                CREATE TABLE route(id INTEGER PRIMARY KEY, mode TEXT, minLat REAL, maxLat REAL, minLon REAL, maxLon REAL, stops BLOB, path BLOB);
                CREATE TABLE routeTile(x INTEGER, y INTEGER, PRIMARY KEY(x, y));
                """)
        }
        migrator.registerMigration("v13") { db in
            // Additive cache column; NULL (a line cached before v13) reads as unknown until the trip-line rebuild refills it.
            try db.execute(sql: "ALTER TABLE tripLine ADD COLUMN topSpeed REAL")
        }
        return migrator
    }

    public static func defaultPath() throws -> String {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // Best effort: the attribute is unsupported on macOS (CI), and the diary must still open.
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("diary.sqlite").path
    }

    public func append(_ points: [FilteredPoint]) throws {
        try pool.write { db in
            for p in points {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO point(t, lat, lon, rawLat, rawLon, hAcc, speed, kind, course) VALUES (?,?,?,?,?,?,?,?,?)",
                    arguments: [p.t.timeIntervalSince1970, p.lat, p.lon, p.rawLat, p.rawLon, p.hAcc, p.speed, p.kind.rawValue, p.course])
            }
        }
    }

    public func log(_ events: [LoggedEvent]) throws {
        try pool.write { db in
            for e in events {
                try db.execute(sql: "INSERT INTO event(t, kind, detail) VALUES (?,?,?)",
                               arguments: [e.t.timeIntervalSince1970, e.kind, e.detail])
            }
        }
    }

    public func lastPoint() throws -> FilteredPoint? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM point ORDER BY t DESC LIMIT 1").map(Self.point)
        }
    }

    public func points(from: Date, to: Date) throws -> [FilteredPoint] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM point WHERE t >= ? AND t <= ? ORDER BY t",
                             arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]).map(Self.point)
        }
    }

    /// Up to `limit` points in the box with `after < t <= to`, in ascending time order: read in chunks with the last `t` as cursor.
    public func points(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, after: Date, to: Date, limit: Int) throws -> [FilteredPoint] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM point WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ? AND t > ? AND t <= ? ORDER BY t LIMIT ?",
                             arguments: [minLat, maxLat, minLon, maxLon, after.timeIntervalSince1970, to.timeIntervalSince1970, limit]).map(Self.point)
        }
    }

    public func smoothed(from: Date, to: Date) throws -> [(t: Date, lat: Double, lon: Double)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM smoothedPoint WHERE t >= ? AND t <= ? ORDER BY t",
                             arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]).map {
                (Date(timeIntervalSince1970: $0["t"]), $0["lat"], $0["lon"])
            }
        }
    }

    /// Derived cache: replaced freely, never the stored points.
    public func saveSmoothed(_ pts: [(t: Date, lat: Double, lon: Double)]) throws {
        try pool.write { db in
            for p in pts {
                try db.execute(sql: "INSERT OR REPLACE INTO smoothedPoint(t, lat, lon) VALUES (?,?,?)",
                               arguments: [p.t.timeIntervalSince1970, p.lat, p.lon])
            }
        }
    }

    public func smoothedUntil() throws -> Date? {
        try pool.read { db in
            try Double.fetchOne(db, sql: "SELECT MAX(t) FROM smoothedPoint").map { Date(timeIntervalSince1970: $0) }
        }
    }

    /// Derived cache: replaced freely, never the stored points.
    /// Assumes points only ever arrive newer than the cache: any future backup merge/import must clear tripLine, or older points stay uncached.
    public func saveTripLines(_ lines: [TripLine], replacingFrom: Date) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM tripLine WHERE end >= ?", arguments: [replacingFrom.timeIntervalSince1970])
            for l in lines {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO tripLine(start, end, minLat, maxLat, minLon, maxLon, distance, coords, topSpeed) VALUES (?,?,?,?,?,?,?,?,?)",
                    arguments: [l.start.timeIntervalSince1970, l.end.timeIntervalSince1970, l.minLat, l.maxLat, l.minLon, l.maxLon,
                                l.distance, Self.encode(l.coords), l.topSpeed])
            }
        }
    }

    /// Deletes everything recorded in `from..<to` (local days the caller chose): points, smoothed points, trip lines and
    /// matching of trips overlapping it, visits, motion activity, day summaries and steps of those days. A place known only
    /// from deleted visits goes too. Coverage is marked for recounting. One transaction; returns the points deleted.
    @discardableResult
    public func deleteRecords(from: Date, to: Date, days: [String]) throws -> Int {
        let a = from.timeIntervalSince1970, b = to.timeIntervalSince1970
        return try pool.write { db in
            try db.execute(sql: "DELETE FROM point WHERE t >= ? AND t < ?", arguments: [a, b])
            let removed = db.changesCount
            try db.execute(sql: "DELETE FROM smoothedPoint WHERE t >= ? AND t < ?", arguments: [a, b])
            // Trips touching the range go whole, with their matching: no line may still show a deleted moment.
            let trips = try Double.fetchAll(db, sql: "SELECT start FROM tripLine WHERE start < ? AND end >= ?", arguments: [b, a])
            for t in trips {
                for table in ["tripLine"] { try db.execute(sql: "DELETE FROM \(table) WHERE start = ?", arguments: [t]) }
                for table in ["matchedStretch", "modeStretch", "segmentHit"] { try db.execute(sql: "DELETE FROM \(table) WHERE tripStart = ?", arguments: [t]) }
            }
            for table in ["matchedStretch", "modeStretch", "segmentHit"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE tripStart >= ? AND tripStart < ?", arguments: [a, b])
            }
            try db.execute(sql: "DELETE FROM visit WHERE start < ? AND end >= ?", arguments: [b, a])
            try db.execute(sql: "DELETE FROM activity WHERE t >= ? AND t < ?", arguments: [a, b])
            for d in days {
                try db.execute(sql: "DELETE FROM day WHERE day = ?", arguments: [d])
                try db.execute(sql: "DELETE FROM daySteps WHERE day = ?", arguments: [d])
            }
            // A place with no visit left was learned only from deleted days.
            try db.execute(sql: "DELETE FROM placeCell WHERE placeId NOT IN (SELECT DISTINCT placeId FROM visit WHERE placeId IS NOT NULL)")
            try db.execute(sql: "DELETE FROM place WHERE id NOT IN (SELECT DISTINCT placeId FROM visit WHERE placeId IS NOT NULL)")
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES ('coverageDirty', '1')")
            return removed
        }
    }

    /// Replaces one cached trip's line (same start), only when that trip is cached; never touches other trips.
    @discardableResult
    public func replaceTripLine(_ l: TripLine) throws -> Bool {
        try pool.write { db in
            guard try Row.fetchOne(db, sql: "SELECT 1 FROM tripLine WHERE start = ?", arguments: [l.start.timeIntervalSince1970]) != nil else { return false }
            try db.execute(sql: "UPDATE tripLine SET end = ?, minLat = ?, maxLat = ?, minLon = ?, maxLon = ?, distance = ?, coords = ?, topSpeed = ? WHERE start = ?",
                           arguments: [l.end.timeIntervalSince1970, l.minLat, l.maxLat, l.minLon, l.maxLon, l.distance, Self.encode(l.coords),
                                       l.topSpeed, l.start.timeIntervalSince1970])
            return true
        }
    }

    public func tripLines(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, from: Date, to: Date) throws -> [TripLine] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM tripLine WHERE maxLat >= ? AND minLat <= ? AND maxLon >= ? AND minLon <= ?
                AND end >= ? AND start <= ? ORDER BY start
                """, arguments: [minLat, maxLat, minLon, maxLon, from.timeIntervalSince1970, to.timeIntervalSince1970]).map { r in
                TripLine(start: Date(timeIntervalSince1970: r["start"]), end: Date(timeIntervalSince1970: r["end"]),
                         minLat: r["minLat"], maxLat: r["maxLat"], minLon: r["minLon"], maxLon: r["maxLon"],
                         distance: r["distance"], coords: Self.decode(r["coords"]), topSpeed: r["topSpeed"] ?? -1)
            }
        }
    }

    public func saveDays(_ days: [DaySummary], from day: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM day WHERE day >= ?", arguments: [day])
            for d in days {
                try db.execute(sql: "INSERT OR REPLACE INTO day(day, distance, movingTime, walked, points) VALUES (?,?,?,?,?)",
                               arguments: [d.day, d.distance, d.movingTime, d.walked, d.points])
            }
        }
    }

    public func days() throws -> [(summary: DaySummary, steps: Int?)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day.*, daySteps.steps AS steps FROM day LEFT JOIN daySteps ON daySteps.day = day.day ORDER BY day.day DESC
                """).map { r in
                let steps: Int? = r["steps"]
                return (summary: DaySummary(day: r["day"], distance: r["distance"], movingTime: r["movingTime"], walked: r["walked"], points: r["points"]),
                        steps: steps)
            }
        }
    }

    /// Permanent: a later, partial pedometer query never lowers a stored value, and a NULL never replaces a number.
    public func saveSteps(_ s: [DaySteps]) throws {
        try pool.write { db in
            for x in s {
                try db.execute(sql: """
                    INSERT INTO daySteps(day, steps, distance, floorsUp) VALUES (?,?,?,?)
                    ON CONFLICT(day) DO UPDATE SET
                        steps = MAX(steps, excluded.steps),
                        distance = COALESCE(MAX(distance, excluded.distance), distance, excluded.distance),
                        floorsUp = COALESCE(MAX(floorsUp, excluded.floorsUp), floorsUp, excluded.floorsUp)
                    """, arguments: [x.day, x.steps, x.distance, x.floorsUp])
            }
        }
    }

    public func lifeStats() throws -> LifeStats {
        try pool.read { db in
            let a = try Row.fetchOne(db, sql: "SELECT SUM(distance) AS distance, SUM(walked) AS walked, COUNT(*) AS days, SUM(points) AS points FROM day")!
            let b = try Row.fetchOne(db, sql: "SELECT SUM(steps) AS steps, SUM(floorsUp) AS floorsUp, MIN(day) AS since FROM daySteps")!
            let distance: Double? = a["distance"], walked: Double? = a["walked"], points: Int? = a["points"]
            let steps: Int? = b["steps"], floorsUp: Int? = b["floorsUp"], since: String? = b["since"]
            return LifeStats(distance: distance ?? 0, walked: walked ?? 0, days: a["days"], points: points ?? 0,
                             steps: steps, floorsUp: floorsUp, stepsSince: since)
        }
    }

    /// Trips overlapping [from, to), found by the start primary key.
    // shortcut: a trip longer than a day before its card's day is missed in the drawing, upgrade if one exists
    public func tripLines(from: Date, to: Date) throws -> [TripLine] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM tripLine WHERE start >= ? AND start < ? AND end >= ? ORDER BY start",
                             arguments: [from.timeIntervalSince1970 - 86400, to.timeIntervalSince1970, from.timeIntervalSince1970]).map { r in
                TripLine(start: Date(timeIntervalSince1970: r["start"]), end: Date(timeIntervalSince1970: r["end"]),
                         minLat: r["minLat"], maxLat: r["maxLat"], minLon: r["minLon"], maxLon: r["maxLon"],
                         distance: r["distance"], coords: Self.decode(r["coords"]), topSpeed: r["topSpeed"] ?? -1)
            }
        }
    }

    /// The first cached trip's start: a fixed origin for colouring lines by age, whatever part of the map is loaded.
    public func tripLinesSince() throws -> Date? {
        try pool.read { db in
            try Double.fetchOne(db, sql: "SELECT MIN(start) FROM tripLine").map { Date(timeIntervalSince1970: $0) }
        }
    }

    public func tripLinesUntil() throws -> Date? {
        try pool.read { db in
            try Double.fetchOne(db, sql: "SELECT MAX(end) FROM tripLine").map { Date(timeIntervalSince1970: $0) }
        }
    }

    /// Little-endian Float64 triples (lat, lon, speed).
    private static func encode(_ coords: [(lat: Double, lon: Double, speed: Double)]) -> Data {
        var d = Data(capacity: coords.count * 24)
        for c in coords {
            for v in [c.lat, c.lon, c.speed] { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }

    private static func decode(_ d: Data) -> [(lat: Double, lon: Double, speed: Double)] {
        let vals = (0..<d.count / 8).map { i in
            Double(bitPattern: UInt64(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) }))
        }
        return (0..<vals.count / 3).map { (vals[$0 * 3], vals[$0 * 3 + 1], vals[$0 * 3 + 2]) }
    }

    /// One transaction, tile row last: a crash never leaves a tile marked fetched without its ways. A way in two tiles is stored once.
    public func saveTile(_ tile: Tile, ways: [Way], stops: [Stop], version: Int) throws {
        try pool.write { db in
            for w in ways {
                var row: StatementArguments = [w.id, w.kind.rawValue, w.name, w.oneway, Self.pack(w.nodes.map { UInt64(bitPattern: $0) })]
                row += [Self.pack(w.coords.flatMap { [$0.lat.bitPattern, $0.lon.bitPattern] })]
                row += [w.coords.map(\.lat).min(), w.coords.map(\.lat).max(), w.coords.map(\.lon).min(), w.coords.map(\.lon).max()]
                row += [w.countable]
                try db.execute(sql: "INSERT OR REPLACE INTO way(id, kind, name, oneway, nodes, coords, minLat, maxLat, minLon, maxLon, countable) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                               arguments: row)
            }
            for s in stops {
                try db.execute(sql: "INSERT OR REPLACE INTO stop(id, kind, lat, lon) VALUES (?,?,?,?)",
                               arguments: [s.id, s.kind.rawValue, s.lat, s.lon])
            }
            var tileRow: StatementArguments = [tile.x, tile.y, Date().timeIntervalSince1970]
            tileRow += [version]
            try db.execute(sql: "INSERT OR REPLACE INTO tile(x, y, fetchedAt, version) VALUES (?,?,?,?)", arguments: tileRow)
        }
    }

    /// True only when the stored tile is at least that version; a tile from before v7 has none and is stale.
    public func hasTile(_ tile: Tile, version: Int) throws -> Bool {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT 1 FROM tile WHERE x = ? AND y = ? AND version >= ?", arguments: [tile.x, tile.y, version]) != nil
        }
    }

    public func stops(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) throws -> [Stop] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM stop WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ? ORDER BY id",
                             arguments: [minLat, maxLat, minLon, maxLon]).compactMap { r in
                StopKind(rawValue: r["kind"]).map { Stop(id: r["id"], kind: $0, lat: r["lat"], lon: r["lon"]) }
            }
        }
    }

    /// Permanent, like points: CoreMotion keeps only 7 days.
    public func saveActivities(_ a: [(t: Date, activity: Activity)]) throws {
        try pool.write { db in
            for x in a {
                try db.execute(sql: "INSERT OR REPLACE INTO activity(t, kind) VALUES (?,?)", arguments: [x.t.timeIntervalSince1970, x.activity.rawValue])
            }
        }
    }

    /// The rows in range plus the latest one before it, so the first point has a state.
    public func activities(from: Date, to: Date) throws -> [(t: Date, activity: Activity)] {
        try pool.read { db in
            let f = from.timeIntervalSince1970
            let before = try Double.fetchOne(db, sql: "SELECT MAX(t) FROM activity WHERE t < ?", arguments: [f]) ?? f
            return try Row.fetchAll(db, sql: "SELECT t, kind FROM activity WHERE t >= ? AND t <= ? ORDER BY t",
                                    arguments: [before, to.timeIntervalSince1970]).map {
                (t: Date(timeIntervalSince1970: $0["t"]), activity: Activity(rawValue: $0["kind"]) ?? .unknown)
            }
        }
    }

    /// Ways whose bounding box overlaps the box.
    public func ways(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) throws -> [Way] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM way WHERE maxLat >= ? AND minLat <= ? AND maxLon >= ? AND minLon <= ? ORDER BY id",
                             arguments: [minLat, maxLat, minLon, maxLon]).map(Self.way)
        }
    }

    /// Ways by id, in id order; ids are bound 500 at a time, under SQLite's argument limit.
    /// Ways by id. A negative id is a public-transport route (-relation id), returned as its track, so a ride snapped to its
    /// line is drawn wherever matched stretches are.
    public func ways(ids: [Int64]) throws -> [Way] {
        let routes = try self.routes(ids: ids.filter { $0 < 0 }.map { -$0 }).map { r in
            Way(id: -r.id, kind: r.mode == .tram ? .tram : r.mode == .boat ? .ferry : r.mode == .bus ? .road : .rail, name: nil, oneway: true,
                nodes: r.path.indices.map { Int64($0) }, coords: r.path, countable: false)
        }
        let positive = ids.filter { $0 > 0 }
        return try routes + pool.read { db in
            var out: [Way] = []
            for k in stride(from: 0, to: positive.count, by: 500) {
                let chunk = Array(positive[k..<min(k + 500, positive.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                out += try Row.fetchAll(db, sql: "SELECT * FROM way WHERE id IN (\(marks))", arguments: StatementArguments(chunk)).map(Self.way)
            }
            return out.sorted { $0.id < $1.id }
        }
    }

    private static func way(_ r: Row) -> Way {
        let ll = unpack(r["coords"]).map { Double(bitPattern: $0) }
        return Way(id: r["id"], kind: WayKind(rawValue: r["kind"]) ?? .road, name: r["name"], oneway: r["oneway"],
                   nodes: unpack(r["nodes"]).map { Int64(bitPattern: $0) },
                   coords: (0..<ll.count / 2).map { (ll[$0 * 2], ll[$0 * 2 + 1]) },
                   countable: (r["countable"] as Bool?) ?? false)
    }

    /// Derived cache: replaces that trip's matches, modes and segment hits in one transaction.
    public func saveMatches(tripStart: Date, _ stretches: [MatchedStretch], modes: [ModeStretch], hits: Set<SegmentHit> = []) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM segmentHit WHERE tripStart = ?", arguments: [tripStart.timeIntervalSince1970])
            for h in hits {
                let row: StatementArguments = [tripStart.timeIntervalSince1970, h.wayId, h.seg, h.bike]
                try db.execute(sql: "INSERT INTO segmentHit(tripStart, wayId, seg, bike) VALUES (?,?,?,?)", arguments: row)
            }
            try db.execute(sql: "DELETE FROM matchedStretch WHERE tripStart = ?", arguments: [tripStart.timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM modeStretch WHERE tripStart = ?", arguments: [tripStart.timeIntervalSince1970])
            for m in modes {
                var row: StatementArguments = [tripStart.timeIntervalSince1970, m.seq, m.mode.rawValue, m.confidence]
                row += [m.start.timeIntervalSince1970, m.end.timeIntervalSince1970]
                try db.execute(sql: "INSERT INTO modeStretch(tripStart, seq, mode, confidence, start, end) VALUES (?,?,?,?,?,?)", arguments: row)
            }
            for m in stretches {
                var row: StatementArguments = [tripStart.timeIntervalSince1970, m.seq, m.wayId, m.fromM, m.toM]
                row += [m.confidence, m.start.timeIntervalSince1970, m.end.timeIntervalSince1970]
                try db.execute(sql: "INSERT INTO matchedStretch(tripStart, seq, wayId, fromM, toM, confidence, start, end) VALUES (?,?,?,?,?,?,?,?)",
                               arguments: row)
            }
        }
    }

    /// A full re-match starts from none: hits of re-cut trips would otherwise stay under their old start.
    public func clearSegmentHits() throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM segmentHit") }
    }

    /// Distinct hits over all trips.
    public func segmentHits() throws -> [SegmentHit] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT DISTINCT wayId, seg, bike FROM segmentHit ORDER BY wayId, seg, bike").map {
                SegmentHit(wayId: $0["wayId"], seg: $0["seg"], bike: $0["bike"])
            }
        }
    }

    /// Hits with the start of the trip that made them, oldest first.
    public func segmentHitsDated() throws -> [(hit: SegmentHit, tripStart: Date)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT tripStart, wayId, seg, bike FROM segmentHit ORDER BY tripStart").map {
                (SegmentHit(wayId: $0["wayId"], seg: $0["seg"], bike: $0["bike"]), Date(timeIntervalSince1970: $0["tripStart"]))
            }
        }
    }

    /// Replaces the progress per area and the street covered dates for one counting rule (with or without cycling).
    public func saveProgress(_ areas: [AreaProgress], covered: [String: Date], bike: Bool) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM areaProgress WHERE bike = ?", arguments: [bike])
            try db.execute(sql: "DELETE FROM streetCovered WHERE bike = ?", arguments: [bike])
            for a in areas {
                try db.execute(sql: "INSERT INTO areaProgress(areaId, bike, covered, total) VALUES (?,?,?,?)", arguments: [a.areaId, bike, a.covered, a.total])
            }
            for (k, t) in covered {
                try db.execute(sql: "INSERT INTO streetCovered(key, bike, at) VALUES (?,?,?)", arguments: [k, bike, t.timeIntervalSince1970])
            }
        }
    }

    public func areaProgress(bike: Bool) throws -> [AreaProgress] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM areaProgress WHERE bike = ? ORDER BY areaId", arguments: [bike]).map {
                AreaProgress(areaId: $0["areaId"], covered: $0["covered"], total: $0["total"])
            }
        }
    }

    /// Streets that became walked during trips starting in `from..<to`.
    public func newStreets(from: Date, to: Date, bike: Bool) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM streetCovered WHERE bike = ? AND at >= ? AND at < ?",
                             arguments: [bike, from.timeIntervalSince1970, to.timeIntervalSince1970]) ?? 0
        }
    }

    /// Name and level of every stored area, for labelling progress.
    public func areaNames() throws -> [Int64: (name: String, level: Int)] {
        try pool.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, name, level FROM area").map { r -> (Int64, (name: String, level: Int)) in
                (r["id"], (r["name"], r["level"]))
            })
        }
    }

    public func countableWays() throws -> [Way] {
        try pool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM way WHERE countable = 1 ORDER BY id").map(Self.way) }
    }

    /// One transaction: replaces every covered way and the tally "onFoot withBike total".
    public func saveCoverage(_ r: CoverageResult) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM coveredWay")
            for (id, bike) in r.ways {
                try db.execute(sql: "INSERT INTO coveredWay(wayId, bike) VALUES (?,?)", arguments: [id, bike])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?,?)",
                           arguments: ["streetsWalked", "\(r.onFoot) \(r.withBike) \(r.total)"])
        }
    }

    /// Covered ways whose box overlaps the box; without bike, ways covered only by cycling are left out.
    public func coveredWays(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, bike: Bool) throws -> [Way] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT way.* FROM way JOIN coveredWay ON coveredWay.wayId = way.id
                WHERE way.maxLat >= ? AND way.minLat <= ? AND way.maxLon >= ? AND way.minLon <= ? AND (? OR coveredWay.bike = 0)
                ORDER BY way.id
                """, arguments: [minLat, maxLat, minLon, maxLon, bike]).map(Self.way)
        }
    }

    public func streetsWalked(bike: Bool) throws -> (covered: Int, total: Int)? {
        guard let m = try meta("streetsWalked") else { return nil }
        let n = m.split(separator: " ").compactMap { Int($0) }
        return n.count == 3 ? (bike ? n[1] : n[0], n[2]) : nil
    }

    public func modes(tripStart: Date) throws -> [ModeStretch] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM modeStretch WHERE tripStart = ? ORDER BY seq",
                             arguments: [tripStart.timeIntervalSince1970]).compactMap { r in
                TravelMode(rawValue: r["mode"]).map { ModeStretch(seq: r["seq"], mode: $0, confidence: r["confidence"],
                                                       start: Date(timeIntervalSince1970: r["start"]), end: Date(timeIntervalSince1970: r["end"])) }
            }
        }
    }

    /// Modes of every trip starting in the range, by trip start.
    public func modes(from: Date, to: Date) throws -> [Date: [ModeStretch]] {
        try pool.read { db in
            var out: [Date: [ModeStretch]] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT * FROM modeStretch WHERE tripStart >= ? AND tripStart <= ? ORDER BY tripStart, seq",
                                      arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]) {
                guard let m = TravelMode(rawValue: r["mode"]) else { continue }
                out[Date(timeIntervalSince1970: r["tripStart"]), default: []].append(
                    ModeStretch(seq: r["seq"], mode: m, confidence: r["confidence"],
                                start: Date(timeIntervalSince1970: r["start"]), end: Date(timeIntervalSince1970: r["end"])))
            }
            return out
        }
    }

    public func matches(tripStart: Date) throws -> [MatchedStretch] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM matchedStretch WHERE tripStart = ? ORDER BY seq",
                             arguments: [tripStart.timeIntervalSince1970]).map {
                MatchedStretch(seq: $0["seq"], wayId: $0["wayId"], fromM: $0["fromM"], toM: $0["toM"], confidence: $0["confidence"],
                               start: Date(timeIntervalSince1970: $0["start"]), end: Date(timeIntervalSince1970: $0["end"]))
            }
        }
    }

    /// Little-endian 64-bit words (Float64 bit patterns or Int64 node ids).
    /// Borders found for a tile; the tile is then marked so its borders are not asked for again.
    public func saveAreas(_ areas: [Area], tile: Tile) throws {
        try pool.write { db in
            for a in areas {
                let b = a.bounds
                var row: StatementArguments = [a.id, a.level, a.name, b.minLat, b.maxLat, b.minLon, b.maxLon]
                row += [Self.packRings(a.rings), Self.packRings(a.holes)]
                try db.execute(sql: "INSERT OR REPLACE INTO area(id, level, name, minLat, maxLat, minLon, maxLon, rings, holes) VALUES (?,?,?,?,?,?,?,?,?)",
                               arguments: row)
            }
            try db.execute(sql: "INSERT OR REPLACE INTO areaTile(x, y) VALUES (?, ?)", arguments: [tile.x, tile.y])
        }
    }

    public func hasAreas(_ tile: Tile) throws -> Bool {
        try pool.read { db in try Row.fetchOne(db, sql: "SELECT 1 FROM areaTile WHERE x = ? AND y = ?", arguments: [tile.x, tile.y]) != nil }
    }

    /// Which of these relation ids already have a stored shape.
    public func storedAreaIds(_ ids: [Int64]) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        return try pool.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT id FROM area WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                                   arguments: StatementArguments(ids)))
        }
    }

    public func areas(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) throws -> [Area] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM area WHERE maxLat >= ? AND minLat <= ? AND maxLon >= ? AND minLon <= ? ORDER BY id",
                             arguments: [minLat, maxLat, minLon, maxLon]).map { r in
                Area(id: r["id"], level: r["level"], name: r["name"], rings: Self.unpackRings(r["rings"]), holes: Self.unpackRings(r["holes"]))
            }
        }
    }

    /// Routes found for a tile; the tile is then marked so its routes are not asked for again.
    public func saveRoutes(_ routes: [Route], tile: Tile) throws {
        try pool.write { db in
            for r in routes {
                let lats = r.path.map(\.lat), lons = r.path.map(\.lon)
                var row: StatementArguments = [r.id, r.mode.rawValue, lats.min(), lats.max(), lons.min(), lons.max()]
                row += [Self.pack(r.stops.flatMap { [UInt64(bitPattern: $0.id), $0.lat.bitPattern, $0.lon.bitPattern] }), Self.packRings([r.path])]
                try db.execute(sql: "INSERT OR REPLACE INTO route(id, mode, minLat, maxLat, minLon, maxLon, stops, path) VALUES (?,?,?,?,?,?,?,?)", arguments: row)
            }
            try db.execute(sql: "INSERT OR REPLACE INTO routeTile(x, y) VALUES (?, ?)", arguments: [tile.x, tile.y])
        }
    }

    public func hasRoutes(_ tile: Tile) throws -> Bool {
        try pool.read { db in try Row.fetchOne(db, sql: "SELECT 1 FROM routeTile WHERE x = ? AND y = ?", arguments: [tile.x, tile.y]) != nil }
    }

    public func routes(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) throws -> [Route] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM route WHERE maxLat >= ? AND minLat <= ? AND maxLon >= ? AND minLon <= ? ORDER BY id",
                             arguments: [minLat, maxLat, minLon, maxLon]).compactMap(Self.route)
        }
    }

    public func routes(ids: [Int64]) throws -> [Route] {
        guard !ids.isEmpty else { return [] }
        return try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM route WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                             arguments: StatementArguments(ids)).compactMap(Self.route)
        }
    }

    private static func route(_ r: Row) -> Route? {
        guard let mode = TravelMode(rawValue: r["mode"]) else { return nil }
        let w = unpack(r["stops"])
        let stops = stride(from: 0, to: w.count - 2, by: 3).map { Route.Stop(id: Int64(bitPattern: w[$0]), lat: Double(bitPattern: w[$0 + 1]), lon: Double(bitPattern: w[$0 + 2])) }
        return Route(id: r["id"], mode: mode, stops: stops, path: unpackRings(r["path"]).first ?? [])
    }

    /// Rings as words: per ring its point count, then lat and lon bit patterns.
    private static func packRings(_ rings: [[(lat: Double, lon: Double)]]) -> Data {
        pack(rings.flatMap { r in [UInt64(r.count)] + r.flatMap { [$0.lat.bitPattern, $0.lon.bitPattern] } })
    }

    private static func unpackRings(_ d: Data) -> [[(lat: Double, lon: Double)]] {
        let w = unpack(d)
        var out: [[(lat: Double, lon: Double)]] = [], i = 0
        while i < w.count {
            let n = Int(w[i]); i += 1
            guard i + 2 * n <= w.count else { break }
            out.append((0..<n).map { k in (Double(bitPattern: w[i + 2 * k]), Double(bitPattern: w[i + 2 * k + 1])) })
            i += 2 * n
        }
        return out
    }

    private static func pack(_ words: [UInt64]) -> Data {
        var d = Data(capacity: words.count * 8)
        for w in words { withUnsafeBytes(of: w.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    private static func unpack(_ d: Data) -> [UInt64] {
        (0..<d.count / 8).map { i in UInt64(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) }) }
    }

    public func places() throws -> [Place] {
        try pool.read { db in
            var cells: [Int64: [Row]] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT * FROM placeCell") { cells[r["placeId"], default: []].append(r) }
            return try Row.fetchAll(db, sql: "SELECT * FROM place ORDER BY id").map { r in
                let id: Int64 = r["id"]
                var weight: [PlaceCell: Double] = [:], recent: [PlaceCell: Double] = [:]
                for c in cells[id] ?? [] {
                    let cell = PlaceCell(x: c["x"], y: c["y"])
                    if let w: Double = c["weight"] { weight[cell] = w }
                    if let w: Double = c["recent"] { recent[cell] = w }
                }
                func list<T: LosslessStringConvertible>(_ column: String) -> [T] {
                    (r[column] as String? ?? "").split(separator: ",").compactMap { T(String($0)) }
                }
                var place = Place(id: id, name: r["name"], cells: weight, recent: recent, visitDays: Set(list("visitDays") as [Int]),
                                  updatedAt: Date(timeIntervalSince1970: r["updatedAt"]), lastVisit: Date(timeIntervalSince1970: r["lastVisit"]),
                                  totalSeconds: r["totalSeconds"], visits: r["visits"], isCandidate: r["isCandidate"],
                                  realDays: Set(list("realDays") as [Int]))
                place.recentDurations = list("recentDurations")
                return place
            }
        }
    }

    /// One transaction. `removing` = ids merged away (their cells already live in the survivor).
    public func savePlaces(_ places: [Place], removing ids: [Int64]) throws {
        try pool.write { db in try Self.writePlaces(db, places, removing: ids) }
    }

    public func saveVisits(_ visits: [Visit]) throws {
        try pool.write { db in try Self.writeVisits(db, visits) }
    }

    /// Places, merged-away ids, visits and the learning cursor in one transaction, so a crash can never count a visit twice.
    public func saveLearned(places: [Place], removing ids: [Int64], visits: [Visit], meta key: String, _ value: String) throws {
        try pool.write { db in
            try Self.writePlaces(db, places, removing: ids)
            try Self.writeVisits(db, visits)
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?,?)", arguments: [key, value])
        }
    }

    /// Built step by step: one 12-value literal is too much for the type checker.
    private static func placeRow(_ p: Place, _ pin: (lat: Double, lon: Double)?) -> StatementArguments {
        func list(_ xs: [some LosslessStringConvertible]) -> String { xs.map(String.init).joined(separator: ",") }
        var row: StatementArguments = [p.id, p.name, p.updatedAt.timeIntervalSince1970, p.totalSeconds, p.visits, p.isCandidate]
        row += [pin?.lat, pin?.lon, list(p.visitDays.sorted()), p.lastVisit.timeIntervalSince1970]
        row += [list(p.realDays.sorted()), list(p.recentDurations)]
        return row
    }

    private static func writePlaces(_ db: Database, _ places: [Place], removing ids: [Int64]) throws {
        for id in ids {
            try db.execute(sql: "DELETE FROM placeCell WHERE placeId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM place WHERE id = ?", arguments: [id])
        }
        for p in places {
            let pin = p.pin   // cache only: loading recomputes it
            // The stored name always wins (set, changed or cleared): the owner may rename while a run holds an older copy.
            try db.execute(sql: """
                INSERT INTO place(id, name, updatedAt, totalSeconds, visits, isCandidate, pinLat, pinLon, visitDays, lastVisit,
                                  realDays, recentDurations)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET updatedAt = excluded.updatedAt,
                    totalSeconds = excluded.totalSeconds, visits = excluded.visits, isCandidate = excluded.isCandidate,
                    pinLat = excluded.pinLat, pinLon = excluded.pinLon, visitDays = excluded.visitDays, lastVisit = excluded.lastVisit,
                    realDays = excluded.realDays, recentDurations = excluded.recentDurations
                """, arguments: Self.placeRow(p, pin))
            try db.execute(sql: "DELETE FROM placeCell WHERE placeId = ?", arguments: [p.id])
            for c in Set(p.cells.keys).union(p.recent.keys) {
                try db.execute(sql: "INSERT INTO placeCell(placeId, x, y, weight, recent) VALUES (?,?,?,?,?)",
                               arguments: [p.id, c.x, c.y, p.cells[c], p.recent[c]])
            }
        }
    }

    private static func writeVisits(_ db: Database, _ visits: [Visit]) throws {
        for v in visits {
            try db.execute(sql: "INSERT OR REPLACE INTO visit(start, end, placeId) VALUES (?,?,?)",
                           arguments: [v.start.timeIntervalSince1970, v.end.timeIntervalSince1970, v.placeId])
        }
    }

    /// Visits overlapping the range.
    public func visits(from: Date, to: Date) throws -> [Visit] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM visit WHERE end >= ? AND start <= ? ORDER BY start",
                             arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]).map {
                Visit(start: Date(timeIntervalSince1970: $0["start"]), end: Date(timeIntervalSince1970: $0["end"]), placeId: $0["placeId"])
            }
        }
    }

    public func renamePlace(_ id: Int64, to name: String?) throws {
        try pool.write { db in try db.execute(sql: "UPDATE place SET name = ? WHERE id = ?", arguments: [name, id]) }
    }

    public func meta(_ key: String) throws -> String? {
        try pool.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    /// Moves a time cursor (seconds since 1970) back to `t` when it is past it, so late-arriving points get processed.
    public func rewindMeta(_ key: String, to t: Date) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE meta SET value = ? WHERE key = ? AND CAST(value AS REAL) > ?",
                           arguments: [String(t.timeIntervalSince1970), key, t.timeIntervalSince1970])
        }
    }

    /// A consistent copy of the whole diary at `url` (which must not exist yet), read through a reader connection so
    /// recording's writes are never blocked while it runs.
    public func backup(to url: URL) throws {
        try pool.backup(to: DatabaseQueue(path: url.path))
    }

    /// Opens the file with `Diary(path:)`, so it MIGRATES THE FILE IN PLACE: callers pass a private copy, never the picked file.
    /// Throws when the file is not a diary, or `DiaryError.newerBackup` when a newer app version wrote it.
    public static func backupSummary(at path: String) throws -> BackupSummary {
        try refuseNewer(path)
        let backup = try Diary(path: path)
        return try backup.pool.read { db in
            let r = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, MIN(t) AS first, MAX(t) AS last FROM point")!
            let first: Double? = r["first"], last: Double? = r["last"]
            return BackupSummary(points: r["n"], first: first.map(Date.init(timeIntervalSince1970:)),
                                 last: last.map(Date.init(timeIntervalSince1970:)))
        }
    }

    /// A newer app version's file may hold rows this version would misread: refused before anything opens or copies it.
    private static func refuseNewer(_ path: String) throws {
        if try DatabaseQueue(path: path).read({ try migrator().hasBeenSuperseded($0) }) { throw DiaryError.newerBackup }
    }

    /// Every table `merge` handles; `event` is never imported and `meta` is handled apart.
    public static let mergedTables = ["point", "activity", "way", "tile", "stop", "daySteps", "place", "placeCell", "visit",
                                      "smoothedPoint", "tripLine", "matchedStretch", "modeStretch", "segmentHit", "coveredWay", "day"]

    /// Merges a backup that `backupSummary` already migrated, in one transaction: nothing here is deleted or overwritten
    /// (the current row wins on the same key), except the cache versions, which are cleared so the caches rebuild.
    public func merge(backupAt path: String) throws -> MergeResult {
        try Self.refuseNewer(path)   // checked here too: callers are not trusted to have run backupSummary
        return try pool.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS b", arguments: [path])   // not allowed inside a transaction
            defer { try? db.execute(sql: "DETACH DATABASE b") }
            var result = MergeResult(addedPoints: 0, fresh: false)
            try db.inTransaction {
                result.fresh = try Row.fetchOne(db, sql: "SELECT 1 FROM main.point LIMIT 1") == nil
                let placeless = try Row.fetchOne(db, sql: "SELECT 1 FROM main.place LIMIT 1") == nil
                // By the current diary's column names: a newer backup's extra columns are ignored.
                func copy(_ table: String) throws {
                    let cols = try Row.fetchAll(db, sql: "PRAGMA main.table_info(\"\(table)\")")
                        .map { "\"\($0["name"] as String)\"" }.joined(separator: ", ")
                    try db.execute(sql: "INSERT OR IGNORE INTO main.\"\(table)\"(\(cols)) SELECT \(cols) FROM b.\"\(table)\"")
                }
                try copy("point")
                result.addedPoints = db.changesCount
                for t in ["activity", "way", "tile", "stop"] { try copy(t) }
                // Same rule as saveSteps: a stored count is never lowered.
                try db.execute(sql: """
                    INSERT INTO main.daySteps(day, steps, distance, floorsUp) SELECT day, steps, distance, floorsUp FROM b.daySteps WHERE true
                    ON CONFLICT(day) DO UPDATE SET
                        steps = MAX(steps, excluded.steps),
                        distance = COALESCE(MAX(distance, excluded.distance), distance, excluded.distance),
                        floorsUp = COALESCE(MAX(floorsUp, excluded.floorsUp), floorsUp, excluded.floorsUp)
                    """)
                // shortcut: a backup place's name is not carried into a diary that already has places, upgrade if the owner merges old phones
                if placeless { for t in ["place", "placeCell", "visit"] { try copy(t) } }
                if result.fresh {
                    // The backup's caches and cursors describe exactly its points.
                    for t in ["smoothedPoint", "tripLine", "matchedStretch", "modeStretch", "segmentHit", "coveredWay", "day"] { try copy(t) }
                    try db.execute(sql: "INSERT OR REPLACE INTO main.meta(key, value) SELECT key, value FROM b.meta")
                } else if result.addedPoints > 0 {
                    try db.execute(sql: "DELETE FROM main.meta WHERE key IN ('smoothingVersion', 'matcherVersion', 'daysVersion')")
                    // Visits already stored are skipped by Places.settle, so the rewind cannot count a visit twice.
                    let cursor = try placeless
                        ? Double.fetchOne(db, sql: "SELECT CAST(value AS REAL) FROM b.meta WHERE key = 'placesProcessedUntil'") : nil
                    if let target = try cursor ?? Double.fetchOne(db, sql: "SELECT MIN(t) FROM b.point") {
                        try db.execute(sql: "UPDATE main.meta SET value = ? WHERE key = 'placesProcessedUntil' AND CAST(value AS REAL) > ?",
                                       arguments: [String(target), target])
                    }
                }
                return .commit
            }
            return result
        }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try pool.write { db in try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?,?)", arguments: [key, value]) }
    }

    public func events(from: Date, to: Date) throws -> [LoggedEvent] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM event WHERE t >= ? AND t <= ? ORDER BY t, id",
                             arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]).map { r in
                LoggedEvent(t: Date(timeIntervalSince1970: r["t"]), kind: r["kind"], detail: r["detail"])
            }
        }
    }

    public func pruneEvents(olderThan: Date) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM event WHERE t < ?", arguments: [olderThan.timeIntervalSince1970])
        }
    }

    private static func point(_ r: Row) -> FilteredPoint {
        FilteredPoint(t: Date(timeIntervalSince1970: r["t"]), lat: r["lat"], lon: r["lon"],
                      rawLat: r["rawLat"], rawLon: r["rawLon"], hAcc: r["hAcc"], speed: r["speed"],
                      kind: PointKind(rawValue: r["kind"]) ?? .moving,   // unknown kind: doubt resolves to Moving
                      course: (r["course"] as Double?) ?? -1)
    }
}
