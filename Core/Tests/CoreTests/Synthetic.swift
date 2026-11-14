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

/// Walks `path` (metres north/east of 52.37, 4.90) at `speed` m/s, sampling every `every` s.
/// `noise` is the per-axis sigma in metres; hAcc = noise * 1.5.
func walk(path: [(north: Double, east: Double)], speed: Double, every: TimeInterval, noise: Double,
          seed: UInt64, start: Date, doppler: Doppler? = nil) -> (truth: [(Date, Double, Double)], samples: [Sample]) {
    let originLat = 52.37, originLon = 4.90
    var rng = SeededRandom(seed: seed)
    var dRng = SeededRandom(seed: seed ^ 0xD099_1E55)
    var courseError = 0.0
    let phi = exp(-every / 5)
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
        let noisy = Geo.offset(lat: p.lat, lon: p.lon, north: rng.gaussian() * noise, east: rng.gaussian() * noise)
        truth.append((t, p.lat, p.lon))
        var spd = speed, crs = course
        if let d = doppler {
            spd = max(0, speed + 0.3 * dRng.gaussian())
            courseError = phi * courseError + (1 - phi * phi).squareRoot() * d.courseSigma * dRng.gaussian()
            let secs = t.timeIntervalSince(start) - d.lag
            let heading = legs.last(where: { $0.start <= secs })?.course ?? legs.first?.course ?? course
            crs = spd < 0.5 ? -1 : (heading + courseError + 360).truncatingRemainder(dividingBy: 360)
        }
        samples.append(Sample(t: t, lat: noisy.lat, lon: noisy.lon, hAcc: noise * 1.5, speed: spd, course: crs))
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
