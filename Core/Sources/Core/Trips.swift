import Foundation

public struct Trip: Sendable, Equatable {
    public var points: [FilteredPoint]
    public var start: Date
    public var end: Date
    public var distance: Double  // m
    public var movingTime: TimeInterval
}

public enum Trips {
    /// Moving points only; a still point, a gap > maxGap or a jump > maxJump ends a trip; trips with < 2 points are dropped.
    /// A still point first trims the run's slow settling tail (within 30 m of it and within 5 m of the fix before it), then ends the trip at its position.
    public static func split(_ points: [FilteredPoint], maxGap: TimeInterval = 600, maxJump: Double = 500) -> [Trip] {
        var trips: [Trip] = []
        var run: [FilteredPoint] = []
        func flush() {
            defer { run = [] }
            guard run.count >= 2 else { return }
            var distance = 0.0, time = 0.0
            for (a, b) in zip(run, run.dropFirst()) {
                distance += Geo.distance(a.lat, a.lon, b.lat, b.lon)
                time += b.t.timeIntervalSince(a.t)
            }
            trips.append(Trip(points: run, start: run[0].t, end: run[run.count - 1].t, distance: distance, movingTime: time))
        }
        for p in points {
            guard p.kind == .moving else {
                let lastFix = run.last  // gap/jump are judged from the real last fix, not the trimmed one
                while run.count > 1, let last = run.last,
                      Geo.distance(last.lat, last.lon, p.lat, p.lon) <= 30,
                      Geo.distance(last.lat, last.lon, run[run.count - 2].lat, run[run.count - 2].lon) <= 5 {
                    run.removeLast()
                }
                // Kind .moving so the end fix counts as movement; skipped across a gap/jump like any other fix.
                if let last = lastFix, p.t.timeIntervalSince(last.t) <= maxGap, Geo.distance(last.lat, last.lon, p.lat, p.lon) <= maxJump {
                    var end = p; end.kind = .moving; run.append(end)
                }
                flush(); continue
            }
            if let last = run.last,
               p.t.timeIntervalSince(last.t) > maxGap || Geo.distance(last.lat, last.lon, p.lat, p.lon) > maxJump {
                flush()
            }
            run.append(p)
        }
        flush()
        return trips
    }
}
