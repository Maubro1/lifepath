import CoreMotion
import SwiftUI
import UserNotifications

struct OnboardingView: View {
    let settings = AppSettings()
    @State private var page = 0
    /// Decided once: an empty diary (a fresh install) is offered a restore; never re-checked, so the page can't vanish mid-restore.
    @State private var offerRestore: Bool?

    var body: some View {
        let o = offerRestore == true ? 1 : 0
        TabView(selection: $page) {
            step("What LifePath does",
                 "LifePath keeps a private diary of where you go. Everything stays on this iPhone; nothing is sent anywhere.", nil).tag(0)
            if offerRestore == true {
                screen("Used LifePath before?",
                       "Restore your diary from a backup file in Files or iCloud Drive. You can also do this later in Settings.") {
                    RestoreButton(title: "Restore from a backup").buttonStyle(.borderedProminent)
                }.tag(1)
            }
            step("Location while using",
                 "First allow location while you use the app.", ("Allow While Using", { Recorder.shared.requestWhenInUse() })).tag(1 + o)
            step("Location always",
                 "Then choose Always, so LifePath can keep recording with the app closed.", ("Allow Always", { Recorder.shared.requestAlways() })).tag(2 + o)
            step("Keep it running",
                 "Please don't swipe LifePath away in the app switcher. That stops it recording.", nil).tag(3 + o)
            step("Motion and notifications",
                 "Motion & Fitness lets LifePath notice when you set off and save battery while you're still. Notifications remind you weekly to refresh the app's signing. Both are optional.",
                 ("Allow Motion and Notifications", {
                     CMMotionActivityManager().queryActivityStarting(from: .now.addingTimeInterval(-60), to: .now, to: .main) { _, _ in }
                     UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                 })).tag(4 + o)
            step("Ready", "LifePath is set up.", ("Start", { settings.onboarded = true; Recorder.shared.start(); SigningReminder.schedule() })).tag(5 + o)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .onAppear { if offerRestore == nil { offerRestore = (try? Recorder.shared.diaryForImport()?.lastPoint()) == nil } }
    }

    private func step(_ title: String, _ text: String, _ action: (String, () -> Void)?) -> some View {
        screen(title, text) { if let action { Button(action.0, action: action.1).buttonStyle(.borderedProminent) } }
    }

    private func screen<Control: View>(_ title: String, _ text: String, @ViewBuilder _ control: () -> Control) -> some View {
        ScrollView {   // at accessibility sizes the page scrolls, the button included
            VStack(spacing: 24) {
                Text(title).font(.title).bold().multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                Text(text).multilineTextAlignment(.center)
                control()
            }
            .frame(maxWidth: .infinity)
            .padding().padding(.bottom, 40)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
