import Foundation

public enum MotionState: String, Sendable { case moving, settling, still }

public struct Fence: Sendable, Equatable {
    public var lat, lon, radius: Double
    public init(lat: Double, lon: Double, radius: Double) { self.lat = lat; self.lon = lon; self.radius = radius }
}

public enum MotionEvent: Sendable {
    case fix(FilteredPoint)                 // recording manager, after filter
    case tick                               // keep-alive update or any wake; drives time-based rules
    case steps(Int)                         // cumulative since Still began
    case activity(Activity, confident: Bool)
    case wakeFix(Sample, reason: String)    // spot check, significant change, visit
    case geofenceExit
    case spotCheckDue, spotCheckEnded
    case deepSleepChanged(Bool)             // effective deep sleep (manual setting OR thermal/low power/battery)
}

public enum Command: Sendable, Equatable {
    case startRecording, stopRecording
    case startSpotCheck, stopSpotCheck, scheduleSpotCheck(after: TimeInterval)
    case setKeepAlive(Bool)                 // false only in deep sleep
    case armGeofence(Fence), disarmGeofence
    case writeStillPoint(FilteredPoint)
    case resolveDeparture(stillSince: Date) // app queries CoreMotion history, then backfills
    case log(LoggedEvent)
}

public struct MotionEngine: Sendable {
    public private(set) var state: MotionState = .moving
    public private(set) var fence: Fence?
    public init(motionAvailable: Bool, deepSleep: Bool) {}
    public mutating func handle(_ e: MotionEvent, at now: Date) -> [Command] { [] }
}
