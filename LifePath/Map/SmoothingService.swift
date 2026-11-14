import BackgroundTasks
import Core
import Diary

/// Smooths finished trips into the derived `smoothedPoint` cache. Only while the app is open or the phone is charging.
enum SmoothingService {
    static let taskID = "app.lifepath.LifePath.smooth"
    private static let margin: TimeInterval = 600   // newest 10 min stay raw; also the re-smoothing overlap
    @MainActor private static var ranThisForeground = false

    /// Synchronous and cancellable between trips (each trip is saved whole, in time order, so a cancel leaves a clean prefix).
    static func run(_ diary: Diary) throws -> (trips: Int, points: Int) {
        let from = try diary.smoothedUntil()?.addingTimeInterval(-margin) ?? .distantPast
        let trips = Trips.split(try diary.points(from: from, to: Date().addingTimeInterval(-margin)))
        var points = 0
        for trip in trips {
            try Task.checkCancellation()
            let fixes = trip.points.map { RawFix(t: $0.t, lat: $0.rawLat, lon: $0.rawLon, hAcc: $0.hAcc, speed: $0.speed, course: $0.course) }
            let line = TripSmoother.smooth(fixes)
            try diary.saveSmoothed(line)
            points += line.count
        }
        return (trips.count, points)
    }

    private static func execute() async {
        guard let diary = await MainActor.run(body: { Recorder.shared.readDiary }) else { return }   // locked before first unlock
        let detail: String
        do { let r = try run(diary); detail = "trips=\(r.trips) points=\(r.points)" }
        catch is CancellationError { return }
        catch { detail = "failed" }
        await MainActor.run { Recorder.shared.log("smooth", detail); Recorder.shared.flush() }
    }

    /// At most once per foreground; the work never touches the main actor.
    @MainActor static func appBecameActive() {
        guard !ranThisForeground else { return }
        ranThisForeground = true
        Task.detached(priority: .utility) { await execute() }
    }

    /// Re-arms the charging-only background run.
    @MainActor static func appWentToBackground() {
        ranThisForeground = false
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresExternalPower = true
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Must run before launch finishes.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            nonisolated(unsafe) let task = task
            let work = Task.detached(priority: .utility) {
                await execute()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }
}
