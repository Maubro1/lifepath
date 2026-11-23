import Core
import SwiftUI

/// The map's less frequent options: how your lines are coloured, and the map style.
struct LayersSheet: View {
    @Binding var colour: LineColour
    @Binding var satellite: Bool
    @Binding var period: TimeFilter
    @Binding var showSlow: Bool
    @Binding var showFast: Bool
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
                    if colour == .speed {
                        // One side always stays on, so the map never goes blank by accident.
                        Toggle("Top speed under 40 km/h", isOn: $showSlow).disabled(showSlow && !showFast)
                        Toggle("Top speed 40 km/h and over", isOn: $showFast).disabled(showFast && !showSlow)
                    }
                } header: { Text("Your lines") } footer: {
                    if colour == .speed {
                        Text("A trip's top speed is the fastest it went for 15 seconds. Walks and bike rides stay under 40 km/h; trains and most car and bus trips go over, though a slow trip through town can stay under.")
                    }
                }
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
        if colour == .date {
            HStack(spacing: 10) {   // the whole age range as one bar, sampled from the same ramp the lines use
                Text("Newest").font(.footnote).foregroundStyle(Color.ink)
                LinearGradient(colors: stride(from: 0.0, through: 1, by: 0.125).map { f in
                    let r = Palette.dateRamp(f); return Color(UIColor(Hex(light: r.light, dark: r.dark)))
                }, startPoint: .leading, endPoint: .trailing)
                .frame(height: 12)
                .clipShape(.capsule)
                Text("Oldest").font(.footnote).foregroundStyle(Color.ink)
            }
            .frame(minHeight: 32)
        }
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
