import Foundation

/// One ~20 m segment of a way passed on foot (or by bike, when `bike`).
public struct SegmentHit: Hashable, Sendable {
    public var wayId: Int64
    public var seg: Int
    public var bike: Bool
    public init(wayId: Int64, seg: Int, bike: Bool) { self.wayId = wayId; self.seg = seg; self.bike = bike }
}

public struct CoverageResult: Sendable, Equatable {
    public var ways: [Int64: Bool]   // covered way → true when covered only with cycling
    public var onFoot: Int
    public var withBike: Int
    public var total: Int
    public init(ways: [Int64: Bool], onFoot: Int, withBike: Int, total: Int) { self.ways = ways; self.onFoot = onFoot; self.withBike = withBike; self.total = total }
}

/// Streets walked, by the CityStrides rule: ways cut into ~20 m segments, a street covered at ≥ 90% of its length (every segment when 10 or fewer).
public enum Coverage {
    public static let version = 1
    public static let segmentLength = 20.0
    public static let reach = 15.0

    public static func segments(_ length: Double) -> Int { max(1, Int((length / segmentLength).rounded())) }

    /// Segments of countable ways within `reach` of confident matched stretches, inside confident walk, run or bike stretches.
    public static func hits(_ matches: [MatchedStretch], modes: [ModeStretch], graph: RoadGraph) -> Set<SegmentHit> {
        var out = Set<SegmentHit>(), lengths: [Int: Double] = [:]
        for m in modes where m.confidence >= TravelModes.confident && [.walk, .run, .bike].contains(m.mode) {
            for s in matches where s.confidence >= MapMatcher.confident && s.start <= m.end && m.start <= s.end {
                guard let wi = graph.index[s.wayId] else { continue }
                // shortcut: hit length is linear in time inside a matched stretch, upgrade if speed changes within a stretch show in coverage
                let span = s.end.timeIntervalSince(s.start)
                func at(_ t: Date) -> Double { span > 0 ? s.fromM + (s.toM - s.fromM) * t.timeIntervalSince(s.start) / span : s.fromM }
                let path = graph.ways[wi].slice(fromM: at(max(s.start, m.start)), toM: at(min(s.end, m.end)))
                // shortcut: a road passed under a bridge within 15 m is hit too, upgrade with layer tags if the owner sees it
                for (a, b) in zip(path, path.dropFirst()) {
                    let n = max(1, Int((Geo.distance(a.lat, a.lon, b.lat, b.lon) / 5).rounded(.up)))
                    for k in 0...n {
                        let f = Double(k) / Double(n)
                        for c in graph.candidates(lat: a.lat + f * (b.lat - a.lat), lon: a.lon + f * (b.lon - a.lon), radius: reach) {
                            let ci = graph.index[c.wayId]!
                            guard graph.ways[ci].countable else { continue }
                            let len = lengths[ci] ?? graph.lens[ci].reduce(0, +), segs = segments(len)
                            lengths[ci] = len
                            guard len > 0 else { continue }   // a way on one point has no segments to hit
                            out.insert(SegmentHit(wayId: c.wayId, seg: min(segs - 1, Int(MapMatcher.along(c, graph) / (len / Double(segs)))), bike: m.mode == .bike))
                        }
                    }
                }
            }
        }
        return out
    }

    /// Streets: an unnamed countable way, or named countable ways of one name joined at shared nodes. Counted on foot and with bike hits.
    public static func streets(ways all: [Way], hits: [SegmentHit]) -> CoverageResult {
        let ways = all.filter(\.countable)
        var parent = Array(ways.indices), first: [String: [Int64: Int]] = [:]
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for (i, w) in ways.enumerated() {
            guard let name = w.name else { continue }
            for n in w.nodes {
                if let j = first[name]?[n] { parent[root(i)] = root(j) } else { first[name, default: [:]][n] = i }
            }
        }
        var footSegs: [Int64: Set<Int>] = [:], anySegs: [Int64: Set<Int>] = [:]
        for h in hits {
            anySegs[h.wayId, default: []].insert(h.seg)
            if !h.bike { footSegs[h.wayId, default: []].insert(h.seg) }
        }
        // Per street: length, segments, hit length and hit segments, on foot and with bike.
        var streets: [Int: (l: Double, s: Int, hf: Double, nf: Int, ha: Double, na: Int, ids: [Int64])] = [:]
        for (i, w) in ways.enumerated() {
            let l = zip(w.coords, w.coords.dropFirst()).map { (a: (lat: Double, lon: Double), b: (lat: Double, lon: Double)) -> Double in
                Geo.distance(a.lat, a.lon, b.lat, b.lon) }.reduce(0, +)
            let s = segments(l), nf = footSegs[w.id]?.filter { $0 < s }.count ?? 0, na = anySegs[w.id]?.filter { $0 < s }.count ?? 0
            var t = streets[root(i)] ?? (0, 0, 0, 0, 0, 0, [])
            t.l += l; t.s += s; t.hf += Double(nf) * l / Double(s); t.nf += nf; t.ha += Double(na) * l / Double(s); t.na += na; t.ids.append(w.id)
            streets[root(i)] = t
        }
        var r = CoverageResult(ways: [:], onFoot: 0, withBike: 0, total: streets.count)
        for t in streets.values {
            func covered(_ h: Double, _ n: Int) -> Bool { t.s <= 10 ? n == t.s : h >= 0.9 * t.l - 1e-6 }
            let onFoot = covered(t.hf, t.nf)
            guard covered(t.ha, t.na) else { continue }
            r.withBike += 1
            if onFoot { r.onFoot += 1 }
            for id in t.ids { r.ways[id] = !onFoot }
        }
        return r
    }
}
