import Foundation

public enum WayKind: String, Sendable { case foot, road, rail, tram, ferry }

public struct Way: Sendable, Equatable {
    public var id: Int64
    public var kind: WayKind
    public var name: String?
    public var oneway: Bool
    public var nodes: [Int64]
    public var coords: [(lat: Double, lon: Double)]
    public init(id: Int64, kind: WayKind, name: String?, oneway: Bool, nodes: [Int64], coords: [(lat: Double, lon: Double)]) {
        self.id = id; self.kind = kind; self.name = name; self.oneway = oneway; self.nodes = nodes; self.coords = coords
    }
    public static func == (a: Way, b: Way) -> Bool {
        a.id == b.id && a.kind == b.kind && a.name == b.name && a.oneway == b.oneway && a.nodes == b.nodes
            && a.coords.count == b.coords.count && zip(a.coords, b.coords).allSatisfy { $0.lat == $1.lat && $0.lon == $1.lon }
    }
}

/// A 0.03° x 0.018° tile (about 2 km), the unit of street downloads.
public struct Tile: Sendable, Hashable {
    public var x: Int, y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
    public init(lat: Double, lon: Double) { self.init(x: Int((lon / 0.03).rounded(.down)), y: Int((lat / 0.018).rounded(.down))) }
    public var bounds: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        (Double(y) * 0.018, Double(x) * 0.03, Double(y + 1) * 0.018, Double(x + 1) * 0.03)
    }
}

public enum OSM {
    private struct Doc: Decodable {
        struct El: Decodable {
            struct P: Decodable { var lat: Double; var lon: Double }
            var type: String; var id: Int64; var nodes: [Int64]?; var geometry: [P]?; var tags: [String: String]?
        }
        var elements: [El]
    }

    static func kind(_ t: [String: String]) -> WayKind? {
        if let h = t["highway"] {
            return ["footway", "path", "pedestrian", "steps", "cycleway", "track", "living_street"].contains(h) ? .foot : .road
        }
        switch t["railway"] {
        case "rail", "light_rail", "subway": return .rail
        case "tram": return .tram
        default: return t["route"] == "ferry" ? .ferry : nil
        }
    }

    /// Ways from Overpass JSON made with `out body geom`; elements that are not mapped travel ways are dropped.
    public static func parse(_ data: Data) throws -> [Way] {
        try JSONDecoder().decode(Doc.self, from: data).elements.compactMap { e in
            guard e.type == "way", let tags = e.tags, let kind = kind(tags), let nodes = e.nodes, let geo = e.geometry,
                  nodes.count >= 2, nodes.count == geo.count else { return nil }
            // shortcut: oneway=-1 (against the drawn direction) is read as two-way, upgrade if it shows in matches
            let oneway = kind == .road && (["yes", "1", "true"].contains(tags["oneway"] ?? "") || tags["junction"] == "roundabout")
            return Way(id: e.id, kind: kind, name: tags["name"], oneway: oneway, nodes: nodes, coords: geo.map { ($0.lat, $0.lon) })
        }
    }

    public static func query(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) -> String {
        let b = "(\(minLat),\(minLon),\(maxLat),\(maxLon))"
        return "[out:json][timeout:60];(way[\"highway\"]\(b);way[\"railway\"~\"^(rail|light_rail|subway|tram)$\"]\(b);way[\"route\"=\"ferry\"]\(b););out body geom;"
    }
}

public struct Candidate: Sendable {
    public var wayId: Int64
    public var segment: Int
    public var t: Double
    public var lat: Double, lon: Double
    public var distance: Double
}

public struct RoadGraph: Sendable {
    static let cell = 25.0
    let ways: [Way]
    let index: [Int64: Int]
    let lens: [[Double]]
    var grid: [PlaceCell: [Int32]] = [:]  // cell -> (way index << 16 | segment), see seg(_:)
    var edges: [Int64: [(to: Int64, len: Double)]] = [:]

    // shortcut: a way has < 65536 segments, and metres per degree of longitude are those at 52°N (PlaceGrid); upgrade for far-away travel
    public init(ways: [Way]) {
        self.ways = ways
        index = Dictionary(ways.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { $1 })
        lens = ways.map { w in (0..<w.nodes.count - 1).map { Geo.distance(w.coords[$0].lat, w.coords[$0].lon, w.coords[$0 + 1].lat, w.coords[$0 + 1].lon) } }
        for (wi, w) in ways.enumerated() {
            for i in 0..<w.nodes.count - 1 {
                edges[w.nodes[i], default: []].append((w.nodes[i + 1], lens[wi][i]))
                if !w.oneway { edges[w.nodes[i + 1], default: []].append((w.nodes[i], lens[wi][i])) }
                let a = Self.metres(w.coords[i]), b = Self.metres(w.coords[i + 1])
                for cx in Self.span(a.x, b.x) { for cy in Self.span(a.y, b.y) {
                    grid[PlaceCell(x: cx, y: cy), default: []].append(Int32(wi << 16 | i))
                } }
            }
        }
    }

    static func metres(_ c: (lat: Double, lon: Double)) -> (x: Double, y: Double) { (c.lon * PlaceGrid.mPerLon, c.lat * PlaceGrid.mPerLat) }
    static func span(_ a: Double, _ b: Double) -> ClosedRange<Int> { Int((min(a, b) / cell).rounded(.down))...Int((max(a, b) / cell).rounded(.down)) }

    /// Segments within `radius` metres of the point, nearest first, one candidate (the closest position) per segment.
    public func candidates(lat: Double, lon: Double, radius: Double) -> [Candidate] {
        let p = Self.metres((lat, lon))
        var seen = Set<Int32>(), out: [Candidate] = []
        for cx in Self.span(p.x - radius, p.x + radius) { for cy in Self.span(p.y - radius, p.y + radius) {
            for s in grid[PlaceCell(x: cx, y: cy)] ?? [] where seen.insert(s).inserted {
                let w = ways[Int(s >> 16)], i = Int(s & 0xFFFF)
                let a = Self.metres(w.coords[i]), b = Self.metres(w.coords[i + 1])
                let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
                let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
                let d = ((a.x + t * dx - p.x) * (a.x + t * dx - p.x) + (a.y + t * dy - p.y) * (a.y + t * dy - p.y)).squareRoot()
                guard d <= radius else { continue }
                out.append(Candidate(wayId: w.id, segment: i, t: t,
                                     lat: w.coords[i].lat + t * (w.coords[i + 1].lat - w.coords[i].lat),
                                     lon: w.coords[i].lon + t * (w.coords[i + 1].lon - w.coords[i].lon), distance: d))
            }
        } }
        return out.sorted { $0.distance < $1.distance }
    }

    /// Shortest distance along the network in metres (partial segments included), nil beyond `limit` or when unreachable.
    public func routeDistance(from a: Candidate, to b: Candidate, limit: Double) -> Double? {
        guard let ai = index[a.wayId], let bi = index[b.wayId] else { return nil }
        let aw = ways[ai], bw = ways[bi], al = lens[ai][a.segment], bl = lens[bi][b.segment]
        if ai == bi && a.segment == b.segment {
            let d = (b.t - a.t) * al
            if d >= 0 || !aw.oneway { return abs(d) <= limit ? abs(d) : nil }
        }
        var dist: [Int64: Double] = [:], heap = MinHeap()
        func push(_ n: Int64, _ d: Double) {
            if d <= limit, d < dist[n, default: .infinity] { dist[n] = d; heap.push(d, n) }
        }
        push(aw.nodes[a.segment + 1], (1 - a.t) * al)
        if !aw.oneway { push(aw.nodes[a.segment], a.t * al) }
        var tail: [Int64: Double] = [bw.nodes[b.segment]: b.t * bl]
        if !bw.oneway { tail[bw.nodes[b.segment + 1]] = min(tail[bw.nodes[b.segment + 1]] ?? .infinity, (1 - b.t) * bl) }
        var best = Double.infinity
        while let (d, n) = heap.pop(), d < best {
            if d > dist[n]! { continue }
            if let t = tail[n] { best = min(best, d + t) }
            for e in edges[n] ?? [] { push(e.to, d + e.len) }
        }
        return best <= limit ? best : nil
    }
}

/// Binary min-heap of (distance, node); stale entries are skipped by the caller.
struct MinHeap {
    var a: [(Double, Int64)] = []
    mutating func push(_ d: Double, _ n: Int64) {
        a.append((d, n)); var i = a.count - 1
        while i > 0, a[(i - 1) / 2].0 > a[i].0 { a.swapAt(i, (i - 1) / 2); i = (i - 1) / 2 }
    }
    mutating func pop() -> (Double, Int64)? {
        guard let top = a.first else { return nil }
        a.swapAt(0, a.count - 1); a.removeLast()
        var i = 0
        while true {
            var m = i
            for c in [2 * i + 1, 2 * i + 2] where c < a.count && a[c].0 < a[m].0 { m = c }
            if m == i { return top }
            a.swapAt(i, m); i = m
        }
    }
}
