import Core
import SwiftUI

/// The map's less frequent options: line colouring with its legend (whose chips also filter), map style and heat.
struct LayersSheet: View {
    @Binding var colour: LineColour
    @Binding var hiddenModes: String
    @Binding var satellite: Bool
    @Binding var heat: Bool

    private var hidden: Set<String> { Set(hiddenModes.split(separator: ",").map(String.init)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Colour lines by", selection: $colour) {
                        ForEach(LineColour.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    legend
                } header: { Text("Your lines") } footer: {
                    if colour == .mode { Text("Tap a travel mode to hide or show its lines.") }
                }
                Section("Map") {
                    Picker("Map style", selection: $satellite) {
                        Text("Standard").tag(false)
                        Text("Satellite").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Heat: where you spend time", isOn: $heat)
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var legend: some View {
        switch colour {
        case .plain: EmptyView()
        case .date: HStack { swatch(Palette.mustard, "Newest"); swatch(Palette.satsuma, "Middle"); swatch(Palette.cherry, "Oldest") }
        case .speed: HStack { swatch(Palette.mode(.walk), "Walking pace"); swatch(Palette.mode(.bike), "Cycling"); swatch(Palette.mode(.car), "Driving") }
        case .mode:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(TravelMode.allCases, id: \.self) { m in
                    let off = hidden.contains(m.rawValue)
                    Button { toggle(m) } label: { swatch(Palette.mode(m), m.label).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                        .buttonStyle(.plain)
                        .opacity(off ? 0.45 : 1)
                        .accessibilityValue(off ? "Hidden" : "Shown")
                        .accessibilityHint("Hides or shows these lines")
                }
                swatch(Palette.unsure, "Unsure")
            }
        }
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

    private func toggle(_ m: TravelMode) {
        var h = hidden
        if h.contains(m.rawValue) { h.remove(m.rawValue) } else { h.insert(m.rawValue) }
        hiddenModes = h.sorted().joined(separator: ",")
    }
}
