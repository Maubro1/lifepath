import Foundation

/// One trip simplified for drawing when zoomed out; coords are (lat, lon, speed).
public struct TripLine: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var minLat, maxLat, minLon, maxLon, distance: Double
    public var coords: [(lat: Double, lon: Double, speed: Double)]

    public init(start: Date, end: Date, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
                distance: Double, coords: [(lat: Double, lon: Double, speed: Double)]) {
        self.start = start; self.end = end
        self.minLat = minLat; self.maxLat = maxLat; self.minLon = minLon; self.maxLon = maxLon
        self.distance = distance; self.coords = coords
    }

    public static func == (a: TripLine, b: TripLine) -> Bool {
        a.start == b.start && a.end == b.end && a.minLat == b.minLat && a.maxLat == b.maxLat
            && a.minLon == b.minLon && a.maxLon == b.maxLon && a.distance == b.distance
            && a.coords.count == b.coords.count
            && zip(a.coords, b.coords).allSatisfy { $0.lat == $1.lat && $0.lon == $1.lon && $0.speed == $1.speed }
    }
}

public enum TripLines {
    public static let tolerance: Double = 3  // m: detail kept in the cache; the map thins by Visvalingam area per zoom
    public static let version = 2   // a new version rebuilds the cache once

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
                        coords: kept.map { (p[$0].lat, p[$0].lon, p[$0].speed >= 0 ? p[$0].speed : median) })
    }

    /// The trip as the map draws it: smoothed points, and every confident matched stretch drawn along its street, rail or
    /// ferry line (solid even when the fixes were rough); vertices borrow the nearest fix's speed. Then simplified like `make`.
    public static func snapped(_ trip: Trip, smoothed: [Date: (lat: Double, lon: Double)], matches: [MatchedStretch],
                               ways: [Int64: Way]) -> TripLine {
        let p = trip.points
        var coords = p.map { q in q.kind == .rough ? (lat: q.lat, lon: q.lon) : smoothed[q.t] ?? (lat: q.lat, lon: q.lon) }
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
                        distance: trip.distance, coords: kept.map { (coords[$0].lat, coords[$0].lon, speeds[$0]) })
    }
}
