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
    @State private var backup: URL?
    @State private var movingBackup = false
    @State private var backupError: String?
    @Environment(\.scenePhase) private var scenePhase

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
            stillSince: recorder.stillSince, lastCheckIn: recorder.lastCheckIn, notSavingSince: recorder.notSavingSince,
            signingExpiry: expiry, now: now)
        NavigationStack {
            List {
                Section("Status") {
                    Label(s.headline, systemImage: s.level == .problem ? "exclamationmark.triangle" : s.level == .resting ? "moon" : "checkmark.circle")
                        .foregroundStyle(s.level == .problem ? .red : s.level == .resting ? .secondary : .green)
                    if let hint = s.hint { Text(hint) }
                    LabeledContent("Last point", value: time(recorder.lastPoint))
                    LabeledContent("Last location check", value: time(recorder.lastCheckIn))
                    LabeledContent("SideStore refresh due", value: expiry.map { time($0) } ?? "unknown")
                    LabeledContent("Points today", value: "\(pointsToday)")
                    let stepCounting = MotionService.stepCounting
                    LabeledContent("Step counting", value: stepCounting)
                    if ["Off", "Not set up"].contains(stepCounting) {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .accessibilityHint("Turn on Motion & Fitness for LifePath")
                    }
                }
                Section {
                    Picker("Recording detail", selection: settings.$quality) {
                        ForEach(Quality.allCases, id: \.self) { Text(Self.label($0)).tag($0) }
                    }
                } footer: {
                    Text("How closely trips are traced while you move. Higher uses more battery. Drops a step by itself when the phone is hot or in Low Power Mode.")
                }
                Section {
                    Toggle("Show blue location bar", isOn: settings.$showsIndicator)
                } footer: {
                    Text("Helps keep iOS from pausing LifePath. Off hides the bar, but recording may stop more often.")
                }
                Section {
                    Toggle("Always rest deeply", isOn: settings.$deepSleep)
                } footer: {
                    Text("LifePath already rests deeply by itself when the battery is low, the phone is warm or Low Power Mode is on. On: checks every 15 min instead of 5, so the start of a trip may be missed.")
                }
                Section {
                    Toggle("Download street maps automatically", isOn: settings.$downloadStreets)
                } footer: {
                    Text("Fetches the streets around your trips from OpenStreetMap. Each request sends only a map rectangle, never your track.")
                }
                Section {
                    Toggle("Use mobile data for map downloads", isOn: settings.$streetsOnCellular)
                } footer: {
                    Text("Off: street maps download only on Wi-Fi.")
                }
                Section {
                    Toggle("Count cycling in Streets walked", isOn: settings.$countCycling)
                } footer: {
                    Text("On: streets you cycled count too, like on CityStrides. Off: only walking and running count. Car, bus, tram, train and boat never count.")
                }
                Section {
                    Button("Save a backup") {
                        Task {
                            do { backup = try await recorder.backup(); movingBackup = true } catch { backupError = error.localizedDescription }
                        }
                    }
                    .fileMover(isPresented: $movingBackup, file: backup) { result in
                        if case .failure = result, let backup { try? FileManager.default.removeItem(at: backup) }   // cancelled: no copy left in tmp
                    }
                } footer: {
                    Text("A copy of your whole diary. Keep it in Files or iCloud Drive: deleting LifePath deletes everything stored inside it.")
                }
                Section {
                    Button("Save health report") { report = ReportDocument(text: recorder.healthReport()); exporting = true }
                } footer: {
                    Text("A text file of the last 3 days, for troubleshooting.")
                }
                Section { LabeledContent("Version", value: version) }
            }
            .navigationTitle("LifePath")
            .refreshable { refresh() }
            .onAppear { refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .fileExporter(isPresented: $exporting, document: report, contentType: .plainText, defaultFilename: filename) { _ in }
            .alert("Backup failed", isPresented: Binding { backupError != nil } set: { if !$0 { backupError = nil } }) {} message: {
                Text(backupError ?? "")
            }
        }
    }

    private static func label(_ q: Quality) -> String {
        switch q {
        case .saver: "Battery saver"
        case .balanced: "Balanced"
        case .precise: "Precise"
        case .max: "Maximum"
        }
    }

    private func refresh() {
        now = Date()
        pointsToday = recorder.pointsToday()
    }
}
