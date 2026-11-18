import Foundation

public enum Simplify {
    /// The next detail step at or above `t`: 3, 6, 12, 24 m …, so zooming within a step keeps the same lines.
    public static func step(_ t: Double) -> Double {
        var s = 3.0
        while s < t { s *= 2 }
        return s
    }

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

    /// Visvalingam–Whyatt effective area per vertex, in m², computed once: a vertex is drawn when its area exceeds the
    /// screen's (pixel size)². Areas never decrease in removal order, so a coarser view keeps a subset of a finer one and a
    /// line never jumps between shapes while zooming. Ends are `.infinity` (always kept).
    public static func visvalingam(_ coords: [(lat: Double, lon: Double)]) -> [Double] {
        let n = coords.count
        var area = [Double](repeating: .infinity, count: n)
        guard n > 2 else { return area }
        let r = 6_371_008.8, rad = Double.pi / 180, k = cos(coords[0].lat * rad)
        let xy = coords.map { (x: ($0.lon - coords[0].lon) * rad * r * k, y: ($0.lat - coords[0].lat) * rad * r) }
        var prev = Array(-1..<(n - 1)), next = Array(1...n)
        func tri(_ i: Int) -> Double {
            let a = xy[prev[i]], b = xy[i], c = xy[next[i]]
            return abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
        }
        // Min-heap of (area, vertex, version); a stale entry (older version) is skipped when popped.
        var heap: [(a: Double, i: Int, v: Int)] = [], version = [Int](repeating: 0, count: n)
        func push(_ e: (a: Double, i: Int, v: Int)) {
            heap.append(e); var c = heap.count - 1
            while c > 0 { let p = (c - 1) / 2; if heap[p].a <= heap[c].a { break }; heap.swapAt(p, c); c = p }
        }
        func pop() -> (a: Double, i: Int, v: Int) {
            let top = heap[0], last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last; var p = 0
                while true {
                    let l = 2 * p + 1, rr = l + 1; var m = p
                    if l < heap.count && heap[l].a < heap[m].a { m = l }
                    if rr < heap.count && heap[rr].a < heap[m].a { m = rr }
                    if m == p { break }; heap.swapAt(p, m); p = m
                }
            }
            return top
        }
        for i in 1..<(n - 1) { push((tri(i), i, 0)) }
        var floor = 0.0
        while !heap.isEmpty {
            let e = pop()
            guard e.v == version[e.i] else { continue }
            floor = max(floor, e.a)   // monotone: never below a vertex removed earlier
            area[e.i] = floor
            let p = prev[e.i], q = next[e.i]
            next[p] = q; prev[q] = p
            for j in [p, q] where j > 0 && j < n - 1 { version[j] += 1; push((tri(j), j, version[j])) }
        }
        return area
    }
}
