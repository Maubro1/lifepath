import Foundation

/// Fills what the engine could not see live: still points over a suspended rest, and the true trip start.
public enum Backfill {
    /// Still points every `every` s after `from` (exclusive) up to `to` (inclusive), pinned to the fence.
    public static func stillPoints(fence: Fence, from: Date, to: Date, every: TimeInterval = 300) -> [FilteredPoint] {
        guard every > 0 else { return [] }
        return stride(from: every, through: to.timeIntervalSince(from), by: every).map { fence.stillPoint(at: from.addingTimeInterval($0)) }
    }

    /// Earliest of the first moving activity and the first step burst (>= 15 steps within 60 s) since `stillSince`.
    /// `activities` must already be limited to confident ones; `stepTimes` holds one timestamp per step.
    public static func departure(stillSince: Date, activities: [(Date, Activity)], stepTimes: [Date]) -> Date? {
        let moved = activities.filter { $0.0 >= stillSince && $0.1.isMoving }.map { $0.0 }.min()
        let steps = stepTimes.filter { $0 >= stillSince }.sorted()
        let burst = steps.indices.dropLast(14).first { steps[$0 + 14].timeIntervalSince(steps[$0]) <= 60 }.map { steps[$0] }
        return [moved, burst].compactMap { $0 }.min()
    }
}
