import SwiftUI

@main
struct LifePathApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // Before onboarding finishes nothing records; the Start button calls start().
    init() { if UserDefaults.standard.bool(forKey: "onboarded") { Recorder.shared.start() } }

    var body: some Scene {
        WindowGroup { Root() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { Recorder.shared.flush() }
                if phase == .active { SigningReminder.schedule() }
            }
    }
}

private struct Root: View {
    let settings = AppSettings()

    var body: some View {
        if settings.onboarded { SettingsView() } else { OnboardingView() }
    }
}
