import Foundation
@testable import Core

/// SplitMix64: deterministic, so synthetic walks are reproducible.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Standard normal via Box-Muller.
    mutating func gaussian() -> Double {
        let u1 = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &self)
        let u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Realistic Doppler for `walk`: speed + N(0, 0.3 m/s), course + AR(1) error (5 s correlation, stationary sigma
/// `courseSigma` degrees), course -1 below 0.5 m/s, and the reported course lagging the true heading by `lag` seconds.
/// Drawn from a separate RNG stream, so positions are the same with or without it.
struct Doppler {
    var courseSigma: Double
    var lag: TimeInterval = 0
    static let foot = Doppler(courseSigma: 10)
    static let vehicle = Doppler(courseSigma: 3, lag: 2)
}

/// Phone-like position error on top of the white `noise`: a first-order Gauss-Markov drift per axis (stationary sigma
/// `sigma` m, correlation time `tau` s) plus a constant per-trip offset of `offset` m in a seeded direction. Measured on
/// phones against RTK: 26-66 s correlation, ~3.5 m slow part, 2-6 m offset (Kanzaki et al. 2025; reports/LifePath tracking accuracy.md).
/// Drawn from its own RNG stream, so the white noise is the same with or without it.
struct Drift {
    var sigma: Double, tau: TimeInterval, offset: Double
    static let phone = Drift(sigma: 3.5, tau: 45, offset: 4)
}

/// Walks `path` (metres north/east of 52.37, 4.90) at `speed` m/s, sampling every `every` s.
/// `noise` is the per-axis sigma in metres of the white part; hAcc = 1.5 x the total per-axis sigma (white and drift).
func walk(path: [(north: Double, east: Double)], speed: Double, every: TimeInterval, noise: Double,
          seed: UInt64, start: Date, doppler: Doppler? = nil, drift: Drift? = nil) -> (truth: [(Date, Double, Double)], samples: [Sample]) {
    let originLat = 52.37, originLon = 4.90
    var rng = SeededRandom(seed: seed)
    var dRng = SeededRandom(seed: seed ^ 0xD099_1E55)
    var courseError = 0.0
    let phi = exp(-every / 5)
    var gRng = SeededRandom(seed: seed ^ 0x6A55_3A2C)
    let angle = Double.random(in: 0..<2 * .pi, using: &gRng)
    var gn = (drift?.sigma ?? 0) * gRng.gaussian(), ge = (drift?.sigma ?? 0) * gRng.gaussian()   // starts stationary
    let hAcc = 1.5 * (noise * noise + pow(drift?.sigma ?? 0, 2)).squareRoot()
    // Leg start times and headings, to look up the heading `lag` seconds ago.
    var legs: [(start: Double, course: Double)] = []
    var acc = 0.0
    for (a, b) in zip(path, path.dropFirst()) {
        let dn = b.north - a.north, de = b.east - a.east
        legs.append((acc, (atan2(de, dn) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)))
        acc += (dn * dn + de * de).squareRoot() / speed
    }
    var truth: [(Date, Double, Double)] = []
    var samples: [Sample] = []
    guard let first = path.first else { return (truth, samples) }

    func emit(_ t: Date, _ n: Double, _ e: Double, course: Double) {
        let p = Geo.offset(lat: originLat, lon: originLon, north: n, east: e)
        var dn = 0.0, de = 0.0
        if let d = drift {
            if !samples.isEmpty {
                let a = exp(-every / d.tau), b = (1 - a * a).squareRoot() * d.sigma
                gn = a * gn + b * gRng.gaussian(); ge = a * ge + b * gRng.gaussian()
            }
            dn = gn + d.offset * cos(angle); de = ge + d.offset * sin(angle)
        }
        let noisy = Geo.offset(lat: p.lat, lon: p.lon, north: rng.gaussian() * noise + dn, east: rng.gaussian() * noise + de)
        truth.append((t, p.lat, p.lon))
        var spd = speed, crs = course
        if let d = doppler {
            spd = max(0, speed + 0.3 * dRng.gaussian())
            courseError = phi * courseError + (1 - phi * phi).squareRoot() * d.courseSigma * dRng.gaussian()
            let secs = t.timeIntervalSince(start) - d.lag
            let heading = legs.last(where: { $0.start <= secs })?.course ?? legs.first?.course ?? course
            crs = spd < 0.5 ? -1 : (heading + courseError + 360).truncatingRemainder(dividingBy: 360)
        }
        samples.append(Sample(t: t, lat: noisy.lat, lon: noisy.lon, hAcc: hAcc, speed: spd, course: crs))
    }

    var nextSample = 0.0    // time of next sample
    var legStart = 0.0      // time at which the current leg begins
    var lastCourse = 0.0
    for (a, b) in zip(path, path.dropFirst()) {
        let dn = b.north - a.north, de = b.east - a.east
        let length = (dn * dn + de * de).squareRoot()
        let duration = length / speed
        let course = (atan2(de, dn) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        lastCourse = course
        while nextSample <= legStart + duration + 1e-9 {
            let f = duration > 0 ? (nextSample - legStart) / duration : 0
            emit(start.addingTimeInterval(nextSample), a.north + dn * f, a.east + de * f, course: course)
            nextSample += every
        }
        legStart += duration
    }
    if samples.isEmpty { emit(start, first.north, first.east, course: lastCourse) }
    return (truth, samples)
}

/// Multipath: the samples in `range` all jump `east` metres sideways, with a confident-looking `hAcc`.
/// Doppler stays as given unless `course` overrides it during the burst: -1 (invalid) or a heading toward the fake displacement.
enum BurstCourse { case keep, invalid, towardFake }
func multipath(_ samples: [Sample], range: Range<Int>, east: Double, hAcc: Double, course: BurstCourse = .keep) -> [Sample] {
    var out = samples
    for i in range {
        let p = Geo.offset(lat: samples[i].lat, lon: samples[i].lon, north: 0, east: east)
        let c: Double
        switch course {
        case .keep: c = samples[i].course
        case .invalid: c = -1
        case .towardFake: c = east >= 0 ? 90 : 270
        }
        out[i] = Sample(t: samples[i].t, lat: p.lat, lon: p.lon, hAcc: hAcc, speed: samples[i].speed, course: c)
    }
    return out
}

/// A vehicle (or walker) along `path` (metres north/east of 52.37, 4.90) at `speed` m/s, halting `seconds` at `atM` metres along it.
/// Precise: `.moving` fixes every `every` s, Gaussian `noise` per axis, Doppler speed + N(0, 0.3) (0 in halts).
/// `rough`: `.rough` fixes every 10 s, hAcc 700–1500, error ≤ 300 m, speed -1, as trains report.
func ride(path: [(north: Double, east: Double)], speed: Double, every: TimeInterval, noise: Double, seed: UInt64, start: Date,
          halts: [(atM: Double, seconds: Double)] = [], rough: Bool = false) -> [FilteredPoint] {
    var rng = SeededRandom(seed: seed)
    let legs = zip(path, path.dropFirst()).map { a, b -> Double in
        let dn = b.north - a.north, de = b.east - a.east
        return (dn * dn + de * de).squareRoot()
    }
    let length = legs.reduce(0, +), stops = halts.sorted { $0.atM < $1.atM }
    // Metres along the path at time t, and whether halted then.
    func along(_ t: Double) -> (m: Double, halted: Bool) {
        var t = t, m = 0.0
        for h in stops {
            let reach = (h.atM - m) / speed
            if t < reach { return (m + t * speed, false) }
            t -= reach; m = h.atM
            if t < h.seconds { return (m, true) }
            t -= h.seconds
        }
        return (min(length, m + t * speed), false)
    }
    func position(_ m: Double) -> (north: Double, east: Double) {
        var m = m
        for (k, l) in legs.enumerated() {
            if m <= l || k == legs.count - 1 {
                let f = l > 0 ? min(1, m / l) : 0, a = path[k], b = path[k + 1]
                return (a.north + f * (b.north - a.north), a.east + f * (b.east - a.east))
            }
            m -= l
        }
        return path[0]
    }
    let duration = length / speed + halts.map(\.seconds).reduce(0, +)
    return stride(from: 0.0, through: duration, by: rough ? 10 : every).map { t -> FilteredPoint in
        let (m, halted) = along(t), at = position(m)
        var en = rng.gaussian() * noise, ee = rng.gaussian() * noise
        if rough {
            let a = Double.random(in: 0..<2 * .pi, using: &rng), r = Double.random(in: 0...300, using: &rng)
            en = r * sin(a); ee = r * cos(a)
        }
        let p = Geo.offset(lat: 52.37, lon: 4.90, north: at.north + en, east: at.east + ee)
        let hAcc: Double = rough ? .random(in: 700...1500, using: &rng) : noise * 1.5
        let v: Double = rough ? -1 : halted ? 0 : max(0, speed + 0.3 * rng.gaussian())
        return FilteredPoint(t: start.addingTimeInterval(t), lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon,
                             hAcc: hAcc, speed: v, kind: rough ? .rough : .moving)
    }
}
