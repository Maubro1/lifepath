import SwiftUI
import UniformTypeIdentifiers

/// Picks a backup file, previews it and merges it into the diary, with progress in a sheet.
struct RestoreButton: View {
    let title: String
    @State private var picking = false
    private var service: ImportService { ImportService.shared }

    var body: some View {
        Button(title) { picking = true }
            .accessibilityHint("Pick a LifePath backup file to add to your diary")
            // All files: the backup is checked by reading it, no file type is declared.
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { Task { await service.read(url) } }
            }
            .sheet(isPresented: Binding { service.phase != .idle } set: { if !$0 { service.cancel() } }) {
                NavigationStack { content.navigationTitle("Restore").navigationBarTitleDisplayMode(.inline) }
                    .interactiveDismissDisabled(service.phase == .reading || service.phase == .merging)
            }
    }

    @ViewBuilder private var content: some View {
        switch service.phase {
        case .idle: EmptyView()
        case .reading: List { ProgressView("Checking the backup…") }
        case .ready(let s, _):
            List {
                Section {
                    LabeledContent("Points", value: s.points.formatted())
                    LabeledContent("From", value: s.first?.formatted(date: .abbreviated, time: .omitted) ?? "–")
                    LabeledContent("To", value: s.last?.formatted(date: .abbreviated, time: .omitted) ?? "–")
                } footer: {
                    Text(s.points == 0 ? "This backup holds no points."
                         : "These points are added to your diary. Nothing already in it is removed, and a copy of your diary is kept first.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { service.cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") { Task { await service.merge() } }
                        .disabled(s.points == 0)
                        .accessibilityHint("Adds the backup's points to your diary")
                }
            }
        case .merging: List { ProgressView("Adding the backup to your diary…") }
        case .rebuilding:
            List {
                Section {
                    ProgressView("Rebuilding the map, places, streets and days…")
                } footer: {
                    Text("This can take a few minutes for years of history. Keep LifePath open; if you leave, it continues next time.")
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { service.cancel() } } }
        case .done(let n):
            List { Text("Restored. \(n.formatted()) points added.") }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { service.cancel() } } }
        case .failed(let message):
            List { Label(message, systemImage: "exclamationmark.triangle") }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { service.cancel() } } }
        }
    }
}
