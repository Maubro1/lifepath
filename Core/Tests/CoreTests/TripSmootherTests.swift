import XCTest
@testable import Core

final class TripSmootherTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let block: [(north: Double, east: Double)] = [(0, 0), (300, 0), (300, 400), (0, 400), (0, 0)]

    /// Per-index error (m) of `out` against `truth`.
    func errors(_ out: [(t: Date, lat: Double, lon: Double)], _ truth: [(Date, Double, Double)]) -> [Double] {
        XCTAssertEqual(out.count, truth.count)
        return zip(out, truth).map { Geo.distance($0.lat, $0.lon, $1.1, $1.2) }
    }
    func median(_ e: [Double]) -> Double { let s = e.sorted(); return s[s.count / 2] }

    /// Live filter errors on the exact same samples (quality .balanced, activity .walking).
    func liveErrors(_ samples: [Sample], _ truth: [(Date, Double, Double)]) -> [Double] {
        var f = TrackFilter(quality: .balanced)
        let e = zip(samples, truth).map { s, t in
            f.process(s, receivedAt: s.t, activity: .walking).map { Geo.distance($0.lat, $0.lon, t.1, t.2) } ?? .nan
        }
        XCTAssertFalse(e.contains { $0.isNaN }, "the live filter dropped a fix")
        return e
    }

    func testWalkMedianAtMost6mWithoutCourse() {
        let w = walk(path: block, speed: 1.4, every: 1, noise: 12, seed: 7, start: t0, doppler: .foot)
        let fixes = w.samples.map { var f = $0; f.course = -1; return f }
        let m = median(errors(TripSmoother.smooth(fixes), w.truth))
        print("MEAS smoother no-course median", m)
        XCTAssertLessThanOrEqual(m, 6, "median \(m) m")
    }

    func testWalkNotWorseThanLiveFilter() {
        let w = walk(path: block, speed: 1.4, every: 1, noise: 12, seed: 7, start: t0, doppler: .foot)
        let s = median(errors(TripSmoother.smooth(w.samples), w.truth))
        let l = median(liveErrors(w.samples, w.truth))
        print("MEAS walk median smoother", s, "live", l)
        XCTAssertLessThanOrEqual(s, l, "smoother median \(s) m, live \(l) m")
    }

    func testCornersWithin10m() {
        let w = walk(path: block, speed: 1.4, every: 1, noise: 12, seed: 7, start: t0, doppler: .foot)
        let out = TripSmoother.smooth(w.samples)
        for c in block.dropFirst().dropLast() {
            let p = Geo.offset(lat: 52.37, lon: 4.90, north: c.north, east: c.east)
            let d = out.map { Geo.distance($0.lat, $0.lon, p.lat, p.lon) }.min()!
            print("MEAS smoother corner", c, d)
            XCTAssertLessThanOrEqual(d, 10, "corner \(c) nearest output \(d) m")
        }
    }

    func testMultipathBurstBetterThanLive() {
        let w = walk(path: [(0, 0), (400, 0)], speed: 1.4, every: 1, noise: 3, seed: 5, start: t0, doppler: .foot)
        let samples = multipath(w.samples, range: 100..<108, east: 30, hAcc: 8)
        let s = errors(TripSmoother.smooth(samples), w.truth)[100..<108].max()!
        let l = liveErrors(samples, w.truth)[100..<108].max()!
        print("MEAS burst max smoother", s, "live", l)
        XCTAssertLessThanOrEqual(s, l, "max deviation in burst: smoother \(s) m, live \(l) m")
    }

    func testNoCourseFallsBackToPositionOnly() {
        let w = walk(path: block, speed: 1.4, every: 1, noise: 12, seed: 3, start: t0, doppler: .foot)
        let fixes = w.samples.enumerated().map { i, f in var f = f; if i % 3 == 0 { f.course = -1 }; if i % 7 == 0 { f.speed = -1 }; return f }
        let out = TripSmoother.smooth(fixes)
        XCTAssertEqual(out.count, fixes.count)
        XCTAssertFalse(out.contains { !$0.lat.isFinite || !$0.lon.isFinite }, "NaN or infinite output")
        print("MEAS mixed-course median", median(errors(out, w.truth)))
    }

    func testSmootherNeverBridgesTrips() {
        let w = walk(path: [(0, 0), (200, 0)], speed: 1.4, every: 1, noise: 5, seed: 13, start: t0, doppler: .foot)
        let fixes = w.samples
        let out = TripSmoother.smooth(fixes)
        XCTAssertEqual(out.count, fixes.count)
        XCTAssertEqual(out.map(\.t), fixes.map(\.t))
    }

    func testSingleAndTwoFixTrips() {
        XCTAssertTrue(TripSmoother.smooth([]).isEmpty)
        let a = Sample(t: t0, lat: 52.37, lon: 4.90, hAcc: 10, speed: -1, course: -1)
        let one = TripSmoother.smooth([a])
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].lat, a.lat, accuracy: 1e-9); XCTAssertEqual(one[0].lon, a.lon, accuracy: 1e-9)
        let p = Geo.offset(lat: 52.37, lon: 4.90, north: 10, east: 0)
        let b = Sample(t: t0.addingTimeInterval(5), lat: p.lat, lon: p.lon, hAcc: 10, speed: 2, course: 0)
        let two = TripSmoother.smooth([a, b])
        XCTAssertEqual(two.map(\.t), [a.t, b.t])
        let moved = Geo.distance(two[0].lat, two[0].lon, a.lat, a.lon)
        print("MEAS two-fix first moved", moved)
        XCTAssertGreaterThan(moved, 0.1, "the backward pass pulls the first fix toward the second (forward-only leaves it at 0)")
        for q in two {
            XCTAssertTrue(q.lat.isFinite && q.lon.isFinite)
            XCTAssertLessThanOrEqual(Geo.distance(q.lat, q.lon, 52.37, 4.90), 15, "stays between the two fixes")
        }
    }

    func testInvalidAccuracyFixBarelyMovesLine() {
        let w = walk(path: [(0, 0), (300, 0)], speed: 1.4, every: 1, noise: 3, seed: 17, start: t0, doppler: .foot)
        var fixes = w.samples
        let clean = TripSmoother.smooth(fixes)
        let p = Geo.offset(lat: fixes[100].lat, lon: fixes[100].lon, north: 0, east: 200)
        fixes[100].lat = p.lat; fixes[100].lon = p.lon; fixes[100].hAcc = -1
        let out = TripSmoother.smooth(fixes)
        XCTAssertFalse(out.contains { !$0.lat.isFinite || !$0.lon.isFinite }, "NaN or infinite output")
        let d = zip(out, clean).map { Geo.distance($0.lat, $0.lon, $1.lat, $1.lon) }.max()!
        print("MEAS invalid-accuracy max deviation", d)
        XCTAssertLessThanOrEqual(d, 5, "max deviation from the clean line \(d) m")
        fixes[100].hAcc = .nan
        let nanOut = TripSmoother.smooth(fixes)
        XCTAssertFalse(nanOut.contains { !$0.lat.isFinite || !$0.lon.isFinite }, "NaN hAcc leaks into the output")
        XCTAssertLessThanOrEqual(zip(nanOut, clean).map { Geo.distance($0.lat, $0.lon, $1.lat, $1.lon) }.max()!, 5)
    }

    func pathLength(_ o: [(t: Date, lat: Double, lon: Double)]) -> Double {
        zip(o, o.dropFirst()).map { Geo.distance($0.lat, $0.lon, $1.lat, $1.lon) }.reduce(0, +)
    }

    /// Train: straight 30 m/s, a rough fix every 10 s (as stored), hAcc 700–1500 m, true error ≤ 40 m.
    func testRoughStretchWeightedByConsistency() {
        var rng = SeededRandom(seed: 21)
        var fixes: [Sample] = [], truth: [(Date, Double, Double)] = []
        for i in 0...60 {
            let t = t0.addingTimeInterval(Double(i) * 10)
            let p = Geo.offset(lat: 52.37, lon: 4.90, north: Double(i) * 300, east: 0)
            let n = max(-28, min(28, rng.gaussian() * 15)), e = max(-28, min(28, rng.gaussian() * 15))   // radial ≤ 40 m
            let q = Geo.offset(lat: p.lat, lon: p.lon, north: n, east: e)
            truth.append((t, p.lat, p.lon))
            fixes.append(Sample(t: t, lat: q.lat, lon: q.lon, hAcc: 700 + Double.random(in: 0...800, using: &rng), speed: -1, course: -1))
        }
        let out = TripSmoother.smooth(fixes, rough: Set(fixes.indices))
        let e = errors(out, truth).max()!
        print("MEAS train rough max error", e)
        XCTAssertLessThanOrEqual(e, 60, "max error \(e) m")
    }

    /// Bus: 10 m/s route, a fix every 2 s, a 3-fix 150 m out-and-back excursion with confident hAcc and no course.
    func testSpikeRemoved() {
        let w = walk(path: [(0, 0), (3000, 0)], speed: 10, every: 2, noise: 5, seed: 23, start: t0, doppler: .vehicle)
        let samples = multipath(w.samples, range: 70..<73, east: 150, hAcc: 10, course: .invalid)
        let d = errors(TripSmoother.smooth(samples), w.truth).max()!
        print("MEAS bus spike max deviation", d)
        XCTAssertLessThanOrEqual(d, 20, "max deviation \(d) m")
    }

    /// Canyon walk: 1.3 m/s, every 30 s a 10-fix burst 25–35 m to alternating sides without Doppler; pedometer pace per 30 s.
    func testWalkingPaceStraightensZigzag() {
        let w = walk(path: [(0, 0), (780, 0)], speed: 1.3, every: 1, noise: 4, seed: 29, start: t0, doppler: .foot)
        var fixes = w.samples, rng = SeededRandom(seed: 31)
        for (k, b) in stride(from: 15, to: fixes.count - 10, by: 30).enumerated() {
            let off = (k % 2 == 0 ? 1.0 : -1.0) * (25 + Double.random(in: 0...10, using: &rng))
            for i in b..<b + 10 {
                let p = Geo.offset(lat: fixes[i].lat, lon: fixes[i].lon, north: 0, east: off)
                fixes[i] = Sample(t: fixes[i].t, lat: p.lat, lon: p.lon, hAcc: 10, speed: -1, course: -1)
            }
        }
        let pace = stride(from: 0.0, to: 600, by: 30).map { (t: t0.addingTimeInterval($0), speed: 1.3 * (1 + 0.05 * rng.gaussian())) }
        let walked = pace.map { $0.speed * 30 }.reduce(0, +)
        let withPace = TripSmoother.smooth(fixes, pace: pace), without = TripSmoother.smooth(fixes)
        let ratio = pathLength(withPace) / walked
        let mean = { (o: [(t: Date, lat: Double, lon: Double)]) in self.errors(o, w.truth).reduce(0, +) / Double(o.count) }
        print("MEAS canyon length ratio", ratio, "without pace", pathLength(without) / walked, "mean error", mean(withPace), "without", mean(without))
        XCTAssertEqual(ratio, 1, accuracy: 0.15, "path length / pedometer distance \(ratio)")
        XCTAssertLessThan(mean(withPace), mean(without))
    }
}
