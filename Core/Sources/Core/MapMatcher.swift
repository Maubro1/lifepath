import Foundation

/// One run of consecutive points matched to one way: from `fromM` to `toM` metres along it, the points timed `start...end`.
public struct MatchedStretch: Sendable, Equatable, Codable {
    public var seq: Int
    public var wayId: Int64
    public var fromM, toM: Double
    public var confidence: Double   // 0...1; below MapMatcher.confident the map shows the recorded line
    public var start, end: Date   // times of its first and last point: stable however the trip's points are read
    public init(seq: Int, wayId: Int64, fromM: Double, toM: Double, confidence: Double, start: Date, end: Date) {
        self.seq = seq; self.wayId = wayId; self.fromM = fromM; self.toM = toM; self.confidence = confidence; self.start = start; self.end = end
    }
}

/// Hidden Markov Model map matching with Viterbi decoding (Newson & Krumm 2009), in log space.
public enum MapMatcher {
    public static let version = 1
    public static let confident = 0.6

    /// A used point: its candidates, their log emissions, and the best log score of a path ending in each (forward Viterbi).
    struct Step { var i: Int; var sigma: Double; var rough: Bool; var walking: Bool; var cands: [Candidate]; var emis: [Double]; var fwd: [Double] }

    public static func match(_ points: [FilteredPoint], graph: RoadGraph) -> [MatchedStretch] {
        let fast = fastRough(points)
        var out: [MatchedStretch] = [], chain: [Step] = [], trans: [[[Double]]] = []  // trans[k]: log transition chain[k-1] -> chain[k]
        func flush() { out += stretches(chain, trans, points, graph: graph, seq: out.count); chain = []; trans = [] }

        for (i, p) in points.enumerated() where p.kind != .still {
            let rough = p.kind == .rough
            // shortcut: slow rough fixes (trams, buses, walks with ~1 km error) stay unmatched, upgrade with 3b travel modes
            if rough && !fast[i] { continue }
            let sigma = rough ? min(p.hAcc, 300) : max(4, p.hAcc)
            if let prev = chain.last, distance(points[prev.i], p) < 2 * sigma { continue }
            let walking = !rough && isWalking(points, i)
            // shortcut: cycle paths are foot ways, so a bike on a separate path matches the road beside it, upgrade with 3b travel modes
            let kinds: Set<WayKind> = rough ? [.rail, .tram, .ferry] : walking ? [.foot, .road] : [.road, .rail, .tram, .ferry]
            // shortcut: the 8 nearest segments keep Viterbi at 64 routes a step; a dense square can crowd out the true way, raise if matches show it
            let cands = Array(graph.candidates(lat: p.lat, lon: p.lon, radius: rough ? min(p.hAcc, 1500) : max(30, 2 * p.hAcc))
                .filter { kinds.contains(graph.ways[graph.index[$0.wayId]!].kind) }.prefix(8))
            if cands.isEmpty { flush(); continue }
            let emis = cands.map { -0.5 * ($0.distance / sigma) * ($0.distance / sigma) }
            var step = Step(i: i, sigma: sigma, rough: rough, walking: walking, cands: cands, emis: emis, fwd: emis)
            if let prev = chain.last {
                let straight = distance(points[prev.i], p), beta = rough || prev.rough ? 50.0 : 3.0
                let t = prev.cands.map { a in cands.map { b in
                    graph.routeDistance(from: a, to: b, limit: 2 * straight + 200, oneway: !(walking && prev.walking))
                        .map { -abs($0 - straight) / beta } ?? -.infinity
                } }
                step.fwd = cands.indices.map { j in prev.fwd.indices.map { prev.fwd[$0] + t[$0][j] }.max()! + emis[j] }
                if step.fwd.allSatisfy({ $0 == -.infinity }) { flush(); step.fwd = emis } else { trans.append(t) }
            }
            if chain.isEmpty { trans = [[]] }
            chain.append(step)
        }
        flush()
        return out
    }

    /// Picks each step's candidate by max-marginal (forward + backward Viterbi) and groups runs on one way into stretches.
    static func stretches(_ chain: [Step], _ trans: [[[Double]]], _ points: [FilteredPoint], graph: RoadGraph, seq: Int) -> [MatchedStretch] {
        guard chain.count > 1 else { return [] }
        var bwd = chain.map { [Double](repeating: 0, count: $0.cands.count) }
        for k in stride(from: chain.count - 2, through: 0, by: -1) {
            bwd[k] = bwd[k].indices.map { i in chain[k + 1].cands.indices.map { j in trans[k + 1][i][j] + chain[k + 1].emis[j] + bwd[k + 1][j] }.max()! }
        }
        // Chosen candidate, whether it lies within 2σ, and the margin over the best candidate on another way.
        var picks: [(c: Candidate, near: Bool, margin: Double)] = []
        for (k, s) in chain.enumerated() {
            let m = s.cands.indices.map { s.fwd[$0] + bwd[k][$0] }, best = m.max()!
            // Ties (a junction node shared by two ways) keep the previous way, so a street is not split at every crossing.
            let j = m.indices.first { m[$0] >= best - 1e-6 && s.cands[$0].wayId == picks.last?.c.wayId } ?? m.firstIndex(of: best)!
            let c = s.cands[j], runner = m.indices.filter { s.cands[$0].wayId != c.wayId }.map { m[$0] }.max() ?? -.infinity
            picks.append((c, c.distance <= 2 * s.sigma, 1 - exp(runner - best)))
        }
        var runs: [(way: Int64, a: Int, b: Int)] = []  // picks a..<b on one way
        for (k, p) in picks.enumerated() {
            if runs.last?.way == p.c.wayId { runs[runs.count - 1].b = k + 1 } else { runs.append((p.c.wayId, k, k + 1)) }
        }
        // A one-point run is a nick into a crossing way at a junction: dropped, and the way on both sides rejoined.
        var kept: [(way: Int64, a: Int, b: Int)] = []
        for r in runs where r.b - r.a > 1 {
            if kept.last?.way == r.way { kept[kept.count - 1].b = r.b } else { kept.append(r) }
        }
        return kept.enumerated().map { n, r -> MatchedStretch in
            let run = picks[r.a..<r.b], len = Double(run.count)
            var conf = Double(run.filter(\.near).count) / len * run.map(\.margin).reduce(0, +) / len
            // shortcut: rough fixes see only rail/tram/ferry, so no road competes and a fast car beside a railway would draw solid;
            // below train-only speeds (25 m/s) such a stretch stays unsure, upgrade with 3b travel modes
            let steps = chain[r.a..<r.b]
            if steps.allSatisfy(\.rough) {
                let v = zip(steps, steps.dropFirst()).map { a, b -> Double in
                    let dt = points[b.i].t.timeIntervalSince(points[a.i].t)
                    return dt > 0 ? distance(points[a.i], points[b.i]) / dt : 0
                }.sorted()
                if v[v.count / 2] < 25 { conf = min(conf, confident / 2) }
            }
            return MatchedStretch(seq: seq + n, wayId: r.way, fromM: along(picks[r.a].c, graph), toM: along(picks[r.b - 1].c, graph),
                                  confidence: max(0, min(1, conf)), start: points[chain[r.a].i].t, end: points[chain[r.b - 1].i].t)
        }
    }

    static func along(_ c: Candidate, _ g: RoadGraph) -> Double {
        let l = g.lens[g.index[c.wayId]!]
        return l[..<c.segment].reduce(0, +) + c.t * l[c.segment]
    }

    static func distance(_ a: FilteredPoint, _ b: FilteredPoint) -> Double { Geo.distance(a.lat, a.lon, b.lat, b.lon) }

    /// Walking pace: median Doppler speed over ±30 s below 2.5 m/s (straight-line speed over the window when no Doppler).
    static func isWalking(_ p: [FilteredPoint], _ i: Int) -> Bool {
        var lo = i, hi = i
        while lo > 0, p[i].t.timeIntervalSince(p[lo - 1].t) <= 30 { lo -= 1 }
        while hi < p.count - 1, p[hi + 1].t.timeIntervalSince(p[i].t) <= 30 { hi += 1 }
        let s = p[lo...hi].filter { $0.kind == .moving && $0.speed >= 0 }.map(\.speed).sorted()
        if !s.isEmpty { return s[s.count / 2] < 2.5 }
        let dt = p[hi].t.timeIntervalSince(p[lo].t)
        return dt <= 0 || distance(p[lo], p[hi]) / dt < 2.5
    }

    /// Per point: a rough fix in a run of rough fixes whose straight-line speed, first to last, exceeds 15 m/s.
    static func fastRough(_ p: [FilteredPoint]) -> [Bool] {
        var out = [Bool](repeating: false, count: p.count), a = 0
        while a < p.count {
            guard p[a].kind == .rough else { a += 1; continue }
            var b = a
            while b + 1 < p.count, p[b + 1].kind == .rough { b += 1 }
            let dt = p[b].t.timeIntervalSince(p[a].t)
            if dt > 0, distance(p[a], p[b]) / dt > 15 { for k in a...b { out[k] = true } }
            a = b + 1
        }
        return out
    }
}
