import Foundation

/// A band the fog clears: a line with a half-width in metres, or a circle when it has one coordinate.
public struct FogStroke: Sendable {
    public var coords: [(lat: Double, lon: Double)]
    public var halfWidth: Double
    public init(coords: [(lat: Double, lon: Double)], halfWidth: Double) { self.coords = coords; self.halfWidth = halfWidth }
}

/// How much of the map each trip and place clears (stage 6 design spec, Fog mode).
public enum Fog {
    public static let onFoot = 15.0, road = 6.0, stop = 25.0, place = 25.0

    static func halfWidth(_ m: ModeStretch?) -> Double {
        guard let m, m.confidence >= TravelModes.confident else { return road }
        switch m.mode {
        case .walk, .run, .bike: return onFoot
        case .car, .bus, .tram: return road
        case .train, .boat: return 0
        }
    }

    /// Bands along a trip line by travel mode; a train or boat run clears only circles where it starts and ends.
    public static func strokes(line: TripLine, modes: [ModeStretch]) -> [FogStroke] {
        let c = line.coords.map { (lat: $0.lat, lon: $0.lon) }
        guard c.count >= 2 else { return c.map { FogStroke(coords: [$0], halfWidth: road) } }
        // shortcut: a coordinate's time is placed by distance at constant speed (trip lines keep no times), upgrade to stored times if mode edges look off
        var cum = [0.0]
        for (a, b) in zip(c, c.dropFirst()) { cum.append(cum.last! + Geo.distance(a.lat, a.lon, b.lat, b.lon)) }
        let span = line.end.timeIntervalSince(line.start), total = max(cum.last!, 1e-9)
        func time(_ m: Double) -> Date { line.start + span * m / total }
        let widths = (0..<c.count - 1).map { i -> Double in
            let t = time((cum[i] + cum[i + 1]) / 2)
            return halfWidth(modes.first { $0.start <= t && t <= $0.end })
        }
        var out: [FogStroke] = [], a = 0
        for b in 1...widths.count where b == widths.count || widths[b] != widths[a] {
            let run = Array(c[a...b])
            out += widths[a] > 0 ? [FogStroke(coords: run, halfWidth: widths[a])]
                : [FogStroke(coords: [run.first!], halfWidth: stop), FogStroke(coords: [run.last!], halfWidth: stop)]
            a = b
        }
        return out
    }

    /// A circle at every learned place.
    public static func circles(places: [Place]) -> [FogStroke] {
        places.filter { !$0.isCandidate }.compactMap { $0.pin.map { FogStroke(coords: [$0], halfWidth: place) } }
    }
}
