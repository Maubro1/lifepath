import Foundation

public enum Authorization: String, Sendable { case always, whenInUse, denied, notDetermined }

public struct TrackingStatus: Sendable, Equatable {
    public enum Level: String, Sendable { case healthy, resting, problem }
    public var level: Level
    public var headline: String
    public var hint: String?

    public static func evaluate(authorization: Authorization, preciseLocation: Bool, state: MotionState,
                                lastPoint: Date?, lastCheckIn: Date?, signingExpiry: Date?, now: Date) -> TrackingStatus {
        TrackingStatus(level: .healthy, headline: "", hint: nil)
    }
}
