import Core
import Diary
import MapKit
import SwiftUI

enum LineColour: String, CaseIterable { case plain = "One colour", date = "By age", speed = "By speed" }

/// What the map shows filling up: walked streets lit, or fog cleared where you have been.
enum MapMode: String, CaseIterable {
    case streets = "Streets", fog = "Fog", heat = "Heat"
    var symbol: String { switch self { case .streets: "road.lanes"; case .fog: "cloud.fog"; case .heat: "flame" } }
}

struct MapLine: Sendable {
    var key: String           // trip start, segment, rough flag, tolerance and a content hash: equal keys draw the same line
    var rough: Bool           // a stretch of rough fixes, drawn thin and dashed
    var coords: [(lat: Double, lon: Double)]
    var speeds: [Double]      // per coord, unknowns filled with the trip median
    var modes: [TravelMode?]  // per coord; nil: unsure or unknown
    var locations: [Double]   // per coord, 0...1 along the line, for the speed gradient
    var dateFraction: Double  // trip start within the time range
    var importance: [Double] = []   // Visvalingam area per coord (m²): drawn when above the screen's pixel², so shapes never jump
}

struct MapData: Sendable {
    var generation: Int
    var lines: [MapLine] = []
    var heatLines: [(key: String, coords: [(lat: Double, lon: Double)])] = []   // every cached trip in the region, in Heat mode
    var heatPlaces: [(lat: Double, lon: Double, hours: Double)] = []
    var heatMax = 0.0                                                           // passes through the busiest cell at this zoom
    var places: [Place] = []                    // pins visible at the end of the range, in the visible region
    var outlines: [Int64: Set<PlaceCell>] = [:] // their regions, at street zoom only
    var fog: [(key: String, stroke: FogStroke)] = []   // what clears the fog, in Fog mode
    var fogFills: [FogFill] = []                       // closed pockets narrower than a walk's band, cleared whole
    var here: Here?                                    // the area under the map centre, for the place chip
    var today: (distance: Double, steps: Int?, newStreets: Int)?
    var walked: (covered: Int, total: Int)?     // the tally; nil before the first coverage run
    var bike = false                            // whether the tally counted cycling
}

/// The neighbourhood (or city) under the map centre and its progress.
struct Here: Sendable, Equatable {
    var name: String
    var cityId: Int64
    var covered: Int, total: Int
    var share: Double { total > 0 ? Double(covered) / Double(total) : 0 }
}

enum TimeFilter: String, CaseIterable {
    case today = "Today", week = "Week", month = "Month", year = "Year", all = "All", custom = "Custom", off = "Off"
}

struct MapOptions: Equatable {
    var filter = TimeFilter.today
    var customFrom = Date()
    var customTo = Date()
    var recorded = false
    var mode = MapMode.streets
    var slowTrips = true, fastTrips = true   // by top speed (`TripLines.topSpeed`) under / from 40 km/h, in every map mode

    func range(now: Date) -> (from: Date, to: Date) {
        let cal = Calendar.current, today = cal.startOfDay(for: now)
        switch filter {
        case .today: return (today, now)
        case .week: return (cal.date(byAdding: .day, value: -6, to: today)!, now)
        case .month: return (cal.date(byAdding: .month, value: -1, to: today)!, now)
        case .year: return (cal.date(byAdding: .year, value: -1, to: today)!, now)
        case .all: return (.distantPast, now)
        case .off: return (now, now)
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
        var minLat, maxLat, minLon, maxLon: Double
        var from, to: Date
        var recorded, street, zoomedOut: Bool   // in the order the call passes them
        var mode: MapMode
        var bike: Bool
        var metresPerPoint: Double
        var centerLat, centerLon: Double
        var places: [Place]   // in memory, refreshed by each places run; the loader never reads them per pan
        var slow = true, fast = true

        /// A trip shows when its side of 40 km/h is on; an unknown top speed (-1) always shows.
        func keep(_ topSpeed: Double) -> Bool { topSpeed < 0 || (topSpeed < 40 / 3.6 ? slow : fast) }
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
                      from: range.from, to: range.to, recorded: options.recorded,
                      street: r.span.latitudeDelta * 111_000 < 2000, zoomedOut: metresPerPoint > 7.5,
                      mode: options.mode, bike: UserDefaults.standard.bool(forKey: "countCycling"), metresPerPoint: metresPerPoint, centerLat: c.latitude, centerLon: c.longitude,
                      places: PlaceService.shared.places, slow: options.slowTrips, fast: options.fastTrips)   // half the cache's 15 m tolerance per screen point
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
        let modesByTrip = q.mode == .fog ? try diary.modes(from: q.from, to: q.to) : [:]   // one read for every trip in range
        var trips: [(coords: [(lat: Double, lon: Double)], speeds: [Double], modes: [TravelMode?], start: Date, segment: Int, rough: Bool)] = []
        var after = q.from.addingTimeInterval(-0.001)   // reads are `t > after`: keep a point exactly at `from`
        // Trips up to the cache's end come from the trip-line cache (snapped, 3 m detail) at every zoom, so a line is the same data
        // whatever the zoom; points resume where those trips end, never mid-trip.
        if !q.recorded, let until = try diary.tripLinesUntil() {
            let cached = try diary.tripLines(minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon, from: q.from, to: min(until, q.to))
            // shortcut: cached lines carry no rough flag and draw solid; upgrade when stage 3 stores rail-matched lines
            // Cached lines are simplified, so a point has no index in the trip: the whole line takes the trip's longest confident mode.
            trips = try cached.filter { q.keep($0.topSpeed) }.map { c in
                let mode = MapColors.dominantMode(modesByTrip[c.start] ?? [])
                return (coords: c.coords.map { (lat: $0.lat, lon: $0.lon) }, speeds: MapColors.filledSpeeds(c.coords.map(\.speed)),
                        modes: [TravelMode?](repeating: mode, count: c.coords.count), start: c.start, segment: 0, rough: false)
            }
            after = max(after, min(until, q.to), cached.map(\.end).max() ?? after)
        }
        let tripsAfter = after
        var ways: [Int64: Way] = [:]   // the streets confident stretches use, each read once
        func add(_ split: [Trip]) throws {
            for trip in split {
                try Task.checkCancellation()
                // shortcut: a trip not yet cached is judged on the points read in this region; the cache judges the whole trip
                guard q.keep(TripLines.topSpeed(trip.points)) else { continue }
                var coords = trip.points.map { (lat: $0.lat, lon: $0.lon) }
                if !q.recorded {
                    let smooth = try diary.smoothed(from: trip.start, to: trip.end)
                    let byT = Dictionary(smooth.map { ($0.t, (lat: $0.lat, lon: $0.lon)) }, uniquingKeysWith: { a, _ in a })
                    for (i, p) in trip.points.enumerated() where p.kind != .rough { if let s = byT[p.t] { coords[i] = s } }   // rough points stay raw
                }
                var speeds = MapColors.filledSpeeds(trip.points.map(\.speed))
                var rough = trip.points.map { $0.kind == .rough }
                var modes = MapColors.pointModes(modesByTrip[trip.start] ?? [], times: trip.points.map(\.t))   // the trip's, recorded or matched
                if !q.recorded {
                    let stretches = try diary.matches(tripStart: trip.start).filter { $0.confidence >= MapMatcher.confident }
                    let missing = Set(stretches.map(\.wayId)).filter { ways[$0] == nil }
                    if !missing.isEmpty { for w in try diary.ways(ids: Array(missing)) { ways[w.id] = w } }
                    // Confident stretches draw along their street, rail or ferry line, solid even when the fixes were rough; vertices borrow the nearest fix's speed.
                    var nc: [(lat: Double, lon: Double)] = [], ns: [Double] = [], nm: [TravelMode?] = [], nr: [Bool] = [], next = 0
                    // Stretches are timed, not indexed: this trip's points were read in a box and chunks, so only a stretch whose end points are both here applies.
                    let at = Dictionary(trip.points.enumerated().map { ($1.t, $0) }, uniquingKeysWith: { a, _ in a })
                    for m in stretches {
                        guard let first = at[m.start], let last = at[m.end], first >= next, first <= last, let way = ways[m.wayId] else { continue }
                        nc += coords[next..<first]; ns += speeds[next..<first]; nm += modes[next..<first]; nr += rough[next..<first]
                        var j = first   // vertices run in travel order, so the nearest fix only moves forward
                        for v in way.slice(fromM: m.fromM, toM: m.toM) {
                            while j < last, Geo.distance(v.lat, v.lon, coords[j + 1].lat, coords[j + 1].lon) < Geo.distance(v.lat, v.lon, coords[j].lat, coords[j].lon) { j += 1 }
                            nc.append(v); ns.append(speeds[j]); nm.append(modes[j]); nr.append(false)
                        }
                        next = last + 1
                    }
                    if next > 0 { nc += coords[next...]; ns += speeds[next...]; nm += modes[next...]; nr += rough[next...]; coords = nc; speeds = ns; modes = nm; rough = nr }
                }
                // Runs of rough and precise points become separate lines; a rough run takes its precise neighbours, so every edge touching a rough point is dashed.
                var first = 0, segment = 0
                while first < rough.count {
                    var e = first
                    while e < rough.count, rough[e] == rough[first] { e += 1 }
                    let run = rough[first] ? max(0, first - 1)..<min(rough.count, e + 1) : first..<e
                    if run.count > 1 || rough.count == 1 {
                        let c = Array(coords[run]), sp = Array(speeds[run]), md = Array(modes[run])
                        let keep = Simplify.douglasPeucker(c, tolerance: TripLines.tolerance)   // fixed detail, never by zoom
                        trips.append((coords: keep.map { c[$0] }, speeds: keep.map { sp[$0] }, modes: keep.map { md[$0] }, start: trip.start, segment: segment, rough: rough[first]))
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
        out.bike = q.bike
        out.walked = try diary.streetsWalked(bike: q.bike)
        let progress = Dictionary(try diary.areaProgress(bike: q.bike).map { ($0.areaId, $0) }, uniquingKeysWith: { a, _ in a })
        let found = Areas.locate(lat: q.centerLat, lon: q.centerLon,
                                 in: try diary.areas(minLat: q.centerLat, maxLat: q.centerLat, minLon: q.centerLon, maxLon: q.centerLon))
        if let city = found.city, let a = found.neighbourhood, let p = progress[a.id] ?? progress[city.id] {
            out.here = Here(name: progress[a.id] != nil ? a.name : city.name, cityId: city.id, covered: p.covered, total: p.total)
        }
        let start = Calendar.current.startOfDay(for: Date())
        let key = Days.key(Date(), .current)
        let day = try diary.days().first { $0.summary.day == key }
        out.today = (day?.summary.distance ?? 0, day?.steps, try diary.newStreets(from: start, to: .distantFuture, bike: q.bike))
        if q.mode == .heat {
            // Heat: every cached trip in the region, all time; the busiest cell (4 screen points) sets the scale at this zoom.
            let cached = try diary.tripLines(minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon, from: .distantPast, to: q.to)
            let cell = 4 * q.metresPerPoint, k = cos((q.minLat + q.maxLat) / 2 * .pi / 180)
            var passes: [Int64: Double] = [:]
            for l in cached {
                guard q.keep(l.topSpeed) else { continue }   // the top-speed choice holds in Heat too
                var seen = Set<Int64>()
                for (a, b) in zip(l.coords, l.coords.dropFirst()) {
                    let n = max(1, Int(Geo.distance(a.lat, a.lon, b.lat, b.lon) / cell * 2))
                    for i in 0...n {
                        let f = Double(i) / Double(n), lat = a.lat + (b.lat - a.lat) * f, lon = a.lon + (b.lon - a.lon) * f
                        seen.insert(Int64((lat * 111_320 / cell).rounded(.down)) << 32 | Int64((lon * 111_320 * k / cell).rounded(.down)) & 0xFFFF_FFFF)
                    }
                }
                for c in seen { passes[c, default: 0] += 1 }
                let c = l.coords.map { (lat: $0.lat, lon: $0.lon) }
                out.heatLines.append(("h\(l.start.timeIntervalSince1970)", Simplify.douglasPeucker(c, tolerance: q.metresPerPoint / 2).map { c[$0] }))
            }
            out.heatMax = passes.values.max() ?? 0
            out.heatPlaces = q.places.compactMap { p in p.pin.map { (lat: $0.lat, lon: $0.lon, hours: p.totalSeconds / 3600) } }
        } else if q.mode == .fog {
            // Fog: every cached trip line in the region, all time, plus this period's lines so a trip clears at once.
            let cached = try diary.tripLines(minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon, from: .distantPast, to: q.to)
            let modes = cached.isEmpty ? [:] : try diary.modes(from: cached.map(\.start).min()!, to: q.to)
            for l in cached where q.keep(l.topSpeed) {   // the top-speed choice holds in Fog too
                for (i, st) in Fog.strokes(line: l, modes: modes[l.start] ?? []).enumerated() {
                    // Thinned to half a screen point at this zoom: invisible under the soft fog edge, far lighter to draw.
                    let keep = Simplify.douglasPeucker(st.coords, tolerance: q.metresPerPoint / 2)
                    out.fog.append(("c\(l.start.timeIntervalSince1970)-\(i)", FogStroke(coords: keep.map { st.coords[$0] }, halfWidth: st.halfWidth)))
                }
            }
            for st in Fog.circles(places: q.places) { out.fog.append(("p\(st.coords[0].lat),\(st.coords[0].lon)", st)) }
        }
        // All time ages from the diary's first trip, not the first one in view: a key holds the age, so a per-view origin would
        // re-key every line on each pan and make the map redraw all of them.
        let lo = q.from == .distantPast ? (try diary.tripLinesSince() ?? trips.map(\.start).min() ?? q.to) : q.from
        let span = max(1, q.to.timeIntervalSince(lo))
        try Task.checkCancellation()
        // shortcut: past the vertex budget lines are thinned by Douglas–Peucker, which can change shapes; upgrade to a global Visvalingam cut if huge ranges show it
        for (trip, keep) in zip(trips, Simplify.fit(trips.map(\.coords), tolerance: 0, budget: budget)) {
            let coords = trip.coords
            var along = [0.0]
            for (a, b) in zip(keep, keep.dropFirst()) {
                along.append(along[along.count - 1] + Geo.distance(coords[a].lat, coords[a].lon, coords[b].lat, coords[b].lon))
            }
            let total = along[along.count - 1]
            let fraction = trip.start.timeIntervalSince(lo) / span
            var h = Hasher()   // content and colour: a grown or re-smoothed line gets a new key
            for i in keep { h.combine(coords[i].lat); h.combine(coords[i].lon); h.combine(trip.speeds[i]); h.combine(trip.modes[i]) }
            h.combine(Int(fraction * 64))   // shortcut: date colour in 64 steps, so a live reload keeps old lines; finer only if steps show
            out.lines.append(MapLine(key: "\(trip.start.timeIntervalSince1970)-\(trip.segment)\(trip.rough ? "r" : "")-\(h.finalize())",
                                     rough: trip.rough,
                                     coords: keep.map { coords[$0] }, speeds: keep.map { trip.speeds[$0] }, modes: keep.map { trip.modes[$0] },
                                     locations: along.enumerated().map { total > 0 ? $1 / total : Double($0) / Double(max(1, keep.count - 1)) },
                                     dateFraction: fraction, importance: Simplify.visvalingam(keep.map { coords[$0] })))
        }
        if q.mode == .fog {
            for l in out.lines where l.coords.count > 1 {
                var a = 0
                func width(_ m: TravelMode?) -> Double {
                    switch m { case .walk?, .run?, .bike?: Fog.onFoot; case .train?, .boat?: 0; default: Fog.road }
                }
                for b in 1..<l.coords.count where b == l.coords.count - 1 || width(l.modes[b]) != width(l.modes[a]) {
                    let w = width(l.modes[a]), run = Array(l.coords[a...b])
                    out.fog += w > 0 ? [("l\(l.key)-\(a)", FogStroke(coords: run, halfWidth: w))] : []
                    a = b
                }
            }
        }
        if q.mode == .fog {
            try Task.checkCancellation()
            out.fogFills = Fog.enclosedGaps(out.fog.map(\.stroke), minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon)
        }
        return out
    }
}

struct MapScreen: View {
    @State private var loader = MapLoader()
    @AppStorage("recordedLine") private var recordedLine = false
    @AppStorage("lineColour") private var colour = LineColour.plain
    @AppStorage("mapMode") private var mode = MapMode.streets
    @AppStorage("satellite") private var satellite = false
    @AppStorage("showSlowTrips") private var showSlow = true
    @AppStorage("showFastTrips") private var showFast = true
    @State private var onScreen = false
    @State private var choosingDates = false
    @State private var choosingLayers = false
    @State private var openPlace: Place?
    @State private var openCity: CityRef?
    @State private var target: MKMapRect?
    @State private var openToday = false
    @AppStorage("countCycling") private var countCycling = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme

    private var visible: Bool { onScreen && scenePhase == .active }

    @State private var panelHeight: CGFloat = 0

    var body: some View {
        ZStack {   // the map alone runs full screen; the controls on this stack keep to the safe area
        TrackMapView(data: loader.data, mode: mode, colour: colour, dark: scheme == .dark, satellite: satellite,
                     visible: visible, onRegion: { region, width in loader.regionChanged(region, width: width) },
                     onPlace: { id in openPlace = loader.data?.places.first { $0.id == id } },
                     target: target, onLayers: { choosingLayers = true }, bottomInset: panelHeight + 8)
        .ignoresSafeArea()   // behind the status bar and the tab bar
        }
        .overlay(alignment: .topLeading) { chip }
        .overlay(alignment: .bottom) { bottom.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 } }
        .onAppear { onScreen = true; if DemoData.argument("-layers") != nil { choosingLayers = true } }   // screenshots of the panel
        .onDisappear { onScreen = false }
        .onChange(of: visible, initial: true) { _, v in loader.setActive(v) }
        .onChange(of: mode, initial: true) { _, m in loader.options.mode = m }
        .onChange(of: loader.options) { loader.reload() }
        .onChange(of: recordedLine, initial: true) { _, r in loader.options.recorded = r }
        .onChange(of: [showSlow, showFast], initial: true) { _, v in   // lines, Fog and Heat alike
            loader.options.slowTrips = v[0]; loader.options.fastTrips = v[1]
        }
        .onChange(of: countCycling) { loader.reload() }
        .onReceive(NotificationCenter.default.publisher(for: SmoothingService.linesChanged)) { _ in loader.reload() }   // no-op unless visible
        .onReceive(NotificationCenter.default.publisher(for: PlaceService.changed)) { _ in loader.reload() }
        .onReceive(NotificationCenter.default.publisher(for: Recorder.pointsSaved)) { _ in loader.pointsSaved() }   // no-op unless visible
        .sheet(item: $openPlace, onDismiss: { loader.reload() }) { PlaceSheet(place: $0) }
        .sheet(item: $openCity) { ref in PlaceCard(cityId: ref.id) { rect in openCity = nil; target = rect } }
        .sheet(isPresented: $choosingLayers) {
            LayersSheet(colour: $colour, satellite: $satellite, period: $loader.options.filter, showSlow: $showSlow, showFast: $showFast,
                        chooseDates: { choosingLayers = false; choosingDates = true })
        }
        .onChange(of: loader.options.filter) { _, f in if f == .custom { choosingDates = true } }
        .sheet(isPresented: $choosingDates) { dates }
        .sheet(isPresented: $openToday) { NavigationStack { DayPage(day: Calendar.current.startOfDay(for: Date())) } }
        .onChange(of: AppNav.shared.showDay) { _, day in
            // A day page asked to show its day: that day alone, framed on its lines.
            guard let day else { return }
            AppNav.shared.showDay = nil
            openToday = false
            loader.options.customFrom = day; loader.options.customTo = day; loader.options.filter = .custom
            guard let diary = Recorder.shared.readDiary else { return }
            let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
            Task {
                let lines = await Task.detached(priority: .userInitiated) { (try? diary.tripLines(from: day, to: end)) ?? [] }.value
                let coords = lines.flatMap { $0.coords.map { (lat: $0.lat, lon: $0.lon) } }
                if !coords.isEmpty { target = mapRect(coords, pad: 200) }
            }
        }
    }

    /// Top left: the area under the map centre and how much of it is walked.
    @ViewBuilder private var chip: some View {
        if let h = loader.data?.here {
            Button { openCity = CityRef(id: h.cityId) } label: {
                HStack(spacing: 6) {
                    Text(h.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(h.share.formatted(.percent.precision(.fractionLength(0))))
                        .font(.display(17, relativeTo: .headline))
                        .foregroundStyle(Color.satsuma)
                        .contentTransition(.numericText(value: h.share))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ink)
            .animation(.snappy, value: h)
            .padding(.leading, 8)
            .padding(.top, 8)
            .accessibilityLabel("\(h.name), \(Int((h.share * 100).rounded())) percent of streets walked")
            .accessibilityHint("Shows progress per neighbourhood")
        }
    }

    /// Bottom: Streets or Fog, the period of your lines, and today in one line.
    private var bottom: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Map", selection: $mode) {
                ForEach(MapMode.allCases, id: \.self) { m in Label(m.rawValue, systemImage: m.symbol).tag(m) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Show streets walked, fog or heat")
            if let t = loader.data?.today {
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    stat(Format.distance(t.distance), "today")
                    if let steps = t.steps { stat(steps.formatted(), "steps") }
                    if t.newStreets > 0 { stat("+\(t.newStreets)", t.newStreets == 1 ? "new street" : "new streets", accent: true) }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.muted)
                }
                .accessibilityElement(children: .combine)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityLabel("Today")
                .accessibilityHint("Opens today")
                .accessibilityAddTraits(.isButton)
                .contentShape(.rect)
                .onTapGesture { openToday = true }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// A number over its caption, as in the You tab's facts.
    private func stat(_ value: String, _ caption: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.display(20, relativeTo: .title3)).foregroundStyle(accent ? Color.satsuma : Color.ink)
                .monospacedDigit().lineLimit(1)
            Text(caption).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
        }
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

/// A city to open in a place card.
struct CityRef: Identifiable { var id: Int64 }
