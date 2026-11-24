import Foundation

public enum Authorization: String, Sendable { case always, whenInUse, denied, notDetermined }

public struct TrackingStatus: Sendable, Equatable {
    public enum Level: String, Sendable { case healthy, resting, problem }
    public var level: Level
    public var headline: String
    public var hint: String?

    public static func evaluate(authorization: Authorization, preciseLocation: Bool, state: MotionState,
                                stillSince: Date?, lastCheckIn: Date?, notSavingSince: Date?, signingExpiry: Date?, now: Date,
                                paused: Bool = false) -> TrackingStatus {
        if paused { return TrackingStatus(level: .resting, headline: "Paused", hint: nil) }
        func problem(_ headline: String, _ hint: String) -> TrackingStatus {
            TrackingStatus(level: .problem, headline: headline, hint: hint)
        }
        func hhmm(_ d: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
            return f.string(from: d)
        }
        if let f = notSavingSince {   // first: points are piling up in memory and a kill loses them
            return problem("Not saving since \(hhmm(f))", "LifePath can't write to its diary. Check that your iPhone has free storage, then open LifePath again.")
        }
        if authorization != .always {
            return problem("Location access isn't set to Always", "Settings → LifePath → Location → Always")
        }
        if !preciseLocation {
            return problem("Precise Location is off", "Settings → LifePath → Location → Precise Location")
        }
        if let c = lastCheckIn, now.timeIntervalSince(c) > 60 * 60 {   // deep sleep too keeps a spot check every 15 min
            return problem("LifePath hasn't checked where you are for over an hour", "Was LifePath swiped away, updated or refreshed in SideStore? Open it once to restart tracking.")
        }
        if let e = signingExpiry, e.timeIntervalSince(now) < 24 * 3600 {
            return problem("LifePath needs a refresh in SideStore soon", "Open SideStore and tap Refresh All, then open LifePath once.")
        }
        if state == .still {
            return TrackingStatus(level: .resting, headline: "Resting: you've been still since \(hhmm(stillSince ?? now))", hint: nil)
        }
        return TrackingStatus(level: .healthy, headline: "Tracking", hint: nil)
    }
}
