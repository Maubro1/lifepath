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

    public private(set) var dropCounts: [String: Int] = [:]
    public mutating func takeDropCounts() -> [String: Int] { defer { dropCounts = [:] }; return dropCounts }
    private mutating func drop(_ reason: String) -> FilteredPoint? { dropCounts[reason, default: 0] += 1; return nil }

    private static let gate = 1.0   // innovation gate in sigmas; 2.5 let an 8-fix, 30 m burst drag the line 37 m (measured)
    private static let metresPerDegree = 6_371_008.8 * Double.pi / 180

    public mutating func process(_ s: Sample, receivedAt: Date, activity: Activity) -> FilteredPoint? {
        guard s.hAcc >= 0, s.hAcc <= quality.accuracyCeiling else { return drop("accuracy") }
        guard receivedAt.timeIntervalSince(s.t) <= 10 else { return drop("stale") }
        guard s.t.timeIntervalSince(receivedAt) <= 2 else { return drop("future") }
        let qa: Double   // acceleration noise, m/s^2
        switch activity {
        case .running, .cycling: qa = 2
        case .automotive: qa = 4
        default: qa = 1
        }

        if let origin, let last {
            let dt = s.t.timeIntervalSince(last.t)
            guard dt > 0 else { return drop("order") }
            let jump = Geo.distance(last.lat, last.lon, s.lat, s.lon)
            if (jump - s.hAcc - last.hAcc) / dt > 60 { return drop("teleport") }

            let cosLat = cos(origin.lat * .pi / 180)
            let zx = (s.lon - origin.lon) * Self.metresPerDegree * cosLat
            let zy = (s.lat - origin.lat) * Self.metresPerDegree
            x += vx * dt; y += vy * dt
            let (prior00, prior01, prior11) = (p00, p01, p11)
            let q2 = qa * qa
            p00 += dt * (2 * p01 + dt * p11) + q2 * dt * dt * dt / 3
            p01 += dt * p11 + q2 * dt * dt / 2
            p11 += q2 * dt
            // Robust update: an innovation beyond the gate inflates the measurement variance by ratio^2 (never dropped).
            let ex = zx - x, ey = zy - y
            let sigma = (p00 + s.hAcc * s.hAcc).squareRoot()
            let ratio = (ex * ex + ey * ey).squareRoot() / (Self.gate * sigma)
            let gated = ratio > 1
            let sInv = 1 / (p00 + s.hAcc * s.hAcc * (gated ? ratio * ratio : 1))
            let k0 = p00 * sInv, k1 = p01 * sInv
            x += k0 * ex; y += k0 * ey; vx += k1 * ex; vy += k1 * ey
            p11 -= k1 * p01; p01 *= 1 - k0; p00 *= 1 - k0
            // A gated fix carries no information, so the uncertainty must not balloon and let the next outlier through.
            if gated { (p00, p01, p11) = (prior00, prior01, prior11) }
        } else {
            origin = Fix(t: s.t, lat: s.lat, lon: s.lon, hAcc: s.hAcc)
            x = 0; y = 0; vx = 0; vy = 0; p00 = s.hAcc * s.hAcc; p01 = 0; p11 = 25
        }
        last = Fix(t: s.t, lat: s.lat, lon: s.lon, hAcc: s.hAcc)

        let o = origin!
        let out = Geo.offset(lat: o.lat, lon: o.lon, north: y, east: x)
        return FilteredPoint(t: s.t, lat: out.lat, lon: out.lon, rawLat: s.lat, rawLon: s.lon,
                             hAcc: s.hAcc, speed: s.speed >= 0 && s.hAcc <= 20 ? s.speed : -1, kind: .moving)
    }

    public mutating func reset() {
        origin = nil; last = nil; x = 0; y = 0; vx = 0; vy = 0; p00 = 0; p01 = 0; p11 = 0
    }
}
