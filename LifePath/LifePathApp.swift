import CoreLocation
import SwiftUI

@main
struct LifePathApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before onboarding nothing may prompt; its Start page calls start() instead.
        if AppSettings().onboarded || CLLocationManager().authorizationStatus != .notDetermined { Recorder.shared.start() }
    }

    var body: some Scene {
        WindowGroup { Root() }
            .onChange(of: scenePhase, initial: true) { _, phase in   // initial: a cold launch is already .active
                if phase == .background { Recorder.shared.log("app", "closed"); Recorder.shared.flush() }
                if phase == .active { Recorder.shared.log("app", "open"); SigningReminder.schedule() }
            }
    }
}

private struct Root: View {
    let settings = AppSettings()

    var body: some View {
        if settings.onboarded { SettingsView() } else { OnboardingView() }
    }
}
