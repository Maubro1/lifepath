import Core
import MapKit
import SwiftUI

/// A city's progress in big digits, then each of its neighbourhoods with a bar; tapping one flies the map there.
struct PlaceCard: View {
    let cityId: Int64
    let fly: (MKMapRect) -> Void
    @State private var city: (area: Area, share: Double, counts: AreaProgress?)?
    @State private var parts: [(area: Area, share: Double)] = []
    @AppStorage("countCycling") private var countCycling = false

    var body: some View {
        NavigationStack {
            List {
                if let city {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(city.share.formatted(.percent.precision(.fractionLength(0))))
                                .font(.display(56, relativeTo: .largeTitle))
                                .foregroundStyle(Color.satsuma)
                            Text(countCycling ? "of streets walked or cycled" : "of streets walked").foregroundStyle(Color.muted)
                            if let p = city.counts {
                                Text("\(p.covered.formatted()) of \(p.total.formatted()) streets · a street counts once you have covered 90% of it")
                                    .font(.footnote).foregroundStyle(Color.muted)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Section("Neighbourhoods") {
                        ForEach(parts, id: \.area.id) { p in
                            Button { fly(rect(p.area)) } label: { row(p.area.name, p.share) }
                                .accessibilityHint("Shows it on the map")
                        }
                    }
                }
            }
            .navigationTitle(city?.area.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func row(_ name: String, _ share: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).foregroundStyle(Color.ink)
                Spacer()
                Text(share.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(Color.muted)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.inset)
                    Rectangle().fill(Color.satsuma).frame(width: g.size.width * share)
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private func rect(_ a: Area) -> MKMapRect {
        let b = a.bounds
        return mapRect([(b.minLat, b.minLon), (b.maxLat, b.maxLon)], pad: 0)
    }

    private func load() async {
        guard let diary = Recorder.shared.readDiary else { return }
        let id = cityId, bike = countCycling
        let read = await Task.detached(priority: .userInitiated) { () -> ((Area, Double, AreaProgress?), [(Area, Double)])? in
            guard let progress = try? Dictionary(diary.areaProgress(bike: bike).map { ($0.areaId, $0) }, uniquingKeysWith: { a, _ in a }),
                  let all = try? diary.areas(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180),
                  let city = all.first(where: { $0.id == id }) else { return nil }
            func share(_ a: Area) -> Double { progress[a.id].map { $0.total > 0 ? Double($0.covered) / Double($0.total) : 0 } ?? 0 }
            // Neighbourhoods with streets whose first corner lies in this city, best first.
            let inCity = all.filter { a in
                a.level > 8 && progress[a.id] != nil && Areas.locate(lat: a.rings[0][0].lat, lon: a.rings[0][0].lon, in: [city]).city != nil
            }
            // An area holding finer ones only keeps the streets left over between them: list the finer ones.
            let parts = inCity.filter { a in !inCity.contains { $0.id != a.id && a.contains(lat: $0.rings[0][0].lat, lon: $0.rings[0][0].lon) } }
            return ((city, share(city), progress[city.id]), parts.map { ($0, share($0)) }.sorted { $0.1 > $1.1 })
        }.value
        guard let read else { return }
        city = (read.0.0, read.0.1, read.0.2)
        parts = read.1.map { (area: $0.0, share: $0.1) }
    }
}
