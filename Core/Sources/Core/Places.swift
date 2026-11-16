import Foundation

/// A place learned from still time: a decaying time-density grid; the pin is derived from it.
public struct Place: Sendable, Equatable, Codable, Identifiable {
    public var id: Int64
    public var name: String?
    public var cells: [PlaceCell: Double]     // decayed weight (seconds·confidence), 60-day half-life
    public var recent: [PlaceCell: Double]    // same weight with a 30-day half-life, only to break pin ties
    public var visitDays: Set<Int>            // local day numbers of visit starts
    public var updatedAt: Date
    public var lastVisit: Date                // end of the latest visit joined
    public var totalSeconds: Double
    public var visits: Int
    public var isCandidate: Bool
    public var recentDurations: [Double] = []   // last 20 visit lengths in seconds, oldest first
    public var realDays: Set<Int> = []          // local day numbers with a real visit; life-long, never trimmed

    public init(id: Int64, name: String?, cells: [PlaceCell: Double], recent: [PlaceCell: Double] = [:], visitDays: Set<Int> = [],
                updatedAt: Date, lastVisit: Date, totalSeconds: Double, visits: Int, isCandidate: Bool, realDays: Set<Int> = []) {
        self.id = id; self.name = name; self.cells = cells; self.recent = recent; self.visitDays = visitDays
        self.updatedAt = updatedAt; self.lastVisit = lastVisit; self.totalSeconds = totalSeconds; self.visits = visits; self.isCandidate = isCandidate; self.realDays = realDays
    }

    /// 4 per day with a visit plus 1 per hour spent; 100 makes the place a pin.
    public var points: Double { 4 * Double(visitDays.count) + totalSeconds / 3600 }

    /// Days a pin outlives its last real visit: at least 6 months, or 3 × the usual gap between stays (runs of consecutive real days)
    /// when longer, plus a month per year the place has been in the life (≤ 6), at most 2 years: a gym fades fast, a holiday home does not.
    public var hideAfterDays: Int {
        let days = realDays.sorted()
        let gaps = zip(days, days.dropFirst()).map { $1 - $0 }.filter { $0 > 1 }.suffix(8).sorted()   // shortcut: re-sorts on each call; cache if the map asks per frame
        let years = days.last.map { ($0 - (visitDays.min() ?? $0)) / 365 } ?? 0
        return min(730, max(180, 3 * (gaps.isEmpty ? 0 : gaps[(gaps.count - 1) / 2])) + 30 * min(6, years))
    }

    /// A pin, shown while its last real visit up to `now` is within `hideAfterDays`; no real visit by then means hidden.
    // shortcut: for a past date, hideAfterDays and isCandidate use the whole history; replay them per date if old periods look wrong.
    public func isVisible(at now: Date) -> Bool {
        let today = Places.day(now)
        guard let last = realDays.filter({ $0 <= today }).max() else { return false }
        return !isCandidate && today - last <= hideAfterDays
    }

    /// Density peak: the cell with the most 3×3-smoothed weight; peaks within 10% of it go to the one with more recent weight.
    public var pin: (lat: Double, lon: Double)? {   // nil only for a place with no cells
        func smoothed(_ m: [PlaceCell: Double], _ c: PlaceCell) -> Double {
            var s = 0.0
            for dx in -1...1 { for dy in -1...1 { s += m[PlaceCell(x: c.x + dx, y: c.y + dy)] ?? 0 } }
            return s
        }
        let scored = cells.keys.map { ($0, smoothed(cells, $0)) }
        let top = scored.map(\.1).max() ?? 0
        let best = scored.filter { $0.1 >= 0.9 * top }
            .max { (smoothed(recent, $0.0), $0.1, $0.0.y, $0.0.x) < (smoothed(recent, $1.0), $1.1, $1.0.y, $1.0.x) }
        return best.map { PlaceGrid.center(of: $0.0) }
    }

    /// Smallest cell set holding `share` of the weight, with one-cell holes filled.
    public func region(share: Double = 0.9) -> Set<PlaceCell> {
        let sorted = cells.sorted { ($0.value, $0.key.y, $0.key.x) > ($1.value, $1.key.y, $1.key.x) }
        let goal = share * cells.values.reduce(0, +)
        var set = Set<PlaceCell>(), sum = 0.0
        for (c, w) in sorted where sum < goal || set.isEmpty { set.insert(c); sum += w }
        let holes = PlaceGrid.dilate(set, by: 1).subtracting(set).filter { c in
            [(1, 0), (-1, 0), (0, 1), (0, -1)].allSatisfy { set.contains(PlaceCell(x: c.x + $0.0, y: c.y + $0.1)) }
        }
        return set.union(holes)
    }

    /// The fix's cell, widened by its accuracy (at most 50 m), touches the region.
    public func contains(lat: Double, lon: Double, hAcc: Double) -> Bool {
        let r = min(Int((max(hAcc, 0) / PlaceGrid.cellSize).rounded(.up)), 10)
        return !PlaceGrid.dilate([PlaceGrid.cell(lat: lat, lon: lon)], by: r).isDisjoint(with: region())
    }
}

public struct Visit: Sendable, Equatable, Codable {
    public var start: Date
    public var end: Date
    public var placeId: Int64?
    public init(start: Date, end: Date, placeId: Int64?) { self.start = start; self.end = end; self.placeId = placeId }
}

public enum Places {
    /// Runs of still points (split where two are > 30 min apart) lasting ≥ minDuration, plus the moving fixes just before them within the first still fix's accuracy.
    /// A run still open at the end of `points` is returned too; the caller decides whether the rest has finished.
    public static func visits(from points: [FilteredPoint], minDuration: TimeInterval = 600) -> [(start: Date, end: Date, points: [FilteredPoint])] {
        var out: [(start: Date, end: Date, points: [FilteredPoint])] = []
        var i = 0
        while i < points.count {
            guard points[i].kind == .still else { i += 1; continue }
            var j = i
            while j + 1 < points.count, points[j + 1].kind == .still, points[j + 1].t.timeIntervalSince(points[j].t) <= 1800 { j += 1 }
            if points[j].t.timeIntervalSince(points[i].t) >= minDuration {
                let first = points[i]
                var s = i
                while s > 0, points[s - 1].kind == .moving,
                      Geo.distance(points[s - 1].lat, points[s - 1].lon, first.lat, first.lon) <= first.hAcc { s -= 1 }
                out.append((points[s].t, points[j].t, Array(points[s...j])))
            }
            i = j + 1
        }
        return out
    }

    /// Which visits read from one window of points are finished and safe to learn, and where the next read starts.
    /// Open: the run reaches the window's last point and nothing ends it yet (a later chunk, or less than 30 min before `now` in the last one).
    /// Overlapping a stored visit means it was learned already (the re-read overlap).
    /// `stalled`: the open run begins at the window's first point, so the caller must widen the window or the cursor never advances.
    // shortcut: backfilled time that extends a stored visit is skipped, not learned; extend the visit when place time looks short.
    public static func settle(visits: [(start: Date, end: Date, points: [FilteredPoint])], first: Date, lastT: Date, now: Date, isLast: Bool, stored: [Visit])
        -> (finished: [(start: Date, end: Date, points: [FilteredPoint])], next: Date, stalled: Bool) {
        var finished: [(start: Date, end: Date, points: [FilteredPoint])] = []
        for v in visits {
            if v.points.last?.t == lastT, isLast ? now.timeIntervalSince(v.end) <= 1800 : true {
                return (finished, v.start, !isLast && v.points.first?.t == first)
            }
            if !stored.contains(where: { v.start <= $0.end && v.end >= $0.start }) { finished.append(v) }
        }
        return (finished, lastT, false)
    }

    static let halfLife: TimeInterval = 60 * 86_400, recentHalfLife: TimeInterval = 30 * 86_400

    static func day(_ t: Date) -> Int {
        Int(((t.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: t))) / 86_400).rounded(.down))
    }

    /// Folds one finished visit into the places. Not idempotent: the caller must not feed the same visit twice.
    public static func learn(_ places: [Place], visit: (start: Date, end: Date, points: [FilteredPoint]), now: Date, nextId: Int64) -> (places: [Place], visit: Visit) {
        var places = places.map { p -> Place in
            let dt = now.timeIntervalSince(p.updatedAt)
            guard dt > 0 else { return p }
            var p = p
            let f = pow(0.5, dt / halfLife), fr = pow(0.5, dt / recentHalfLife)
            p.cells = p.cells.mapValues { $0 * f }; p.recent = p.recent.mapValues { $0 * fr }; p.updatedAt = now
            return p
        }
        let pts = visit.points.sorted { $0.t < $1.t }
        guard !pts.isEmpty else { return (places, Visit(start: visit.start, end: visit.end, placeId: nil)) }

        // Join the place whose region widened by 20 m holds most of the visit's points; else start a candidate.
        let cells = pts.map { PlaceGrid.cell(lat: $0.lat, lon: $0.lon) }
        let visitBox = PlaceGrid.bounds(cells)
        let hits = places.map { p -> Int in
            guard PlaceGrid.bounds(p.cells.keys).near(visitBox) else { return 0 }   // skip the region work for far places
            let zone = PlaceGrid.dilate(p.region(), by: 4); return cells.filter(zone.contains).count
        }
        var k: Int
        if let best = hits.indices.max(by: { hits[$0] < hits[$1] }), 2 * hits[best] > pts.count {
            k = best
        } else {
            places.append(Place(id: nextId, name: nil, cells: [:], updatedAt: now, lastVisit: visit.end, totalSeconds: 0, visits: 0, isCandidate: true))
            k = places.count - 1
        }
        let added = PlaceGrid.splat(pts)
        places[k].cells.merge(added, uniquingKeysWith: +)
        places[k].recent.merge(added, uniquingKeysWith: +)
        places[k].visits += 1
        let length = visit.end.timeIntervalSince(visit.start)
        let sorted = places[k].recentDurations.sorted()
        // real: ≥ 5 h, or at least half this place's usual stay (the first visit needs the 5 h)
        if length >= 5 * 3600 || (!sorted.isEmpty && length >= 0.5 * sorted[(sorted.count - 1) / 2]) { places[k].realDays.formUnion(day(visit.start)...day(visit.end)) }
        places[k].recentDurations = Array((places[k].recentDurations + [length]).suffix(20))
        places[k].totalSeconds += length
        places[k].visitDays.insert(day(visit.start))
        places[k].lastVisit = max(places[k].lastVisit, visit.end)
        places[k].updatedAt = max(places[k].updatedAt, now)

        // Merge every place whose region touches this one into whichever has more time.
        var region = places[k].region(), box = PlaceGrid.bounds(places[k].cells.keys)
        while let o = places.indices.first(where: {
            $0 != k && PlaceGrid.bounds(places[$0].cells.keys).near(box) && !PlaceGrid.dilate(places[$0].region(), by: 1).isDisjoint(with: region)
        }) {
            let (keep, gone) = places[o].totalSeconds > places[k].totalSeconds ? (o, k) : (k, o)
            let g = places[gone]
            places[keep].cells.merge(g.cells, uniquingKeysWith: +)
            places[keep].recent.merge(g.recent, uniquingKeysWith: +)
            places[keep].visitDays.formUnion(g.visitDays)
            places[keep].visits += g.visits
            places[keep].lastVisit = max(places[keep].lastVisit, g.lastVisit)
            places[keep].totalSeconds += g.totalSeconds
            places[keep].name = places[keep].name ?? g.name
            places[keep].recentDurations = Array((places[keep].recentDurations + g.recentDurations).suffix(20))   // shortcut: survivor's then the other's, not by visit time; fine for a median
            places[keep].realDays.formUnion(g.realDays)
            places.remove(at: gone)
            k = keep > gone ? keep - 1 : keep
            region = places[k].region(); box = PlaceGrid.bounds(places[k].cells.keys)
        }

        places[k].isCandidate = places[k].points < 100   // never from one long stay: 10 h is only 14 points
        return (places, Visit(start: visit.start, end: visit.end, placeId: places[k].id))
    }
}
