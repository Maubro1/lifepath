import BackgroundTasks
import Core
import Diary

/// Smooths finished trips into the derived `smoothedPoint` cache. Only while the app is open or the phone is charging.
enum SmoothingService {
    static let taskID = "app.lifepath.LifePath.smooth"
    private static let margin: TimeInterval = 600   // newest 10 min stay raw; also the re-smoothing overlap
    @MainActor private static var ranThisForeground = false
    @MainActor static var running: Task<Void, Never>?
    static let linesChanged = Notification.Name("app.lifepath.tripLinesChanged")   // posted on the main actor after a run wrote trip lines

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
        var trips = 0, points = 0, lines = 0
        func process(_ split: [Trip]) throws {
            for trip in split {
                try Task.checkCancellation()
                trips += 1
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
        }
        // A first build covers all history: read it a month at a time (empty stretches skipped), the open trip carried across edges.
        let end = Date().addingTimeInterval(-margin), month: TimeInterval = 30 * 86_400
        var after = min(smoothFrom, linesFrom).addingTimeInterval(-0.001), carry: [FilteredPoint] = []   // reads are `t > after`
        while let first = try diary.points(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, after: after, to: end, limit: 1).first {
            try Task.checkCancellation()
            let chunk = try diary.points(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, after: after, to: min(end, first.t.addingTimeInterval(month)), limit: Int.max)
            try process(Trips.split(chunk: chunk, carry: &carry))
            after = chunk[chunk.count - 1].t
        }
        try process(Trips.split(carry))
        return (trips, points, lines)
    }

    private static func execute() async {
        guard let diary = await MainActor.run(body: { Recorder.shared.readDiary }) else { return }   // locked before first unlock
        let detail: String, wroteLines: Bool
        do { let r = try run(diary); detail = "trips=\(r.trips) points=\(r.points) lines=\(r.lines)"; wroteLines = r.lines > 0 }
        catch is CancellationError { return }
        catch { detail = "failed"; wroteLines = false }
        await MainActor.run {
            Recorder.shared.log("smooth", detail); Recorder.shared.flush()
            if wroteLines { NotificationCenter.default.post(name: linesChanged, object: nil) }   // the map reloads once if visible
        }
        await PlaceService.execute(diary)   // same cancellation: a cancelled smooth run returned above, and the places run checks it too
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
