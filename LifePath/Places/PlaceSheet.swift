import Core
import SwiftUI

/// A learned place: its name (editable) and how much of the owner's life it holds.
struct PlaceSheet: View {
    let place: Place
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(place: Place) {
        self.place = place
        _name = State(initialValue: place.name ?? "")
    }

    private var firstVisit: Date? {   // visitDays are local day numbers
        place.visitDays.min().map { Date(timeIntervalSince1970: Double($0) * 86_400 - Double(TimeZone.current.secondsFromGMT())) }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name, prompt: Text("Name this place"))
                    .accessibilityLabel("Place name")
                    .onSubmit(save)
                LabeledContent("Time spent", value: Duration.seconds(place.totalSeconds).formatted(.units(allowed: [.days, .hours], width: .wide)))
                LabeledContent("Visits", value: "\(place.visits)")
                LabeledContent("First visit", value: firstVisit?.formatted(date: .abbreviated, time: .omitted) ?? "unknown")
                LabeledContent("Last visit", value: place.lastVisit.formatted(date: .abbreviated, time: .omitted))
            }
            .navigationTitle(place.name ?? "Place")
            .toolbar { Button("Done") { dismiss() }.accessibilityLabel("Save and close") }
            .onDisappear(perform: save)   // a swipe-down keeps the edit too
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let new = name.trimmingCharacters(in: .whitespaces)
        guard new != (place.name ?? "") else { return }
        do {
            try Recorder.shared.readDiary?.renamePlace(place.id, to: new.isEmpty ? nil : new)
            if let i = PlaceService.shared.places.firstIndex(where: { $0.id == place.id }) {   // the map reads this copy
                PlaceService.shared.places[i].name = new.isEmpty ? nil : new
            }
        } catch {
            Recorder.shared.log("rename", "failed")
        }
    }
}
