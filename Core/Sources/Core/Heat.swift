import Foundation

public struct HeatCell: Sendable, Hashable { public var x: Int; public var y: Int }

public enum Heat {
    // shortcut: 40 Mercator m ≈ 25 m on the ground near 52°N; scale by cos(lat) if the owner travels far north or south
    public static let cellSize: Double = 40
    private static let R = 6_378_137.0

    public static func cell(lat: Double, lon: Double) -> HeatCell {
        let x = R * lon * .pi / 180
        let y = R * log(tan(.pi / 4 + lat * .pi / 360))
        return HeatCell(x: Int((x / cellSize).rounded(.down)), y: Int((y / cellSize).rounded(.down)))
    }

    public static func center(of c: HeatCell) -> (lat: Double, lon: Double) {
        let x = (Double(c.x) + 0.5) * cellSize, y = (Double(c.y) + 0.5) * cellSize
        return (lat: (2 * atan(exp(y / R)) - .pi / 2) * 180 / .pi, lon: x / R * 180 / .pi)
    }

    /// Each point counts for the time until the next one, capped by its own kind; the last point gets 0.
    public static func grid(_ points: [FilteredPoint]) -> [HeatCell: TimeInterval] {
        let p = points.filter { $0.kind != .rough }.sorted { $0.t < $1.t }   // where time was spent needs a precise place
        var g: [HeatCell: TimeInterval] = [:]
        for (a, b) in zip(p, p.dropFirst()) {
            g[cell(lat: a.lat, lon: a.lon), default: 0] += min(b.t.timeIntervalSince(a.t), a.kind == .still ? 300 : 60)
        }
        return g
    }

    /// `grid` of one time-ordered chunk, counting the pair across the edge from the previous chunk's last point.
    public static func grid(_ points: [FilteredPoint], previous: FilteredPoint?) -> [HeatCell: TimeInterval] {
        grid(previous.map { [$0] + points } ?? points)
    }
}
