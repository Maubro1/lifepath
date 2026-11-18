import Core
import Diary
import SwiftUI

/// One day: its map, its numbers, and the day told as stays and trips.
struct DayPage: View {
    let day: Date
    @State private var lines: [[(lat: Double, lon: Double)]] = []
    @State private var story: [StoryItem] = []
    @State private var facts: (distance: Double, moving: TimeInterval, steps: Int?, new: Int)?
    @State private var picture: UIImage?
    @State private var renaming: Place?
    @AppStorage("countCycling") private var countCycling = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        List {
            Section {
                Button {
                    AppNav.shared.showDay = day
                    AppNav.shared.tab = 0
                } label: {
                    ZStack {
                        Rectangle().fill(Color.inset)
                        if let picture { Image(uiImage: picture).resizable().scaledToFill() }
                    }
                    .frame(height: 220)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Map of this day")
                .accessibilityHint("Shows this day on the map")
                if let f = facts {
                    HStack(alignment: .top, spacing: 0) {
                        fact(Format.distance(f.distance), "moved")
                        fact(Format.duration(f.moving), "moving")
                        if let s = f.steps { fact(s.formatted(), "steps") }
                        fact("+\(f.new)", "new streets", accent: f.new > 0)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            Section("The day") {
                if story.isEmpty { Text("Nothing recorded").foregroundStyle(Color.muted) }
                ForEach(Array(story.enumerated()), id: \.offset) { _, item in row(item) }
            }
        }
        .navigationTitle(Format.dayTitle(day))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scheme) { await load() }
        .sheet(item: $renaming, onDismiss: { Task { await load() } }) { PlaceSheet(place: $0) }
    }

    private func fact(_ value: String, _ caption: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(20, relativeTo: .title3)).foregroundStyle(accent ? Color.satsuma : Color.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.caption).foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func row(_ item: StoryItem) -> some View {
        switch item {
        case let .stay(name, placeId, start, end):
            Button {
                renaming = placeId.flatMap { id in PlaceService.shared.places.first { $0.id == id } }
            } label: {
                HStack {
                    Text(name).font(.headline).foregroundStyle(Color.ink)
                    Spacer()
                    Text(span(start, end)).font(.subheadline.monospaced()).foregroundStyle(Color.muted)
                }
            }
            .buttonStyle(.plain)
            .disabled(placeId == nil)
            .accessibilityHint(placeId == nil ? "" : "Rename this place")
        case let .trip(mode, start, end, distance):
            HStack(spacing: 10) {
                // Modes stay internal: a walk or a trip, nothing more specific.
                let walk = mode == .walk || mode == .run
                Image(systemName: walk ? "figure.walk" : "arrow.triangle.swap").foregroundStyle(walk ? Color.satsuma : Color.muted).frame(width: 18)
                Text(walk ? "Walk" : "Trip").foregroundStyle(Color.ink)
                Spacer()
                Text("\(Format.duration(end.timeIntervalSince(start))) · \(Format.distance(distance))")
                    .font(.subheadline.monospaced()).foregroundStyle(Color.muted)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func span(_ a: Date, _ b: Date) -> String {
        "\(a.formatted(date: .omitted, time: .shortened)) – \(b.formatted(date: .omitted, time: .shortened))"
    }

    private func load() async {
        guard let diary = Recorder.shared.readDiary else { return }
        let day = day, bike = countCycling, places = PlaceService.shared.places
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let read = await Task.detached(priority: .userInitiated) { () -> ([TripLine], [StoryItem], (Double, TimeInterval, Int?, Int))? in
            guard let lines = try? diary.tripLines(from: day, to: end), let visits = try? diary.visits(from: day, to: end) else { return nil }
            let modes = ((try? diary.modes(from: day, to: end)) ?? [:]).values.flatMap { $0 }
            let story = DayStory.build(day: day, visits: visits, places: places, modes: modes, lines: lines) { lat, lon in
                // The nearest named street within about 60 m, from the downloaded street maps only.
                let near = (try? diary.ways(minLat: lat - 0.0006, maxLat: lat + 0.0006, minLon: lon - 0.001, maxLon: lon + 0.001)) ?? []
                return near.filter { $0.name != nil && $0.countable }
                    .min { a, b in
                        a.coords.map { Geo.distance(lat, lon, $0.lat, $0.lon) }.min()! < b.coords.map { Geo.distance(lat, lon, $0.lat, $0.lon) }.min()!
                    }?.name
            }
            let key = day.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            let summary = (try? diary.days())?.first { $0.summary.day == key }
            let new = (try? diary.newStreets(from: day, to: end, bike: bike)) ?? 0
            return (lines, story, (summary?.summary.distance ?? 0, summary?.summary.movingTime ?? 0, summary?.steps, new))
        }.value
        guard let read else { return }
        lines = read.0.map { $0.coords.map { (lat: $0.lat, lon: $0.lon) } }
        story = read.1
        facts = (read.2.0, read.2.1, read.2.2, read.2.3)
        picture = await DaySnapshot.image(key: day.formatted(.iso8601.year().month().day()), lines: lines, dark: scheme == .dark,
                                          size: CGSize(width: 360, height: 220))
    }
}
