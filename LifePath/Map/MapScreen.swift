import Core
import Diary
import MapKit
import SwiftUI

struct MapLine: Sendable {
    var key: String           // trip start, segment, rough flag, tolerance and a content hash: equal keys draw the same line
    var rough: Bool           // a stretch of rough fixes, drawn thin and dashed
    var coords: [(lat: Double, lon: Double)]
    var speeds: [Double]      // per coord, unknowns filled with the trip median
    var locations: [Double]   // per coord, 0...1 along the line, for the speed gradient
    var dateFraction: Double  // trip start within the time range
}

struct MapData: Sendable {
    var generation: Int
    var lines: [MapLine] = []
    var heat: [HeatCell: TimeInterval] = [:]
    var still: [(lat: Double, lon: Double)] = []
    var places: [Place] = []                    // pins visible at the end of the range, in the visible region
    var outlines: [Int64: Set<PlaceCell>] = [:] // their regions, at street zoom only
}

enum TimeFilter: String, CaseIterable {
    case today = "Today", week = "Week", month = "Month", year = "Year", all = "All", custom = "Custom"
}

struct MapOptions: Equatable {
    var filter = TimeFilter.today
    var customFrom = Date()
    var customTo = Date()
    var heat = false
    var recorded = false

    func range(now: Date) -> (from: Date, to: Date) {
        let cal = Calendar.current, today = cal.startOfDay(for: now)
        switch filter {
        case .today: return (today, now)
        case .week: return (cal.date(byAdding: .day, value: -6, to: today)!, now)
        case .month: return (cal.date(byAdding: .month, value: -1, to: today)!, now)
        case .year: return (cal.date(byAdding: .year, value: -1, to: today)!, now)
        case .all: return (.distantPast, now)
        case .custom:
            let a = cal.startOfDay(for: min(customFrom, customTo)), b = cal.startOfDay(for: max(customFrom, customTo))
            return (a, cal.date(byAdding: .day, value: 1, to: b)!)
        }
    }
}

/// Loads lines and heat for the visible region, off the main actor, only while the map is on screen.
@MainActor @Observable final class MapLoader {
    var options = MapOptions()
    private(set) var data: MapData?
    @ObservationIgnored private var region: MKCoordinateRegion?
    @ObservationIgnored private var width = 0.0
    @ObservationIgnored private var active = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastLoad = Date.distantPast
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    private struct Query: Sendable {
        var minLat, maxLat, minLon, maxLon, tolerance: Double
        var from, to: Date
        var heat, recorded, street, zoomedOut: Bool
        var places: [Place]   // in memory, refreshed by each places run; the loader never reads them per pan
    }

    private nonisolated static let budget = 400_000   // vertices per load and points per read chunk: memory guards that coarsen, never drop a trip

    func setActive(_ on: Bool) {
        active = on
        if on { reload() } else { task?.cancel(); task = nil; liveTask?.cancel(); liveTask = nil }
    }

    /// New points were saved: redraw at most every 15 s, only while on screen.
    func pointsSaved() {
        guard active, liveTask == nil else { return }
        let wait = max(0, 15 - Date().timeIntervalSince(lastLoad))
        liveTask = Task {
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            liveTask = nil
            reload()
        }
    }

    func regionChanged(_ r: MKCoordinateRegion, width w: Double) {
        region = r; width = w
        reload(debounce: true)
    }

    func reload(debounce: Bool = false) {
        task?.cancel()
        guard active, let r = region, width > 0 else { return }
        lastLoad = Date()
        let c = r.center, range = options.range(now: Date())
        let metresPerPoint = r.span.longitudeDelta * 111_320 * cos(c.latitude * .pi / 180) / width
        // shortcut: no antimeridian wrap; fine unless the owner maps across 180°
        let q = Query(minLat: max(-90, c.latitude - r.span.latitudeDelta * 0.6), maxLat: min(90, c.latitude + r.span.latitudeDelta * 0.6),
                      minLon: c.longitude - r.span.longitudeDelta * 0.6, maxLon: c.longitude + r.span.longitudeDelta * 0.6,
                      tolerance: Simplify.step(2 * metresPerPoint),
                      from: range.from, to: range.to, heat: options.heat, recorded: options.recorded,
                      street: r.span.latitudeDelta * 111_000 < 2000, zoomedOut: metresPerPoint > 7.5, places: PlaceService.shared.places)   // half the cache's 15 m tolerance per screen point
        generation += 1
        let gen = generation
        task = Task {
            if debounce { do { try await Task.sleep(for: .milliseconds(300)) } catch { return } }
            guard let diary = Recorder.shared.readDiary else { return }   // locked before first unlock
            let work = Task.detached(priority: .userInitiated) { try MapLoader.load(diary, q, generation: gen) }
            let result = await withTaskCancellationHandler { try? await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let result else { return }
            data = result
        }
    }

    private nonisolated static func load(_ diary: Diary, _ q: Query, generation: Int) throws -> MapData {
        var out = MapData(generation: generation)
        var trips: [(coords: [(lat: Double, lon: Double)], speeds: [Double], start: Date, segment: Int, rough: Bool)] = []
        var after = q.from.addingTimeInterval(-0.001)   // reads are `t > after`: keep a point exactly at `from`
        // Zoomed out, trips up to the cache's end come from the trip-line cache (smoothed lines only); points resume where those trips end, never mid-trip.
        if q.zoomedOut, !q.recorded, let until = try diary.tripLinesUntil() {
            let cached = try diary.tripLines(minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon, from: q.from, to: min(until, q.to))
            // shortcut: cached lines carry no rough flag and draw solid; upgrade when stage 3 stores rail-matched lines
            trips = cached.map { (coords: $0.coords.map { (lat: $0.lat, lon: $0.lon) }, speeds: MapColors.filledSpeeds($0.coords.map(\.speed)), start: $0.start, segment: 0, rough: false) }
            after = max(after, min(until, q.to), cached.map(\.end).max() ?? after)
        }
        let tripsAfter = after
        if q.heat { after = q.from.addingTimeInterval(-0.001) }   // dwell over the whole range
        var ways: [Int64: Way]?   // streets of the visible box, read once on the first trip that has matches
        func add(_ split: [Trip]) throws {
            for trip in split {
                try Task.checkCancellation()
                var coords = trip.points.map { (lat: $0.lat, lon: $0.lon) }
                if !q.recorded {
                    let smooth = try diary.smoothed(from: trip.start, to: trip.end)
                    let byT = Dictionary(smooth.map { ($0.t, (lat: $0.lat, lon: $0.lon)) }, uniquingKeysWith: { a, _ in a })
                    for (i, p) in trip.points.enumerated() where p.kind != .rough { if let s = byT[p.t] { coords[i] = s } }   // rough points stay raw
                }
                var speeds = MapColors.filledSpeeds(trip.points.map(\.speed))
                var rough = trip.points.map { $0.kind == .rough }
                if !q.recorded {
                    let stretches = try diary.matches(tripStart: trip.start).filter { $0.confidence >= MapMatcher.confident }
                    if !stretches.isEmpty, ways == nil {
                        let all = try diary.ways(minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon)
                        ways = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    }
                    // Confident stretches draw along their street, rail or ferry line, solid even when the fixes were rough; vertices borrow the nearest fix's speed.
                    var nc: [(lat: Double, lon: Double)] = [], ns: [Double] = [], nr: [Bool] = [], next = 0
                    // Stretches are timed, not indexed: this trip's points were read in a box and chunks, so only a stretch whose end points are both here applies.
                    let at = Dictionary(trip.points.enumerated().map { ($1.t, $0) }, uniquingKeysWith: { a, _ in a })
                    for m in stretches {
                        guard let first = at[m.start], let last = at[m.end], first >= next, first <= last, let way = ways?[m.wayId] else { continue }
                        nc += coords[next..<first]; ns += speeds[next..<first]; nr += rough[next..<first]
                        var j = first   // vertices run in travel order, so the nearest fix only moves forward
                        for v in way.slice(fromM: m.fromM, toM: m.toM) {
                            while j < last, Geo.distance(v.lat, v.lon, coords[j + 1].lat, coords[j + 1].lon) < Geo.distance(v.lat, v.lon, coords[j].lat, coords[j].lon) { j += 1 }
                            nc.append(v); ns.append(speeds[j]); nr.append(false)
                        }
                        next = last + 1
                    }
                    if next > 0 { nc += coords[next...]; ns += speeds[next...]; nr += rough[next...]; coords = nc; speeds = ns; rough = nr }
                }
                // Runs of rough and precise points become separate lines; a rough run takes its precise neighbours, so every edge touching a rough point is dashed.
                var first = 0, segment = 0
                while first < rough.count {
                    var e = first
                    while e < rough.count, rough[e] == rough[first] { e += 1 }
                    let run = rough[first] ? max(0, first - 1)..<min(rough.count, e + 1) : first..<e
                    if run.count > 1 || rough.count == 1 {
                        let c = Array(coords[run]), sp = Array(speeds[run])
                        let keep = Simplify.douglasPeucker(c, tolerance: q.tolerance)   // keep only the drawn shape: memory follows the output
                        trips.append((coords: keep.map { c[$0] }, speeds: keep.map { sp[$0] }, start: trip.start, segment: segment, rough: rough[first]))
                    }
                    first = e; segment += 1
                }
            }
        }
        // Every point in range, oldest first, one chunk at a time; the open trip carries across chunk edges.
        var carry: [FilteredPoint] = [], previous: FilteredPoint?
        while true {
            try Task.checkCancellation()
            let chunk = try diary.points(minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon, after: after, to: q.to, limit: budget)
            if q.heat { out.heat.merge(Heat.grid(chunk, previous: previous), uniquingKeysWith: +); previous = chunk.last ?? previous }
            try add(Trips.split(chunk: chunk.filter { $0.t > tripsAfter }, carry: &carry))
            guard chunk.count == budget, let last = chunk.last else { break }
            after = last.t
        }
        try add(Trips.split(carry))
        // Pins as they stood at the end of the range: a past period shows the pins of that time.
        out.places = q.places.filter { p in
            guard p.isVisible(at: q.to), let pin = p.pin else { return false }
            return (q.minLat...q.maxLat).contains(pin.lat) && (q.minLon...q.maxLon).contains(pin.lon)
        }
        if q.street { for p in out.places { out.outlines[p.id] = p.region() } }
        if q.street {
            let cell = 0.000225   // ~25 m of latitude: one dot per place, not one per check-in
            out.still = try diary.stillPoints(minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon, from: q.from, to: q.to,
                                              cell: cell, lonCell: cell / cos((q.minLat + q.maxLat) / 2 * .pi / 180))
        }
        let lo = q.from == .distantPast ? (trips.map(\.start).min() ?? q.to) : q.from
        let span = max(1, q.to.timeIntervalSince(lo))
        try Task.checkCancellation()
        for (trip, keep) in zip(trips, Simplify.fit(trips.map(\.coords), tolerance: q.tolerance, budget: budget)) {
            let coords = trip.coords
            var along = [0.0]
            for (a, b) in zip(keep, keep.dropFirst()) {
                along.append(along[along.count - 1] + Geo.distance(coords[a].lat, coords[a].lon, coords[b].lat, coords[b].lon))
            }
            let total = along[along.count - 1]
            let fraction = trip.start.timeIntervalSince(lo) / span
            var h = Hasher()   // content and colour: a grown or re-smoothed line gets a new key
            for i in keep { h.combine(coords[i].lat); h.combine(coords[i].lon); h.combine(trip.speeds[i]) }
            h.combine(Int(fraction * 64))   // shortcut: date colour in 64 steps, so a live reload keeps old lines; finer only if steps show
            out.lines.append(MapLine(key: "\(trip.start.timeIntervalSince1970)-\(trip.segment)\(trip.rough ? "r" : "")-\(q.tolerance)-\(h.finalize())",
                                     rough: trip.rough,
                                     coords: keep.map { coords[$0] }, speeds: keep.map { trip.speeds[$0] },
                                     locations: along.enumerated().map { total > 0 ? $1 / total : Double($0) / Double(max(1, keep.count - 1)) },
                                     dateFraction: fraction))
        }
        return out
    }
}

struct MapScreen: View {
    @State private var loader = MapLoader()
    @State private var bySpeed = false
    @State private var satellite = false
    @State private var onScreen = false
    @State private var choosingDates = false
    @State private var openPlace: Place?
    @Environment(\.scenePhase) private var scenePhase

    private var visible: Bool { onScreen && scenePhase == .active }

    var body: some View {
        TrackMapView(data: loader.data, bySpeed: bySpeed, satellite: satellite, visible: visible) { region, width in
            loader.regionChanged(region, width: width)
        } onPlace: { id in openPlace = loader.data?.places.first { $0.id == id } }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .bottom) { controls }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: visible, initial: true) { _, v in loader.setActive(v) }
        .onChange(of: loader.options) { loader.reload() }
        .onReceive(NotificationCenter.default.publisher(for: SmoothingService.linesChanged)) { _ in loader.reload() }   // no-op unless visible
        .onReceive(NotificationCenter.default.publisher(for: PlaceService.changed)) { _ in loader.reload() }
        .onReceive(NotificationCenter.default.publisher(for: Recorder.pointsSaved)) { _ in loader.pointsSaved() }   // no-op unless visible
        .sheet(item: $openPlace, onDismiss: { loader.reload() }) { PlaceSheet(place: $0) }
        .onChange(of: loader.options.filter) { _, f in if f == .custom { choosingDates = true } }
        .sheet(isPresented: $choosingDates) { dates }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Time range", selection: $loader.options.filter) {
                ForEach(TimeFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Time range")
            HStack {
                Picker("Colour lines by", selection: $bySpeed) {
                    Text("Date").tag(false)
                    Text("Speed").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Colour lines by")
                Picker("Map style", selection: $satellite) {
                    Text("Standard").tag(false)
                    Text("Satellite").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Map style")
            }
            HStack {
                Toggle("Heat", isOn: $loader.options.heat)
                    .accessibilityLabel("Heat map")
                Toggle("Recorded line", isOn: $loader.options.recorded)
                    .accessibilityLabel("Recorded line")
                    .accessibilityHint("Shows the line as recorded instead of smoothed")
                if loader.options.filter == .custom {
                    Button("Dates") { choosingDates = true }
                        .accessibilityLabel("Choose custom dates")
                }
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .padding(8)
    }

    private var dates: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $loader.options.customFrom, displayedComponents: .date)
                    .accessibilityLabel("From date")
                DatePicker("To", selection: $loader.options.customTo, displayedComponents: .date)
                    .accessibilityLabel("To date")
            }
            .navigationTitle("Custom range")
            .toolbar { Button("Done") { choosingDates = false }.accessibilityLabel("Done choosing dates") }
        }
        .presentationDetents([.medium])
    }
}
