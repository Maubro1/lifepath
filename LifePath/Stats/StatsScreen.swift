import Core
import Diary
import SwiftUI

/// Whole-life totals, read from the small `day` and `daySteps` tables off the main actor, only while on screen.
struct StatsScreen: View {
    @State private var stats: LifeStats?
    @State private var walked: (covered: Int, total: Int)?
    @State private var bike = false
    @State private var onScreen = false
    @AppStorage("countCycling") private var countCycling = false
    @Environment(\.scenePhase) private var scenePhase

    private var visible: Bool { onScreen && scenePhase == .active }

    var body: some View {
        NavigationStack {
            List {
                if let s = stats {
                    Section("Where you went") {
                        LabeledContent("Distance", value: Format.distance(s.distance))
                        LabeledContent("Days tracked", value: s.days.formatted())
                        LabeledContent("Points stored", value: s.points.formatted())
                    }
                    Section {
                        LabeledContent("Steps", value: s.steps?.formatted() ?? "—")
                        LabeledContent("Flights of stairs", value: s.floorsUp?.formatted() ?? "—")
                        LabeledContent("Distance walked", value: Format.distance(s.walked))
                    } header: {
                        Text("On foot")
                    } footer: {
                        if s.steps != nil, let since = s.stepsSince.flatMap(Format.date) {
                            Text("Steps and stairs counted since \(since.formatted(date: .long, time: .omitted)). Distance walked counts walking and running only, never rides.")
                        } else {
                            Text("Step counting is off. Turn on Motion & Fitness for LifePath in iOS Settings.")
                        }
                    }
                    Section("Streets walked") { Text(MapScreen.tallyText(walked, bike: bike)) }
                }
            }
            .navigationTitle("Stats")
            .refreshable {
                if let diary = Recorder.shared.readDiary { await DayService.run(diary) }
                await load()
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: visible, initial: true) { _, v in if v { Task { await load() } } }
        .onChange(of: countCycling) { if visible { Task { await load() } } }
        .onReceive(NotificationCenter.default.publisher(for: DayService.changed)) { _ in if visible { Task { await load() } } }
    }

    private func load() async {
        guard let diary = Recorder.shared.readDiary else { return }   // locked before first unlock
        let bike = UserDefaults.standard.bool(forKey: "countCycling")
        let read = await Task.detached(priority: .userInitiated) { () -> (LifeStats, (covered: Int, total: Int)?)? in
            guard let s = try? diary.lifeStats() else { return nil }
            return (s, try? diary.streetsWalked(bike: bike))
        }.value
        if let read { stats = read.0; walked = read.1; self.bike = bike }
    }
}
