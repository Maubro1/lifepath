import Foundation

/// `vehicle`: a motorised ride whose kind is not clear; never guessed (set only by `TravelModes.settle`).
public enum TravelMode: String, Sendable, Codable, CaseIterable { case walk, run, bike, car, bus, tram, train, boat, vehicle }

/// One run of a trip's points in one travel mode: timestamps `start...end` of its first and last point (not indices: the map reads a trip's points only in part).
public struct ModeStretch: Sendable, Equatable, Codable {
    public var seq: Int
    public var mode: TravelMode
    public var confidence: Double   // 0...1; below TravelModes.confident the stretch is shown and matched as unsure
    public var start: Date, end: Date
    public init(seq: Int, mode: TravelMode, confidence: Double, start: Date, end: Date) {
        self.seq = seq; self.mode = mode; self.confidence = confidence; self.start = start; self.end = end
    }
}

/// Travel mode per stretch: a small Hidden Markov Model over 30 s windows of a trip, decoded with Viterbi in log space.
/// Features: CoreMotion activity, speed, halts at mapped stops, nearness to each network, share of rough fixes.
public enum TravelModes {
    public static let version = 3
    public static let confident = 0.6

    /// What one 30 s window shows.
    struct Window {
        var first: Int, last: Int          // point indices
        var v: Double?                     // m/s
        var stopDist: [StopKind: Double]?  // halted: metres from the halt to the nearest stop of each kind
        var act: Activity?                 // nil: none, stationary or unknown
        var kinds: [Set<WayKind>]          // per point: kinds of way near it
        var open: Double                   // share of precise points with no way within 50 m
        var rough: Double                  // share of rough points
    }

    public static func classify(_ points: [FilteredPoint], graph: RoadGraph, stops: [Stop],
                                activities: [(t: Date, activity: Activity)]) -> [ModeStretch] {
        let used = points.indices.filter { points[$0].kind != .still }
        guard let start = used.first.map({ points[$0].t }) else { return [] }
        // Windows of 30 s from the trip start; empty ones are skipped, so a tunnel joins the windows on either side.
        var groups: [[Int]] = [], bin = -1
        for i in used {
            let b = Int(points[i].t.timeIntervalSince(start) / 30)
            if b != bin { groups.append([]); bin = b }
            groups[groups.count - 1].append(i)
        }
        let acts = activities.sorted { $0.t < $1.t }
        var k = 0
        let act = points.map { p -> Activity? in
            while k < acts.count, acts[k].t <= p.t { k += 1 }
            return k > 0 ? acts[k - 1].activity : nil
        }
        let roughV = MapMatcher.roughRunSpeed(points)
        let windows = groups.map { window($0, points, roughV, act, graph, stops) }
        let modes = TravelMode.allCases.filter { $0 != .vehicle }   // `vehicle` comes only from settle
        let e = windows.map { w in modes.map { emission(w, $0) } }

        // Viterbi: best log score of a path ending in each mode, with back pointers.
        var score = e[0], back: [[Int]] = [[]]
        for w in 1..<max(1, e.count) {
            var next = score, from = [Int](repeating: 0, count: modes.count)
            for (b, mb) in modes.enumerated() {
                let best = modes.indices.max { score[$0] + transition(modes[$0], mb) < score[$1] + transition(modes[$1], mb) }!
                next[b] = score[best] + transition(modes[best], mb) + e[w][b]
                from[b] = best
            }
            score = next; back.append(from)
        }
        var path = [score.indices.max { score[$0] < score[$1] }!]
        for w in stride(from: e.count - 1, to: 0, by: -1) { path.append(back[w][path.last!]) }
        path.reverse()

        // Runs of one mode become stretches; confidence from the smallest summed emission margin over any other mode.
        var out: [ModeStretch] = [], a = 0
        for b in 1...path.count where b == path.count || path[b] != path[a] {
            let c = path[a]
            let margin = modes.indices.filter { $0 != c }.map { o in (a..<b).map { e[$0][c] - e[$0][o] }.reduce(0, +) }.min() ?? 0
            out.append(ModeStretch(seq: out.count, mode: modes[c], confidence: 1 - exp(-max(0, margin)),
                                   start: points[windows[a].first].t, end: points[windows[b - 1].last].t))
            a = b
        }
        return out
    }

    static func window(_ idx: [Int], _ p: [FilteredPoint], _ roughV: [Double], _ act: [Activity?], _ g: RoadGraph, _ stops: [Stop]) -> Window {
        let precise = idx.filter { p[$0].kind == .moving }, roughs = idx.filter { p[$0].kind == .rough }
        // Speed: median Doppler; else straight line first to last precise point; else the median rough-run speed.
        var v: Double?
        let doppler = precise.map { p[$0].speed }.filter { $0 >= 0 }.sorted()
        if !doppler.isEmpty { v = doppler[doppler.count / 2] }
        else if let a = precise.first, let b = precise.last, p[b].t > p[a].t { v = MapMatcher.distance(p[a], p[b]) / p[b].t.timeIntervalSince(p[a].t) }
        else if !roughs.isEmpty { let r = roughs.map { roughV[$0] }.sorted(); v = r[r.count / 2] }

        // Halt: consecutive precise points below 0.5 m/s (Doppler, else displacement) spanning at least 10 s; placed at their mean.
        var run: [Int] = [], halt: (lat: Double, lon: Double)?
        for (n, i) in precise.enumerated() {
            let dt = n > 0 ? p[i].t.timeIntervalSince(p[precise[n - 1]].t) : 0
            let s = p[i].speed >= 0 ? p[i].speed : dt > 0 ? MapMatcher.distance(p[precise[n - 1]], p[i]) / dt : -1
            guard s >= 0, s < 0.5 else { run = []; continue }
            run.append(i)
            if p[i].t.timeIntervalSince(p[run[0]].t) >= 10 {
                let c = Double(run.count)
                halt = (run.map { p[$0].lat }.reduce(0, +) / c, run.map { p[$0].lon }.reduce(0, +) / c)
            }
        }
        // shortcut: stops are scanned linearly per halted window (a trip's tiles hold hundreds), upgrade to a grid if the run time shows it
        let stopDist = halt.map { h in
            Dictionary(stops.map { ($0.kind, Geo.distance(h.lat, h.lon, $0.lat, $0.lon)) }, uniquingKeysWith: min)
        }

        // Activity: the majority over the points, ties to the first listed.
        let choices: [Activity?] = [nil, .walking, .running, .cycling, .automotive]
        let votes = choices.map { c in idx.filter { [.stationary, .unknown, nil].contains(act[$0]) ? c == nil : act[$0] == c }.count }

        var kinds: [Set<WayKind>] = [], open = 0
        // No downloaded ways at all says nothing about the network: kinds stay empty and the network is left out of the emission.
        for i in idx where !g.ways.isEmpty {
            let q = p[i], rough = q.kind == .rough, r = rough ? min(q.hAcc, 300) : 25
            let c = g.candidates(lat: q.lat, lon: q.lon, radius: rough ? r : 50)
            kinds.append(Set(c.filter { $0.distance <= r }.map { g.ways[g.index[$0.wayId]!].kind }))
            if !rough && c.isEmpty { open += 1 }
        }
        return Window(first: idx[0], last: idx[idx.count - 1], v: v, stopDist: stopDist, act: choices[votes.firstIndex(of: votes.max()!)!],
                      kinds: kinds, open: precise.isEmpty ? 0 : Double(open) / Double(precise.count),
                      rough: Double(roughs.count) / Double(idx.count))
    }

    /// Log emission of a window in a mode.
    static func emission(_ w: Window, _ m: TravelMode) -> Double {
        var e = 0.0
        if w.stopDist == nil, let v = w.v {
            let (mu, sigma): (Double, Double) = switch m {
            case .walk: (1.4, 0.4)
            case .run: (3.2, 0.8)
            case .bike: (5, 1.5)
            case .car, .bus, .vehicle: (12, 9)
            case .tram: (8, 4)
            case .train: (25, 12)
            case .boat: (6, 3)
            }
            e += -log(sigma) - 0.5 * ((v - mu) / sigma) * ((v - mu) / sigma)
        }
        if let a = w.act {
            let expected: Activity = switch m { case .walk: .walking; case .run: .running; case .bike: .cycling; default: .automotive }
            e += a == expected ? 0 : -2
        }
        func near(_ ks: Set<WayKind>) -> Double {
            w.kinds.isEmpty ? 0 : Double(w.kinds.filter { !$0.isDisjoint(with: ks) }.count) / Double(w.kinds.count)
        }
        if !w.kinds.isEmpty { switch m {
        case .walk, .run: break   // walkers go anywhere
        case .bike: e += near([.cycle, .foot, .road]) - 1
        case .car, .bus, .vehicle: e += 3 * (near([.road]) - 1)
        case .tram: e += 3 * (near([.tram, .rail]) - 1)
        case .train: e += 3 * (near([.rail]) - 1)
        case .boat: e += 4.5 * (max(near([.ferry]), w.open) - 1)   // heavier: boats are rare
        } }
        // Trains report rough fixes; cars and boats (open sky) rarely do.
        e -= w.rough * (m == .tram ? 1 : m == .train ? 0 : 2)
        // Boats are rare and their narrow speed prior beats bus and car at 3 to 10 m/s: without street data a boat needs more.
        if m == .boat && w.kinds.isEmpty { e -= 1.5 }
        if let d = w.stopDist {
            func within(_ k: StopKind, _ r: Double) -> Bool { (d[k] ?? .infinity) <= r }
            switch m {
            case .bus: e += within(.bus, 30) ? 0 : -1
            case .tram: e += within(.tram, 50) ? 0 : -1
            case .train: e += within(.rail, 300) ? 0 : -2
            case .boat: e += within(.ferry, 100) ? 0 : -0.5
            case .car: e += within(.bus, 30) ? -1 : 0
            case .walk, .run, .bike, .vehicle: break
            }
        } else if m == .bus {
            e -= 0.1   // a bus needs evidence: car wins ties
        }
        return e
    }

    /// Log transition: walk↔run is a small step, on foot↔vehicle a change, vehicle↔vehicle rare.
    static func transition(_ a: TravelMode, _ b: TravelMode) -> Double {
        if a == b { return 0 }
        let foot: Set<TravelMode> = [.walk, .run]
        if foot.contains(a) && foot.contains(b) { return -2 }
        return foot.contains(a) || foot.contains(b) ? -4 : -8
    }

    /// Whole rides between walks, after the 30 s windows: consecutive non-foot stretches form one piece (a change of vehicle
    /// passes through walking). A piece whose 95th-percentile speed is walking pace is a walk (one GPS spike sets a maximum,
    /// not a P95); at cycling speeds with a bike window it is a bike; otherwise it keeps its longest confident mode, which the
    /// windows chose with rail, tram, ferry and bus-stop evidence, or becomes `vehicle` when no mode is confident.
    public static func settle(_ stretches: [ModeStretch], points: [FilteredPoint]) -> [ModeStretch] {
        let foot: Set<TravelMode> = [.walk, .run]
        var pieces: [[ModeStretch]] = []
        for s in stretches.sorted(by: { $0.start < $1.start }) {
            if let last = pieces.last?.last, !foot.contains(last.mode), !foot.contains(s.mode) { pieces[pieces.count - 1].append(s) }
            else { pieces.append([s]) }
        }
        var out: [ModeStretch] = []
        for piece in pieces {
            let first = piece[0], start = first.start, end = piece[piece.count - 1].end
            var mode = first.mode, confidence = first.confidence
            if !foot.contains(first.mode) {
                let speeds = points.filter { $0.t >= start && $0.t <= end && $0.speed >= 0 }.map(\.speed).sorted()
                let p95 = speeds.isEmpty ? nil : speeds[min(speeds.count - 1, Int(Double(speeds.count) * 0.95))]
                var time: [TravelMode: Double] = [:]
                for s in piece where s.confidence >= confident { time[s.mode, default: 0] += s.end.timeIntervalSince(s.start) }
                let best = time.max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }?.key
                if let p95, p95 < 8 / 3.6 { mode = .walk }
                else if let p95, p95 < 35 / 3.6, piece.contains(where: { $0.mode == .bike }) { mode = .bike }
                else { mode = best ?? .vehicle }
                let backing = piece.filter { $0.mode == best }
                confidence = (backing.isEmpty ? piece : backing).map(\.confidence).max() ?? 0
            }
            // Neighbouring pieces of the same mode (a walk either side of a spike) join into one.
            if let last = out.last, last.mode == mode {
                out[out.count - 1].end = end
                out[out.count - 1].confidence = max(last.confidence, confidence)
            } else {
                out.append(ModeStretch(seq: out.count, mode: mode, confidence: confidence, start: start, end: end))
            }
        }
        return out
    }
}
