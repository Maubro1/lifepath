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
    /// A still point first trims the run's trailing settling fixes inside its fence (hAcc) radius.
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
                while let last = run.last, Geo.distance(last.lat, last.lon, p.lat, p.lon) <= p.hAcc { run.removeLast() }
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
