import Foundation

public enum Backfill {
    public static func stillPoints(fence: Fence, from: Date, to: Date, every: TimeInterval = 300) -> [FilteredPoint] { [] }
    public static func departure(stillSince: Date, activities: [(Date, Activity)], stepTimes: [Date]) -> Date? { nil }
}
