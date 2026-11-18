import Foundation

public enum WayKind: String, Sendable { case foot, road, rail, tram, ferry, cycle }

public enum StopKind: String, Sendable { case bus, tram, rail, ferry }

public struct Stop: Sendable, Equatable {
    public var id: Int64
    public var kind: StopKind
    public var lat: Double, lon: Double
    public init(id: Int64, kind: StopKind, lat: Double, lon: Double) { self.id = id; self.kind = kind; self.lat = lat; self.lon = lon }
}

public struct Way: Sendable, Equatable {
    public var id: Int64
    public var kind: WayKind
    public var name: String?
    public var oneway: Bool
    public var nodes: [Int64]
    public var coords: [(lat: Double, lon: Double)]
    public var countable: Bool   // a street for Streets walked
    public init(id: Int64, kind: WayKind, name: String?, oneway: Bool, nodes: [Int64], coords: [(lat: Double, lon: Double)], countable: Bool = true) {
        self.id = id; self.kind = kind; self.name = name; self.oneway = oneway; self.nodes = nodes; self.coords = coords; self.countable = countable
    }
    public static func == (a: Way, b: Way) -> Bool {
        a.id == b.id && a.kind == b.kind && a.name == b.name && a.oneway == b.oneway && a.nodes == b.nodes && a.countable == b.countable
            && a.coords.count == b.coords.count && zip(a.coords, b.coords).allSatisfy { $0.lat == $1.lat && $0.lon == $1.lon }
    }
}

extension Way {
    /// The way's geometry from `fromM` to `toM` metres along it (partial end segments included), in that direction: reversed when `toM < fromM`.
    public func slice(fromM: Double, toM: Double) -> [(lat: Double, lon: Double)] {
        let lo = min(fromM, toM), hi = max(fromM, toM)
        var out: [(lat: Double, lon: Double)] = [], at = 0.0
        for i in 0..<max(0, coords.count - 1) {
            let a = coords[i], b = coords[i + 1], len = Geo.distance(a.lat, a.lon, b.lat, b.lon), end = at + len, start = at
            func point(_ m: Double) -> (lat: Double, lon: Double) {
                let t = len == 0 ? 0 : (m - start) / len
                return (a.lat + t * (b.lat - a.lat), a.lon + t * (b.lon - a.lon))
            }
            if end >= lo && start <= hi {
                if out.isEmpty { out.append(point(max(lo, start))) }
                out.append(point(min(hi, end)))
            }
            at = end
        }
        return toM < fromM ? out.reversed() : out
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
            struct M: Decodable { var type: String; var ref: Int64?; var role: String?; var geometry: [P]?; var lat: Double?; var lon: Double? }
            var type: String; var id: Int64; var lat: Double?; var lon: Double?; var nodes: [Int64]?; var geometry: [P]?; var tags: [String: String]?
            var members: [M]?
        }
        var elements: [El]
    }

    static func kind(_ t: [String: String]) -> WayKind? {
        if let h = t["highway"] {
            if h == "cycleway" || (["path", "footway", "track"].contains(h) && t["bicycle"] == "designated") { return .cycle }
            return ["footway", "path", "pedestrian", "steps", "track", "living_street"].contains(h) ? .foot : .road
        }
        switch t["railway"] {
        case "rail", "light_rail", "subway": return .rail
        case "tram": return .tram
        default: return t["route"] == "ferry" ? .ferry : nil
        }
    }

    /// A street for Streets walked: foot, cycle and road ways, without motorways, driveways, sidewalks, crossings and private ways.
    static func countable(_ t: [String: String], _ kind: WayKind) -> Bool {
        guard [.foot, .cycle, .road].contains(kind) else { return false }
        if ["motorway", "motorway_link", "trunk_link", "service", "construction", "proposed", "platform", "raceway", "bus_guideway",
            "busway", "corridor", "elevator", "escape"].contains(t["highway"] ?? "") || t["motorroad"] == "yes" { return false }
        if ["sidewalk", "crossing"].contains(t["footway"] ?? "") || t["cycleway"] == "crossing" || t["path"] == "crossing" { return false }
        if ["private", "no"].contains(t["access"] ?? "") || t["foot"] == "no" { return ["yes", "designated", "permissive"].contains(t["foot"] ?? "") }
        return true
    }

    /// What a stored tile contains: 1 = ways only, 2 = plus stops and cycle ways, 3 = plus street flags.
    public static let version = 3

    static func stopKind(_ t: [String: String]) -> StopKind? {
        if t["highway"] == "bus_stop" { return .bus }
        if t["railway"] == "tram_stop" { return .tram }
        if t["railway"] == "station" || t["railway"] == "halt" { return .rail }
        return t["amenity"] == "ferry_terminal" ? .ferry : nil
    }

    /// Ways and stops from Overpass JSON made with `out body geom`; elements that are not mapped travel ways or stops are dropped.
    public static func parse(_ data: Data) throws -> (ways: [Way], stops: [Stop]) {
        let els = try JSONDecoder().decode(Doc.self, from: data).elements
        let stops: [Stop] = els.compactMap { e in
            guard e.type == "node", let tags = e.tags, let k = stopKind(tags), let lat = e.lat, let lon = e.lon else { return nil }
            return Stop(id: e.id, kind: k, lat: lat, lon: lon)
        }
        let ways: [Way] = els.compactMap { e in
            guard e.type == "way", let tags = e.tags, let kind = kind(tags), let nodes = e.nodes, let geo = e.geometry,
                  nodes.count >= 2, nodes.count == geo.count else { return nil }
            // shortcut: oneway=-1 (against the drawn direction) is read as two-way, upgrade if it shows in matches
            let oneway = kind == .road && (["yes", "1", "true"].contains(tags["oneway"] ?? "") || tags["junction"] == "roundabout")
            return Way(id: e.id, kind: kind, name: tags["name"], oneway: oneway, nodes: nodes, coords: geo.map { ($0.lat, $0.lon) },
                       countable: countable(tags, kind))
        }
        return (ways, stops)
    }

    /// Borders touching a tile: cities and finer admin areas as tags only (their shapes come once each from `areaGeometryQuery`), place areas drawn as ways with their shape.
    public static func areaIndexQuery(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) -> String {
        let b = "(\(minLat),\(minLon),\(maxLat),\(maxLon))"
        return "[out:json][timeout:60];(rel[\"boundary\"=\"administrative\"][\"admin_level\"~\"^(8|9|10|11)$\"]\(b);rel[\"boundary\"=\"place\"][\"place\"~\"^(suburb|quarter|neighbourhood)$\"]\(b););out tags;way[\"place\"~\"^(suburb|quarter|neighbourhood)$\"]\(b);out tags geom;"
    }

    public static func areaGeometryQuery(ids: [Int64]) -> String {
        "[out:json][timeout:90];rel(id:\(ids.map(String.init).joined(separator: ",")));out tags geom;"
    }

    /// Areas with a shape, and the relation ids whose shape still has to be fetched.
    public static func parseAreas(_ data: Data) throws -> (areas: [Area], missing: [Int64]) {
        var areas: [Area] = [], missing: [Int64] = []
        for e in try JSONDecoder().decode(Doc.self, from: data).elements {
            guard let t = e.tags, let name = t["name"] else { continue }
            let level = t["boundary"] == "administrative" ? Int(t["admin_level"] ?? "") ?? 0 : 12
            if e.type == "relation" {
                guard (8...12).contains(level) else { continue }
                guard let members = e.members else { missing.append(e.id); continue }
                let r = Areas.assemble(members.compactMap { m in
                    m.type == "way" ? m.geometry.map { (m.role ?? "outer", $0.map { ($0.lat, $0.lon) }) } : nil
                })
                if !r.outer.isEmpty { areas.append(Area(id: e.id, level: level, name: name, rings: r.outer, holes: r.inner)) }
            } else if e.type == "way", t["place"] != nil, let g = e.geometry, g.count >= 4,
                      g.first!.lat == g.last!.lat, g.first!.lon == g.last!.lon {
                areas.append(Area(id: -e.id, level: 12, name: name, rings: [g.map { ($0.lat, $0.lon) }], holes: []))
            }
        }
        return (areas, missing)
    }

    /// Public-transport routes touching a tile: relation members only (stop and way ids), no shapes.
    public static func routeIndexQuery(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) -> String {
        let b = "(\(minLat),\(minLon),\(maxLat),\(maxLon))"
        return "[out:json][timeout:60];rel[\"type\"=\"route\"][\"route\"~\"^(train|subway|light_rail|monorail|tram|bus|trolleybus|ferry)$\"]\(b);out body;"
    }

    public static func routeGeometryQuery(ids: [Int64]) -> String {
        "[out:json][timeout:120];rel(id:\(ids.map(String.init).joined(separator: ",")));out geom;"
    }

    /// Routes with their stops in order and their track joined end to end (oriented from the first stop), and the ids of
    /// relations whose shape still has to be fetched.
    public static func parseRoutes(_ data: Data) throws -> (routes: [Route], missing: [Int64]) {
        var routes: [Route] = [], missing: [Int64] = []
        for e in try JSONDecoder().decode(Doc.self, from: data).elements where e.type == "relation" {
            guard let mode = (e.tags?["route"]).flatMap(Route.mode), let members = e.members else { continue }
            let ways = members.filter { $0.type == "way" }.compactMap(\.geometry)
            guard !ways.isEmpty || members.contains(where: { $0.lat != nil }) else { missing.append(e.id); continue }
            func stops(_ roles: (String) -> Bool) -> [Route.Stop] {
                members.compactMap { m in
                    guard m.type == "node", let r = m.role, roles(r), let lat = m.lat, let lon = m.lon, let id = m.ref else { return nil }
                    return Route.Stop(id: id, lat: lat, lon: lon)
                }
            }
            var list = stops { $0.hasPrefix("stop") }
            if list.isEmpty { list = stops { $0.hasPrefix("platform") } }
            // Ways in member order, each turned to continue from the end so far.
            var path: [(lat: Double, lon: Double)] = []
            func same(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Bool { a.lat == b.lat && a.lon == b.lon }
            for w in ways {
                let c = w.map { (lat: $0.lat, lon: $0.lon) }
                guard let end = path.last else { path = c; continue }
                if path.count == c.count, same(path[0], c[0]) || same(path[0], c[c.count - 1]), !same(end, c[0]), !same(end, c[c.count - 1]) {
                    path.reverse()   // the first way pointed away from the second
                }
                let tail = path[path.count - 1]
                path += same(tail, c[0]) ? Array(c.dropFirst()) : same(tail, c[c.count - 1]) ? Array(c.reversed().dropFirst()) : c
            }
            if let s = list.first, let a = path.first, let z = path.last,
               Geo.distance(s.lat, s.lon, z.lat, z.lon) < Geo.distance(s.lat, s.lon, a.lat, a.lon) { path.reverse() }
            if list.count >= 2 && path.count >= 2 { routes.append(Route(id: e.id, mode: mode, stops: list, path: path)) }
        }
        return (routes, missing)
    }

    public static func query(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) -> String {
        let b = "(\(minLat),\(minLon),\(maxLat),\(maxLon))"
        return "[out:json][timeout:60];(way[\"highway\"]\(b);way[\"railway\"~\"^(rail|light_rail|subway|tram)$\"]\(b);way[\"route\"=\"ferry\"]\(b);node[\"highway\"=\"bus_stop\"]\(b);node[\"railway\"~\"^(tram_stop|station|halt)$\"]\(b);node[\"amenity\"=\"ferry_terminal\"]\(b););out body geom;"
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
    var grid: [PlaceCell: [Int]] = [:]  // cell -> (way index << 16 | segment), see seg(_:)
    var edges: [Int64: [(to: Int64, len: Double, against: Bool)]] = [:]  // against: backwards on a one-way road

    // shortcut: a way has < 65536 segments, and metres per degree of longitude are those at 52°N (PlaceGrid); upgrade for far-away travel
    public init(ways: [Way]) {
        self.ways = ways
        index = Dictionary(ways.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { $1 })
        lens = ways.map { w in (0..<w.nodes.count - 1).map { Geo.distance(w.coords[$0].lat, w.coords[$0].lon, w.coords[$0 + 1].lat, w.coords[$0 + 1].lon) } }
        for (wi, w) in ways.enumerated() {
            for i in 0..<w.nodes.count - 1 {
                edges[w.nodes[i], default: []].append((w.nodes[i + 1], lens[wi][i], false))
                edges[w.nodes[i + 1], default: []].append((w.nodes[i], lens[wi][i], w.oneway))
                let a = Self.metres(w.coords[i]), b = Self.metres(w.coords[i + 1])
                for cx in Self.span(a.x, b.x) { for cy in Self.span(a.y, b.y) {
                    grid[PlaceCell(x: cx, y: cy), default: []].append(wi << 16 | i)
                } }
            }
        }
    }

    static func metres(_ c: (lat: Double, lon: Double)) -> (x: Double, y: Double) { (c.lon * PlaceGrid.mPerLon, c.lat * PlaceGrid.mPerLat) }
    static func span(_ a: Double, _ b: Double) -> ClosedRange<Int> { Int((min(a, b) / cell).rounded(.down))...Int((max(a, b) / cell).rounded(.down)) }

    /// Segments within `radius` metres of the point, nearest first, one candidate (the closest position) per segment.
    public func candidates(lat: Double, lon: Double, radius: Double) -> [Candidate] {
        let p = Self.metres((lat, lon))
        var seen = Set<Int>(), out: [Candidate] = []
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
    /// `oneway: false` lets walkers go against one-way roads.
    public func routeDistance(from a: Candidate, to b: Candidate, limit: Double, oneway: Bool = true) -> Double? {
        guard let ai = index[a.wayId], let bi = index[b.wayId] else { return nil }
        let aw = ways[ai], bw = ways[bi], al = lens[ai][a.segment], bl = lens[bi][b.segment]
        let aOne = oneway && aw.oneway, bOne = oneway && bw.oneway
        if ai == bi && a.segment == b.segment {
            let d = (b.t - a.t) * al
            if d >= 0 || !aOne { return abs(d) <= limit ? abs(d) : nil }
        }
        var dist: [Int64: Double] = [:], heap = MinHeap()
        func push(_ n: Int64, _ d: Double) {
            if d <= limit, d < dist[n, default: .infinity] { dist[n] = d; heap.push(d, n) }
        }
        push(aw.nodes[a.segment + 1], (1 - a.t) * al)
        if !aOne { push(aw.nodes[a.segment], a.t * al) }
        var tail: [Int64: Double] = [bw.nodes[b.segment]: b.t * bl]
        if !bOne { tail[bw.nodes[b.segment + 1]] = min(tail[bw.nodes[b.segment + 1]] ?? .infinity, (1 - b.t) * bl) }
        var best = Double.infinity
        while let (d, n) = heap.pop(), d < best {
            if d > dist[n]! { continue }
            if let t = tail[n] { best = min(best, d + t) }
            for e in edges[n] ?? [] where !(oneway && e.against) { push(e.to, d + e.len) }
        }
        return best <= limit ? best : nil
    }

    /// `routeDistance` from `a` to each target with one search: same rules, same results.
    public func routeDistances(from a: Candidate, to targets: [Candidate], limit: Double, oneway: Bool = true) -> [Double?] {
        var out = [Double?](repeating: nil, count: targets.count)
        guard let ai = index[a.wayId] else { return out }
        let aw = ways[ai], al = lens[ai][a.segment], aOne = oneway && aw.oneway
        var tail: [Int64: [(k: Int, len: Double)]] = [:], open: [Int] = []
        for (k, b) in targets.enumerated() {
            guard let bi = index[b.wayId] else { continue }
            let bw = ways[bi], bl = lens[bi][b.segment]
            if ai == bi && a.segment == b.segment {
                let d = (b.t - a.t) * al
                if d >= 0 || !aOne { out[k] = abs(d) <= limit ? abs(d) : nil; continue }
            }
            tail[bw.nodes[b.segment], default: []].append((k, b.t * bl))
            if !(oneway && bw.oneway) { tail[bw.nodes[b.segment + 1], default: []].append((k, (1 - b.t) * bl)) }
            open.append(k)
        }
        guard !open.isEmpty else { return out }
        var dist: [Int64: Double] = [:], heap = MinHeap(), best = [Double](repeating: .infinity, count: targets.count)
        func push(_ n: Int64, _ d: Double) {
            if d <= limit, d < dist[n, default: .infinity] { dist[n] = d; heap.push(d, n) }
        }
        push(aw.nodes[a.segment + 1], (1 - a.t) * al)
        if !aOne { push(aw.nodes[a.segment], a.t * al) }
        while let (d, n) = heap.pop(), open.contains(where: { d < best[$0] }) {
            if d > dist[n]! { continue }
            for t in tail[n] ?? [] { best[t.k] = min(best[t.k], d + t.len) }
            for e in edges[n] ?? [] where !(oneway && e.against) { push(e.to, d + e.len) }
        }
        for k in open where best[k] <= limit { out[k] = best[k] }
        return out
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
