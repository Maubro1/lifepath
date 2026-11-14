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
    public static let tolerance: Double = 15  // m

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
}
