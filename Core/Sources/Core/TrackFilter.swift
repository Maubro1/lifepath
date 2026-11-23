import Foundation

public struct TrackFilter: Sendable {
    public var quality: Quality
    public init(quality: Quality) { self.quality = quality }

    private struct Fix { var t: Date; var lat, lon, hAcc: Double }
    private var origin: Fix?            // first accepted sample; Kalman state is metres from here
    private var last: Fix?              // last accepted raw sample
    private var lastRough: Date?        // last kept rough fix: at most one per 10 s
    // Two-model IMM: calm (qa) and manoeuvre (qa × manoeuvre); each a CV Kalman filter, mixed per fix.
    private var models = [CV(), CV()]
    private var mu = [0.9, 0.1]         // model probabilities
    private var unexplained = 0         // consecutive gated fixes the calm model's Doppler does not explain (cap 8)
    private var gatedRun: [(x: Double, y: Double)] = []   // raw positions of the current run of gated fixes (last 10)

    public private(set) var dropCounts: [String: Int] = [:]
    private var speedAccs: [Double] = [], courseAccs: [Double] = []   // iOS's own Doppler accuracies since the last take
    /// Median speed and course accuracy iOS reported since the last call, for the health report; nil when none arrived.
    public mutating func takeDopplerSummary() -> String? {
        defer { speedAccs = []; courseAccs = [] }
        func median(_ v: [Double]) -> String { v.isEmpty ? "-" : String(format: "%.2f", v.sorted()[v.count / 2]) }
        guard !speedAccs.isEmpty || !courseAccs.isEmpty else { return nil }
        return "speedAcc=\(median(speedAccs)) courseAcc=\(median(courseAccs)) n=\(max(speedAccs.count, courseAccs.count))"
    }
    public mutating func takeDropCounts() -> [String: Int] { defer { dropCounts = [:] }; return dropCounts }
    private mutating func drop(_ reason: String) -> FilteredPoint? { dropCounts[reason, default: 0] += 1; return nil }

    private static let gate = 2.45   // 2-D 95% innovation gate, in sigmas
    private static let manoeuvre = 8.0   // qa multiplier of the manoeuvre model
    private static let switchRate = 0.2 // model switches per second
    private static let metresPerDegree = 6_371_008.8 * Double.pi / 180

    /// Constant-velocity Kalman state per axis; both axes see the same hAcc and q, so they share one covariance.
    private struct CV: Sendable {
        var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0
        var p00 = 0.0, p01 = 0.0, p11 = 0.0

        mutating func predict(_ dt: Double, qa: Double) {
            x += vx * dt; y += vy * dt
            let q2 = qa * qa
            p00 += dt * (2 * p01 + dt * p11) + q2 * dt * dt * dt / 3
            p01 += dt * p11 + q2 * dt * dt / 2
            p11 += q2 * dt
        }

        /// Robust update: an innovation beyond the gate (2-D 95%) inflates the measurement variance linearly; never dropped.
        /// Returns the 2-D Gaussian likelihood of the innovation under the gated variance.
        func gateRatio(zx: Double, zy: Double, hAcc: Double) -> Double {
            ((zx - x) * (zx - x) + (zy - y) * (zy - y)).squareRoot() / (TrackFilter.gate * (p00 + hAcc * hAcc).squareRoot())
        }

        mutating func update(zx: Double, zy: Double, hAcc: Double, inflate: Double = 1) -> Double {
            let ex = zx - x, ey = zy - y
            let d2 = ex * ex + ey * ey
            let sGated = p00 + hAcc * hAcc * max(gateRatio(zx: zx, zy: zy, hAcc: hAcc), 1)
            let s = sGated + hAcc * hAcc * max(gateRatio(zx: zx, zy: zy, hAcc: hAcc), 1) * (inflate - 1)
            let k0 = p00 / s, k1 = p01 / s
            x += k0 * ex; y += k0 * ey; vx += k1 * ex; vy += k1 * ey
            p11 -= k1 * p01; p01 *= 1 - k0; p00 *= 1 - k0
            return exp(-0.5 * d2 / sGated) / (2 * .pi * sGated)   // likelihood under the gated R only, so the inflation cannot make the calm model look more likely
        }

        /// Doppler velocity with the same Huber gate; course -1 uses the speed along the filter's own heading.
        /// Returns the likelihood of the velocity innovation (1 when no update is made).
        mutating func doppler(speed: Double, course: Double, rv: Double) -> Double {
            let vNorm = (vx * vx + vy * vy).squareRoot()
            guard course >= 0 || vNorm > 0.3 else { return 1 }
            let c = course * .pi / 180
            let zE = course >= 0 ? speed * sin(c) : speed * vx / vNorm
            let zN = course >= 0 ? speed * cos(c) : speed * vy / vNorm
            let evx = zE - vx, evy = zN - vy
            let vRatio = velocityRatio(zE: zE, zN: zN, rv: rv)
            let vInv = 1 / (p11 + rv * max(vRatio, 1))
            let g0 = p01 * vInv, g1 = p11 * vInv
            x += g0 * evx; y += g0 * evy; vx += g1 * evx; vy += g1 * evy
            p00 -= g0 * p01; p01 -= g0 * p11; p11 -= g1 * p11
            return exp(-0.5 * (evx * evx + evy * evy) * vInv) * vInv / (2 * .pi)
        }

        func velocityRatio(zE: Double, zN: Double, rv: Double) -> Double {
            ((zE - vx) * (zE - vx) + (zN - vy) * (zN - vy)).squareRoot() / (TrackFilter.gate * (p11 + rv).squareRoot())
        }
    }

    public mutating func process(_ s: Sample, receivedAt: Date, activity: Activity) -> FilteredPoint? {
        guard s.hAcc >= 0 else { return drop("accuracy") }
        if s.speedAccuracy >= 0 { speedAccs.append(s.speedAccuracy) }
        if s.courseAccuracy >= 0 { courseAccs.append(s.courseAccuracy) }
        guard receivedAt.timeIntervalSince(s.t) <= 10 else { return drop("stale") }
        guard s.t.timeIntervalSince(receivedAt) <= 2 else { return drop("future") }
        if s.hAcc >= quality.accuracyCeiling {   // kept raw, never fed to the Kalman state; Wi-Fi fixes report 65 m or more (Apple)
            if let r = lastRough, s.t.timeIntervalSince(r) < 10 { return drop(s.t > r ? "rough-spacing" : "order") }
            lastRough = s.t
            return FilteredPoint(t: s.t, lat: s.lat, lon: s.lon, rawLat: s.lat, rawLon: s.lon, hAcc: s.hAcc, speed: -1, kind: .rough)
        }
        let qa: Double   // acceleration noise of the calm model, m/s^2
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
            // Mixing: model j starts from the blend of both models, weighted by P(was i | now j).
            let stay = exp(-Self.switchRate * dt)
            let c = [stay * mu[0] + (1 - stay) * mu[1], (1 - stay) * mu[0] + stay * mu[1]]
            let prior = models
            for j in 0..<2 {
                let w = (0..<2).map { i in (i == j ? stay : 1 - stay) * mu[i] / c[j] }
                var m = CV()
                for i in 0..<2 {
                    m.x += w[i] * prior[i].x; m.y += w[i] * prior[i].y; m.vx += w[i] * prior[i].vx; m.vy += w[i] * prior[i].vy
                }
                for i in 0..<2 {   // spread terms averaged over the two axes to keep one shared covariance
                    let dx = prior[i].x - m.x, dy = prior[i].y - m.y, dvx = prior[i].vx - m.vx, dvy = prior[i].vy - m.vy
                    m.p00 += w[i] * (prior[i].p00 + (dx * dx + dy * dy) / 2)
                    m.p01 += w[i] * (prior[i].p01 + (dx * dvx + dy * dvy) / 2)
                    m.p11 += w[i] * (prior[i].p11 + (dvx * dvx + dvy * dvy) / 2)
                }
                models[j] = m
            }
            // Doppler speed sigma 0.7 m/s plus heading error * speed. iOS's own per-fix accuracies only ever widen these:
            // their calibration is unmeasured, so they may down-weight a spike but never make a reading more trusted.
            let floor = activity == .cycling || activity == .automotive ? 3.0 : 10.0
            let heading = max(floor, s.courseAccuracy) * .pi / 180
            let rv = pow(max(0.7, s.speedAccuracy), 2) + pow(s.speed * heading, 2)
            for j in 0..<2 { models[j].predict(dt, qa: j == 0 ? qa : qa * Self.manoeuvre) }
            // A gated fix whose offset the calm model's (valid-course) Doppler does not explain is multipath-like:
            // inflate the calm model's R by the run length. Course -1 never counts as agreeing.
            let gated = models[0].gateRatio(zx: zx, zy: zy, hAcc: s.hAcc) > 1
            let course = s.course * .pi / 180
            let agrees = s.speed >= 0 && s.hAcc <= 20 && s.course >= 0
                && models[0].velocityRatio(zE: s.speed * sin(course), zN: s.speed * cos(course), rv: rv) < 1
            unexplained = gated && agrees ? min(unexplained + 1, 8) : 0
            gatedRun = gated ? Array((gatedRun + [(zx, zy)]).suffix(10)) : []
            // Divergence guard: 10 gated fixes that agree with each other are a real shift; re-seed from their mean.
            let mx = gatedRun.map(\.x).reduce(0, +) / 10, my = gatedRun.map(\.y).reduce(0, +) / 10
            if gatedRun.count == 10, gatedRun.allSatisfy({ hypot($0.x - mx, $0.y - my) <= 2 * s.hAcc }) {
                let valid = s.speed >= 0 && s.hAcc <= 20 && s.course >= 0
                for j in 0..<2 {
                    models[j].x = mx; models[j].y = my; models[j].p00 = s.hAcc * s.hAcc; models[j].p01 = 0
                    if valid { models[j].vx = s.speed * sin(course); models[j].vy = s.speed * cos(course); models[j].p11 = rv }
                }
                gatedRun = []; unexplained = 0
            }
            var like = [0.0, 0.0]
            for j in 0..<2 {
                like[j] = models[j].update(zx: zx, zy: zy, hAcc: s.hAcc, inflate: j == 0 ? Double(max(unexplained, 1)) : 1)
                if s.speed >= 0, s.hAcc <= 20 { like[j] *= models[j].doppler(speed: s.speed, course: s.course, rv: rv) }
            }
            let total = like[0] * c[0] + like[1] * c[1]
            if total > 0 { mu = [like[0] * c[0] / total, like[1] * c[1] / total] } else { mu = c }
        } else {
            origin = Fix(t: s.t, lat: s.lat, lon: s.lon, hAcc: s.hAcc)
            let m = CV(p00: s.hAcc * s.hAcc, p11: 25)
            models = [m, m]; mu = [0.9, 0.1]; unexplained = 0; gatedRun = []
        }
        last = Fix(t: s.t, lat: s.lat, lon: s.lon, hAcc: s.hAcc)

        let o = origin!
        let out = Geo.offset(lat: o.lat, lon: o.lon, north: mu[0] * models[0].y + mu[1] * models[1].y,
                             east: mu[0] * models[0].x + mu[1] * models[1].x)
        return FilteredPoint(t: s.t, lat: out.lat, lon: out.lon, rawLat: s.lat, rawLon: s.lon,
                             hAcc: s.hAcc, speed: s.speed >= 0 && s.hAcc <= 20 ? s.speed : -1, kind: .moving,
                             course: s.course >= 0 && s.hAcc <= 20 ? s.course : -1)
    }

    public mutating func reset() {
        origin = nil; last = nil; lastRough = nil; models = [CV(), CV()]; mu = [0.9, 0.1]; unexplained = 0; gatedRun = []
    }
}
