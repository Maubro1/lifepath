import Foundation

/// A city (admin level 8) or a neighbourhood (levels 9 to 11, or 12 for place boundaries and place areas) from OSM.
public struct Area: Sendable, Equatable {
    public var id: Int64          // relation id; a closed way is stored as -way id
    public var level: Int
    public var name: String
    public let rings: [[(lat: Double, lon: Double)]]   // outer rings, closed
    public let holes: [[(lat: Double, lon: Double)]]   // inner rings, closed

    public init(id: Int64, level: Int, name: String, rings: [[(lat: Double, lon: Double)]], holes: [[(lat: Double, lon: Double)]]) {
        self.id = id; self.level = level; self.name = name; self.rings = rings; self.holes = holes
        let all = rings.joined()
        bounds = (all.map(\.lat).min() ?? 0, all.map(\.lat).max() ?? 0, all.map(\.lon).min() ?? 0, all.map(\.lon).max() ?? 0)
    }

    public static func == (a: Area, b: Area) -> Bool {
        func same(_ x: [[(lat: Double, lon: Double)]], _ y: [[(lat: Double, lon: Double)]]) -> Bool {
            x.count == y.count && zip(x, y).allSatisfy { $0.count == $1.count && zip($0, $1).allSatisfy { $0.lat == $1.lat && $0.lon == $1.lon } }
        }
        return a.id == b.id && a.level == b.level && a.name == b.name && same(a.rings, b.rings) && same(a.holes, b.holes)
    }

    public let bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)   // of the outer rings

    /// Even-odd test over all rings: inside an outer ring and not inside a hole.
    public func contains(lat: Double, lon: Double) -> Bool {
        guard lat >= bounds.minLat, lat <= bounds.maxLat, lon >= bounds.minLon, lon <= bounds.maxLon else { return false }
        func inside(_ r: [(lat: Double, lon: Double)]) -> Bool {
            var c = false, j = r.count - 1
            for i in r.indices {
                if (r[i].lat > lat) != (r[j].lat > lat),
                   lon < (r[j].lon - r[i].lon) * (lat - r[i].lat) / (r[j].lat - r[i].lat) + r[i].lon { c.toggle() }
                j = i
            }
            return c
        }
        return (rings + holes).filter(inside).count % 2 == 1
    }

    /// Size for picking the smallest containing area: shoelace in degrees² (outer minus holes).
    var size: Double {
        func shoelace(_ r: [(lat: Double, lon: Double)]) -> Double {
            abs(zip(r, r.dropFirst()).map { $0.lon * $1.lat - $1.lon * $0.lat }.reduce(0, +)) / 2
        }
        return rings.map(shoelace).reduce(0, +) - holes.map(shoelace).reduce(0, +)
    }
}

public enum Areas {
    /// Joins member ways end to end into closed rings, reversing as needed; chains that never close are dropped.
    public static func assemble(_ members: [(role: String, coords: [(lat: Double, lon: Double)])])
        -> (outer: [[(lat: Double, lon: Double)]], inner: [[(lat: Double, lon: Double)]]) {
        func rings(_ parts: [[(lat: Double, lon: Double)]]) -> [[(lat: Double, lon: Double)]] {
            func same(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Bool { a.lat == b.lat && a.lon == b.lon }
            var left = parts.filter { $0.count >= 2 }, out: [[(lat: Double, lon: Double)]] = []
            while !left.isEmpty {
                var ring = left.removeFirst()
                while !same(ring.first!, ring.last!) {
                    guard let k = left.firstIndex(where: { same($0.first!, ring.last!) || same($0.last!, ring.last!) }) else { break }
                    let next = left.remove(at: k)
                    ring += (same(next.first!, ring.last!) ? next : next.reversed()).dropFirst()
                }
                if ring.count >= 4 && same(ring.first!, ring.last!) { out.append(ring) }
            }
            return out
        }
        return (rings(members.filter { $0.role != "inner" }.map(\.coords)), rings(members.filter { $0.role == "inner" }.map(\.coords)))
    }

    /// The smallest city (level 8) holding the point, and the smallest finer area holding it inside that city; the city itself when there is none.
    public static func locate(lat: Double, lon: Double, in areas: [Area]) -> (city: Area?, neighbourhood: Area?) {
        let holding = areas.filter { $0.contains(lat: lat, lon: lon) }.sorted { $0.size < $1.size }
        guard let city = holding.first(where: { $0.level == 8 }) else { return (nil, nil) }
        // shortcut: a neighbourhood counts as inside its city when its bounding box is, upgrade to a polygon test if borders overlap oddly
        let b = city.bounds
        let n = holding.first { a in
            let x = a.bounds
            return a.level > 8 && x.minLat >= b.minLat && x.maxLat <= b.maxLat && x.minLon >= b.minLon && x.maxLon <= b.maxLon
        }
        return (city, n ?? city)
    }
}
