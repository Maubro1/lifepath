import Core
import SwiftUI
import UniformTypeIdentifiers

struct ReportDocument: FileDocument {
    static let readableContentTypes = [UTType.plainText]
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

struct SettingsView: View {
    let recorder = Recorder.shared
    let settings = AppSettings()
    @State private var now = Date()
    @State private var pointsToday = 0
    @State private var report = ReportDocument(text: "")
    @State private var exporting = false

    private var expiry: Date? { SigningReminder.expiry }
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }
    private var filename: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return "LifePath-health-\(f.string(from: Date()))"
    }

    private func time(_ d: Date?) -> String { d?.formatted(date: .abbreviated, time: .shortened) ?? "none yet" }

    var body: some View {
        let s = TrackingStatus.evaluate(
            authorization: recorder.authorization, preciseLocation: recorder.preciseLocation, state: recorder.state,
            lastPoint: recorder.lastPoint, stillSince: recorder.stillSince, lastCheckIn: recorder.lastCheckIn,
            signingExpiry: expiry, now: now)
        NavigationStack {
            List {
                Section("Status") {
                    Label(s.headline, systemImage: s.level == .problem ? "exclamationmark.triangle" : s.level == .resting ? "moon" : "checkmark.circle")
                        .foregroundStyle(s.level == .problem ? .red : s.level == .resting ? .secondary : .green)
                    if let hint = s.hint { Text(hint) }
                    LabeledContent("Last point", value: time(recorder.lastPoint))
                    LabeledContent("Last check-in", value: time(recorder.lastCheckIn))
                    LabeledContent("Signing expires", value: expiry.map { time($0) } ?? "unknown")
                    LabeledContent("Points today", value: "\(pointsToday)")
                }
                Section {
                    Picker("Quality", selection: settings.$quality) {
                        ForEach(Quality.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Toggle("Show blue location bar", isOn: settings.$showsIndicator)
                    Toggle("Deep sleep", isOn: settings.$deepSleep)
                } footer: {
                    Text("Deep sleep saves battery by recording less detail, until you turn it off.")
                }
                Section {
                    Button("Create health report") { report = ReportDocument(text: recorder.healthReport()); exporting = true }
                    LabeledContent("Version", value: version)
                }
            }
            .navigationTitle("LifePath")
            .refreshable { refresh() }
            .onAppear { refresh() }
            .fileExporter(isPresented: $exporting, document: report, contentType: .plainText, defaultFilename: filename) { _ in }
        }
    }

    private func refresh() {
        now = Date()
        pointsToday = recorder.pointsToday()
    }
}
