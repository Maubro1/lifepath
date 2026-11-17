import XCTest
@testable import Core

final class TravelModesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A straight way at `north` metres from `from` to `to` metres east of (52.37, 4.90), a node every 500 m.
    func line(_ id: Int64, _ kind: WayKind, north: Double, from: Double, to: Double) -> Way {
        let n = max(1, Int(((to - from) / 500).rounded(.up)))
        let coords = (0...n).map { k -> (lat: Double, lon: Double) in
            Geo.offset(lat: 52.37, lon: 4.90, north: north, east: from + (to - from) * Double(k) / Double(n))
        }
        return Way(id: id, kind: kind, name: nil, oneway: false, nodes: (0...n).map { id * 1000 + Int64($0) }, coords: coords)
    }

    func stop(_ id: Int64, _ kind: StopKind, north: Double, east: Double) -> Stop {
        let p = Geo.offset(lat: 52.37, lon: 4.90, north: north, east: east)
        return Stop(id: id, kind: kind, lat: p.lat, lon: p.lon)
    }

    /// Asserts the modes, that every stretch is confident, and prints the measurement.
    func check(_ s: [ModeStretch], _ expect: [TravelMode], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        print("MEAS", name, s.map { "\($0.mode.rawValue) \(String(format: "%.3f", $0.confidence)) [\(Int($0.start.timeIntervalSince(t0)))...\(Int($0.end.timeIntervalSince(t0)))]" })
        XCTAssertEqual(s.map(\.mode), expect, file: file, line: line)
        XCTAssertTrue(s.allSatisfy { $0.confidence >= TravelModes.confident }, file: file, line: line)
    }

    /// 3 min walk on a footway, 10 min bus at 9 m/s on a road halting 20 s at 6 mapped stops 500 m apart, 3 min walk.
    func walkBusWalk() -> (pts: [FilteredPoint], graph: RoadGraph, stops: [Stop], acts: [(t: Date, activity: Activity)], bounds: [Date]) {
        let b1 = t0.addingTimeInterval(181), b2 = t0.addingTimeInterval(802)
        let halts = (1...6).map { k -> (atM: Double, seconds: Double) in (Double(k) * 500, 20) }
        let pts = ride(path: [(0, -252), (0, 0)], speed: 1.4, every: 1, noise: 3, seed: 1, start: t0)
            + ride(path: [(0, 0), (0, 4500)], speed: 9, every: 1, noise: 4, seed: 2, start: b1, halts: halts)
            + ride(path: [(0, 4500), (0, 4752)], speed: 1.4, every: 1, noise: 3, seed: 3, start: b2)
        let graph = RoadGraph(ways: [line(1, .foot, north: 0, from: -252, to: 0), line(2, .road, north: 0, from: 0, to: 4500),
                                     line(3, .foot, north: 0, from: 4500, to: 4752)])
        let stops = (1...6).map { k -> Stop in stop(Int64(k), .bus, north: 5, east: Double(k) * 500) }
        return (pts, graph, stops, [(t0, .walking), (b1, .automotive), (b2, .walking)], [b1, b2])
    }

    func assertBoundaries(_ s: [ModeStretch], _ pts: [FilteredPoint], _ truth: [Date], file: StaticString = #filePath, line: UInt = #line) {
        guard s.count == truth.count + 1 else { return }
        for (k, b) in truth.enumerated() {
            let err = s[k + 1].start.timeIntervalSince(b)
            print("MEAS boundary error s", err)
            XCTAssertLessThanOrEqual(abs(err), 30, file: file, line: line)
        }
    }

    func testWalkBusWalk() {
        let trip = walkBusWalk()
        let s = TravelModes.classify(trip.pts, graph: trip.graph, stops: trip.stops, activities: trip.acts)
        check(s, [.walk, .bus, .walk], "walk bus walk")
        assertBoundaries(s, trip.pts, trip.bounds)
    }

    func testCarAtRedLightsIsCar() {
        // 10 min at 12 m/s; bus stops every 500 m from 250, red lights at 500, 1500 ... 4500: 250 m from any stop.
        let lights = (0..<5).map { k -> (atM: Double, seconds: Double) in (500 + Double(k) * 1000, 40) }
        let pts = ride(path: [(0, 0), (0, 7200)], speed: 12, every: 1, noise: 4, seed: 4, start: t0, halts: lights)
        let stops = (0..<15).map { k -> Stop in stop(Int64(k), .bus, north: 5, east: 250 + Double(k) * 500) }
        let s = TravelModes.classify(pts, graph: RoadGraph(ways: [line(1, .road, north: 0, from: 0, to: 7200)]),
                                     stops: stops, activities: [(t0, .automotive)])
        check(s, [.car], "car at red lights")
    }

    func testRoughTrainBesideMotorway() {
        // As MapMatcherTests.testRoughTrainMatchesRailNotMotorway: rail and motorway 150 m apart, 30 min at 25 m/s,
        // rough fixes every 10 s with error ≤ 300 m toward the motorway; a station at each end; activity partly stationary.
        var rng = SeededRandom(seed: 3)
        let pts = (0..<180).map { i -> FilteredPoint in
            let a = Double.random(in: 0...Double.pi, using: &rng), r = Double.random(in: 0...300, using: &rng)
            let p = Geo.offset(lat: 52.37, lon: 4.90, north: r * sin(a), east: Double(i) * 250 + r * cos(a))
            return FilteredPoint(t: t0.addingTimeInterval(Double(i) * 10), lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon,
                                 hAcc: .random(in: 700...1500, using: &rng), speed: -1, kind: .rough)
        }
        let graph = RoadGraph(ways: [line(1, .rail, north: 0, from: -2000, to: 48000), line(2, .road, north: 150, from: -2000, to: 48000)])
        let stops = [stop(1, .rail, north: 0, east: 0), stop(2, .rail, north: 0, east: 44750)]
        let acts: [(t: Date, activity: Activity)] = [(t0, .automotive), (t0.addingTimeInterval(600), .stationary), (t0.addingTimeInterval(900), .automotive)]
        check(TravelModes.classify(pts, graph: graph, stops: stops, activities: acts), [.train], "rough train beside motorway")
    }

    func testWalkToTrain() {
        // 3 min walk on a footway to a station, then 20 min of rough fixes along the rail at 25 m/s.
        let b = t0.addingTimeInterval(181)
        let pts = ride(path: [(0, -252), (0, 0)], speed: 1.4, every: 1, noise: 3, seed: 5, start: t0)
            + ride(path: [(0, 0), (0, 30000)], speed: 25, every: 1, noise: 0, seed: 6, start: b, rough: true)
        let graph = RoadGraph(ways: [line(1, .foot, north: 20, from: -252, to: 0), line(2, .rail, north: 0, from: 0, to: 30000)])
        let s = TravelModes.classify(pts, graph: graph, stops: [stop(1, .rail, north: 0, east: 0)], activities: [(t0, .walking), (b, .automotive)])
        check(s, [.walk, .train], "walk to train")
        assertBoundaries(s, pts, [b])
    }

    func testTramOnTramTracks() {
        // 8 m/s along tram tracks, halting 20 s at 4 tram stops, a road 60 m away; no motion data.
        let halts = (1...4).map { k -> (atM: Double, seconds: Double) in (Double(k) * 800, 20) }
        let pts = ride(path: [(0, 0), (0, 4000)], speed: 8, every: 1, noise: 4, seed: 7, start: t0, halts: halts)
        let graph = RoadGraph(ways: [line(1, .tram, north: 0, from: 0, to: 4000), line(2, .road, north: 60, from: 0, to: 4000)])
        let stops = (1...4).map { k -> Stop in stop(Int64(k), .tram, north: 3, east: Double(k) * 800) }
        check(TravelModes.classify(pts, graph: graph, stops: stops, activities: []), [.tram], "tram")
    }

    func testBikeOnCyclePath() {
        let pts = ride(path: [(0, 0), (0, 3000)], speed: 5, every: 1, noise: 4, seed: 8, start: t0)
        let graph = RoadGraph(ways: [line(1, .cycle, north: 0, from: 0, to: 3000)])
        check(TravelModes.classify(pts, graph: graph, stops: [], activities: [(t0, .cycling)]), [.bike], "bike")
    }

    func testWaterbusOpenWater() {
        // 6 m/s with no way within 200 m, then a 60 s halt at a ferry terminal; no motion data.
        let pts = ride(path: [(0, 0), (0, 3600)], speed: 6, every: 1, noise: 4, seed: 9, start: t0, halts: [(3600, 60)])
        let graph = RoadGraph(ways: [line(1, .road, north: 300, from: 0, to: 3600)])
        check(TravelModes.classify(pts, graph: graph, stops: [stop(1, .ferry, north: 10, east: 3600)], activities: []), [.boat], "waterbus")
    }

    func testRoughBusOnRoadIsNotBoat() {
        // 10 min at 6 m/s on a road, mostly rough fixes (a bus with the phone in a pocket), no stops mapped.
        let pts = ride(path: [(0, 0), (0, 3600)], speed: 6, every: 1, noise: 4, seed: 13, start: t0, rough: true)
        let s = TravelModes.classify(pts, graph: RoadGraph(ways: [line(1, .road, north: 0, from: 0, to: 3600)]), stops: [], activities: [(t0, .automotive)])
        XCTAssertFalse(s.contains { $0.mode == .boat }, "\(s.map(\.mode))")
    }

    func testNoStreetsYetIsNotBoat() {
        // Streets not downloaded yet: a 6 m/s vehicle ride must not read as boat for lack of nearby ways.
        let pts = ride(path: [(0, 0), (0, 3600)], speed: 6, every: 1, noise: 4, seed: 14, start: t0)
        let s = TravelModes.classify(pts, graph: RoadGraph(ways: []), stops: [], activities: [(t0, .automotive)])
        XCTAssertFalse(s.contains { $0.mode == .boat }, "\(s.map(\.mode))")
    }

    func testNoActivityStillClassifies() {
        let trip = walkBusWalk()
        let s = TravelModes.classify(trip.pts, graph: trip.graph, stops: trip.stops, activities: [])
        check(s, [.walk, .bus, .walk], "walk bus walk, no activity")
        assertBoundaries(s, trip.pts, trip.bounds)

        // Paths round a 400 m park; the walk crosses its middle, at least 100 m from any way.
        let corners: [(Double, Double)] = [(0, 0), (0, 400), (400, 400), (400, 0), (0, 0)]
        let ring = corners.map { c -> (lat: Double, lon: Double) in Geo.offset(lat: 52.37, lon: 4.90, north: c.0, east: c.1) }
        let park = RoadGraph(ways: [Way(id: 1, kind: .foot, name: nil, oneway: false, nodes: [1, 2, 3, 4, 1], coords: ring)])
        let walk = ride(path: [(100, 100), (300, 300)], speed: 1.3, every: 1, noise: 3, seed: 10, start: t0)
        check(TravelModes.classify(walk, graph: park, stops: [], activities: []), [.walk], "park walk, no activity")
    }

    func testRunIsRun() {
        let pts = ride(path: [(0, 0), (0, 1200)], speed: 3.3, every: 1, noise: 3, seed: 11, start: t0)
        let graph = RoadGraph(ways: [line(1, .foot, north: 0, from: 0, to: 1200)])
        check(TravelModes.classify(pts, graph: graph, stops: [], activities: [(t0, .running)]), [.run], "run")
    }

    func testTwoPointTrip() {
        let pts = ride(path: [(0, 0), (0, 14)], speed: 1.4, every: 10, noise: 3, seed: 12, start: t0)
        XCTAssertEqual(pts.count, 2)
        let s = TravelModes.classify(pts, graph: RoadGraph(ways: []), stops: [], activities: [])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.start, pts[0].t)
        XCTAssertEqual(s.first?.end, pts[1].t)
    }
}
