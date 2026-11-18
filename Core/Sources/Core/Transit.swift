import Foundation

/// One public-transport line in one direction, from an OSM route relation: its stops in order and its track.
public struct Route: Sendable, Equatable {
    public struct Stop: Sendable, Equatable {
        public var id: Int64
        public var lat: Double, lon: Double
        public init(id: Int64, lat: Double, lon: Double) { self.id = id; self.lat = lat; self.lon = lon }
    }
    public var id: Int64
    public var mode: TravelMode
    public var stops: [Stop]
    public var path: [(lat: Double, lon: Double)]

    public init(id: Int64, mode: TravelMode, stops: [Stop], path: [(lat: Double, lon: Double)]) {
        self.id = id; self.mode = mode; self.stops = stops; self.path = path
    }

    public static func == (a: Route, b: Route) -> Bool {
        a.id == b.id && a.mode == b.mode && a.stops == b.stops && a.path.count == b.path.count
            && zip(a.path, b.path).allSatisfy { $0.lat == $1.lat && $0.lon == $1.lon }
    }

    /// OSM `route=` values LifePath snaps to, and the mode each means.
    public static func mode(_ route: String) -> TravelMode? {
        switch route {
        case "train", "subway", "light_rail", "monorail": .train
        case "tram": .tram
        case "bus", "trolleybus": .bus
        case "ferry": .boat
        default: nil
        }
    }
}

/// Snaps a ride to the line it was on (stage 7 spec, section 3): its first and last fixes lie near two stops of one route
/// relation, boarding before alighting (which settles the direction), and its fixes follow that route's track between them.
public enum Transit {
    /// Stop radius by mode: stations are big, bus stops small.
    static func radius(_ m: TravelMode) -> Double { m == .train ? 150 : m == .bus ? 40 : 80 }
    /// How close fixes must follow the track.
    static func tolerance(_ m: TravelMode) -> Double { m == .train || m == .boat ? 60 : 30 }

    public static func match(_ piece: [FilteredPoint], routes: [Route]) -> (route: Route, from: Int, to: Int, path: [(lat: Double, lon: Double)])? {
        guard let first = piece.first, let last = piece.last else { return nil }
        var best: (route: Route, from: Int, to: Int, path: [(lat: Double, lon: Double)], passed: Int, length: Double)?
        var tied = false
        for r in routes where r.stops.count >= 2 && r.path.count >= 2 {
            let rad = radius(r.mode)
            func nearest(_ p: FilteredPoint) -> Int? {
                r.stops.indices.filter { Geo.distance(p.lat, p.lon, r.stops[$0].lat, r.stops[$0].lon) <= rad }
                    .min { Geo.distance(p.lat, p.lon, r.stops[$0].lat, r.stops[$0].lon) < Geo.distance(p.lat, p.lon, r.stops[$1].lat, r.stops[$1].lon) }
            }
            guard let i = nearest(first), let j = nearest(last), i < j else { continue }
            let a = vertex(r.path, near: r.stops[i]), b = vertex(r.path, near: r.stops[j])
            guard a < b else { continue }
            let slice = Array(r.path[a...b])
            // Fixes along the way follow the track; with no fixes between the stations (a metro) the stations decide.
            let precise = piece.filter { $0.kind == .moving }
            let near = precise.filter { distance($0, to: slice) <= tolerance(r.mode) }.count
            guard precise.isEmpty || Double(near) >= 0.7 * Double(precise.count) else { continue }
            let passed = r.stops[(i + 1)..<j].filter { s in piece.contains { Geo.distance($0.lat, $0.lon, s.lat, s.lon) <= rad } }.count
            let length = zip(slice, slice.dropFirst()).map { Geo.distance($0.lat, $0.lon, $1.lat, $1.lon) }.reduce(0, +)
            if let b = best {
                if passed > b.passed { best = (r, i, j, slice, passed, length); tied = false }
                else if passed == b.passed && abs(length - b.length) > 0.1 * b.length { tied = true }   // a different track: unsure
            } else { best = (r, i, j, slice, passed, length) }
        }
        guard let best, !tied else { return nil }
        return (best.route, best.from, best.to, best.path)
    }

    /// The path vertex closest to a stop.
    static func vertex(_ path: [(lat: Double, lon: Double)], near s: Route.Stop) -> Int {
        path.indices.min { Geo.distance(path[$0].lat, path[$0].lon, s.lat, s.lon) < Geo.distance(path[$1].lat, path[$1].lon, s.lat, s.lon) }!
    }

    /// Metres from a fix to a polyline (local flat projection around the fix).
    static func distance(_ p: FilteredPoint, to line: [(lat: Double, lon: Double)]) -> Double {
        let k = cos(p.lat * .pi / 180), m = 111_320.0
        func xy(_ c: (lat: Double, lon: Double)) -> (x: Double, y: Double) { ((c.lon - p.lon) * m * k, (c.lat - p.lat) * m) }
        var best = Double.infinity
        for (a, b) in zip(line, line.dropFirst()) {
            let u = xy(a), v = xy(b), dx = v.x - u.x, dy = v.y - u.y, len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : min(1, max(0, -(u.x * dx + u.y * dy) / len2))
            best = min(best, ((u.x + t * dx) * (u.x + t * dx) + (u.y + t * dy) * (u.y + t * dy)).squareRoot())
        }
        return line.count == 1 ? Geo.distance(p.lat, p.lon, line[0].lat, line[0].lon) : best
    }

    /// The matched ride as a stretch on the route's track (way id = -relation id), from stop `i` to stop `j`.
    public static func stretch(_ r: Route, from i: Int, to j: Int, start: Date, end: Date) -> MatchedStretch {
        func along(_ v: Int) -> Double {
            zip(r.path[0..<v], r.path[1...v]).map { Geo.distance($0.lat, $0.lon, $1.lat, $1.lon) }.reduce(0, +)
        }
        return MatchedStretch(seq: 0, wayId: -r.id, fromM: along(vertex(r.path, near: r.stops[i])), toM: along(vertex(r.path, near: r.stops[j])),
                              confidence: 1, start: start, end: end)
    }
}
