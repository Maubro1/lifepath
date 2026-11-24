import Core
import SwiftUI

/// Deleting the records of chosen days, from a day page or Settings.
@MainActor enum DeleteData {
    /// Deletes local days `first...last` (whole days); returns the points removed.
    static func days(_ first: Date, _ last: Date) async -> Int? {
        guard let diary = Recorder.shared.readDiary else { return nil }
        let cal = Calendar.current, a = cal.startOfDay(for: min(first, last))
        let b = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(first, last)))!
        var keys: [String] = [], d = a
        while d < b { keys.append(Days.key(d, .current)); d = cal.date(byAdding: .day, value: 1, to: d)! }
        let n = await Task.detached(priority: .userInitiated) { [keys] in try? diary.deleteRecords(from: a, to: b, days: keys) }.value
        PlaceService.shared.places = (try? diary.places()) ?? PlaceService.shared.places
        Recorder.shared.log("delete", "\(keys.count) days")
        for name in [SmoothingService.linesChanged, DayService.changed, PlaceService.changed] { NotificationCenter.default.post(name: name, object: nil) }
        return n
    }
}

/// Settings: choose a period and delete it, after a clear confirmation.
struct DeletePeriodSheet: View {
    @State private var from = Calendar.current.startOfDay(for: Date())
    @State private var to = Calendar.current.startOfDay(for: Date())
    @State private var confirming = false
    @State private var done: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { Group {
                Section {
                    DatePicker("From", selection: $from, in: ...Date(), displayedComponents: .date)
                    DatePicker("To", selection: $to, in: ...Date(), displayedComponents: .date)
                } footer: {
                    Text("Deletes everything LifePath recorded on these days: your lines, the places you stayed, steps and the day summaries. Places you only visited on these days are forgotten. This cannot be undone.")
                }
                Section {
                    Button("Delete these days", role: .destructive) { confirming = true }
                    if let done { Text("Deleted. \(done.formatted()) saved locations removed.").foregroundStyle(Color.muted) }
                }
            }
            .listRowBackground(Color.card) }
            .scrollContentBackground(.hidden)
            .background(Color.page)
            .navigationTitle("Delete days")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Delete \(Self.label(from, to))?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { done = await DeleteData.days(from, to) } }
            } message: {
                Text("This cannot be undone. A backup you saved earlier still holds these days.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    static func label(_ a: Date, _ b: Date) -> String {
        let f = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        return Calendar.current.isDate(a, inSameDayAs: b) ? a.formatted(f) : "\(min(a, b).formatted(f)) – \(max(a, b).formatted(f))"
    }
}
