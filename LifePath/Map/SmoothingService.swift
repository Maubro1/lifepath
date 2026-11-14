import BackgroundTasks
import Core
import Diary

/// Smooths finished trips into the derived `smoothedPoint` cache. Only while the app is open or the phone is charging.
enum SmoothingService {
    static let taskID = "app.lifepath.LifePath.smooth"
    private static let margin: TimeInterval = 600   // newest 10 min stay raw; also the re-smoothing overlap
    @MainActor private static var ranThisForeground = false
    @MainActor static var running: Task<Void, Never>?

    /// Synchronous and cancellable between trips (each trip is saved whole, in time order, so a cancel leaves a clean prefix).
    static func run(_ diary: Diary) throws -> (trips: Int, points: Int, lines: Int) {
        // Load a margin before the overlap so the re-smoothed seam has context; save only the overlap onward.
        let until = try diary.smoothedUntil()
        let smoothFrom = until?.addingTimeInterval(-2 * margin) ?? .distantPast
        let keepFrom = until?.addingTimeInterval(-margin) ?? .distantPast
        // Trip lines restart at the newest cached trip (it may have been cut by the last run's end); an empty cache covers all history.
        let linesFrom = try diary.tripLinesUntil().map { u in
            try diary.tripLines(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, from: u, to: .distantFuture).map(\.start).min() ?? u
        } ?? .distantPast
        let trips = Trips.split(try diary.points(from: min(smoothFrom, linesFrom), to: Date().addingTimeInterval(-margin)))
        var points = 0, lines = 0
        for trip in trips {
            try Task.checkCancellation()
            let fixes = trip.points.map { Sample(t: $0.t, lat: $0.rawLat, lon: $0.rawLon, hAcc: $0.hAcc, speed: $0.speed, course: $0.course) }
            let smooth = TripSmoother.smooth(fixes)
            let line = smooth.filter { $0.t >= keepFrom }
            try diary.saveSmoothed(line)
            points += line.count
            guard trip.end >= linesFrom else { continue }   // earlier trips are already cached
            // Smoothed where smoothed, recorded elsewhere (as the map draws it).
            let byT = Dictionary(smooth.map { ($0.t, (lat: $0.lat, lon: $0.lon)) }, uniquingKeysWith: { a, _ in a })
            var shown = trip
            for i in shown.points.indices { if let s = byT[shown.points[i].t] { shown.points[i].lat = s.lat; shown.points[i].lon = s.lon } }
            try diary.saveTripLines([TripLines.make(shown)], replacingFrom: trip.start)
            lines += 1
        }
        return (trips.count, points, lines)
    }

    private static func execute() async {
        guard let diary = await MainActor.run(body: { Recorder.shared.readDiary }) else { return }   // locked before first unlock
        let detail: String
        do { let r = try run(diary); detail = "trips=\(r.trips) points=\(r.points) lines=\(r.lines)" }
        catch is CancellationError { return }
        catch { detail = "failed" }
        await MainActor.run { Recorder.shared.log("smooth", detail); Recorder.shared.flush() }
    }

    /// At most once per foreground and never two at once; the work never touches the main actor.
    @MainActor static func appBecameActive() {
        guard !ranThisForeground, running == nil else { return }
        ranThisForeground = true
        running = Task.detached(priority: .utility) {
            await execute()
            await MainActor.run { running = nil }
        }
    }

    /// Re-arms the charging-only background run.
    @MainActor static func appWentToBackground() {
        ranThisForeground = false
        running?.cancel()
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
