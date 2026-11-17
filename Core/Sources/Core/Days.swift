import Foundation

public struct DaySummary: Sendable, Equatable {
    public var day: String          // "yyyy-MM-dd", local
    public var distance: Double     // m, along the smoothed line where there is one
    public var movingTime: TimeInterval
    public var walked: Double       // m inside confident walk or run stretches
    public var points: Int
    public init(day: String, distance: Double, movingTime: TimeInterval, walked: Double, points: Int) {
        self.day = day; self.distance = distance; self.movingTime = movingTime; self.walked = walked; self.points = points
    }
}

public struct DaySteps: Sendable, Equatable {
    public var day: String
    public var steps: Int
    public var distance: Double?
    public var floorsUp: Int?
    public init(day: String, steps: Int, distance: Double?, floorsUp: Int?) {
        self.day = day; self.steps = steps; self.distance = distance; self.floorsUp = floorsUp
    }
}

public struct LifeStats: Sendable, Equatable {
    public var distance: Double
    public var walked: Double
    public var days: Int
    public var points: Int
    public var steps: Int?
    public var floorsUp: Int?
    public var stepsSince: String?
    public init(distance: Double, walked: Double, days: Int, points: Int, steps: Int?, floorsUp: Int?, stepsSince: String?) {
        self.distance = distance; self.walked = walked; self.days = days; self.points = points
        self.steps = steps; self.floorsUp = floorsUp; self.stepsSince = stepsSince
    }
}

// shortcut: days are keyed in the time zone current at compute time, so a trip abroad may shift by the offset, upgrade if the owner travels across zones and sees it
public enum Days {
    public static let version = 1

    /// "yyyy-MM-dd" of `t` in the calendar's time zone, always Gregorian (the phone's calendar may be Japanese or Buddhist).
    public static func key(_ t: Date, _ calendar: Calendar) -> String {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        let c = g.dateComponents([.year, .month, .day], from: t)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Credits points, trip time, distance and walked distance to the local day of each point (of a pair's earlier point).
    /// Only points and pairs whose first point has `t >= from` count. Trips must be in time order.
    // shortcut: a pair straddling midnight counts wholly on the earlier day (one fix interval at most), upgrade if a day's total looks off
    public static func tally(points: [FilteredPoint], trips: [Trip], modes: [ModeStretch], smoothed: [Date: (lat: Double, lon: Double)],
                             from: Date, calendar: Calendar, into days: inout [String: DaySummary]) {
        var span: DateInterval?, current = ""
        // Keys formatted once per day, not per point.
        func credit(_ t: Date, _ add: (inout DaySummary) -> Void) {
            if span?.contains(t) != true || t == span?.end {
                span = calendar.dateInterval(of: .day, for: t)
                current = key(t, calendar)
            }
            add(&days[current, default: DaySummary(day: current, distance: 0, movingTime: 0, walked: 0, points: 0)])
        }
        for p in points where p.t >= from { credit(p.t) { $0.points += 1 } }

        let walks = modes.filter { ($0.mode == .walk || $0.mode == .run) && $0.confidence >= TravelModes.confident }
            .sorted { $0.start < $1.start }
        var k = 0
        for trip in trips {
            for (a, b) in zip(trip.points, trip.points.dropFirst()) where a.t >= from {
                credit(a.t) { $0.movingTime += b.t.timeIntervalSince(a.t) }
            }
            let precise = trip.points.filter { $0.kind != .rough }   // a rough point can be a kilometre off, as in Trips.split
            for (a, b) in zip(precise, precise.dropFirst()) where a.t >= from {
                let pa = smoothed[a.t] ?? (a.lat, a.lon), pb = smoothed[b.t] ?? (b.lat, b.lon)
                let d = Geo.distance(pa.lat, pa.lon, pb.lat, pb.lon)
                while k < walks.count, walks[k].end < a.t { k += 1 }
                let walked = k < walks.count && walks[k].start <= a.t && b.t <= walks[k].end
                credit(a.t) { $0.distance += d; if walked { $0.walked += d } }
            }
        }
    }
}
