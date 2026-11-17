import Foundation

/// Offline best-estimate line for one finished trip: TrackFilter's calm constant-velocity Kalman forward,
/// then a Rauch–Tung–Striebel backward pass. No IMM, no consistency inflation: the backward pass replaces them.
public enum TripSmoother {
    /// State [p, v] per axis in metres from the first fix; both axes see the same R and Q, so they share one covariance.
    private struct S { var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0, p00 = 0.0, p01 = 0.0, p11 = 0.0 }
    private static let gate = 2.45   // 2-D 95% innovation gate, in sigmas (as TrackFilter)
    private static let metresPerDegree = 6_371_008.8 * Double.pi / 180

    /// Bump to re-smooth every stored trip once (SmoothingService compares it with the diary's `meta`).
    public static let version = 2

    /// Time-weighted median speed: valid Doppler, and each rough stretch at its end-to-end speed (a train ride of rough
    /// fixes is not a walk). Below 2.5 m/s the trip counts as walking.
    public static func medianSpeed(_ fixes: [Sample], rough: Set<Int>) -> Double {
        var v: [(speed: Double, w: Double)] = []
        var i = 0
        while i < fixes.count {
            var j = i
            if rough.contains(i) {
                while j + 1 < fixes.count, rough.contains(j + 1) { j += 1 }
                let dt = fixes[j].t.timeIntervalSince(fixes[i].t)
                if dt > 0 { v.append((Geo.distance(fixes[i].lat, fixes[i].lon, fixes[j].lat, fixes[j].lon) / dt, dt)) }
            } else if fixes[i].speed >= 0 {
                v.append((fixes[i].speed, i + 1 < fixes.count ? min(max(fixes[i + 1].t.timeIntervalSince(fixes[i].t), 0), 30) : 1))
            }
            i = j + 1
        }
        v.sort { $0.speed < $1.speed }
        var half = v.reduce(0) { $0 + $1.w } / 2
        for x in v { half -= x.w; if half <= 0 { return x.speed } }
        return 0
    }

    /// `rough`: indices of `.rough` fixes; `pace`: step-counter speed per 30 s bucket (by bucket start), used on walking trips only.
    public static func smooth(_ fixes: [Sample], rough: Set<Int> = [], pace: [(t: Date, speed: Double)] = []) -> [(t: Date, lat: Double, lon: Double)] {
        guard let o = fixes.first else { return [] }
        let median = medianSpeed(fixes, rough: rough), walking = median < 2.5
        let qa = median < 2.5 ? 1.0 : median < 7 ? 2.0 : 4.0
        let heading = (median < 2.5 ? 10.0 : 3.0) * .pi / 180
        // shortcut: runs (2.5–7 m/s) get the bike/vehicle 3°; R_v differs < 0.25 m²/s² at run speeds; upgrade if trips carry an activity label
        let cosLat = cos(o.lat * .pi / 180)
        let z = fixes.map { f in (x: (f.lon - o.lon) * metresPerDegree * cosLat, y: (f.lat - o.lat) * metresPerDegree) }
        var r = fixes.map { $0.hAcc >= 0 ? max($0.hAcc, 1) : 1e4 }   // per-axis sigma; negative or NaN hAcc: negligible weight
        let n = fixes.count
        func gap(_ a: Int, _ b: Int) -> Double { fixes[b].t.timeIntervalSince(fixes[a].t) }

        // Rough stretches are weighed by consistency, not by iOS's (often ~1 km) accuracy: the robust spread of second
        // differences (residual against the time-interpolated neighbours, ×2) is √6 σ for near-constant motion.
        var i = 0
        while i < n {
            var j = i
            while rough.contains(i), j + 1 < n, rough.contains(j + 1) { j += 1 }
            if j - i >= 2 {
                var d: [Double] = []
                for k in i + 1..<j where gap(k - 1, k + 1) > 0 {
                    let w = gap(k - 1, k) / gap(k - 1, k + 1)
                    d.append(abs(2 * (z[k].x - z[k - 1].x - w * (z[k + 1].x - z[k - 1].x))))
                    d.append(abs(2 * (z[k].y - z[k - 1].y - w * (z[k + 1].y - z[k - 1].y))))
                }
                if !d.isEmpty {
                    d.sort()
                    let sigma = 1.4826 * d[d.count / 2] / 6.0.squareRoot()   // median absolute value → σ
                    for k in i...j where r[k] < 1e4 { r[k] = min(max(sigma, 20), r[k]) }
                }
            }
            i = j + 1
        }

        // Spikes: a run of ≤ 3 fixes within 30 s whose excursion from the line between its neighbours, beyond all their
        // accuracies, needs a speed above the trip's plausible maximum, while the neighbours line up: both on the line between
        // the outer neighbours and reachable from each other at that speed, within accuracy (so a spike or the edge of a longer
        // burst never serves as a neighbour).
        // shortcut: a spike at the very first or last fix stays; upgrade if trip ends show spikes on the map
        func off(_ k: Int, _ p: Int, _ q: Int) -> Double {   // distance from the p→q line at k's time, beyond the accuracies
            let w = gap(p, k) / gap(p, q)
            return hypot(z[k].x - z[p].x - w * (z[q].x - z[p].x), z[k].y - z[p].y - w * (z[q].y - z[p].y)) - r[k] - max(r[p], r[q])
        }
        let vmax = median < 2.5 ? 4 : median < 7 ? 15 : 3 * median
        for a in 1..<max(n - 2, 1) {
            for len in 1...3 where a + len + 2 < n {
                let b = a + len + 1
                guard gap(a - 1, a) > 0, gap(a, b) > 0, gap(b, b + 1) > 0, gap(a + 1, b - 1) <= 30,
                      r[a] < 1e4, r[b] < 1e4, off(a, a - 1, b + 1) <= 0, off(b, a - 1, b + 1) <= 0,
                      hypot(z[b].x - z[a].x, z[b].y - z[a].y) - r[a] - r[b] <= vmax * gap(a, b) else { continue }
                if (a + 1..<b).contains(where: { off($0, a, b) / max(min(gap(a, $0), gap($0, b)), 0.5) > vmax }) {
                    for k in a + 1..<b { r[k] = 1e4 }
                }
            }
        }

        var pred: [S] = [], filt: [S] = []
        pred.reserveCapacity(fixes.count); filt.reserveCapacity(fixes.count)
        var s = S()
        var unexplained = 0   // consecutive gated fixes the Doppler does not explain (cap 8), as TrackFilter's calm model
        var pj = 0   // pace bucket cursor
        for (i, f) in fixes.enumerated() {
            let r = r[i], zx = z[i].x, zy = z[i].y
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
                    velocity(&s, evx, evy, rv * max(vRatio, 1))
                } else if walking, !rough.contains(i), !pace.isEmpty {
                    // Step-counter pace as a speed along the filter's own heading (σ 0.3 m/s): a zigzag the steps cannot explain is pulled straight.
                    // shortcut: an isotropic 2-D velocity update keeps the shared covariance but is overconfident across the heading; upgrade if corners suffer
                    while pj + 1 < pace.count, pace[pj + 1].t <= f.t { pj += 1 }
                    let sp = hypot(s.vx, s.vy)
                    if pace[pj].t <= f.t, f.t.timeIntervalSince(pace[pj].t) < 30, sp > 0.1 {
                        let k = pace[pj].speed / sp - 1
                        velocity(&s, k * s.vx, k * s.vy, 0.09)
                    }
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

    /// Velocity measurement update with innovation (evx, evy) and per-axis variance `rv`.
    private static func velocity(_ s: inout S, _ evx: Double, _ evy: Double, _ rv: Double) {
        let vInv = 1 / (s.p11 + rv)
        let g0 = s.p01 * vInv, g1 = s.p11 * vInv
        s.x += g0 * evx; s.y += g0 * evy; s.vx += g1 * evx; s.vy += g1 * evy
        s.p00 -= g0 * s.p01; s.p01 -= g0 * s.p11; s.p11 -= g1 * s.p11
    }
}
