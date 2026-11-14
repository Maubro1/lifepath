import Core
import Diary
import MapKit
import SwiftUI

struct MapLine: Sendable {
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

    private struct Query: Sendable {
        var minLat, maxLat, minLon, maxLon, tolerance: Double
        var from, to: Date
        var heat, recorded, street, zoomedOut: Bool
    }

    private nonisolated static let budget = 400_000   // points and vertices per load: a memory guard that coarsens, never drops a trip

    func setActive(_ on: Bool) {
        active = on
        if on { reload() } else { task?.cancel(); task = nil }
    }

    func regionChanged(_ r: MKCoordinateRegion, width w: Double) {
        region = r; width = w
        reload(debounce: true)
    }

    func reload(debounce: Bool = false) {
        task?.cancel()
        guard active, let r = region, width > 0 else { return }
        let c = r.center, range = options.range(now: Date())
        let metresPerPoint = r.span.longitudeDelta * 111_320 * cos(c.latitude * .pi / 180) / width
        // shortcut: no antimeridian wrap; fine unless the owner maps across 180°
        let q = Query(minLat: max(-90, c.latitude - r.span.latitudeDelta * 0.6), maxLat: min(90, c.latitude + r.span.latitudeDelta * 0.6),
                      minLon: c.longitude - r.span.longitudeDelta * 0.6, maxLon: c.longitude + r.span.longitudeDelta * 0.6,
                      tolerance: max(3, 2 * metresPerPoint),
                      from: range.from, to: range.to, heat: options.heat, recorded: options.recorded,
                      street: r.span.latitudeDelta * 111_000 < 2000, zoomedOut: metresPerPoint > 2)
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
        func fetch(_ from: Date) throws -> [FilteredPoint] {
            try diary.points(minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon, from: from, to: q.to, limit: budget + 1)
        }
        // Over budget: an even time sample of the whole range (never only the newest), coarsened until it fits.
        func even(_ from: Date, _ newest: [FilteredPoint]) throws -> (pts: [FilteredPoint], stride: TimeInterval) {
            guard newest.count > budget else { return (newest, 0) }
            var stride = max(1, newest[budget].t.timeIntervalSince(newest[0].t) / Double(budget)), pts: [FilteredPoint]
            repeat {
                try Task.checkCancellation()
                stride *= 2
                pts = try diary.points(minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon, from: from, to: q.to, every: stride, limit: budget + 1)
            } while pts.count > budget
            return (pts, stride)
        }
        let until = q.recorded ? nil : try diary.tripLinesUntil()   // the cache holds smoothed lines only
        // Trips up to `cacheTo` come from the trip-line cache, the rest from full points.
        var cacheTo = q.zoomedOut ? until : nil
        let from = max(q.from, cacheTo ?? q.from)
        var pts = try fetch(from), stride: TimeInterval = 0
        if pts.count > budget, let u = until, u >= pts[1].t {
            pts.removeFirst()
            cacheTo = pts[0].t   // older trips drawn from the cache: every one still shown
        } else {
            (pts, stride) = try even(from, pts)   // only while the cache has not caught up
        }
        try Task.checkCancellation()
        if q.heat { out.heat = try Heat.grid(from == q.from && cacheTo == nil ? pts : even(q.from, fetch(q.from)).pts) }   // dwell over the whole range
        if q.street {
            var seen = Set<HeatCell>()   // one dot per ~25 m cell, not one per check-in
            out.still = pts.filter { $0.kind == .still && seen.insert(Heat.cell(lat: $0.lat, lon: $0.lon)).inserted }.map { ($0.lat, $0.lon) }
        }
        var trips: [(coords: [(lat: Double, lon: Double)], speeds: [Double], start: Date)] = []
        if let c = cacheTo {
            trips = try diary.tripLines(minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon, from: q.from, to: c).map {
                (coords: $0.coords.map { (lat: $0.lat, lon: $0.lon) }, speeds: MapColors.filledSpeeds($0.coords.map(\.speed)), start: $0.start)
            }
        }
        // A coarse sample spaces fixes `stride` apart, so gap and jump limits widen with it (straighter lines, no lost trips).
        for trip in Trips.split(cacheTo.map { c in pts.filter { $0.t > c } } ?? pts, maxGap: max(600, 2 * stride), maxJump: max(500, 50 * stride)) {
            try Task.checkCancellation()
            var coords = trip.points.map { (lat: $0.lat, lon: $0.lon) }
            if !q.recorded {
                let smooth = try diary.smoothed(from: trip.start, to: trip.end)
                let byT = Dictionary(smooth.map { ($0.t, (lat: $0.lat, lon: $0.lon)) }, uniquingKeysWith: { a, _ in a })
                for (i, p) in trip.points.enumerated() { if let s = byT[p.t] { coords[i] = s } }
            }
            trips.append((coords: coords, speeds: MapColors.filledSpeeds(trip.points.map(\.speed)), start: trip.start))
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
            out.lines.append(MapLine(coords: keep.map { coords[$0] }, speeds: keep.map { trip.speeds[$0] },
                                     locations: along.enumerated().map { total > 0 ? $1 / total : Double($0) / Double(max(1, keep.count - 1)) },
                                     dateFraction: trip.start.timeIntervalSince(lo) / span))
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
    @Environment(\.scenePhase) private var scenePhase

    private var visible: Bool { onScreen && scenePhase == .active }

    var body: some View {
        TrackMapView(data: loader.data, bySpeed: bySpeed, satellite: satellite, visible: visible) { region, width in
            loader.regionChanged(region, width: width)
        }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .bottom) { controls }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: visible, initial: true) { _, v in loader.setActive(v) }
        .onChange(of: loader.options) { loader.reload() }
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
