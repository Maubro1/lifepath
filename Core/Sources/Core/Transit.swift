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

    /// A ride stretch: its fixes, whether a walk touches it on each side, whether it may join the piece before it (no stay,
    /// no long walk and under 3 h between them), and the last precise fix before it and the first after it (`lead`, `tail`:
    /// where you stood on the platform; a ride's own first and last fixes are often rough and hundreds of metres off).
    public struct Piece: Sendable {
        public var points: [FilteredPoint]
        public var walkBefore, walkAfter, joins: Bool
        public var lead, tail: FilteredPoint?
        public init(points: [FilteredPoint], walkBefore: Bool, walkAfter: Bool, joins: Bool, lead: FilteredPoint? = nil, tail: FilteredPoint? = nil) {
            self.points = points; self.walkBefore = walkBefore; self.walkAfter = walkAfter; self.joins = joins; self.lead = lead; self.tail = tail
        }
    }

    /// Rides cut into pieces by signal gaps or long station stops, linked back together: consecutive pieces that joined
    /// match one route between two stations (`match`), each end settled at its station, and every gap passable by train.
    /// Returns, per piece of each ride (one piece or more), its share of the route's track; a share runs on to the next piece,
    /// so gaps are drawn too.
    public static func link(_ pieces: [Piece], routes: [Route]) -> [(piece: Int, stretch: MatchedStretch, mode: TravelMode)] {
        var out: [(piece: Int, stretch: MatchedStretch, mode: TravelMode)] = [], i = 0
        while i < pieces.count {
            // From the piece alone on: one the trip snapped on a station blip, or not at all, gets another chance here.
            var j = i, found = false
            while !found, j < pieces.count, j - i <= 8, j == i || pieces[j].joins {
                defer { if !found { j += 1 } }
                let plain = pieces[i...j].flatMap(\.points), lead = pieces[i].lead, tail = pieces[j].tail
                let anchored = (lead.map { [$0] } ?? []) + plain + (tail.map { [$0] } ?? [])
                guard let m = match(anchored, routes: routes) ?? (anchored.count > plain.count ? match(plain, routes: routes) : nil) else { continue }
                let r = m.route, rad = radius(r.mode)
                // A station passed at speed is a blip: an end counts when a walk touches it or the fixes stay there 30 s.
                func dwell(_ ps: [FilteredPoint], _ s: Route.Stop) -> Bool {
                    let t = ps.filter { Geo.distance($0.lat, $0.lon, s.lat, s.lon) <= rad }.map(\.t)
                    guard let first = t.min(), let last = t.max() else { return false }
                    return last.timeIntervalSince(first) >= 30
                }
                // Standing on the platform before or after the ride settles that end too.
                func at(_ p: FilteredPoint?, _ s: Route.Stop) -> Bool { p.map { Geo.distance($0.lat, $0.lon, s.lat, s.lon) <= rad } ?? false }
                guard pieces[i].walkBefore || at(lead, r.stops[m.from]) || dwell(pieces[i].points, r.stops[m.from]),
                      pieces[j].walkAfter || at(tail, r.stops[m.to]) || dwell(pieces[j].points, r.stops[m.to]) else { continue }
                // Metres along the matched track to a fix (its nearest vertex).
                var cum = [0.0]
                for (a, b) in zip(m.path, m.path.dropFirst()) { cum.append(cum[cum.count - 1] + Geo.distance(a.lat, a.lon, b.lat, b.lon)) }
                func along(_ p: FilteredPoint) -> Double {
                    cum[m.path.indices.min { Geo.distance(m.path[$0].lat, m.path[$0].lon, p.lat, p.lon) < Geo.distance(m.path[$1].lat, m.path[$1].lon, p.lat, p.lon) }!]
                }
                // Across each gap the train moves on along the track, at most 320 km/h (rough fixes get 1.5 km of slack).
                let passable = (i..<j).allSatisfy { k in
                    let a = pieces[k].points.last!, b = pieces[k + 1].points.first!
                    let d = along(b) - along(a)
                    return d >= -300 && d <= 89 * b.t.timeIntervalSince(a.t) + 1500
                }
                guard passable else { continue }
                found = true
                let base = stretch(r, from: m.from, to: m.to, start: plain[0].t, end: plain[plain.count - 1].t).fromM, end = base + cum[cum.count - 1]
                var from = base
                for k in i...j {
                    let to = k == j ? end : min(end, max(from, base + along(pieces[k + 1].points[0])))
                    out.append((k, MatchedStretch(seq: 0, wayId: -r.id, fromM: from, toM: to, confidence: 1,
                                                  start: pieces[k].points[0].t, end: pieces[k].points.last!.t), r.mode))
                    from = to
                }
            }
            i = found ? j + 1 : i + 1
        }
        return out
    }

    /// The matched ride as a stretch on the route's track (way id = -relation id), from stop `i` to stop `j`.
    public static func stretch(_ r: Route, from i: Int, to j: Int, start: Date, end: Date) -> MatchedStretch {
        func along(_ v: Int) -> Double {
            // `1...v` would trap for a ride from the line's first stop
            zip(r.path[..<v], r.path.dropFirst().prefix(v)).map { Geo.distance($0.lat, $0.lon, $1.lat, $1.lon) }.reduce(0, +)
        }
        return MatchedStretch(seq: 0, wayId: -r.id, fromM: along(vertex(r.path, near: r.stops[i])), toM: along(vertex(r.path, near: r.stops[j])),
                              confidence: 1, start: start, end: end)
    }
}
