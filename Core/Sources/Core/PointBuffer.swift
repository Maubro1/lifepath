import Foundation

public struct PointBuffer: Sendable {
    public init() {}
    public mutating func add(_ p: FilteredPoint, at now: Date) {}
    public mutating func add(_ e: LoggedEvent) {}
    public func isDue(at now: Date) -> Bool { false }
    public mutating func take() -> (points: [FilteredPoint], events: [LoggedEvent]) { ([], []) }
    public mutating func putBack(points: [FilteredPoint], events: [LoggedEvent]) {}
}
