import Foundation

public struct HealthInput: Sendable {
    public var now: Date
    public var events: [LoggedEvent]
    public var points: [FilteredPoint]
    public var settings: [String: String]
    public init(now: Date, events: [LoggedEvent], points: [FilteredPoint], settings: [String: String]) {
        self.now = now; self.events = events; self.points = points; self.settings = settings
    }
}

public enum HealthReport {
    public static func render(_ input: HealthInput, days: Int = 3) -> String { "" }
}
