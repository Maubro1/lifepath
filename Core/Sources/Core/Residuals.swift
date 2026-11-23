import Foundation

/// Real-world accuracy without ground truth: how far the raw fixes of confident walking stretches lie across the street they
/// were matched to, and how long that offset takes to fade. The fitted fade time replaces the assumed 45 s in the test
/// generator (`Drift.phone`) once the owner's phone has measured it.
public enum Residuals {
    /// Per confident stretch at walking pace (median Doppler below 2.5 m/s, at least 10 fixes): each raw fix's time and signed
    /// metres across the matched way (left of the travel direction positive).
    public static func offsets(_ points: [FilteredPoint], matches: [MatchedStretch], ways: [Int64: Way]) -> [[(t: Date, d: Double)]] {
        matches.filter { $0.confidence >= MapMatcher.confident }.compactMap { m in
            guard let way = ways[m.wayId] else { return nil }
            let line = way.slice(fromM: m.fromM, toM: m.toM)
            let ps = points.filter { $0.kind == .moving && $0.t >= m.start && $0.t <= m.end }
            let v = ps.map(\.speed).filter { $0 >= 0 }.sorted()
            guard ps.count >= 10, line.count >= 2, !v.isEmpty, v[v.count / 2] < 2.5 else { return nil }
            return ps.map { (t: $0.t, d: signed($0.rawLat, $0.rawLon, line)) }
        }
    }

    /// One line for the health report: median and 90th-percentile distance from the street (which includes the sidewalk's own
    /// distance from the mapped centreline), and the lag at which the offsets' correlation falls below 1/e, each stretch's mean
    /// removed. shortcut: removing the mean shortens the fade time on short stretches; fine as a first measurement.
    public static func summary(_ runs: [[(t: Date, d: Double)]]) -> String {
        let all = runs.flatMap { $0.map { abs($0.d) } }.sorted()
        guard all.count >= 20 else { return "not enough matched walking yet" }
        var products = [Double](repeating: 0, count: 18), pairs = [Int](repeating: 0, count: 18), sq = 0.0, n = 0
        for r in runs {
            let mean = r.map(\.d).reduce(0, +) / Double(r.count), x = r.map { (t: $0.t, d: $0.d - mean) }
            for a in x { sq += a.d * a.d; n += 1 }
            for i in x.indices {
                for j in (i + 1)..<x.count {
                    let lag = x[j].t.timeIntervalSince(x[i].t)
                    guard lag < 180 else { break }
                    products[Int(lag / 10)] += x[i].d * x[j].d; pairs[Int(lag / 10)] += 1
                }
            }
        }
        let variance = sq / Double(n)
        let fade = variance > 0 ? (0..<18).first { pairs[$0] >= 10 && products[$0] / Double(pairs[$0]) / variance < exp(-1) } : 0
        return String(format: "median %.1f m from the street, 90%% within %.1f m, ", all[all.count / 2], all[all.count * 9 / 10])
            + "offsets fade after " + (fade.map { "\($0 * 10)-\($0 * 10 + 10) s" } ?? "3 min or more")
            + ", \(all.count) fixes on \(runs.count) stretches"
    }

    /// Signed metres from a point to a polyline (local flat projection around the point), positive left of its direction.
    static func signed(_ lat: Double, _ lon: Double, _ line: [(lat: Double, lon: Double)]) -> Double {
        let k = cos(lat * .pi / 180), m = 111_320.0
        func xy(_ c: (lat: Double, lon: Double)) -> (x: Double, y: Double) { ((c.lon - lon) * m * k, (c.lat - lat) * m) }
        var best = Double.infinity, sign = 1.0
        for (a, b) in zip(line, line.dropFirst()) {
            let u = xy(a), v = xy(b), dx = v.x - u.x, dy = v.y - u.y, len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : min(1, max(0, -(u.x * dx + u.y * dy) / len2))
            let px = u.x + t * dx, py = u.y + t * dy, d = (px * px + py * py).squareRoot()
            // The point sits at the origin: it is left of the segment when the cross product of direction and (point - start) is positive.
            if d < best { best = d; sign = dx * (-u.y) - dy * (-u.x) >= 0 ? 1 : -1 }
        }
        return best * sign
    }
}
