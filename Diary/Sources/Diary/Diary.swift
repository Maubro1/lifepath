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
                    sql: "INSERT OR IGNORE INTO point(t, lat, lon, rawLat, rawLon, hAcc, speed, kind) VALUES (?,?,?,?,?,?,?,?)",
                    arguments: [p.t.timeIntervalSince1970, p.lat, p.lon, p.rawLat, p.rawLon, p.hAcc, p.speed, p.kind.rawValue])
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
                      kind: PointKind(rawValue: r["kind"]) ?? .moving)   // unknown kind: doubt resolves to Moving
    }
}
