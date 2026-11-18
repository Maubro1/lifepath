import Core
import SwiftUI

/// The map's less frequent options: how your lines are coloured, and the map style.
struct LayersSheet: View {
    @Binding var colour: LineColour
    @Binding var satellite: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Colour lines by", selection: $colour) {
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
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var legend: some View {
        if colour == .date { HStack { swatch(Palette.mustard, "Newest"); swatch(Palette.satsuma, "Middle"); swatch(Palette.cherry, "Oldest") } }
    }

    private func swatch(_ h: Hex, _ label: String) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(Color(UIColor(h))).frame(width: 12, height: 12)
            Text(label).font(.footnote).foregroundStyle(Color.ink)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background(Color.inset, in: .rect(cornerRadius: 3))
    }
}
