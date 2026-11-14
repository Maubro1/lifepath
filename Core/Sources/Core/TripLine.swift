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
