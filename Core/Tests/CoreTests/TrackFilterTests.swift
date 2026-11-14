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
        XCTAssertNil(feed(&f, sample(2, hAcc: 65.5)))
        XCTAssertNotNil(feed(&f, sample(3, hAcc: 65)))
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
        let w = walk(path: path, speed: speed, every: 1, noise: 12, seed: seed, start: t0)
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
        let median = errs[errs.count / 2]
        XCTAssertLessThanOrEqual(median, 8, "median error \(median) m over \(errs.count) of \(r.truth.count) points", line: line)
    }

    func testCornerNotCutMoreThan10m() {
        let r = blockWalk()
        var report: [String] = []
        for c in r.path.dropFirst().dropLast() {
            let p = Geo.offset(lat: 52.37, lon: 4.90, north: c.north, east: c.east)
            let d = r.out.map { Geo.distance($0.lat, $0.lon, p.lat, p.lon) }.min() ?? .infinity
            report.append(String(format: "%.1f", d))
            XCTAssertLessThanOrEqual(d, 10, "corner (\(c.north),\(c.east)) nearest output \(d) m; all corners: \(report)")
        }
    }
}
