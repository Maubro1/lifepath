import Core
import Diary
import Foundation

/// Folds finished rests into learned places. Runs at the end of each smoothing run, so only while the app is open or the phone is charging.
final class PlaceService: @unchecked Sendable {
    @MainActor static let shared = PlaceService()
    static let changed = Notification.Name("app.lifepath.placesChanged")   // posted on the main actor after a run changed places or visits
    /// What the last run saw, for the Recorder.
    @MainActor private(set) var places: [Place] = []

    private static let overlap: TimeInterval = 3600, chunk: TimeInterval = 30 * 86_400, gap: TimeInterval = 1800

    /// Synchronous and cancellable between visits; each chunk is saved whole (places, visits, cursor), so a cancel leaves a clean prefix.
    static func run(_ diary: Diary) throws -> (visits: Int, new: Int, merged: Int, places: [Place]) {
        var places = try diary.places()
        let initial = Set(places.map(\.id))
        var nextId = (initial.max() ?? 0) + 1
        var learned = 0
        let now = Date()
        var cursor = try diary.meta("placesProcessedUntil").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0 - overlap) } ?? .distantPast
        // shortcut: a first build reads history a month at a time (a still run filling a whole window doubles it); a rest spanning a window edge is judged by the next read.
        while true {
            try Task.checkCancellation()
            guard let first = try diary.points(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, after: cursor.addingTimeInterval(-0.001), to: now, limit: 1).first else { break }
            var span = chunk
            var pts: [FilteredPoint], isLast: Bool, stored: [Visit], settled: (finished: [(start: Date, end: Date, points: [FilteredPoint])], next: Date, stalled: Bool)
            repeat {
                let to = first.t.addingTimeInterval(span)
                isLast = to >= now
                pts = try diary.points(from: first.t, to: min(to, now))
                stored = try diary.visits(from: first.t, to: min(to, now))
                settled = Places.settle(visits: Places.visits(from: pts), first: first.t, lastT: pts[pts.count - 1].t, now: now, isLast: isLast, stored: stored)
                span *= 2
            } while settled.stalled
            var fresh: [Visit] = [], remap: [Int64: Int64] = [:], changed = places
            for v in settled.finished {
                try Task.checkCancellation()
                let before = Set(changed.map(\.id))
                let r = Places.learn(changed, visit: v, now: now, nextId: nextId)
                nextId = max(nextId, (r.places.map(\.id).max() ?? 0) + 1)
                for gone in before.subtracting(r.places.map(\.id)) { remap[gone] = r.visit.placeId }   // a merge always lands in the visit's place
                changed = r.places; fresh.append(r.visit); learned += 1
            }
            func final(_ id: Int64?) -> Int64? { var i = id; while let c = i, let n = remap[c] { i = n }; return i }
            var visits = fresh.map { Visit(start: $0.start, end: $0.end, placeId: final($0.placeId)) }
            if !remap.isEmpty {
                visits += try diary.visits(from: .distantPast, to: .distantFuture).filter { $0.placeId.map { remap[$0] != nil } ?? false }
                    .map { Visit(start: $0.start, end: $0.end, placeId: final($0.placeId)) }
            }
            try diary.saveLearned(places: changed, removing: Array(Set(places.map(\.id)).subtracting(changed.map(\.id))),
                                  visits: visits, meta: "placesProcessedUntil", String(settled.next.timeIntervalSince1970))
            places = changed
            if isLast || settled.next <= cursor { break }
            cursor = settled.next
        }
        let ids = Set(places.map(\.id))
        return (learned, ids.subtracting(initial).count, initial.subtracting(ids).count, places)
    }

    static func execute(_ diary: Diary) async {
        let r: (visits: Int, new: Int, merged: Int, places: [Place])
        do { r = try run(diary) }
        catch is CancellationError { return }
        catch { await MainActor.run { Recorder.shared.log("places", "failed"); Recorder.shared.flush() }; return }
        await MainActor.run {
            shared.places = r.places
            Recorder.shared.log("places", "visits=\(r.visits) new=\(r.new) merged=\(r.merged)"); Recorder.shared.flush()
            if r.visits > 0 { NotificationCenter.default.post(name: changed, object: nil) }
        }
    }
}
