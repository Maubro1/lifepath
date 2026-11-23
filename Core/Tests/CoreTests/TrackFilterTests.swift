import XCTest
@testable import Core

final class TrackFilterTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func sample(_ t: TimeInterval, north: Double = 0, hAcc: Double = 10) -> Sample {
        let p = Geo.offset(lat: 52.37, lon: 4.90, north: north, east: 0)
        return Sample(t: t0.addingTimeInterval(t), lat: p.lat, lon: p.lon, hAcc: hAcc, speed: 1, course: 0)
    }
    func feed(_ f: inout TrackFilter, _ s: Sample, at received: TimeInterval? = nil) -> FilteredPoint? {
        f.process(s, receivedAt: received.map { t0.addingTimeInterval($0) } ?? s.t, activity: .walking)
    }
    /// A valid first fix proves the filter works at all, so the drop tests cannot pass on a stub.
    func primed() -> TrackFilter {
        var f = TrackFilter(quality: .balanced)
        XCTAssertNotNil(feed(&f, sample(0)))
        return f
    }

    func testDropsNegativeAndCeilingAccuracy() {
        var f = primed()
        XCTAssertNil(feed(&f, sample(1, hAcc: -1)))
        XCTAssertEqual(feed(&f, sample(2, hAcc: 65.5))?.kind, .rough)
        XCTAssertEqual(feed(&f, sample(13, hAcc: 65))?.kind, .rough, "Wi-Fi fixes report 65 m or more (Apple)")
        XCTAssertEqual(feed(&f, sample(14, hAcc: 64.9))?.kind, .moving)
    }

    func testDopplerSummaryReportsMediansAndClears() {
        var f = TrackFilter(quality: .balanced)
        XCTAssertNil(f.takeDopplerSummary())
        for (i, (sa, ca)) in [(0.3, 8.0), (0.5, -1.0), (0.9, 20.0)].enumerated() {
            var s = sample(Double(i)); s.speedAccuracy = sa; s.courseAccuracy = ca
            _ = feed(&f, s)
        }
        XCTAssertEqual(f.takeDopplerSummary(), "speedAcc=0.50 courseAcc=20.00 n=3")
        XCTAssertNil(f.takeDopplerSummary())
    }

    /// iOS's accuracies only widen the Doppler noise: a reading it marks as poor moves the line less, a confident one no more than before.
    func testSpeedAccuracyOnlyDownWeights() throws {
        func run(_ speedAcc: Double) throws -> Double {
            var f = TrackFilter(quality: .balanced)
            var last: FilteredPoint?
            for i in 0..<10 {
                var s = sample(Double(i), north: 1.4 * Double(i), hAcc: 5); s.speed = i == 9 ? 15 : 1.4; s.speedAccuracy = i == 9 ? speedAcc : 0.1
                last = feed(&f, s)
            }
            let p = try XCTUnwrap(last), truth = sample(9, north: 12.6)
            return Geo.distance(p.lat, p.lon, truth.lat, truth.lon)
        }
        XCTAssertLessThan(try run(10), try run(-1), "a spike iOS calls inaccurate pulls less")
        XCTAssertEqual(try run(0.01), try run(-1), accuracy: 1e-9, "never trusted more than the fixed 0.7 m/s")
    }

    /// Trains: iOS reports ~1 km accuracy for positions that are often fine. They are kept as rough points, raw, and never
    /// touch the live filter, so the precise line is the same with or without them.
    func testRoughFixIsKeptNotFiltered() throws {
        var a = primed(), b = primed()
        let r = try XCTUnwrap(feed(&a, sample(5, north: 400, hAcc: 900)))
        XCTAssertEqual(r.kind, .rough)
        XCTAssertEqual(r.lat, sample(5, north: 400).lat, accuracy: 1e-9)
        XCTAssertEqual(r.speed, -1); XCTAssertEqual(r.course, -1); XCTAssertEqual(r.hAcc, 900)
        let withRough = try XCTUnwrap(feed(&a, sample(10, north: 10)))
        let without = try XCTUnwrap(feed(&b, sample(10, north: 10)))
        XCTAssertEqual(withRough, without)
    }

    func testRoughSpacingTenSeconds() {
        var f = primed()
        XCTAssertNotNil(feed(&f, sample(1, hAcc: 900)))
        XCTAssertNil(feed(&f, sample(9, hAcc: 900)))
        XCTAssertNotNil(feed(&f, sample(11, hAcc: 900)))
        XCTAssertEqual(f.takeDropCounts()["rough-spacing"], 1)
    }

    func testCourseSetOnlyWhenAccurate() {
        var f = TrackFilter(quality: .balanced)
        func s(_ t: TimeInterval, hAcc: Double, course: Double) -> Sample {
            Sample(t: t0.addingTimeInterval(t), lat: 52.37, lon: 4.90, hAcc: hAcc, speed: 1, course: course)
        }
        XCTAssertEqual(feed(&f, s(0, hAcc: 10, course: 90))?.course, 90)
        XCTAssertEqual(feed(&f, s(1, hAcc: 30, course: 90))?.course, -1)
        XCTAssertEqual(feed(&f, s(2, hAcc: 10, course: -1))?.course, -1)
    }

    func testDropsStaleAndFuture() {
        var f = primed()
        XCTAssertNil(feed(&f, sample(20), at: 31))   // 11 s old
        XCTAssertNil(feed(&f, sample(33), at: 30))   // 3 s ahead
        XCTAssertNotNil(feed(&f, sample(31), at: 30)) // 1 s ahead is fine
    }

    func testOutOfOrderDropped() {
        var f = primed()
        XCTAssertNotNil(feed(&f, sample(5)))
        XCTAssertNil(feed(&f, sample(5)))
        XCTAssertNil(feed(&f, sample(4)))
    }

    func testTeleportDropped() {
        var f = primed()
        XCTAssertNil(feed(&f, sample(1, north: 1000)))
        XCTAssertNotNil(feed(&f, sample(2, north: 1)))
    }

    private func blockWalk(speed: Double = 1.4, seed: UInt64 = 7, activity: Activity = .walking) -> (path: [(north: Double, east: Double)], truth: [(Date, Double, Double)], out: [FilteredPoint]) {
        let path: [(north: Double, east: Double)] = [(0, 0), (300, 0), (300, 400), (0, 400), (0, 0)]
        let w = walk(path: path, speed: speed, every: 1, noise: 12, seed: seed, start: t0, doppler: .foot)
        var f = TrackFilter(quality: .balanced)
        let out = w.samples.compactMap { f.process($0, receivedAt: $0.t, activity: activity) }
        return (path, w.truth, out)
    }

    func testWalkMedianErrorAtMost8m() { assertMedianAtMost8m(blockWalk()) }

    func testRunMedianErrorAtMost8m() { assertMedianAtMost8m(blockWalk(speed: 3.5, seed: 11, activity: .running)) }

    private func assertMedianAtMost8m(_ r: (path: [(north: Double, east: Double)], truth: [(Date, Double, Double)], out: [FilteredPoint]),
                                      line: UInt = #line) {
        let truthAt = Dictionary(uniqueKeysWithValues: r.truth.map { ($0.0, ($0.1, $0.2)) })
        let errs = r.out.compactMap { p in truthAt[p.t].map { Geo.distance(p.lat, p.lon, $0.0, $0.1) } }.sorted()
        guard !errs.isEmpty else { return XCTFail("no outputs") }
        let median = errs[errs.count / 2]; print("MEAS median", median)
        XCTAssertLessThanOrEqual(median, 8, "median error \(median) m over \(errs.count) of \(r.truth.count) points", line: line)
    }

    func testCornerNotCutMoreThan10m() {
        let r = blockWalk()
        var report: [String] = []
        for c in r.path.dropFirst().dropLast() {
            let p = Geo.offset(lat: 52.37, lon: 4.90, north: c.north, east: c.east)
            let d = r.out.map { Geo.distance($0.lat, $0.lon, p.lat, p.lon) }.min() ?? .infinity
            report.append(String(format: "%.1f", d)); print("MEAS corner", d)
            XCTAssertLessThanOrEqual(d, 10, "corner (\(c.north),\(c.east)) nearest output \(d) m; all corners: \(report)")
        }
    }

    // MARK: bad signal

    /// Output error (m) at each sample time against the truth of the same index list, for the given activity.
    private func errors(_ samples: [Sample], truth: [(Date, Double, Double)], activity: Activity = .walking) -> [Double] {
        var f = TrackFilter(quality: .balanced)
        let e = zip(samples, truth).map { s, t in
            f.process(s, receivedAt: s.t, activity: activity).map { Geo.distance($0.lat, $0.lon, t.1, t.2) } ?? .nan
        }
        XCTAssertFalse(e.contains { $0.isNaN }, "a fix was dropped, so its error is missing")
        return e
    }

    /// 8 fixes 30 m off (hAcc 8) in a straight walk with realistic Doppler; returns max error in the burst and in the 20 fixes after.
    private func burst(_ course: BurstCourse) -> (inBurst: Double, after: Double) {
        let w = walk(path: [(0, 0), (400, 0)], speed: 1.4, every: 1, noise: 3, seed: 5, start: t0, doppler: .foot)
        let e = errors(multipath(w.samples, range: 100..<108, east: 30, hAcc: 8, course: course), truth: w.truth)
        return (e[100..<108].max()!, e[108..<128].max()!)
    }

    func testMultipathBurstBarelyMovesLine() {
        let r = burst(.keep)
        print("MEAS burst keep", r)
        XCTAssertLessThanOrEqual(r.inBurst, 12, "max deviation during burst \(r.inBurst) m")
        XCTAssertLessThanOrEqual(r.after, 12, "max deviation in the 20 fixes after the burst \(r.after) m")
    }

    func testMultipathBurstWithInvalidCourse() {
        // Without any Doppler no live estimator can tell a 30 m lie from a real move; the offline smoother and map matching remove it.
        let r = burst(.invalid)
        print("MEAS burst invalid course", r)
        XCTAssertLessThanOrEqual(r.inBurst, 25, "in burst \(r.inBurst) m")
        XCTAssertLessThanOrEqual(r.after, 25, "after burst \(r.after) m")
    }

    func testMultipathBurstWithCorruptedCourse() {
        // Course rotated toward a multipath shift is adversarial; the offline smoother and map matching remove the remainder.
        let r = burst(.towardFake)
        print("MEAS burst corrupted course", r)
        XCTAssertLessThanOrEqual(r.inBurst, 21, "in burst \(r.inBurst) m")
        XCTAssertLessThanOrEqual(r.after, 21, "after burst \(r.after) m")
    }

    func testCarTurnAt15msWithin10mOfCorner() {
        let w = walk(path: [(0, 0), (600, 0), (600, 600)], speed: 15, every: 1, noise: 3, seed: 21, start: t0, doppler: .vehicle)
        var f = TrackFilter(quality: .balanced)
        let out = w.samples.compactMap { f.process($0, receivedAt: $0.t, activity: .automotive) }
        let c = Geo.offset(lat: 52.37, lon: 4.90, north: 600, east: 0)
        let d = out.map { Geo.distance($0.lat, $0.lon, c.lat, c.lon) }.min()!
        let e = errors(w.samples, truth: w.truth, activity: .automotive)
        let turn = 40   // 600 m at 15 m/s
        let after = e[turn..<(turn + 10)].max()!
        print("MEAS car", d, after)
        XCTAssertLessThanOrEqual(d, 10, "nearest output to the corner \(d) m")
        XCTAssertLessThanOrEqual(after, 20, "max error in the 10 s after the turn (15 m is the target) \(after) m")
    }

    func testGapThenDisplacementRecovers() {
        let a = walk(path: [(0, 0), (150, 0)], speed: 1.4, every: 1, noise: 3, seed: 31, start: t0, doppler: .foot)
        let b = walk(path: [(300, 0), (500, 0)], speed: 1.4, every: 1, noise: 3, seed: 32, start: t0.addingTimeInterval(138), doppler: .foot)
        let e = errors(a.samples + b.samples, truth: a.truth + b.truth)[a.samples.count...]
        print("MEAS gap", Array(e.prefix(5)))
        XCTAssertLessThanOrEqual(e[e.startIndex + 2], 10, "error at the 3rd fix after the gap: \(Array(e.prefix(5)))")
    }

    func testSustainedShiftRecovers() {
        let a = walk(path: [(0, 0), (200, 0)], speed: 1.4, every: 1, noise: 3, seed: 41, start: t0, doppler: .foot)
        let step = TimeInterval(a.samples.count)
        let b = walk(path: [(200, 50), (400, 50)], speed: 1.4, every: 1, noise: 3, seed: 42, start: t0.addingTimeInterval(step), doppler: .foot)
        let e = errors(a.samples + b.samples, truth: a.truth + b.truth)[a.samples.count...]
        print("MEAS shift", Array(e.prefix(20)))
        XCTAssertLessThanOrEqual(e.dropFirst(15).prefix(20).max()!, 10, "errors after the step: \(Array(e.prefix(20)))")
    }

    func testRealTurnStillFollowed() {
        let path: [(north: Double, east: Double)] = [(0, 0), (200, 0), (200, 200)]
        let w = walk(path: path, speed: 1.4, every: 1, noise: 3, seed: 9, start: t0, doppler: .foot)
        var f = TrackFilter(quality: .balanced)
        let out = w.samples.compactMap { f.process($0, receivedAt: $0.t, activity: .walking) }
        let c = Geo.offset(lat: 52.37, lon: 4.90, north: 200, east: 0)
        let d = out.map { Geo.distance($0.lat, $0.lon, c.lat, c.lon) }.min() ?? .infinity
        XCTAssertLessThanOrEqual(d, 10, "nearest output to the corner \(d) m")
        let end = Geo.offset(lat: 52.37, lon: 4.90, north: 200, east: 200)
        XCTAssertLessThanOrEqual(Geo.distance(out.last!.lat, out.last!.lon, end.lat, end.lon), 10)
    }

    func testSpeedInvalidWhenInaccurate() {
        var f = primed()
        XCTAssertEqual(feed(&f, sample(1, hAcc: 20))?.speed, 1)
        XCTAssertEqual(feed(&f, sample(2, hAcc: 20.5))?.speed, -1)
        var s = sample(3)
        s.speed = -1
        XCTAssertEqual(feed(&f, s)?.speed, -1)
    }

    func testDropCountsByReason() {
        var f = primed()
        _ = feed(&f, sample(1, hAcc: -1))
        XCTAssertEqual(feed(&f, sample(2, hAcc: 65.5))?.kind, .rough)   // kept, not dropped
        _ = feed(&f, sample(20), at: 31)
        _ = feed(&f, sample(33), at: 30)
        _ = feed(&f, sample(0))
        _ = feed(&f, sample(1, north: 1000))
        XCTAssertEqual(f.takeDropCounts(), ["accuracy": 1, "stale": 1, "future": 1, "order": 1, "teleport": 1])
        XCTAssertEqual(f.takeDropCounts(), [:])
    }
}
