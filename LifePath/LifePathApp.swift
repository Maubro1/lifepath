import CoreLocation
import SwiftUI

@main
struct LifePathApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SmoothingService.register()
        // Before onboarding nothing may prompt; its Start page calls start() instead.
        if AppSettings().onboarded || CLLocationManager().authorizationStatus != .notDetermined { Recorder.shared.start() }
    }

    var body: some Scene {
        WindowGroup { Root() }
            .onChange(of: scenePhase, initial: true) { _, phase in   // initial: a cold launch is already .active
                if phase == .background { Recorder.shared.log("app", "closed"); Recorder.shared.flush(); SmoothingService.appWentToBackground() }
                if phase == .active { Recorder.shared.log("app", "open"); SigningReminder.schedule(); SmoothingService.appBecameActive() }
            }
    }
}

private struct Root: View {
    let settings = AppSettings()
    /// Same test as `init`: settings read before the first unlock can come back as defaults, but the permission can't.
    @State private var startedBefore = AppSettings().onboarded || CLLocationManager().authorizationStatus != .notDetermined
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Bindable private var nav = AppNav.shared

    var body: some View { themed }

    @ViewBuilder private var content: some View {
        if settings.onboarded || startedBefore {
            TabView(selection: $nav.tab) {
                Tab("Map", systemImage: "map", value: 0) { MapScreen() }
                Tab("You", systemImage: "person.crop.circle", value: 1) { YouScreen() }
            }
        } else { OnboardingView() }
    }

    var themed: some View { content.tint(.satsuma).preferredColorScheme(appearance.scheme) }
}
