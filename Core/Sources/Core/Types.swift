import Foundation

public struct Sample: Sendable, Equatable {
    public var t: Date
    public var lat, lon, hAcc, speed, course: Double   // speed/course < 0 = invalid, as CoreLocation
    public var speedAccuracy, courseAccuracy: Double   // m/s and degrees from CoreLocation; < 0 = unknown (never stored)
    public init(t: Date, lat: Double, lon: Double, hAcc: Double, speed: Double, course: Double,
                speedAccuracy: Double = -1, courseAccuracy: Double = -1) {
        self.t = t; self.lat = lat; self.lon = lon; self.hAcc = hAcc; self.speed = speed; self.course = course
        self.speedAccuracy = speedAccuracy; self.courseAccuracy = courseAccuracy
    }
}

public enum Activity: String, Sendable, Codable {
    case stationary, walking, running, cycling, automotive, unknown
    public var isVehicle: Bool { self == .cycling || self == .automotive }
}

/// rough: a fix above the quality's accuracy ceiling, kept raw for later judging (trains report ~1 km for good positions).
/// Older app versions read an unknown kind as moving.
public enum PointKind: String, Sendable, Codable { case moving, still, rough }

public struct FilteredPoint: Sendable, Equatable, Codable {
    public var t: Date
    public var lat, lon, rawLat, rawLon, hAcc, speed: Double
    public var course: Double   // degrees; < 0 = unknown (still points, old rows, inaccurate fixes)
    public var kind: PointKind
    public init(t: Date, lat: Double, lon: Double, rawLat: Double, rawLon: Double, hAcc: Double, speed: Double, kind: PointKind, course: Double = -1) {
        self.t = t; self.lat = lat; self.lon = lon; self.rawLat = rawLat; self.rawLon = rawLon
        self.hAcc = hAcc; self.speed = speed; self.kind = kind; self.course = course
    }
}

public struct LoggedEvent: Sendable, Equatable, Codable {
    public var t: Date
    public var kind: String
    public var detail: String
    public init(t: Date, kind: String, detail: String) { self.t = t; self.kind = kind; self.detail = detail }
}

public enum Quality: String, CaseIterable, Sendable, Codable {
    case saver, balanced, precise, max

    /// Maximum horizontal accuracy (m) a fix may have to be used.
    public var accuracyCeiling: Double {
        switch self { case .saver: 2000; case .balanced: 65; case .precise: 50; case .max: 30 }
    }
    /// Minimum spacing (m) between stored points.
    public var spacing: Double {
        switch self { case .saver: 100; case .balanced: 10; case .precise: 5; case .max: 2 }
    }
    public var lower: Quality {
        switch self { case .max: .precise; case .precise: .balanced; case .balanced, .saver: .saver }
    }
}
