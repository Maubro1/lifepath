import CoreLocation
import SwiftUI

@main
struct LifePathApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Stage 0 proof: this count must keep rising across updates and SideStore refreshes.
        let key = "pipeline.launchCount"
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
        // Before onboarding nothing may prompt; its last page calls start() instead.
        if AppSettings().onboarded || CLLocationManager().authorizationStatus != .notDetermined { Recorder.shared.start() }
    }

    var body: some Scene {
        WindowGroup { PipelineView() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { Recorder.shared.flush() }
            }
    }
}
