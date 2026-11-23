import Foundation

/// One trip simplified for drawing when zoomed out; coords are (lat, lon, speed).
public struct TripLine: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var minLat, maxLat, minLon, maxLon, distance: Double
    public var coords: [(lat: Double, lon: Double, speed: Double)]
    public var topSpeed: Double   // m/s, `TripLines.topSpeed`; -1 unknown (a line cached before it existed)

    public init(start: Date, end: Date, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
                distance: Double, coords: [(lat: Double, lon: Double, speed: Double)], topSpeed: Double = -1) {
        self.start = start; self.end = end
        self.minLat = minLat; self.maxLat = maxLat; self.minLon = minLon; self.maxLon = maxLon
        self.distance = distance; self.coords = coords; self.topSpeed = topSpeed
    }

    public static func == (a: TripLine, b: TripLine) -> Bool {
        a.start == b.start && a.end == b.end && a.minLat == b.minLat && a.maxLat == b.maxLat
            && a.minLon == b.minLon && a.maxLon == b.maxLon && a.distance == b.distance && a.topSpeed == b.topSpeed
            && a.coords.count == b.coords.count
            && zip(a.coords, b.coords).allSatisfy { $0.lat == $1.lat && $0.lon == $1.lon && $0.speed == $1.speed }
    }
}

public enum TripLines {
    public static let tolerance: Double = 3  // m: detail kept in the cache; the map thins by Visvalingam area per zoom
    public static let version = 5   // a new version rebuilds the cache once; 3: top speed per trip; 4: pottering is no trip; 5: rough fixes smoothed

    /// The trip's top speed (m/s): the highest mean speed it held for 15 s, so a one-second GPS spike cannot decide it while a
    /// bus or car reaching 50 km/h between lights still counts (Huss et al. 2014: a high speed percentile splits walk/bike from
    /// motorised best); -1 when no speed is known. Each point counts for the time to the next one (at most 30 s), so
    /// distance-spaced walking points and per-second vehicle points weigh alike. Doppler speeds are despiked by the median of
    /// each point and its precise neighbours; a run of rough points (trains) counts at its end-to-end speed, and so does each
    /// 30 s of a run of precise points without Doppler (iOS gives none indoors and LifePath keeps none above 20 m accuracy).
    public static func topSpeed(_ p: [FilteredPoint]) -> Double {
        func weight(_ k: Int) -> Double { k + 1 < p.count ? min(max(p[k + 1].t.timeIntervalSince(p[k].t), 0), 30) : 0 }
        var v: [(speed: Double, w: Double)] = []
        var i = 0
        while i < p.count {
            if p[i].kind == .rough {
                var j = i
                while j + 1 < p.count, p[j + 1].kind == .rough { j += 1 }
                let dt = p[j].t.timeIntervalSince(p[i].t)
                if dt > 0 { v.append((Geo.distance(p[i].lat, p[i].lon, p[j].lat, p[j].lon) / dt, dt)) }
                i = j + 1
                continue
            }
            if p[i].speed < 0 {
                var j = i
                while j + 1 < p.count, p[j + 1].kind != .rough, p[j + 1].speed < 0, p[j].t.timeIntervalSince(p[i].t) < 30 { j += 1 }
                let dt = p[j].t.timeIntervalSince(p[i].t)
                if j > i, dt > 0 { v.append((Geo.distance(p[i].lat, p[i].lon, p[j].lat, p[j].lon) / dt, dt)) }
                i = max(j, i + 1)
                continue
            }
            if p[i].speed >= 0 {
                let s = p[max(i - 1, 0)...min(i + 1, p.count - 1)].filter { $0.kind != .rough && $0.speed >= 0 }.map(\.speed).sorted()
                v.append((s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2, weight(i)))
            }
            i += 1
        }
        let total = v.reduce(0) { $0 + $1.w }
        guard total > 0 else { return -1 }
        let span = min(15, total)   // a trip shorter than 15 s: its mean
        var best = 0.0
        for a in v.indices where v[a].w > 0 {   // windows start at a point and run on in time order
            var left = span, sum = 0.0
            for x in v[a...] where left > 0 { let w = min(x.w, left); sum += x.speed * w; left -= w }
            if left <= 1e-9 { best = max(best, sum / span) }
        }
        return best
    }

    /// Kept points' speeds; unknown (< 0) take the trip's median valid speed, or stay -1 when none is valid.
    public static func make(_ trip: Trip) -> TripLine {
        let p = trip.points
        let valid = p.map(\.speed).filter { $0 >= 0 }.sorted()
        let median = valid.isEmpty ? -1 : valid[valid.count / 2]
        let kept = Simplify.douglasPeucker(p.map { ($0.lat, $0.lon) }, tolerance: tolerance)
        let lats = p.map(\.lat), lons = p.map(\.lon)
        return TripLine(start: trip.start, end: trip.end,
                        minLat: lats.min()!, maxLat: lats.max()!, minLon: lons.min()!, maxLon: lons.max()!,
                        distance: trip.distance,
                        coords: kept.map { (p[$0].lat, p[$0].lon, p[$0].speed >= 0 ? p[$0].speed : median) }, topSpeed: topSpeed(p))
    }

    /// The trip as the map draws it: smoothed points (rough ones too), and every confident matched stretch drawn along its street, rail or
    /// ferry line (solid even when the fixes were rough); vertices borrow the nearest fix's speed. Then simplified like `make`.
    public static func snapped(_ trip: Trip, smoothed: [Date: (lat: Double, lon: Double)], matches: [MatchedStretch],
                               ways: [Int64: Way]) -> TripLine {
        let p = trip.points
        // Rough fixes too: the smoother weighs a lone one (iOS's "2 km" fix in a tram) almost to nothing, so drawing it raw
        // put a 700 m spike on the line (21 Nov 2026); a long rough run keeps its shape through its own consistency.
        var coords = p.map { q in smoothed[q.t] ?? (lat: q.lat, lon: q.lon) }
        var speeds = MapColors.filledSpeeds(p.map(\.speed))
        let at = Dictionary(p.enumerated().map { ($1.t, $0) }, uniquingKeysWith: { a, _ in a })
        var nc: [(lat: Double, lon: Double)] = [], ns: [Double] = [], next = 0
        for m in matches.filter({ $0.confidence >= MapMatcher.confident }).sorted(by: { $0.start < $1.start }) {
            guard let first = at[m.start], let last = at[m.end], first >= next, first <= last, let way = ways[m.wayId] else { continue }
            nc += coords[next..<first]; ns += speeds[next..<first]
            var j = first   // vertices run in travel order, so the nearest fix only moves forward
            for v in way.slice(fromM: m.fromM, toM: m.toM) {
                while j < last, Geo.distance(v.lat, v.lon, coords[j + 1].lat, coords[j + 1].lon) < Geo.distance(v.lat, v.lon, coords[j].lat, coords[j].lon) { j += 1 }
                nc.append(v); ns.append(speeds[j])
            }
            next = last + 1
        }
        if next > 0 { nc += coords[next...]; ns += speeds[next...]; coords = nc; speeds = ns }
        guard next > 0 || !smoothed.isEmpty else { return make(trip) }
        let kept = Simplify.douglasPeucker(coords, tolerance: tolerance)
        let lats = coords.map(\.lat), lons = coords.map(\.lon)
        return TripLine(start: trip.start, end: trip.end, minLat: lats.min()!, maxLat: lats.max()!, minLon: lons.min()!, maxLon: lons.max()!,
                        distance: trip.distance, coords: kept.map { (coords[$0].lat, coords[$0].lon, speeds[$0]) }, topSpeed: topSpeed(p))
    }
}
