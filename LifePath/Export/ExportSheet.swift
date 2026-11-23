import Core
import Diary
import SwiftUI

enum ExportService {
    /// Streams the trips from `from` to `to` into a file in the temporary folder, a month of points at a time.
    /// Nil (and no file) when no trip was written; on a throw or cancel the file is deleted.
    static func write(_ diary: Diary, _ f: ExportFormat, from: Date, to: Date, progress: @escaping @Sendable (Int) -> Void) throws -> URL? {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        let name = from == .distantPast ? "LifePath-tracks-\(day.string(from: Date()))"
            : "LifePath-tracks-\(day.string(from: from))-to-\(day.string(from: to.addingTimeInterval(-1)))"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).\(f.rawValue)")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        var written = 0
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            func put(_ s: String) throws { try handle.write(contentsOf: Data(s.utf8)) }
            func putTrips(_ trips: [Trip]) throws {
                for trip in trips {
                    let s = Export.trip(trip, f, first: written == 0)
                    if !s.isEmpty { try put(s); written += 1 }
                }
            }
            try put(Export.head(f))
            // The loop of SmoothingService.run: a month at a time (empty stretches skipped), the open trip carried across edges.
            let month: TimeInterval = 30 * 86_400
            var after = from.addingTimeInterval(-0.001), carry: [FilteredPoint] = []   // reads are `t > after`
            while let first = try diary.points(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, after: after, to: to, limit: 1).first {
                try Task.checkCancellation()
                let chunk = try diary.points(minLat: -90, maxLat: 90, minLon: -180, maxLon: 180, after: after, to: min(to, first.t.addingTimeInterval(month)), limit: Int.max)
                try putTrips(Trips.split(chunk: chunk, carry: &carry))
                after = chunk[chunk.count - 1].t
                progress(written)
            }
            try putTrips(Trips.split(carry))
            try put(Export.tail(f))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        if written == 0 { try? FileManager.default.removeItem(at: url); return nil }
        return url
    }
}

/// Trips as GPX, GeoJSON or KML for all history or a period, handed to the system file mover.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var format = ExportFormat.gpx   // remembered, like every choice in LifePath
    @AppStorage("exportAllHistory") private var allHistory = true
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var task: Task<Void, Never>?
    @State private var trips = 0
    @State private var file: URL?
    @State private var moving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases, id: \.self) { Text(Self.label($0)).tag($0) }
                    }
                    Toggle("All history", isOn: $allHistory)
                    if !allHistory {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                        DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
                    }
                } footer: {
                    Text("Your trips as a file other apps can open. Positions LifePath was unsure of (about a kilometre off, as in some trains) are left out, so the line breaks there. Rests and places are not included; they are in the backup.")
                }
                Section {
                    if task != nil {
                        ProgressView("Writing tracks… \(trips) trips")
                    } else {
                        Button("Export") { start() }
                            .accessibilityHint("Writes the trips to a file and asks where to save it")
                    }
                    if let message { Text(message) }
                }
            }
            .navigationTitle("Export tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .fileMover(isPresented: $moving, file: file) { result in
                if case .failure = result, let file { try? FileManager.default.removeItem(at: file) }   // cancelled: no copy left in tmp
            }
        }
        .onDisappear { task?.cancel() }
    }

    private static func label(_ f: ExportFormat) -> String {
        switch f {
        case .gpx: "GPX"
        case .geojson: "GeoJSON"
        case .kml: "KML"
        }
    }

    private func start() {
        guard let diary = Recorder.shared.readDiary else {
            message = "The diary can't be opened right now. Unlock the iPhone and try again."
            return
        }
        let cal = Calendar.current
        let range = allHistory ? (from: Date.distantPast, to: Date())
            : (from: cal.startOfDay(for: from), to: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to)) ?? to)
        let f = format
        message = nil
        trips = 0
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try ExportService.write(diary, f, from: range.from, to: range.to) { n in Task { @MainActor in trips = n } }
            }
            let result = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
            task = nil
            if Task.isCancelled {   // the sheet closed: nothing to hand over
                if case .success(let url?) = result { try? FileManager.default.removeItem(at: url) }
                return
            }
            switch result {
            case .success(let url?): file = url; moving = true
            case .success(nil): message = "No trips in this period."
            case .failure(let error) where error is CancellationError: break
            case .failure(let error): message = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
