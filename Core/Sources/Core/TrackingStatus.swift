import Foundation

public enum Authorization: String, Sendable { case always, whenInUse, denied, notDetermined }

public struct TrackingStatus: Sendable, Equatable {
    public enum Level: String, Sendable { case healthy, resting, problem }
    public var level: Level
    public var headline: String
    public var hint: String?

    public static func evaluate(authorization: Authorization, preciseLocation: Bool, state: MotionState,
                                stillSince: Date?, lastCheckIn: Date?, deepSleep: Bool, signingExpiry: Date?, now: Date) -> TrackingStatus {
        func problem(_ headline: String, _ hint: String) -> TrackingStatus {
            TrackingStatus(level: .problem, headline: headline, hint: hint)
        }
        if authorization != .always {
            return problem("Location access isn't set to Always", "Settings → LifePath → Location → Always")
        }
        if !preciseLocation {
            return problem("Precise Location is off", "Settings → LifePath → Location → Precise Location")
        }
        if !deepSleep, let c = lastCheckIn, now.timeIntervalSince(c) > 60 * 60 {   // deep sleep stops the keep-alive check-ins
            return problem("No check-in for over an hour", "Did you swipe LifePath away? Open it once to restart tracking.")
        }
        if let e = signingExpiry, e.timeIntervalSince(now) < 24 * 3600 {
            return problem("The app's signing expires soon", "Open SideStore and tap Refresh All.")
        }
        if state == .still {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
            return TrackingStatus(level: .resting, headline: "Resting: you've been still since \(f.string(from: stillSince ?? now))", hint: nil)
        }
        return TrackingStatus(level: .healthy, headline: "Tracking", hint: nil)
    }
}
