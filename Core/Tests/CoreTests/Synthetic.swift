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

/// Walks `path` (metres north/east of 52.37, 4.90) at `speed` m/s, sampling every `every` s.
/// `noise` is the per-axis sigma in metres; hAcc = noise * 1.5.
func walk(path: [(north: Double, east: Double)], speed: Double, every: TimeInterval, noise: Double,
          seed: UInt64, start: Date) -> (truth: [(Date, Double, Double)], samples: [Sample]) {
    let originLat = 52.37, originLon = 4.90
    var rng = SeededRandom(seed: seed)
    var truth: [(Date, Double, Double)] = []
    var samples: [Sample] = []
    guard let first = path.first else { return (truth, samples) }

    func emit(_ t: Date, _ n: Double, _ e: Double, course: Double) {
        let p = Geo.offset(lat: originLat, lon: originLon, north: n, east: e)
        let noisy = Geo.offset(lat: p.lat, lon: p.lon, north: rng.gaussian() * noise, east: rng.gaussian() * noise)
        truth.append((t, p.lat, p.lon))
        samples.append(Sample(t: t, lat: noisy.lat, lon: noisy.lon, hAcc: noise * 1.5, speed: speed, course: course))
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
func multipath(_ samples: [Sample], range: Range<Int>, east: Double, hAcc: Double) -> [Sample] {
    var out = samples
    for i in range {
        let p = Geo.offset(lat: samples[i].lat, lon: samples[i].lon, north: 0, east: east)
        out[i] = Sample(t: samples[i].t, lat: p.lat, lon: p.lon, hAcc: hAcc, speed: samples[i].speed, course: samples[i].course)
    }
    return out
}
