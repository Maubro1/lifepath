import XCTest
@testable import Core

/// The filter and smoother on phone-like error: slow drift (45 s correlation) and a 4 m per-trip offset that no
/// trajectory smoother can remove, sampled every 10 m on foot as LifePath records. 20 seeds, so one lucky seed
/// cannot pass a bad change. The bars are what the code reached when this test was added, plus a small margin:
/// a change to the filter must not raise them.
final class RealisticNoiseTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let block: [(north: Double, east: Double)] = [(0, 0), (300, 0), (300, 400), (0, 400), (0, 0)]
    let seeds: [UInt64] = Array(1...20)

    func median(_ e: [Double]) -> Double { let s = e.sorted(); return s[s.count / 2] }

    func walks() -> [(truth: [(Date, Double, Double)], samples: [Sample])] {
        seeds.map { walk(path: block, speed: 1.4, every: 7, noise: 2, seed: $0, start: t0, doppler: .foot, drift: .phone) }
    }

    func testLiveAndSmoothedMedians() {
        var live: [Double] = [], smooth: [Double] = []
        for w in walks() {
            var f = TrackFilter(quality: .balanced)
            for (s, t) in zip(w.samples, w.truth) {
                guard let p = f.process(s, receivedAt: s.t, activity: .walking) else { continue }
                live.append(Geo.distance(p.lat, p.lon, t.1, t.2))
            }
            smooth += zip(TripSmoother.smooth(w.samples), w.truth).map { Geo.distance($0.lat, $0.lon, $1.1, $1.2) }
        }
        let l = median(live), s = median(smooth)
        print("MEAS realistic live median", l, "smoothed median", s)
        XCTAssertLessThanOrEqual(l, 6.0, "live median \(l) m")
        XCTAssertLessThanOrEqual(s, 5.8, "smoothed median \(s) m")
    }

    func testCorners() {
        var worst = 0.0
        for w in walks() {
            let out = TripSmoother.smooth(w.samples)
            for c in block.dropFirst().dropLast() {
                let p = Geo.offset(lat: 52.37, lon: 4.90, north: c.north, east: c.east)
                worst = max(worst, out.map { Geo.distance($0.lat, $0.lon, p.lat, p.lon) }.min()!)
            }
        }
        print("MEAS realistic worst corner", worst)
        XCTAssertLessThanOrEqual(worst, 11.5, "worst corner \(worst) m")
    }
}
