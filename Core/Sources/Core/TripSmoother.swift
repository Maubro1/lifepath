import Foundation

/// Offline best-estimate line for one finished trip: TrackFilter's calm constant-velocity Kalman forward,
/// then a Rauch–Tung–Striebel backward pass. No IMM, no consistency inflation: the backward pass replaces them.
public enum TripSmoother {
    /// State [p, v] per axis in metres from the first fix; both axes see the same R and Q, so they share one covariance.
    private struct S { var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0, p00 = 0.0, p01 = 0.0, p11 = 0.0 }
    private static let gate = 2.45   // 2-D 95% innovation gate, in sigmas (as TrackFilter)
    private static let metresPerDegree = 6_371_008.8 * Double.pi / 180

    public static func smooth(_ fixes: [Sample]) -> [(t: Date, lat: Double, lon: Double)] {
        guard let o = fixes.first else { return [] }
        let valid = fixes.map(\.speed).filter { $0 >= 0 }.sorted()
        let median = valid.isEmpty ? 0 : valid[valid.count / 2]
        let qa = median < 2.5 ? 1.0 : median < 7 ? 2.0 : 4.0
        let heading = (median < 2.5 ? 10.0 : 3.0) * .pi / 180
        // shortcut: runs (2.5–7 m/s) get the bike/vehicle 3°; R_v differs < 0.25 m²/s² at run speeds; upgrade if trips carry an activity label
        let cosLat = cos(o.lat * .pi / 180)

        var pred: [S] = [], filt: [S] = []
        pred.reserveCapacity(fixes.count); filt.reserveCapacity(fixes.count)
        var s = S()
        var unexplained = 0   // consecutive gated fixes the Doppler does not explain (cap 8), as TrackFilter's calm model
        for (i, f) in fixes.enumerated() {
            let r = f.hAcc >= 0 ? max(f.hAcc, 1) : 1e4   // negative or NaN hAcc: negligible weight (NaN fails >= 0)
            let zx = (f.lon - o.lon) * metresPerDegree * cosLat, zy = (f.lat - o.lat) * metresPerDegree
            if i == 0 {
                s = S(x: zx, y: zy, p00: r * r, p11: 25)
            } else {
                let dt = max(f.t.timeIntervalSince(fixes[i - 1].t), 0), q2 = qa * qa
                s.x += s.vx * dt; s.y += s.vy * dt
                s.p00 += dt * (2 * s.p01 + dt * s.p11) + q2 * dt * dt * dt / 3
                s.p01 += dt * s.p11 + q2 * dt * dt / 2
                s.p11 += q2 * dt
            }
            pred.append(s)
            if i > 0 {
                // Position update with the linear-Huber gate: beyond 2.45σ the measurement variance grows linearly.
                let ex = zx - s.x, ey = zy - s.y
                let ratio = (ex * ex + ey * ey).squareRoot() / (gate * (s.p00 + r * r).squareRoot())
                // A gated fix whose offset valid-course Doppler does not explain is multipath-like: inflate R by the run length.
                let c = f.course * .pi / 180, rv = 0.49 + pow(f.speed * heading, 2)
                let agrees = f.speed >= 0 && f.hAcc >= 0 && f.hAcc <= 20 && f.course >= 0
                    && hypot(f.speed * sin(c) - s.vx, f.speed * cos(c) - s.vy) / (gate * (s.p11 + rv).squareRoot()) < 1
                unexplained = ratio > 1 && agrees ? min(unexplained + 1, 8) : 0
                let sv = s.p00 + r * r * max(ratio, 1) * Double(max(unexplained, 1))
                let k0 = s.p00 / sv, k1 = s.p01 / sv
                s.x += k0 * ex; s.y += k0 * ey; s.vx += k1 * ex; s.vy += k1 * ey
                s.p11 -= k1 * s.p01; s.p01 *= 1 - k0; s.p00 *= 1 - k0
                if f.speed >= 0, f.course >= 0, f.hAcc >= 0, f.hAcc <= 20 {
                    let evx = f.speed * sin(c) - s.vx, evy = f.speed * cos(c) - s.vy
                    let vRatio = (evx * evx + evy * evy).squareRoot() / (gate * (s.p11 + rv).squareRoot())
                    let vInv = 1 / (s.p11 + rv * max(vRatio, 1))
                    let g0 = s.p01 * vInv, g1 = s.p11 * vInv
                    s.x += g0 * evx; s.y += g0 * evy; s.vx += g1 * evx; s.vy += g1 * evy
                    s.p00 -= g0 * s.p01; s.p01 -= g0 * s.p11; s.p11 -= g1 * s.p11
                }
            }
            filt.append(s)
        }

        // RTS backward: C = P_f Fᵀ P_pred⁻¹; x_s = x_f + C (x_s,next − x_pred,next).
        var sm = filt
        for k in stride(from: fixes.count - 2, through: 0, by: -1) {
            let f = filt[k], p = pred[k + 1], n = sm[k + 1]
            let dt = max(fixes[k + 1].t.timeIntervalSince(fixes[k].t), 0)
            let det = p.p00 * p.p11 - p.p01 * p.p01
            guard det > 0 else { continue }   // degenerate prediction: keep the filtered state
            // P_f Fᵀ with F = [[1, dt], [0, 1]], then times P_pred⁻¹ = [[p11, −p01], [−p01, p00]] / det.
            let a00 = f.p00 + dt * f.p01, a01 = f.p01, a10 = f.p01 + dt * f.p11, a11 = f.p11
            let c00 = (a00 * p.p11 - a01 * p.p01) / det, c01 = (a01 * p.p00 - a00 * p.p01) / det
            let c10 = (a10 * p.p11 - a11 * p.p01) / det, c11 = (a11 * p.p00 - a10 * p.p01) / det
            let dx = n.x - p.x, dvx = n.vx - p.vx, dy = n.y - p.y, dvy = n.vy - p.vy
            sm[k].x = f.x + c00 * dx + c01 * dvx; sm[k].vx = f.vx + c10 * dx + c11 * dvx
            sm[k].y = f.y + c00 * dy + c01 * dvy; sm[k].vy = f.vy + c10 * dy + c11 * dvy
        }
        return zip(fixes, sm).map { f, s in
            let p = Geo.offset(lat: o.lat, lon: o.lon, north: s.y, east: s.x)
            return (f.t, p.lat, p.lon)
        }
    }
}
