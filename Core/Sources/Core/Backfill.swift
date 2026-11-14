import Foundation

/// Fills what the engine could not see live: still points over a suspended rest, and the true trip start.
public enum Backfill {
    /// Still points every `every` s after `from` (exclusive) up to `to` (inclusive), pinned to the fence.
    public static func stillPoints(fence: Fence, from: Date, to: Date, every: TimeInterval = 300) -> [FilteredPoint] {
        guard every > 0 else { return [] }
        return stride(from: every, through: to.timeIntervalSince(from), by: every).map { fence.stillPoint(at: from.addingTimeInterval($0)) }
    }

    /// Earliest of the first moving activity and the first step burst (>= 15 steps within 60 s) after the last rest:
    /// the latest confident `.stationary` start with no moving activity or burst within 20 min after it (so a 02:00
    /// bathroom trip is skipped, and so is a wait at the tram stop or a red light that the walk or ride follows), else
    /// `stillSince`. `activities` must already be limited to confident ones; `stepTimes` holds one timestamp per step.
    public static func departure(stillSince: Date, activities: [(Date, Activity)], stepTimes: [Date]) -> Date? {
        let rests = activities.filter { $0.0 >= stillSince && $0.1 == .stationary }.map { $0.0 }.sorted(by: >)
        return (rests + [stillSince]).lazy.compactMap { rest in
            let d = departure(after: rest, activities, stepTimes)
            return rest == stillSince || d.map({ $0.timeIntervalSince(rest) > 1200 }) == true ? d : nil
        }.first
    }

    private static func departure(after start: Date, _ activities: [(Date, Activity)], _ stepTimes: [Date]) -> Date? {
        let moved = activities.filter { $0.0 >= start && $0.1.isMoving }.map { $0.0 }.min()
        let steps = stepTimes.filter { $0 >= start }.sorted()
        let burst = steps.indices.dropLast(14).first { steps[$0 + 14].timeIntervalSince(steps[$0]) <= 60 }.map { steps[$0] }
        return [moved, burst].compactMap { $0 }.min()
    }
}
