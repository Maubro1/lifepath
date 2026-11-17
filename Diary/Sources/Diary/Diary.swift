import Foundation
import GRDB
import Core

public final class Diary: Sendable {
    private let pool: DatabasePool

    public init(path: String) throws {
        pool = try DatabasePool(path: path)   // WAL
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
        try migrator.migrate(pool)
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

    /// One recorded still point per `cell`-degree grid cell (lon cells widened by `lonCell`) in the box and time range.
    public func stillPoints(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, from: Date, to: Date,
                            cell: Double, lonCell: Double) throws -> [(lat: Double, lon: Double)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT lat, lon FROM point WHERE kind = 'still' AND lat >= ? AND lat <= ? AND lon >= ? AND lon <= ? AND t >= ? AND t <= ?
                GROUP BY CAST(ROUND(lat / ?) AS INTEGER), CAST(ROUND(lon / ?) AS INTEGER)
                """, arguments: [minLat, maxLat, minLon, maxLon, from.timeIntervalSince1970, to.timeIntervalSince1970, cell, lonCell]).map {
                ($0["lat"], $0["lon"])
            }
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
                    sql: "INSERT OR REPLACE INTO tripLine(start, end, minLat, maxLat, minLon, maxLon, distance, coords) VALUES (?,?,?,?,?,?,?,?)",
                    arguments: [l.start.timeIntervalSince1970, l.end.timeIntervalSince1970, l.minLat, l.maxLat, l.minLon, l.maxLon,
                                l.distance, Self.encode(l.coords)])
            }
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
                         distance: r["distance"], coords: Self.decode(r["coords"]))
            }
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
                try db.execute(sql: "INSERT OR REPLACE INTO way(id, kind, name, oneway, nodes, coords, minLat, maxLat, minLon, maxLon) VALUES (?,?,?,?,?,?,?,?,?,?)",
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
    public func ways(ids: [Int64]) throws -> [Way] {
        try pool.read { db in
            var out: [Way] = []
            for k in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[k..<min(k + 500, ids.count)])
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
                   coords: (0..<ll.count / 2).map { (ll[$0 * 2], ll[$0 * 2 + 1]) })
    }

    /// Derived cache: replaces that trip's matches and modes in one transaction.
    public func saveMatches(tripStart: Date, _ stretches: [MatchedStretch], modes: [ModeStretch]) throws {
        try pool.write { db in
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
