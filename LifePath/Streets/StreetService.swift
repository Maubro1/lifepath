import Core
import Diary
import Foundation

/// Fetches OpenStreetMap ways around smoothed trips and matches each trip to them. Runs at the end of each smoothing run,
/// so only while the app is open or the phone is charging.
enum StreetService {
    private static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    private struct Remark: Decodable { var remark: String? }   // Overpass reports a server timeout as a remark beside partial data

    static func run(_ diary: Diary) async {
        let detail: String
        do { detail = try await work(diary) }
        catch is CancellationError { return }
        catch { detail = "failed" }
        await MainActor.run { Recorder.shared.log("streets", detail); Recorder.shared.flush() }
    }

    /// Trips in time order, each matched whole once all its tiles are stored, so a cancel leaves a clean prefix.
    /// The first trip still missing a tile while downloads are off or backing off ends the run; it is the cursor's next start.
    private static func work(_ diary: Diary) async throws -> String {
        let defaults = UserDefaults.standard
        let download = defaults.object(forKey: "downloadStreets") as? Bool ?? true
        let cellular = defaults.object(forKey: "streetsOnCellular") as? Bool ?? true
        // A new matcher version re-matches all history once: the cursor restarts at 0 and the version is stored at once,
        // so an interrupted re-match resumes where it stopped.
        let rematch = try diary.meta("matcherVersion") != String(MapMatcher.version)
        if rematch { try diary.setMeta("streetsUntil", "0"); try diary.setMeta("matcherVersion", String(MapMatcher.version)) }
        // The last matched trip is matched again: the next smoothing run may have extended it.
        let from: Date = try rematch ? .distantPast
            : diary.meta("streetsUntil").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        var backoff = try diary.meta("streetsBackoff").flatMap(TimeInterval.init) ?? 0
        var retryAt = try diary.meta("streetsRetryAt").flatMap(TimeInterval.init) ?? 0
        var tiles = 0, matched = 0, waiting = false
        let session = download ? makeSession(cellular: cellular) : nil
        defer { session?.finishTasksAndInvalidate() }

        trips: for line in try diary.tripLines(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, from: from, to: .distantFuture) {
            try Task.checkCancellation()
            // shortcut: a trip re-cut with a new start leaves its old matches as an unread cache row, upgrade if the diary grows from it
            guard let trip = try Trips.split(diary.points(from: line.start, to: line.end)).first(where: { $0.start == line.start }) else { continue }
            // Tiles along the path within the matcher's candidate radius, not the whole box: a long diagonal ride would need thousands.
            var needed = Set<Tile>()
            for p in trip.points {
                let r = p.kind == .rough ? min(p.hAcc, 1500) : min(max(30, 2 * p.hAcc), 1500)
                let dLat = r / 111_320, dLon = r / (111_320 * cos(p.lat * .pi / 180))
                let a = Tile(lat: p.lat - dLat, lon: p.lon - dLon), b = Tile(lat: p.lat + dLat, lon: p.lon + dLon)
                for x in a.x...b.x { for y in a.y...b.y { needed.insert(Tile(x: x, y: y)) } }
            }
            for tile in try needed.filter({ try !diary.hasTile($0, version: OSM.version) }).sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
                guard let session, Date().timeIntervalSince1970 >= retryAt else { waiting = true; break trips }
                let fetched: (ways: [Way], stops: [Stop])
                do { fetched = try await fetch(tile, session) } catch {
                    if Task.isCancelled { throw CancellationError() }
                    // No usable network (offline, or only mobile data while it is not allowed): skip quietly, the next run tries again.
                    if let e = error as? URLError, [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(e.code) {
                        waiting = true; break trips
                    }
                    // Any failure waits, remembered across launches: 60 s, doubling to 30 min.
                    backoff = min(max(60, backoff * 2), 1800)
                    retryAt = Date().timeIntervalSince1970 + backoff
                    try diary.setMeta("streetsBackoff", String(backoff))
                    try diary.setMeta("streetsRetryAt", String(retryAt))
                    // shortcut: a tile that always fails (too dense for 60 s) holds back every later trip, upgrade to skipping it after a few tries if the log shows it
                    waiting = true; break trips
                }
                try diary.saveTile(tile, ways: fetched.ways, stops: fetched.stops, version: OSM.version)
                tiles += 1
                if backoff > 0 { backoff = 0; try diary.setMeta("streetsBackoff", "0") }
            }
            // Ways overlapping the trip's tiles, which already reach the candidate radius past every point.
            var byId: [Int64: Way] = [:]
            for tile in needed {
                let b = tile.bounds
                for w in try diary.ways(minLat: b.minLat, maxLat: b.maxLat, minLon: b.minLon, maxLon: b.maxLon) { byId[w.id] = w }
            }
            // Rough fixes match only rail, tram and ferry, so a trip of nothing else needs no streets in its graph.
            let roughOnly = !trip.points.contains { $0.kind != .rough && $0.kind != .still }
            let kinds: Set<WayKind> = roughOnly ? [.rail, .tram, .ferry] : [.foot, .road, .rail, .tram, .ferry]
            let graph = RoadGraph(ways: byId.values.filter { kinds.contains($0.kind) }.sorted { $0.id < $1.id })
            try diary.saveMatches(tripStart: trip.start, MapMatcher.match(trip.points, graph: graph), modes: [])   // modes from Task 5
            try diary.setMeta("streetsUntil", String(trip.start.timeIntervalSince1970))
            matched += 1
        }
        if matched > 0 { await MainActor.run { NotificationCenter.default.post(name: SmoothingService.linesChanged, object: nil) } }   // the map redraws on the matched streets
        return "tiles=\(tiles) matched=\(matched)" + (waiting ? " waiting" : "")
    }

    /// Only a map rectangle leaves the phone: no cookies, no cache, nothing but the User-Agent.
    private static func makeSession(cellular: Bool) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.allowsCellularAccess = cellular
        c.waitsForConnectivity = false         // no usable network fails at once and is skipped quietly, no waiting radio
        c.timeoutIntervalForRequest = 90       // Overpass may queue before its own 60 s
        c.timeoutIntervalForResource = 180     // a stalled download counts as a failure and backs off
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        c.httpAdditionalHeaders = ["User-Agent": "LifePath/\(version) (personal location diary)"]
        return URLSession(configuration: c)
    }

    private static func fetch(_ tile: Tile, _ session: URLSession) async throws -> (ways: [Way], stops: [Stop]) {
        let b = tile.bounds
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        let query = OSM.query(minLat: b.minLat, minLon: b.minLon, maxLat: b.maxLat, maxLon: b.maxLon)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"   // the rectangle travels in the body, not the URL
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(("data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")).utf8)
        let (data, response) = try await session.data(for: request)
        // Not 200 (429, 504, ...) or a partial answer: nothing is stored, so a tile is never half-saved.
        guard (response as? HTTPURLResponse)?.statusCode == 200, try JSONDecoder().decode(Remark.self, from: data).remark == nil else {
            throw URLError(.badServerResponse)
        }
        return try OSM.parse(data)
    }
}
