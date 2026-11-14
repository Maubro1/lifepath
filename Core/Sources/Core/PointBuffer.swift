import Foundation

public struct PointBuffer: Sendable {
    private var points: [FilteredPoint] = []
    private var events: [LoggedEvent] = []
    /// Arrival time of the oldest pending item; nil when empty.
    private var oldest: Date?

    public init() {}

    public mutating func add(_ p: FilteredPoint, at now: Date) {
        points.append(p)
        oldest = oldest ?? now
    }

    /// Events carry no arrival clock, so their own timestamp stands in for it.
    public mutating func add(_ e: LoggedEvent) {
        events.append(e)
        oldest = oldest ?? e.t
    }

    public func isDue(at now: Date) -> Bool {
        guard let oldest else { return false }
        return now.timeIntervalSince(oldest) >= 30
    }

    public mutating func take() -> (points: [FilteredPoint], events: [LoggedEvent]) {
        defer { points = []; events = []; oldest = nil }
        return (points, events)
    }

    /// Puts a failed write back in front of anything added since; due immediately.
    public mutating func putBack(points: [FilteredPoint], events: [LoggedEvent]) {
        guard !points.isEmpty || !events.isEmpty else { return }
        self.points = points + self.points
        self.events = events + self.events
        oldest = .distantPast
    }
}
