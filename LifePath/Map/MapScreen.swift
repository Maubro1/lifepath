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
    var capped = false
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
        var heat, recorded, street: Bool
    }

    private nonisolated static let cap = 200_000

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
        // shortcut: no antimeridian wrap; fine unless the owner maps across 180°
        let q = Query(minLat: max(-90, c.latitude - r.span.latitudeDelta * 0.6), maxLat: min(90, c.latitude + r.span.latitudeDelta * 0.6),
                      minLon: c.longitude - r.span.longitudeDelta * 0.6, maxLon: c.longitude + r.span.longitudeDelta * 0.6,
                      tolerance: max(3, 2 * r.span.longitudeDelta * 111_320 * cos(c.latitude * .pi / 180) / width),
                      from: range.from, to: range.to, heat: options.heat, recorded: options.recorded,
                      street: r.span.latitudeDelta * 111_000 < 2000)
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
        var pts = try diary.points(minLat: q.minLat, maxLat: q.maxLat, minLon: q.minLon, maxLon: q.maxLon, from: q.from, to: q.to, limit: cap + 1)
        var out = MapData(generation: generation, capped: pts.count > cap)
        if out.capped { pts.removeFirst() }   // cap + 1 fetched only to detect the cap; keep the most recent
        try Task.checkCancellation()
        if q.heat { out.heat = Heat.grid(pts) }
        if q.street {
            var seen = Set<HeatCell>()   // one dot per ~25 m cell, not one per check-in
            out.still = pts.filter { $0.kind == .still && seen.insert(Heat.cell(lat: $0.lat, lon: $0.lon)).inserted }.map { ($0.lat, $0.lon) }
        }
        let trips = Trips.split(pts)
        let lo = q.from == .distantPast ? (trips.first?.start ?? q.to) : q.from
        let span = max(1, q.to.timeIntervalSince(lo))
        for trip in trips {
            try Task.checkCancellation()
            var coords = trip.points.map { (lat: $0.lat, lon: $0.lon) }
            if !q.recorded {
                let smooth = try diary.smoothed(from: trip.start, to: trip.end)
                let byT = Dictionary(smooth.map { ($0.t, (lat: $0.lat, lon: $0.lon)) }, uniquingKeysWith: { a, _ in a })
                for (i, p) in trip.points.enumerated() { if let s = byT[p.t] { coords[i] = s } }
            }
            let speeds = MapColors.filledSpeeds(trip.points.map(\.speed))
            let keep = Simplify.douglasPeucker(coords, tolerance: q.tolerance)
            var along = [0.0]
            for (a, b) in zip(keep, keep.dropFirst()) {
                along.append(along[along.count - 1] + Geo.distance(coords[a].lat, coords[a].lon, coords[b].lat, coords[b].lon))
            }
            let total = along[along.count - 1]
            out.lines.append(MapLine(coords: keep.map { coords[$0] }, speeds: keep.map { speeds[$0] },
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
            if loader.data?.capped == true { Text("Zoom in to see all lines").font(.footnote) }
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
