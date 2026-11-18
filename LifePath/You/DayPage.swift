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
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("countCycling") private var countCycling = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    AppNav.shared.showDay = day
                    AppNav.shared.tab = 0
                } label: {
                    ZStack {
                        Rectangle().fill(Color.inset)
                        if let picture { Image(uiImage: picture).resizable().scaledToFill() }
                    }
                    .frame(height: 220)
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
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
                    .padding(16)
                    .background(Color.card, in: .rect(cornerRadius: 22, style: .continuous))
                }
                Text("The day").font(.display(22, relativeTo: .title2)).foregroundStyle(Color.ink).padding(.top, 8)
                if story.isEmpty {
                    Text("Nothing recorded").font(.subheadline).foregroundStyle(Color.muted)
                } else {
                    // The places of the day on a line; the line between two places is the trip (shown on the map above).
                    VStack(spacing: 0) {
                        ForEach(Array(story.enumerated()), id: \.offset) { i, item in row(item, first: i == 0, last: i == story.count - 1) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.card, in: .rect(cornerRadius: 22, style: .continuous))
                }
            }
            .padding(16)
        }
        .background(Color.page)
        .navigationTitle(Format.dayTitle(day))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("Delete this day", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } label: { Image(systemName: "ellipsis") }
            .accessibilityLabel("More")
        }
        .confirmationDialog("Delete \(DeletePeriodSheet.label(day, day))?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { _ = await DeleteData.days(day, day); dismiss() } }
        } message: {
            Text("Everything recorded on this day goes: its lines, places you stayed, steps. This cannot be undone.")
        }
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

    /// One stop on the timeline: icon on the line, a title, and its times or distance below.
    private func entry(icon: String, tint: Color, title: String, first: Bool, last: Bool, @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Rectangle().fill(first ? Color.clear : Color.inset).frame(width: 2, height: 10)
                Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                    .frame(width: 30, height: 30).background(Color.inset, in: .circle)
                Rectangle().fill(last ? Color.clear : Color.inset).frame(width: 2).frame(maxHeight: .infinity)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Color.ink)
                detail().font(.subheadline.monospacedDigit()).foregroundStyle(Color.muted)
            }
            .padding(.top, 14).padding(.bottom, 12)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func row(_ item: StoryItem, first: Bool, last: Bool) -> some View {
        switch item {
        case let .stay(name, placeId, start, end):
            Button {
                renaming = placeId.flatMap { id in PlaceService.shared.places.first { $0.id == id } }
            } label: {
                entry(icon: "mappin", tint: Color.satsuma, title: name, first: first, last: last) { Text(span(start, end)) }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(placeId == nil)
            .accessibilityHint(placeId == nil ? "" : "Rename this place")
        case .trip:
            EmptyView()   // trips are not listed as text: the map shows them
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
        story = read.1.filter { if case .stay = $0 { true } else { false } }
        facts = (read.2.0, read.2.1, read.2.2, read.2.3)
        picture = await DaySnapshot.image(key: day.formatted(.iso8601.year().month().day()), lines: lines, dark: scheme == .dark,
                                          size: CGSize(width: 360, height: 220))
    }
}
