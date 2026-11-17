import Core
import Diary
import Foundation

/// Copies daily steps into the diary for good and keeps the per-day summaries. Runs at the end of each smoothing run
/// (app open or charging) and on pull to refresh, never two at once.
enum DayService {
    @MainActor static var running: Task<Void, Never>?
    static let changed = Notification.Name("app.lifepath.daysChanged")   // posted on the main actor after a run that saved

    /// A second caller waits for the running one and returns; cancelling a caller cancels the run it waits on.
    static func run(_ diary: Diary) async {
        let (task, mine) = await MainActor.run { () -> (Task<Void, Never>, Bool) in
            if let r = running { return (r, false) }
            let t = Task.detached(priority: .utility) { await execute(diary) }
            running = t
            return (t, true)
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if mine { await MainActor.run { running = nil } }
    }

    private static func execute(_ diary: Diary) async {
        let detail: String
        do { detail = try await work(diary) }
        catch is CancellationError { return }
        catch { detail = "failed" }
        await MainActor.run {
            Recorder.shared.log("days", detail); Recorder.shared.flush()
            if detail != "failed" { NotificationCenter.default.post(name: changed, object: nil) }
        }
    }

    private static func work(_ diary: Diary) async throws -> String {
        let calendar = Calendar.current, now = Date()
        // iOS keeps 7 days: each run copies them; a stored count is never lowered, a failed day is simply left out.
        let steps = await MotionService.daySteps(now: now, calendar: calendar)

        // A new tally, smoother or matcher version rebuilds every day once.
        let smoothingVersion = try diary.meta("smoothingVersion") ?? "", matcherVersion = try diary.meta("matcherVersion") ?? ""
        let version = "\(Days.version).\(smoothingVersion).\(matcherVersion)"
        // shortcut: a cancelled full rebuild starts over next time, upgrade to a resumable cursor if the log shows it never finishing
        let from: Date
        let streetsUntil = try diary.meta("streetsUntil"), daysStreets = try diary.meta("daysStreets")
        if try diary.meta("daysVersion") != version { from = .distantPast } else {
            // From yesterday; only when the street cursor moved since the last run, also from the older cursor: trips from there on were re-matched.
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            func date(_ s: String?) -> Date { s.flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) } ?? yesterday }
            let back = streetsUntil != daysStreets ? min(yesterday, min(date(daysStreets), date(streetsUntil))) : yesterday
            from = calendar.startOfDay(for: back)
        }

        var days: [String: DaySummary] = [:]
        func tally(_ trips: [Trip], _ points: [FilteredPoint]) throws {
            var modes: [ModeStretch] = [], smoothed: [Date: (lat: Double, lon: Double)] = [:]
            if let first = trips.first?.start, let last = trips.last?.end {
                modes = try diary.modes(from: first, to: last).values.flatMap { $0 }
                smoothed = Dictionary(try diary.smoothed(from: first, to: last).map { ($0.t, (lat: $0.lat, lon: $0.lon)) }, uniquingKeysWith: { a, _ in a })
            }
            Days.tally(points: points, trips: trips, modes: modes, smoothed: smoothed, from: from, calendar: calendar, into: &days)
        }
        // A day before `from` gives the trip split its context; only points from `from` on are credited. A month at a time, the open trip carried.
        let month: TimeInterval = 30 * 86_400
        var after = from.addingTimeInterval(-86_400 - 0.001), carry: [FilteredPoint] = []   // reads are `t > after`
        while let first = try diary.points(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, after: after, to: now, limit: 1).first {
            try Task.checkCancellation()
            let chunk = try diary.points(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, after: after, to: min(now, first.t.addingTimeInterval(month)), limit: Int.max)
            try tally(Trips.split(chunk: chunk, carry: &carry), chunk)
            after = chunk[chunk.count - 1].t
        }
        try tally(Trips.split(carry), [])
        try Task.checkCancellation()

        let fromKey = Days.key(from, calendar)
        try diary.saveDays(Array(days.values), from: fromKey)
        do { try diary.saveSteps(steps) } catch { await MainActor.run { Recorder.shared.log("days", "steps-failed") } }
        if let streetsUntil { try diary.setMeta("daysStreets", streetsUntil) }
        try diary.setMeta("daysVersion", version)
        return "from=\(fromKey) days=\(days.count) steps=\(steps.count)"
    }
}
