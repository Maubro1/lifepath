import BackgroundTasks
import Core
import Diary

/// Smooths finished trips into the derived `smoothedPoint` cache. Only while the app is open or the phone is charging.
enum SmoothingService {
    static let taskID = "app.lifepath.LifePath.smooth"
    private static let margin: TimeInterval = 600   // newest 10 min stay raw; also the re-smoothing overlap
    private static let versionKey = "smoothingVersion"
    @MainActor private static var ranThisForeground = false
    @MainActor static var running: Task<Void, Never>?
    static let linesChanged = Notification.Name("app.lifepath.tripLinesChanged")   // posted on the main actor after a run wrote trip lines

    /// Cancellable between trips (each trip is saved whole, in time order, so a cancel leaves a clean prefix).
    static func run(_ diary: Diary) async throws -> (trips: Int, points: Int, lines: Int) {
        // A new smoother version re-smooths all history once: both cursors start over, the version is stored at the end.
        // shortcut: a cancelled re-smooth starts over next time; upgrade to a resumable cursor if the log shows it never finishing
        // The trip-line version is part of it: a new line format rebuilds the cache once.
        let version = "\(TripSmoother.version).\(TripLines.version)"
        let resmooth = try diary.meta(versionKey) != version
        // Load a margin before the overlap so the re-smoothed seam has context; save only the overlap onward.
        let until = try resmooth ? nil : diary.smoothedUntil()
        let smoothFrom = until?.addingTimeInterval(-2 * margin) ?? .distantPast
        let keepFrom = until?.addingTimeInterval(-margin) ?? .distantPast
        // Trip lines restart at the newest cached trip (it may have been cut by the last run's end); an empty cache covers all history.
        let linesFrom: Date = try resmooth ? .distantPast : diary.tripLinesUntil().map { u in
            try diary.tripLines(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, from: u, to: .distantFuture).map(\.start).min() ?? u
        } ?? .distantPast
        var trips = 0, points = 0, lines = 0
        func process(_ split: [Trip]) async throws {
            for trip in split {
                try Task.checkCancellation()
                trips += 1
                let fixes = trip.points.map { Sample(t: $0.t, lat: $0.rawLat, lon: $0.rawLon, hAcc: $0.hAcc, speed: $0.speed, course: $0.course) }
                let rough = Set(trip.points.indices.filter { trip.points[$0].kind == .rough })
                // Walks within CoreMotion's 7-day history get the step counter's pace; older trips smooth without it.
                let pace = TripSmoother.medianSpeed(fixes, rough: rough) < 2.5 && trip.start > Date().addingTimeInterval(-7 * 86_400)
                    ? await MotionService.pace(from: trip.start, to: trip.end) : []
                let smooth = TripSmoother.smooth(fixes, rough: rough, pace: pace)
                let line = smooth.filter { $0.t >= keepFrom }
                try diary.saveSmoothed(line)
                points += line.count
                guard trip.end >= linesFrom else { continue }   // earlier trips are already cached
                // Smoothed where smoothed, snapped where matched (as the map draws it).
                let byT = Dictionary(smooth.map { ($0.t, (lat: $0.lat, lon: $0.lon)) }, uniquingKeysWith: { a, _ in a })
                let matches = try diary.matches(tripStart: trip.start)
                let ways = Dictionary(try diary.ways(ids: Array(Set(matches.map(\.wayId)))).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                try diary.saveTripLines([TripLines.snapped(trip, smoothed: byT, matches: matches, ways: ways)], replacingFrom: trip.start)
                lines += 1
            }
        }
        // A first build covers all history: read it a month at a time (empty stretches skipped), the open trip carried across edges.
        let end = Date().addingTimeInterval(-margin), month: TimeInterval = 30 * 86_400
        var after = min(smoothFrom, linesFrom).addingTimeInterval(-0.001), carry: [FilteredPoint] = []   // reads are `t > after`
        while let first = try diary.points(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, after: after, to: end, limit: 1).first {
            try Task.checkCancellation()
            let chunk = try diary.points(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, after: after, to: min(end, first.t.addingTimeInterval(month)), limit: Int.max)
            try await process(Trips.split(chunk: chunk, carry: &carry))
            after = chunk[chunk.count - 1].t
        }
        try await process(Trips.split(carry))
        if resmooth { try diary.setMeta(versionKey, version) }
        return (trips, points, lines)
    }

    private static func execute() async {
        // Locked before first unlock; during a restore's merge nothing starts (the restore runs the chain after it).
        guard let diary = await MainActor.run(body: { ImportService.shared.merging ? nil : Recorder.shared.readDiary }) else { return }
        let detail: String, wroteLines: Bool
        do { let r = try await run(diary); detail = "trips=\(r.trips) points=\(r.points) lines=\(r.lines)"; wroteLines = r.lines > 0 }
        catch is CancellationError { return }
        catch { detail = "failed"; wroteLines = false }
        await MainActor.run {
            Recorder.shared.log("smooth", detail); Recorder.shared.flush()
            if wroteLines { NotificationCenter.default.post(name: linesChanged, object: nil) }   // the map reloads once if visible
        }
        await PlaceService.execute(diary)   // same cancellation: a cancelled smooth run returned above, and the places run checks it too
        await StreetService.run(diary)   // after places: downloads may wait on the network, the places run never waits on them
        await DayService.run(diary)   // after streets: re-matched trips change the days' walked distance
    }

    /// At most once per foreground and never two at once; the work never touches the main actor.
    @MainActor static func appBecameActive() {
        guard !ranThisForeground, running == nil else { return }
        start()
    }

    /// Starts the chain now (or returns the running one), whether or not it already ran this foreground.
    @MainActor @discardableResult static func start() -> Task<Void, Never> {
        ranThisForeground = true
        if let running { return running }
        let task = Task.detached(priority: .utility) {
            await execute()
            await MainActor.run { running = nil }
        }
        running = task
        return task
    }

    /// Cancels the chain and waits until it and any days run (pull to refresh) have ended.
    @MainActor static func stop() async {
        let task = running
        task?.cancel()
        await task?.value
        await DayService.running?.value
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
            Task { @MainActor in
                let work = start()   // tracked in `running`, so stop() can cancel it
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
            }
        }
    }
}
