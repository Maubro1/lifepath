import Core
import Diary
import Foundation

/// A made-up week in a small grid town near Utrecht, for screenshots of every screen (`-demo` launch argument).
/// Nothing is recorded in demo mode and the real diary is never opened.
enum DemoData {
    static var active: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    /// The value after a launch argument, e.g. `-screen you`.
    static func argument(_ name: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }

    /// Look variant for comparing screenshots (`-variant 2`); 1 is the shipped look.
    static let variant = argument("-variant").flatMap(Int.init) ?? 1

    static let origin = (lat: 52.0860, lon: 5.1640)   // Utrecht Science Park area
    static func at(_ north: Double, _ east: Double) -> (lat: Double, lon: Double) {
        Geo.offset(lat: origin.lat, lon: origin.lon, north: north, east: east)
    }

    /// A fresh diary in the temporary folder filled with a week of data.
    static func make(now: Date = Date()) throws -> Diary {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).sqlite").path
        let diary = try Diary(path: path)
        let cal = Calendar.current, today = cal.startOfDay(for: now)

        // Streets: a 9 x 9 grid, 150 m apart, each street one way; the inner ones walked.
        var ways: [Way] = [], node: Int64 = 1
        for i in 0..<9 {
            for (id, horizontal) in [(Int64(100 + i), true), (Int64(200 + i), false)] {
                let coords = (0...8).map { k in horizontal ? at(Double(i) * 150, Double(k) * 150) : at(Double(k) * 150, Double(i) * 150) }
                ways.append(Way(id: id, kind: .road, name: "\(horizontal ? "Laan" : "Straat") \(i + 1)", oneway: false,
                                nodes: (0...8).map { _ in defer { node += 1 }; return node }, coords: coords))
            }
        }
        let rail = Way(id: 900, kind: .rail, name: nil, oneway: false, nodes: [9001, 9002], coords: [at(-400, -3000), at(-400, 4000)], countable: false)
        try diary.saveTile(Tile(lat: origin.lat, lon: origin.lon), ways: ways + [rail],
                           stops: [Stop(id: 1, kind: .rail, lat: at(-400, 0).lat, lon: at(-400, 0).lon)], version: OSM.version)
        let walked = ways.filter { [102, 103, 104, 105, 203, 204, 205, 206].contains($0.id) }
        try diary.saveCoverage(CoverageResult(ways: Dictionary(uniqueKeysWithValues: walked.map { ($0.id, false) }),
                                              onFoot: walked.count, withBike: walked.count, total: ways.count))

        // Borders: the town and two neighbourhoods.
        func square(_ id: Int64, _ level: Int, _ name: String, _ s: Double, _ w: Double, _ n: Double, _ e: Double) -> Area {
            Area(id: id, level: level, name: name, rings: [[at(s, w), at(s, e), at(n, e), at(n, w), at(s, w)]], holes: [])
        }
        try diary.saveAreas([square(1, 8, "Utrecht", -600, -3200, 1500, 4200), square(2, 10, "Science Park", -100, -100, 1300, 650),
                             square(3, 10, "Rijnsweerd", -100, 650, 1300, 1300)], tile: Tile(lat: origin.lat, lon: origin.lon))
        try diary.saveProgress([AreaProgress(areaId: 1, covered: 8, total: 18), AreaProgress(areaId: 2, covered: 7, total: 11),
                                AreaProgress(areaId: 3, covered: 1, total: 7)], covered: Dictionary(uniqueKeysWithValues: walked.map {
                                    (String($0.id), today.addingTimeInterval(9 * 3600)) }), bike: false)

        // Seven days: a morning walk along the walked streets, some days a train ride, a stay at home and at work.
        let home = at(150, 150), work = at(1050, 600)
        var points: [FilteredPoint] = [], lines: [TripLine] = [], days: [DaySummary] = [], steps: [DaySteps] = [], visits: [Visit] = []
        for d in 0..<7 {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            let start = day.addingTimeInterval(8.5 * 3600)
            let route = [home, at(300, 150), at(300, 600), at(750, 600), at(1050, 600)]
            var trip: [FilteredPoint] = [], t = start
            for (a, b) in zip(route, route.dropFirst()) {
                let n = Int(Geo.distance(a.lat, a.lon, b.lat, b.lon) / 7)
                for k in 0..<n {
                    let f = Double(k) / Double(n), wobble = sin(Double(k) * 0.7) * 0.00002
                    trip.append(FilteredPoint(t: t, lat: a.lat + (b.lat - a.lat) * f + wobble, lon: a.lon + (b.lon - a.lon) * f,
                                              rawLat: a.lat, rawLon: a.lon, hAcc: 6, speed: 1.4, kind: .moving))
                    t += 5
                }
            }
            // An evening walk down one side street; the four streets repeat, so some are walked once and some twice.
            let east = Double([0, 3, 5, 7][d % 4]) * 150, eve = day.addingTimeInterval(19 * 3600)
            let side = (0..<170).map { k in
                let p = at(Double(k) * 7, east + sin(Double(k) * 0.7) * 2)
                return FilteredPoint(t: eve + Double(k) * 5, lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon, hAcc: 6, speed: 1.4, kind: .moving)
            }
            points += side
            try diary.saveMatches(tripStart: eve, [], modes: [ModeStretch(seq: 0, mode: .walk, confidence: 0.9, start: eve, end: side.last!.t)])
            lines.append(TripLine(start: eve, end: side.last!.t, minLat: side.first!.lat, maxLat: side.last!.lat, minLon: side.first!.lon,
                                  maxLon: side.first!.lon, distance: 1190, coords: side.map { ($0.lat, $0.lon, 1.4) }))
            if d % 2 == 0 {   // a train ride along the rail in the afternoon
                let ride = day.addingTimeInterval(15 * 3600)
                trip += (0..<60).map { k in
                    let p = at(-400 + sin(Double(k) / 6) * 12, -3000 + Double(k) * 110)
                    return FilteredPoint(t: ride + Double(k) * 10, lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon, hAcc: 180, speed: 22, kind: .rough)
                }
            }
            points += trip
            var modes = [ModeStretch(seq: 0, mode: .walk, confidence: 0.9, start: start, end: trip.filter { $0.kind == .moving }.last!.t)]
            if let ride = trip.first(where: { $0.kind == .rough })?.t {
                modes.append(ModeStretch(seq: 1, mode: .train, confidence: 0.9, start: ride, end: trip.last!.t))
            }
            try diary.saveMatches(tripStart: start, [], modes: modes)
            let walkEnd = trip.filter { $0.kind == .moving }.last!.t
            lines.append(TripLine(start: start, end: walkEnd, minLat: home.lat, maxLat: work.lat, minLon: home.lon, maxLon: work.lon,
                                  distance: 1500, coords: trip.filter { $0.kind == .moving }.map { ($0.lat, $0.lon, 1.4) }))
            visits += [Visit(start: day, end: start, placeId: 1), Visit(start: walkEnd, end: day.addingTimeInterval(14.5 * 3600), placeId: 2)]
            let key = day.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            days.append(DaySummary(day: key, distance: d % 2 == 0 ? 8_100 : 1_500, movingTime: d % 2 == 0 ? 1_900 : 1_100, walked: 1_500, points: trip.count))
            steps.append(DaySteps(day: key, steps: 4_000 + d * 900, distance: 1_500, floorsUp: 3))
        }
        try diary.append(points.sorted { $0.t < $1.t })
        try diary.saveTripLines(lines.sorted { $0.start < $1.start }, replacingFrom: .distantPast)
        try diary.saveDays(days, from: "0000-00-00")
        try diary.saveSteps(steps)
        let place = { (id: Int64, name: String, p: (lat: Double, lon: Double)) in
            Place(id: id, name: name, cells: [PlaceGrid.cell(lat: p.lat, lon: p.lon): 30 * 3600], updatedAt: now, lastVisit: now,
                  totalSeconds: 30 * 3600, visits: 7, isCandidate: false, realDays: Set(0..<7))
        }
        try diary.savePlaces([place(1, "Home", home), place(2, "Work", work)], removing: [])
        try diary.saveVisits(visits)
        return diary
    }
}
