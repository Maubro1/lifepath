import Foundation

public struct TrackFilter: Sendable {
    public var quality: Quality
    public init(quality: Quality) { self.quality = quality }

    private struct Fix { var t: Date; var lat, lon, hAcc: Double }
    private var origin: Fix?            // first accepted sample; Kalman state is metres from here
    private var last: Fix?              // last accepted raw sample
    // Constant-velocity Kalman state per axis; both axes see the same hAcc and q, so they share one covariance.
    private var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0
    private var p00 = 0.0, p01 = 0.0, p11 = 0.0

    private static let metresPerDegree = 6_371_008.8 * Double.pi / 180

    public mutating func process(_ s: Sample, receivedAt: Date, activity: Activity) -> FilteredPoint? {
        guard s.hAcc >= 0, s.hAcc <= quality.accuracyCeiling,
              receivedAt.timeIntervalSince(s.t) <= 10, s.t.timeIntervalSince(receivedAt) <= 2 else { return nil }
        let qa: Double   // acceleration noise, m/s^2
        switch activity {
        case .running, .cycling: qa = 2
        case .automotive: qa = 4
        default: qa = 1
        }

        if let origin, let last {
            let dt = s.t.timeIntervalSince(last.t)
            guard dt > 0 else { return nil }
            let d = Geo.distance(last.lat, last.lon, s.lat, s.lon)
            if (d - s.hAcc - last.hAcc) / dt > 60 { return nil }

            let cosLat = cos(origin.lat * .pi / 180)
            let zx = (s.lon - origin.lon) * Self.metresPerDegree * cosLat
            let zy = (s.lat - origin.lat) * Self.metresPerDegree
            x += vx * dt; y += vy * dt
            let q2 = qa * qa
            p00 += dt * (2 * p01 + dt * p11) + q2 * dt * dt * dt / 3
            p01 += dt * p11 + q2 * dt * dt / 2
            p11 += q2 * dt
            let sInv = 1 / (p00 + s.hAcc * s.hAcc)
            let k0 = p00 * sInv, k1 = p01 * sInv
            let ex = zx - x, ey = zy - y
            x += k0 * ex; y += k0 * ey; vx += k1 * ex; vy += k1 * ey
            p11 -= k1 * p01; p01 *= 1 - k0; p00 *= 1 - k0
        } else {
            origin = Fix(t: s.t, lat: s.lat, lon: s.lon, hAcc: s.hAcc)
            x = 0; y = 0; vx = 0; vy = 0; p00 = s.hAcc * s.hAcc; p01 = 0; p11 = 25
        }
        last = Fix(t: s.t, lat: s.lat, lon: s.lon, hAcc: s.hAcc)

        let o = origin!
        let out = Geo.offset(lat: o.lat, lon: o.lon, north: y, east: x)
        return FilteredPoint(t: s.t, lat: out.lat, lon: out.lon, rawLat: s.lat, rawLon: s.lon,
                             hAcc: s.hAcc, speed: s.speed, kind: .moving)
    }

    public mutating func reset() {
        origin = nil; last = nil; x = 0; y = 0; vx = 0; vy = 0; p00 = 0; p01 = 0; p11 = 0
    }
}
