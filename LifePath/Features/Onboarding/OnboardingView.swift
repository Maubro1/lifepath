import CoreMotion
import SwiftUI
import UserNotifications

struct OnboardingView: View {
    let settings = AppSettings()
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            step("What LifePath does",
                 "LifePath keeps a private diary of where you go. Everything stays on this iPhone; nothing is sent anywhere.", nil).tag(0)
            step("Location while using",
                 "First allow location while you use the app.", ("Allow While Using", { Recorder.shared.requestWhenInUse() })).tag(1)
            step("Location always",
                 "Then choose Always, so LifePath can keep recording with the app closed.", ("Allow Always", { Recorder.shared.requestAlways() })).tag(2)
            step("Keep it running",
                 "Please don't swipe LifePath away in the app switcher. That stops it recording.", nil).tag(3)
            step("Motion and notifications",
                 "Motion & Fitness lets LifePath notice when you set off and save battery while you're still. Notifications remind you weekly to refresh the app's signing. Both are optional.",
                 ("Allow Motion and Notifications", {
                     CMMotionActivityManager().queryActivityStarting(from: .now.addingTimeInterval(-60), to: .now, to: .main) { _, _ in }
                     UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                 })).tag(4)
            step("Ready", "LifePath is set up.", ("Start", { settings.onboarded = true; Recorder.shared.start(); SigningReminder.schedule() })).tag(5)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }

    private func step(_ title: String, _ text: String, _ action: (String, () -> Void)?) -> some View {
        ScrollView {   // at accessibility sizes the page scrolls, the button included
            VStack(spacing: 24) {
                Text(title).font(.title).bold().multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                Text(text).multilineTextAlignment(.center)
                if let action { Button(action.0, action: action.1).buttonStyle(.borderedProminent) }
            }
            .frame(maxWidth: .infinity)
            .padding().padding(.bottom, 40)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
