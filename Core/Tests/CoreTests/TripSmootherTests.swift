import XCTest
@testable import Core

final class TripSmootherTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let block: [(north: Double, east: Double)] = [(0, 0), (300, 0), (300, 400), (0, 400), (0, 0)]

    func raw(_ s: [Sample]) -> [RawFix] { s.map { RawFix(t: $0.t, lat: $0.lat, lon: $0.lon, hAcc: $0.hAcc, speed: $0.speed, course: $0.course) } }

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
        let fixes = raw(w.samples).map { var f = $0; f.course = -1; return f }
        let m = median(errors(TripSmoother.smooth(fixes), w.truth))
        print("MEAS smoother no-course median", m)
        XCTAssertLessThanOrEqual(m, 6, "median \(m) m")
    }

    func testWalkNotWorseThanLiveFilter() {
        let w = walk(path: block, speed: 1.4, every: 1, noise: 12, seed: 7, start: t0, doppler: .foot)
        let s = median(errors(TripSmoother.smooth(raw(w.samples)), w.truth))
        let l = median(liveErrors(w.samples, w.truth))
        print("MEAS walk median smoother", s, "live", l)
        XCTAssertLessThanOrEqual(s, l, "smoother median \(s) m, live \(l) m")
    }

    func testCornersWithin10m() {
        let w = walk(path: block, speed: 1.4, every: 1, noise: 12, seed: 7, start: t0, doppler: .foot)
        let out = TripSmoother.smooth(raw(w.samples))
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
        let s = errors(TripSmoother.smooth(raw(samples)), w.truth)[100..<108].max()!
        let l = liveErrors(samples, w.truth)[100..<108].max()!
        print("MEAS burst max smoother", s, "live", l)
        XCTAssertLessThanOrEqual(s, l, "max deviation in burst: smoother \(s) m, live \(l) m")
    }

    func testNoCourseFallsBackToPositionOnly() {
        let w = walk(path: block, speed: 1.4, every: 1, noise: 12, seed: 3, start: t0, doppler: .foot)
        let fixes = raw(w.samples).enumerated().map { i, f in var f = f; if i % 3 == 0 { f.course = -1 }; if i % 7 == 0 { f.speed = -1 }; return f }
        let out = TripSmoother.smooth(fixes)
        XCTAssertEqual(out.count, fixes.count)
        XCTAssertFalse(out.contains { !$0.lat.isFinite || !$0.lon.isFinite }, "NaN or infinite output")
        print("MEAS mixed-course median", median(errors(out, w.truth)))
    }

    func testSmootherNeverBridgesTrips() {
        let w = walk(path: [(0, 0), (200, 0)], speed: 1.4, every: 1, noise: 5, seed: 13, start: t0, doppler: .foot)
        let fixes = raw(w.samples)
        let out = TripSmoother.smooth(fixes)
        XCTAssertEqual(out.count, fixes.count)
        XCTAssertEqual(out.map(\.t), fixes.map(\.t))
    }

    func testSingleAndTwoFixTrips() {
        XCTAssertTrue(TripSmoother.smooth([]).isEmpty)
        let a = RawFix(t: t0, lat: 52.37, lon: 4.90, hAcc: 10, speed: -1, course: -1)
        let one = TripSmoother.smooth([a])
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].lat, a.lat, accuracy: 1e-9); XCTAssertEqual(one[0].lon, a.lon, accuracy: 1e-9)
        let p = Geo.offset(lat: 52.37, lon: 4.90, north: 10, east: 0)
        let b = RawFix(t: t0.addingTimeInterval(5), lat: p.lat, lon: p.lon, hAcc: 10, speed: 2, course: 0)
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
        var fixes = raw(w.samples)
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
}
