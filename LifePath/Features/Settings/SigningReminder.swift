import Core
import Foundation
import UserNotifications

enum SigningReminder {
    static let id = "signing-expiry"

    static var expiry: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return ProvisioningProfile.expirationDate(from: data)
    }

    /// Replaces the pending reminder; skipped when the expiry is unknown or already within 24 h (the status box shows that).
    static func schedule(now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let fire = expiry?.addingTimeInterval(-24 * 3600), fire > now else { return }
        let content = UNMutableNotificationContent()
        content.title = "LifePath needs a refresh"
        content.body = "Open SideStore and tap Refresh All."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSince(now), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
