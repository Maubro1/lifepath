import Core
import SwiftUI

/// The map's less frequent options: how your lines are coloured, and the map style.
struct LayersSheet: View {
    @Binding var colour: LineColour
    @Binding var satellite: Bool
    @Binding var period: TimeFilter
    var chooseDates: () -> Void

    var body: some View {
        NavigationStack {
            Form { Group {
                Section {
                    Picker("Show", selection: $period) {
                        ForEach(TimeFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if period == .custom { Button("Choose dates", action: chooseDates) }
                    Picker("Colour", selection: $colour) {
                        ForEach(LineColour.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    legend
                } header: { Text("Your lines") }
                Section("Map") {
                    Picker("Map style", selection: $satellite) {
                        Text("Standard").tag(false)
                        Text("Satellite").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                }
                .listRowBackground(Color.card)   // paper cards, as everywhere in LifePath
            }
            .scrollContentBackground(.hidden)
            .background(Color.page)
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var legend: some View {
        if colour == .date { HStack { swatch(Palette.mustard, "Newest"); swatch(Palette.satsuma, "Middle"); swatch(Palette.cherry, "Oldest") } }
        if colour == .speed {
            HStack {   // the unit once, so four swatches fit a phone's width
                ForEach([5.0, 25, 80, 160], id: \.self) { k in swatch(ramp(k), k == 160 ? "160+" : "\(Int(k))") }
                Text("km/h").font(.footnote).foregroundStyle(Color.muted)
            }
        }
    }

    private func ramp(_ kmh: Double) -> Hex { let r = Palette.speedRamp(kmh); return Hex(light: r.light, dark: r.dark) }

    private func swatch(_ h: Hex, _ label: String) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(Color(UIColor(h))).frame(width: 12, height: 12)
            Text(label).font(.footnote).foregroundStyle(Color.ink)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background(Color.inset, in: .rect(cornerRadius: 12, style: .continuous))
    }
}
