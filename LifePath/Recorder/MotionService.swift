import Core
import CoreMotion

@MainActor final class MotionService {
    /// Absent motion permission: the engine runs with `motionAvailable: false` and no steps or activity arrive.
    nonisolated static var available: Bool {
        CMMotionActivityManager.isActivityAvailable()
            && ![.denied, .restricted].contains(CMMotionActivityManager.authorizationStatus())
    }

    private unowned let recorder: Recorder
    private let pedometer = CMPedometer(), activities = CMMotionActivityManager()
    private var counting = false, lastCount = 0
    /// One timestamp per step since the last Still entry, for `Backfill.departure`.
    // shortcut: an update's steps all get its end date, so a suspended rest dates them late; activity history usually wins.
    private var stepTimes: [Date] = []

    init(recorder: Recorder) { self.recorder = recorder }

    func startActivity() {
        guard Self.available else { return }
        activities.startActivityUpdates(to: .main) { @Sendable a in
            guard let a else { return }
            let activity = Self.activity(a), confident = a.confidence != .low
            Task { @MainActor in self.recorder.activityChanged(activity, confident: confident) }
        }
    }

    /// The counter restarts at each Still entry; the cumulative count goes to the engine as `.steps(n)`.
    func startSteps(from: Date) {
        guard Self.available, CMPedometer.isStepCountingAvailable() else { return }
        pedometer.stopUpdates()
        counting = true; lastCount = 0; stepTimes = []
        pedometer.startUpdates(from: from) { @Sendable data, _ in
            guard let data else { return }
            let n = data.numberOfSteps.intValue, t = data.endDate
            Task { @MainActor in self.steps(n, at: t) }
        }
    }

    func stopSteps() {
        counting = false
        pedometer.stopUpdates()
    }

    private func steps(_ n: Int, at t: Date) {
        guard counting, n > lastCount else { return }
        stepTimes += Array(repeating: t, count: n - lastCount)
        lastCount = n
        recorder.send(.steps(n))
    }

    /// True trip start from CoreMotion history; step times survive `stopSteps` until the next Still entry.
    func departure(stillSince: Date, until now: Date) async -> Date? {
        guard Self.available else { return nil }
        let steps = stepTimes
        let acts: [(Date, Activity)] = await withCheckedContinuation { c in
            activities.queryActivityStarting(from: stillSince, to: now, to: .main) { @Sendable list, _ in
                c.resume(returning: (list ?? []).filter { $0.confidence != .low }.map { ($0.startDate, Self.activity($0)) })
            }
        }
        return Backfill.departure(stillSince: stillSince, activities: acts, stepTimes: steps)
    }

    nonisolated static func activity(_ a: CMMotionActivity) -> Activity {
        a.automotive ? .automotive : a.cycling ? .cycling : a.running ? .running
            : a.walking ? .walking : a.stationary ? .stationary : .unknown
    }
}
