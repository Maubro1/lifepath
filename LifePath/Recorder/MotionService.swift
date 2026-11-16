import Core
import CoreMotion

@MainActor final class MotionService {
    /// Absent motion permission: no steps or activity arrive; the engine runs on fixes alone.
    nonisolated static var available: Bool {
        CMMotionActivityManager.isActivityAvailable()
            && ![.denied, .restricted].contains(CMMotionActivityManager.authorizationStatus())
    }

    private unowned let recorder: Recorder
    private let pedometer = CMPedometer(), activities = CMMotionActivityManager()
    private(set) var counting = false
    private var lastCount = 0

    init(recorder: Recorder) { self.recorder = recorder }

    func startActivity() {
        guard Self.available else { return }
        activities.startActivityUpdates(to: .main) { @Sendable a in
            guard let a else { return }
            let activity = Self.activity(a), confident = a.confidence != .low
            Task { @MainActor in self.recorder.activityChanged(activity, confident: confident) }
        }
    }

    /// The counter restarts at each Still entry; the cumulative count and distance go to the engine as `.steps(n)` and `.walked(m)`.
    func startSteps(from: Date) {
        guard Self.available, CMPedometer.isStepCountingAvailable() else { return }
        pedometer.stopUpdates()
        counting = true; lastCount = 0
        pedometer.startUpdates(from: from) { @Sendable data, _ in
            guard let data else { return }
            let n = data.numberOfSteps.intValue, m = data.distance?.doubleValue
            Task { @MainActor in self.steps(n, m) }
        }
    }

    func stopSteps() {
        counting = false
        pedometer.stopUpdates()
    }

    private func steps(_ n: Int, _ metres: Double?) {
        guard counting, n > lastCount else { return }
        lastCount = n
        recorder.send(.steps(n))
        if let metres { recorder.send(.walked(metres)) }
    }

    /// True trip start from CoreMotion history, which also covers a rest the app slept through.
    func departure(stillSince: Date, until now: Date) async -> Date? {
        guard Self.available else { return nil }
        let buckets = Int((now.timeIntervalSince(stillSince) / 30).rounded(.up))
        let steps = CMPedometer.isStepCountingAvailable() && buckets > 0 ? await stepTimes(stillSince, 0, buckets, until: now) : []
        let acts: [(Date, Activity)] = await withCheckedContinuation { c in
            activities.queryActivityStarting(from: stillSince, to: now, to: .main) { @Sendable list, _ in
                c.resume(returning: (list ?? []).filter { $0.confidence != .low }.map { ($0.startDate, Self.activity($0)) })
            }
        }
        return Backfill.departure(stillSince: stillSince, activities: acts, stepTimes: steps)
    }

    /// Steps in 30 s buckets from `from`, each bucket's steps dated at its start. Empty stretches are skipped by
    /// halving, so a long rest costs a few queries rather than one per bucket.
    private func stepTimes(_ from: Date, _ lo: Int, _ hi: Int, until now: Date) async -> [Date] {
        let a = from.addingTimeInterval(Double(lo) * 30), b = min(from.addingTimeInterval(Double(hi) * 30), now)
        let n: Int = await withCheckedContinuation { c in
            pedometer.queryPedometerData(from: a, to: b) { @Sendable d, _ in c.resume(returning: d?.numberOfSteps.intValue ?? 0) }
        }
        guard n > 0 else { return [] }
        if hi - lo == 1 { return Array(repeating: a, count: n) }
        let mid = (lo + hi) / 2
        return await stepTimes(from, lo, mid, until: now) + stepTimes(from, mid, hi, until: now)
    }

    /// Walking pace (m/s) from pedometer distance in 30 s buckets, each dated at its start; empty without motion permission.
    /// CoreMotion keeps 7 days, so callers ask only for recent trips.
    nonisolated static func pace(from: Date, to: Date) async -> [(t: Date, speed: Double)] {
        guard available, CMPedometer.isDistanceAvailable() else { return [] }
        let pedometer = CMPedometer()
        var out: [(t: Date, speed: Double)] = [], a = from
        while a < to {
            let b = min(a.addingTimeInterval(30), to)
            let d: Double? = await withCheckedContinuation { c in
                pedometer.queryPedometerData(from: a, to: b) { @Sendable d, _ in c.resume(returning: d?.distance?.doubleValue) }
            }
            if let d { out.append((a, d / b.timeIntervalSince(a))) }
            a = b
        }
        return out
    }

    nonisolated static func activity(_ a: CMMotionActivity) -> Activity {
        a.automotive ? .automotive : a.cycling ? .cycling : a.running ? .running
            : a.walking ? .walking : a.stationary ? .stationary : .unknown
    }
}
