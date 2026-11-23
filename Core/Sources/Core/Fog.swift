import Foundation

/// A band the fog clears: a line with a half-width in metres, or a circle when it has one coordinate.
public struct FogStroke: Sendable {
    public var coords: [(lat: Double, lon: Double)]
    public var halfWidth: Double
    public init(coords: [(lat: Double, lon: Double)], halfWidth: Double) { self.coords = coords; self.halfWidth = halfWidth }
}

/// A closed fog pocket to clear whole: rectangles in degrees.
public struct FogFill: Sendable {
    public var rects: [(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)]
    public init(rects: [(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)]) { self.rects = rects }
}

/// How much of the map each trip and place clears (stage 6 design spec, Fog mode).
public enum Fog {
    public static let onFoot = 15.0, road = 6.0, stop = 25.0, place = 25.0

    static func halfWidth(_ m: ModeStretch?) -> Double {
        guard let m, m.confidence >= TravelModes.confident else { return road }
        switch m.mode {
        case .walk, .run, .bike: return onFoot
        case .car, .bus, .tram, .vehicle: return road
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

    /// Fog pockets closed in by cleared bands on every side and narrower than one walk's band (2 × `onFoot`), such as the
    /// road between two cycle paths ridden on both sides, closed off where the trips cross it. Each pocket comes back as cell
    /// rectangles to clear. A pocket touching the edge of the box may not be closed, so it stays: callers pass a box well
    /// beyond the screen. Rasterised on a grid of 2.5 m or coarser over the box, at most about 2 million cells.
    public static func enclosedGaps(_ strokes: [FogStroke], minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) -> [FogFill] {
        let k = cos((minLat + maxLat) / 2 * .pi / 180), m = 111_320.0
        let width = (maxLon - minLon) * m * k, height = (maxLat - minLat) * m
        guard width > 0, height > 0 else { return [] }
        let cell = max(2.5, (width * height / 2e6).squareRoot())
        let nx = Int((width / cell).rounded(.up)), ny = Int((height / cell).rounded(.up)), n = nx * ny
        func grid(_ c: (lat: Double, lon: Double)) -> (x: Double, y: Double) { ((c.lon - minLon) * m * k / cell, (c.lat - minLat) * m / cell) }
        var clear = [Bool](repeating: false, count: n)
        for s in strokes where s.halfWidth > 0 {
            let r = s.halfWidth / cell, p = s.coords.map(grid)
            for (a, b) in p.count == 1 ? [(p[0], p[0])] : Array(zip(p, p.dropFirst())) {
                let x0 = max(0, Int((min(a.x, b.x) - r).rounded(.down))), x1 = min(nx - 1, Int((max(a.x, b.x) + r).rounded(.up)))
                let y0 = max(0, Int((min(a.y, b.y) - r).rounded(.down))), y1 = min(ny - 1, Int((max(a.y, b.y) + r).rounded(.up)))
                guard x0 <= x1, y0 <= y1 else { continue }
                let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
                for y in y0...y1 {
                    for x in x0...x1 {
                        let px = Double(x) + 0.5 - a.x, py = Double(y) + 0.5 - a.y
                        let t = len2 == 0 ? 0 : min(1, max(0, (px * dx + py * dy) / len2))
                        if (px - t * dx) * (px - t * dx) + (py - t * dy) * (py - t * dy) <= r * r { clear[y * nx + x] = true }
                    }
                }
            }
        }
        // Chamfer distance (cells) from every fog cell to the nearest cleared one: half a pocket's width at its widest.
        var d = [Float](repeating: .infinity, count: n)
        for i in 0..<n where clear[i] { d[i] = 0 }
        for (ys, xs, s) in [(Array(0..<ny), Array(0..<nx), -1), (Array((0..<ny).reversed()), Array((0..<nx).reversed()), 1)] {
            for y in ys {
                for x in xs where !clear[y * nx + x] {
                    var v = d[y * nx + x]
                    let yy = y + s
                    if x + s >= 0, x + s < nx { v = min(v, d[y * nx + x + s] + 1) }
                    if yy >= 0, yy < ny {
                        v = min(v, d[yy * nx + x] + 1)
                        if x - 1 >= 0 { v = min(v, d[yy * nx + x - 1] + 1.414) }
                        if x + 1 < nx { v = min(v, d[yy * nx + x + 1] + 1.414) }
                    }
                    d[y * nx + x] = v
                }
            }
        }
        // Pockets: 4-connected fog cells; kept when closed (never touching the box edge) and under one band wide.
        var seen = clear, out: [FogFill] = []
        let limit = Float(onFoot / cell)
        for start in 0..<n where !seen[start] {
            var stack = [start], cells: [Int] = [], open = false, widest: Float = 0
            seen[start] = true
            while let i = stack.popLast() {
                cells.append(i)
                let x = i % nx, y = i / nx
                if x == 0 || y == 0 || x == nx - 1 || y == ny - 1 { open = true }
                widest = max(widest, d[i])
                for (j, ok) in [(i - 1, x > 0), (i + 1, x < nx - 1), (i - nx, y > 0), (i + nx, y < ny - 1)] where ok && !seen[j] {
                    seen[j] = true; stack.append(j)
                }
            }
            guard !open, widest < limit else { continue }
            // Row runs as rectangles, grown half a cell so neighbouring rows overlap and no hairline of fog shows between them.
            var rects: [(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)] = []
            let sorted = cells.sorted()
            var a = 0
            for b in 1...sorted.count where b == sorted.count || sorted[b] != sorted[b - 1] + 1 || sorted[b] / nx != sorted[a] / nx {
                let y = Double(sorted[a] / nx), x0 = Double(sorted[a] % nx), x1 = Double(sorted[b - 1] % nx) + 1
                rects.append((minLat + (y - 0.5) * cell / m, minLon + (x0 - 0.5) * cell / (m * k),
                              minLat + (y + 1.5) * cell / m, minLon + (x1 + 0.5) * cell / (m * k)))
                a = b
            }
            out.append(FogFill(rects: rects))
        }
        return out
    }

    /// A circle at every learned place.
    public static func circles(places: [Place]) -> [FogStroke] {
        places.filter { !$0.isCandidate }.compactMap { $0.pin.map { FogStroke(coords: [$0], halfWidth: place) } }
    }
}
