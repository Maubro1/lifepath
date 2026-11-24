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
    @State private var savingBackup = false   // shown while the copy is written, so a long wait never looks like nothing
    @State private var exportingTracks = false
    @State private var deletingDays = false
    @AppStorage("lastBackup") private var lastBackup: Double = 0   // seconds since 1970; 0 = never
    @AppStorage("appearance") private var appearance: Appearance = .system
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
        Group {   // pushed from the You tab, inside its navigation stack
            List { Group {
                Section("Status") {
                    Label(s.headline, systemImage: s.level == .problem ? "exclamationmark.triangle" : s.level == .resting ? "moon" : "checkmark.circle")
                        .foregroundStyle(s.level == .problem ? Color(UIColor(Palette.cherry)) : s.level == .resting ? Color.muted : Color(UIColor(Palette.mode(.bike))))   // as the You pill
                    if let hint = s.hint { Text(hint) }
                    InfoRow("Last place saved", value: time(recorder.lastPoint))
                    InfoRow("Last check where you are", value: time(recorder.lastCheckIn))
                    if ["Off", "Not set up"].contains(MotionService.stepCounting) {   // only shown when it needs fixing
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
                } header: { Text("Recording") } footer: {
                    Text("How closely your trips are drawn while you move. More detail uses more battery. LifePath steps down by itself when your phone is hot or in Low Power Mode.")
                }
                Section {
                    Toggle("Show blue location bar", isOn: settings.$showsIndicator)
                } footer: {
                    Text("The blue bar at the top of the screen helps your iPhone keep LifePath running. Turn it off to hide it, but recording may stop more often.")
                }
                Section {
                    Toggle("Save extra battery", isOn: settings.$deepSleep)
                } footer: {
                    Text("LifePath already saves battery by itself when the battery is low, your phone is warm or Low Power Mode is on. Turn this on to always save battery: it checks where you are every 15 minutes instead of every 5, so the first minutes of a trip can be missed.")
                }
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text("Appearance") } footer: {
                    Text("System follows your iPhone's light or dark mode.")
                }
                Section {
                    Toggle("Download street maps automatically", isOn: settings.$downloadStreets)
                } header: { Text("Street maps") } footer: {
                    Text("Downloads a map of the streets around your trips, so your lines can follow the real roads and rails. Only the map area is sent, never where you went.")
                }
                Section {
                    Toggle("Use mobile data for map downloads", isOn: settings.$streetsOnCellular)
                } footer: {
                    Text("Off: street maps only download on Wi-Fi.")
                }
                Section {
                    Toggle("Count cycling in Streets walked", isOn: settings.$countCycling)
                } footer: {
                    Text("On: streets you cycled through count as done too. Off: only walking and running count. Car, bus, tram, train and boat never count.")
                }
                Section {
                    if savingBackup {
                        HStack { ProgressView(); Text("Saving a backup… this can take a minute").foregroundStyle(Color.muted) }
                    } else {
                        Button("Save a backup") {
                            savingBackup = true
                            Task {
                                do { backup = try await recorder.backup(); movingBackup = true } catch { backupError = error.localizedDescription }
                                savingBackup = false
                            }
                        }
                    }
                    InfoRow(title: "Last backup") {
                        HStack(spacing: 6) {
                            if backupOld { Circle().fill(Color.satsuma).frame(width: 8, height: 8).accessibilityHidden(true) }
                            Text(lastBackup == 0 ? "never" : Date(timeIntervalSince1970: lastBackup).formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .accessibilityHint(backupOld ? "A new backup is recommended" : "")
                } header: { Text("Your data") } footer: {
                    Text("A copy of everything LifePath remembers. Keep it in Files or iCloud Drive, because deleting the app deletes everything inside it.")
                }
                Section {
                    RestoreButton(title: "Restore from a backup")
                } footer: {
                    Text("Adds the trips and places from a backup file, for example after reinstalling LifePath. Nothing you have now is removed.")
                }
                Section {
                    Button("Delete days…", role: .destructive) { deletingDays = true }
                        .sheet(isPresented: $deletingDays) { DeletePeriodSheet() }
                } footer: {
                    Text("Removes everything recorded on the days you choose.")
                }
                Section {
                    Button("Export your trips") { exportingTracks = true }
                        .accessibilityHint("Choose a format and a period, then where to save the file")
                        .sheet(isPresented: $exportingTracks) { ExportSheet() }
                } footer: {
                    Text("Saves your trips as a file you can open in other map and fitness apps.")
                }
                Section {
                    Button("Save health report") { report = ReportDocument(text: recorder.healthReport()); exporting = true }
                } header: { Text("Help") } footer: {
                    Text("A text file about the last 3 days that helps find out what went wrong when something seems off.")
                }
                Section {
                    NavigationLink("Behind the scenes") { DiagnosticsView(pointsToday: pointsToday) }
                    InfoRow("Refresh in SideStore before", value: expiry.map { time($0) } ?? "unknown")
                    InfoRow("Version", value: version)
                }
                }
                .listRowBackground(Color.card)   // paper cards, as everywhere in LifePath
            }
            .scrollContentBackground(.hidden)
            .background(Color.page)
            .navigationTitle("Settings")
            .refreshable { refresh() }
            .onAppear { refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .background {   // each file dialog on its own leaf: nested file modifiers silently cancel each other
                ZStack {
                    Color.clear.fileExporter(isPresented: $exporting, document: report, contentType: .plainText, defaultFilename: filename) { _ in }
                    Color.clear.fileMover(isPresented: $movingBackup, file: backup) { result in
                        switch result {
                        case .success: lastBackup = Date().timeIntervalSince1970
                        case .failure(let error):
                            if let backup { try? FileManager.default.removeItem(at: backup) }   // no copy left in tmp
                            // Cancelling is no failure; anything else is shown with the system's own words, so it can be fixed.
                            if (error as? CocoaError)?.code != .userCancelled { backupError = "Moving the backup to Files failed: \(error.localizedDescription)" }
                        }
                    }
                }
            }
            .alert("Backup failed", isPresented: Binding { backupError != nil } set: { if !$0 { backupError = nil } }) {} message: {
                Text(backupError ?? "")
            }
        }
    }

    /// Never saved, or more than 30 days ago.
    private var backupOld: Bool { Date().timeIntervalSince1970 - lastBackup > 30 * 86_400 }

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

/// For checking the tracking: the line as recorded, and how many points are stored.
private struct DiagnosticsView: View {
    let pointsToday: Int
    @AppStorage("recordedLine") private var recordedLine = false
    @State private var stored: Int?

    var body: some View {
        List { Group {
            Section {
                Toggle("Show trips as recorded", isOn: $recordedLine)
            } footer: {
                Text("Shows your trips exactly as your phone saved them, before LifePath tidied them up and put them on the streets.")
            }
            Section {
                InfoRow("Locations saved today", value: pointsToday.formatted())
                InfoRow("Locations saved in total", value: stored?.formatted() ?? "…")
            }
            }
            .listRowBackground(Color.card)   // paper cards, as everywhere in LifePath
        }
        .scrollContentBackground(.hidden)
        .background(Color.page)
        .navigationTitle("Behind the scenes")
        .task {
            guard let diary = Recorder.shared.readDiary else { return }
            stored = await Task.detached(priority: .utility) { try? diary.lifeStats().points }.value
        }
    }
}
