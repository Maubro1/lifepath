import Foundation

// Plain structs for Diary v9; Task 1 adds `Days` (tally) to this file.
public struct DaySummary: Sendable, Equatable {
    public var day: String
    public var distance: Double
    public var movingTime: TimeInterval
    public var walked: Double
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
