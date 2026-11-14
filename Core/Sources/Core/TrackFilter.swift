import Foundation

public struct TrackFilter: Sendable {
    public var quality: Quality
    public init(quality: Quality) { self.quality = quality }

    private struct Fix { var t: Date; var lat, lon, hAcc: Double }
    private var origin: Fix?            // first accepted sample; Kalman state is metres from here
    private var last: Fix?              // last accepted raw sample
    private var x = 0.0, y = 0.0, p = 0.0   // east, north, shared variance (both axes see the same hAcc)
    private var recent: [(x: Double, y: Double, w: Double)] = []

    private static let metresPerDegree = 6_371_008.8 * Double.pi / 180

    public mutating func process(_ s: Sample, receivedAt: Date, activity: Activity) -> FilteredPoint? {
        guard s.hAcc >= 0, s.hAcc <= quality.accuracyCeiling,
              receivedAt.timeIntervalSince(s.t) <= 10, s.t.timeIntervalSince(receivedAt) <= 2 else { return nil }
        let q: Double
        switch activity {
        case .cycling, .running: q = 8
        case .automotive: q = 15
        default: q = 6
        }

        if let origin, let last {
            let dt = s.t.timeIntervalSince(last.t)
            guard dt > 0 else { return nil }
            let d = Geo.distance(last.lat, last.lon, s.lat, s.lon)
            if (d - s.hAcc - last.hAcc) / dt > 60 { return nil }

            let cosLat = cos(origin.lat * .pi / 180)
            let zx = (s.lon - origin.lon) * Self.metresPerDegree * cosLat
            let zy = (s.lat - origin.lat) * Self.metresPerDegree
            p += dt * q * q
            let k = p / (p + s.hAcc * s.hAcc)
            x += k * (zx - x)
            y += k * (zy - y)
            p *= 1 - k
        } else {
            origin = Fix(t: s.t, lat: s.lat, lon: s.lon, hAcc: s.hAcc)
            x = 0; y = 0; p = s.hAcc * s.hAcc
        }
        last = Fix(t: s.t, lat: s.lat, lon: s.lon, hAcc: s.hAcc)

        recent.append((x, y, 1 / (max(s.hAcc, 0.1) * max(s.hAcc, 0.1))))   // floor avoids an infinite weight at hAcc 0
        if recent.count > 3 { recent.removeFirst() }
        let w = recent.reduce(0) { $0 + $1.w }
        let mx = recent.reduce(0) { $0 + $1.x * $1.w } / w
        let my = recent.reduce(0) { $0 + $1.y * $1.w } / w
        let o = origin!
        let out = Geo.offset(lat: o.lat, lon: o.lon, north: my, east: mx)
        return FilteredPoint(t: s.t, lat: out.lat, lon: out.lon, rawLat: s.lat, rawLon: s.lon,
                             hAcc: s.hAcc, speed: s.speed, kind: .moving)
    }

    public mutating func reset() {
        origin = nil; last = nil; x = 0; y = 0; p = 0; recent = []
    }
}
