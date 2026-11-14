import Foundation

public enum Simplify {
    /// Indices kept; first and last always kept. Works in local metres (equirectangular around the first point).
    // shortcut: flat projection, fine for trip-sized tracks (tens of km); upgrade if tracks span continents.
    public static func douglasPeucker(_ coords: [(lat: Double, lon: Double)], tolerance: Double) -> [Int] {
        guard coords.count > 2 else { return Array(coords.indices) }
        let r = 6_371_008.8, rad = Double.pi / 180, k = cos(coords[0].lat * rad)
        let xy = coords.map { (x: ($0.lon - coords[0].lon) * rad * r * k, y: ($0.lat - coords[0].lat) * rad * r) }
        var keep = Set([0, coords.count - 1])
        var stack = [(0, coords.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b - a > 1 else { continue }
            let dx = xy[b].x - xy[a].x, dy = xy[b].y - xy[a].y, len2 = dx * dx + dy * dy
            var far = -1, farD = tolerance
            for i in (a + 1)..<b {
                let px = xy[i].x - xy[a].x, py = xy[i].y - xy[a].y
                let t = len2 == 0 ? 0 : min(1, max(0, (px * dx + py * dy) / len2))
                let d = ((px - t * dx) * (px - t * dx) + (py - t * dy) * (py - t * dy)).squareRoot()
                if d > farD { farD = d; far = i }
            }
            if far >= 0 { keep.insert(far); stack.append((a, far)); stack.append((far, b)) }
        }
        return keep.sorted()
    }

    /// Indices kept per line at `tolerance`, doubled until the total fits `budget`: a coarser picture, never fewer lines (each keeps its endpoints).
    public static func fit(_ lines: [[(lat: Double, lon: Double)]], tolerance: Double, budget: Int) -> [[Int]] {
        var tol = tolerance
        while true {
            let kept = lines.map { douglasPeucker($0, tolerance: tol) }
            if kept.reduce(0, { $0 + $1.count }) <= budget || kept.allSatisfy({ $0.count <= 2 }) { return kept }
            tol = max(1, tol * 2)
        }
    }
}
