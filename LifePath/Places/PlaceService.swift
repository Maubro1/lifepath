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
        // shortcut: a first build reads history a month at a time; a still run spanning a month edge is judged by the next chunk.
        while true {
            try Task.checkCancellation()
            guard let first = try diary.points(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, after: cursor.addingTimeInterval(-0.001), to: now, limit: 1).first else { break }
            let to = first.t.addingTimeInterval(chunk)
            let isLast = to >= now
            let pts = try diary.points(from: first.t, to: min(to, now))
            let stored = Set(try diary.visits(from: first.t, to: min(to, now)).map(\.start))
            var next = pts[pts.count - 1].t   // everything up to here is settled unless an open run holds it back
            var fresh: [Visit] = [], remap: [Int64: Int64] = [:], changed = places
            for v in Places.visits(from: pts) {
                try Task.checkCancellation()
                if v.points.last!.t == pts[pts.count - 1].t, isLast ? now.timeIntervalSince(v.end) <= gap : true {   // open: nothing after it ends it
                    next = v.start; break
                }
                guard !stored.contains(v.start) else { continue }
                let before = Set(changed.map(\.id))
                let r = Places.learn(changed, visit: v, now: now, nextId: nextId)
                nextId = max(nextId, (r.places.map(\.id).max() ?? 0) + 1)
                for gone in before.subtracting(r.places.map(\.id)) { remap[gone] = r.visit.placeId }   // a merge always lands in the visit's place
                changed = r.places; fresh.append(r.visit); learned += 1
            }
            if !fresh.isEmpty {
                let removing = Set(places.map(\.id)).subtracting(changed.map(\.id))
                try diary.savePlaces(changed, removing: Array(removing))
                var moved: [Visit] = []
                if !remap.isEmpty {
                    moved = try diary.visits(from: .distantPast, to: .distantFuture).compactMap { v in
                        guard let p = v.placeId, let s = remap[p] else { return nil }
                        return Visit(start: v.start, end: v.end, placeId: s)
                    }
                }
                try diary.saveVisits(fresh + moved)
                places = changed
            }
            try diary.setMeta("placesProcessedUntil", String(next.timeIntervalSince1970))
            if isLast || next <= cursor { break }
            cursor = next
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
