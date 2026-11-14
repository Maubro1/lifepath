import Foundation

/// A 5 m cell in a local metre grid: y = lat in metres / 5, x = lon in metres (at 52°N) / 5.
public struct PlaceCell: Sendable, Hashable, Codable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public enum PlaceGrid {
    public static let cellSize = 5.0
    // shortcut: metres per degree of longitude fixed at the owner's latitude (52°N), so cells stretch elsewhere; scale by the place's own cos(lat) if the owner settles far from 52°
    static let mPerLon = 111_320 * cos(52 * Double.pi / 180), mPerLat = 110_574.0

    public static func cell(lat: Double, lon: Double) -> PlaceCell {
        PlaceCell(x: Int((lon * mPerLon / cellSize).rounded(.down)), y: Int((lat * mPerLat / cellSize).rounded(.down)))
    }

    public static func center(of c: PlaceCell) -> (lat: Double, lon: Double) {
        ((Double(c.y) + 0.5) * cellSize / mPerLat, (Double(c.x) + 0.5) * cellSize / mPerLon)
    }

    /// Every cell within `r` cells (Chebyshev) of the set.
    static func dilate(_ cells: Set<PlaceCell>, by r: Int) -> Set<PlaceCell> {
        var out = Set<PlaceCell>()
        for c in cells { for dx in -r...r { for dy in -r...r { out.insert(PlaceCell(x: c.x + dx, y: c.y + dy)) } } }
        return out
    }

    /// Each point's duration (time to the next, capped 300 s) weighted 1/max(hAcc,5)², spread by a Gaussian of σ = max(hAcc, 5) ≤ 50 m truncated at 2σ.
    static func splat(_ points: [FilteredPoint]) -> [PlaceCell: Double] {
        var out: [PlaceCell: Double] = [:]
        for (i, p) in points.enumerated() where i + 1 < points.count {
            let acc = max(p.hAcc, 5), sigma = min(acc, 50)
            let w = min(points[i + 1].t.timeIntervalSince(p.t), 300) / (acc * acc)
            guard w > 0 else { continue }
            let mx = p.lon * mPerLon, my = p.lat * mPerLat, home = cell(lat: p.lat, lon: p.lon)
            let r = Int((2 * sigma / cellSize).rounded(.up))
            var kernel: [(PlaceCell, Double)] = [], sum = 0.0
            for dx in -r...r { for dy in -r...r {
                let c = PlaceCell(x: home.x + dx, y: home.y + dy)
                let ex = (Double(c.x) + 0.5) * cellSize - mx, ey = (Double(c.y) + 0.5) * cellSize - my
                let d2 = ex * ex + ey * ey
                guard d2 <= 4 * sigma * sigma else { continue }
                let k = exp(-d2 / (2 * sigma * sigma)); kernel.append((c, k)); sum += k
            } }
            for (c, k) in kernel { out[c, default: 0] += w * k / sum }   // normalised: a point adds exactly w
        }
        return out
    }
}
