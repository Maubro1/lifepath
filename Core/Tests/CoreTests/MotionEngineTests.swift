import XCTest
@testable import Core

final class MotionEngineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ t: TimeInterval) -> Date { t0.addingTimeInterval(t) }

    func fp(_ s: Sample) -> FilteredPoint {
        FilteredPoint(t: s.t, lat: s.lat, lon: s.lon, rawLat: s.lat, rawLon: s.lon, hAcc: s.hAcc, speed: s.speed, kind: .moving)
    }
    /// 1 Hz fixes along the east axis from `startEast` to `east`, noise 3 m (hAcc 4.5).
    func route(to east: Double, speed: Double, from start: TimeInterval = 0, startEast: Double = 0, seed: UInt64) -> [FilteredPoint] {
        walk(path: [(north: 0, east: startEast), (north: 0, east: east)], speed: speed, every: 1, noise: 3,
             seed: seed, start: at(start)).samples.map(fp)
    }
    /// A stationary fix with the same noise and hAcc as `route`.
    func standing(_ t: TimeInterval, north: Double = 0, east: Double, rng: inout SeededRandom) -> FilteredPoint {
        let p = Geo.offset(lat: 52.37, lon: 4.90, north: north + rng.gaussian() * 3, east: east + rng.gaussian() * 3)
        return FilteredPoint(t: at(t), lat: p.lat, lon: p.lon, rawLat: p.lat, rawLon: p.lon, hAcc: 4.5, speed: 0, kind: .moving)
    }
    @discardableResult
    func send(_ e: inout MotionEngine, _ ev: MotionEvent, _ t: TimeInterval) -> [Command] { e.handle(ev, at: at(t)) }
    /// Feeds fixes at their own time; returns when the engine first went Still and that call's commands.
    func feed(_ e: inout MotionEngine, _ fixes: [FilteredPoint]) -> (stillAt: TimeInterval?, commands: [Command]) {
        for p in fixes {
            let out = e.handle(.fix(p), at: p.t)
            if e.state == .still { return (p.t.timeIntervalSince(t0), out) }
        }
        return (nil, [])
    }
    /// Ticks every 30 s, calling `also` before each tick; returns when the engine first went Still and that tick's commands.
    func tickUntilStill(_ e: inout MotionEngine, from: TimeInterval, through: TimeInterval,
                        also: (inout MotionEngine, TimeInterval) -> Void = { _, _ in }) -> (stillAt: TimeInterval?, commands: [Command]) {
        for t in stride(from: from, through: through, by: 30) {
            also(&e, t)
            let out = send(&e, .tick, t)
            if e.state == .still { return (t, out) }
        }
        return (nil, [])
    }
    /// Walks 168 m east in 2 min (arrival at 120 s), then stands there with 1 Hz fixes until 300 s.
    func walkThenStand(_ e: inout MotionEngine) -> (stillAt: TimeInterval?, commands: [Command]) {
        var rng = SeededRandom(seed: 11)
        let stand = (121...300).map { standing(TimeInterval($0), east: 168, rng: &rng) }
        return feed(&e, route(to: 168, speed: 1.4, seed: 1) + stand)
    }
    func stillEngine(deepSleep: Bool = false) throws -> (MotionEngine, TimeInterval, [Command]) {
        var e = MotionEngine(deepSleep: deepSleep)
        let r = walkThenStand(&e)
        return (e, try XCTUnwrap(r.stillAt, "never went Still"), r.commands)
    }
    func stillPoints(_ out: [Command]) -> [FilteredPoint] { out.compactMap { if case .writeStillPoint(let p) = $0 { p } else { nil } } }
    func scheduled(_ out: [Command]) -> [TimeInterval] { out.compactMap { if case .scheduleSpotCheck(let d) = $0 { d } else { nil } } }
    func log(_ t: TimeInterval, _ kind: String, _ detail: String) -> Command { .log(LoggedEvent(t: at(t), kind: kind, detail: detail)) }

    func assertWoke(_ out: [Command], _ e: MotionEngine, reason: String, stillAt: TimeInterval, when t: TimeInterval,
                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(e.state, .moving, file: file, line: line)
        let expected: [Command] = [.startRecording, .disarmGeofence, .setKeepAlive(true),
                                   .resolveDeparture(stillSince: at(stillAt), until: at(t)), log(t, "wake", reason), log(t, "state", "moving")]
        for c in expected { XCTAssert(out.contains(c), "missing \(c) in \(out)", file: file, line: line) }
    }

    // MARK: stopping

    func testStopsAfterTwoMinutesWalking() throws {
        var e = MotionEngine(deepSleep: false)
        let r = walkThenStand(&e)
        let s = try XCTUnwrap(r.stillAt, "never went Still")
        XCTAssert((200.0...250.0).contains(s), "Still at \(s) s; arrived at 120 s")
        let f = try XCTUnwrap(e.fence)
        let stop = Geo.offset(lat: 52.37, lon: 4.90, north: 0, east: 168)
        XCTAssertLessThan(Geo.distance(f.lat, f.lon, stop.lat, stop.lon), 5)
        XCTAssertEqual(f.radius, 20)
        XCTAssert(r.commands.contains(.stopRecording))
        XCTAssert(r.commands.contains(.armGeofence(Fence(lat: f.lat, lon: f.lon, radius: 200))))
        XCTAssert(r.commands.contains(.scheduleSpotCheck(after: 30)))
        XCTAssertFalse(r.commands.contains(.setKeepAlive(false)))
        XCTAssertEqual(stillPoints(r.commands), [FilteredPoint(t: at(s), lat: f.lat, lon: f.lon, rawLat: f.lat, rawLon: f.lon,
                                                                hAcc: 20, speed: 0, kind: .still)])
        XCTAssert(r.commands.contains(log(s, "state", "still")))
    }

    func testSettlingToleratesOneOutlierInTwenty() throws {
        /// Standing from the start with a fix every 6 s (about 20 per 2 min); optionally one fix 60 m off at 96 s.
        func run(outlier: Bool) -> (stillAt: TimeInterval?, stateLogs: [Command]) {
            var rng = SeededRandom(seed: 11)
            var e = MotionEngine(deepSleep: false)
            var logs: [Command] = []
            for t in stride(from: 0, through: 300, by: 6) {
                let p = standing(TimeInterval(t), north: outlier && t == 96 ? 60 : 0, east: 0, rng: &rng)
                logs += e.handle(.fix(p), at: p.t).filter { if case .log(let l) = $0 { l.kind == "state" } else { false } }
                if e.state == .still { return (TimeInterval(t), logs) }
            }
            return (nil, logs)
        }
        let base = run(outlier: false), with = run(outlier: true)
        XCTAssertNotNil(base.stillAt, "baseline never went Still")
        XCTAssertNotNil(with.stillAt, "never went Still with one outlier")
        XCTAssertLessThanOrEqual(with.stillAt ?? .infinity, (base.stillAt ?? 0) + 6, "one outlier delayed Still")
        XCTAssertEqual(with.stateLogs, base.stateLogs, "the tolerated outlier churned the state log")
    }

    func testRedLightNotStop() {
        var e = MotionEngine(deepSleep: false)
        var rng = SeededRandom(seed: 12)
        send(&e, .activity(.automotive, confident: true), 0)
        let wait = (301...480).map { standing(TimeInterval($0), east: 4500, rng: &rng) }   // 3 min: Still without the vehicle rule
        let r = feed(&e, route(to: 4500, speed: 15, seed: 2) + wait + route(to: 9000, speed: 15, from: 481, startEast: 4500, seed: 3))
        XCTAssertNil(r.stillAt)
        XCTAssertEqual(e.state, .moving)
    }

    func testStopAfterDriveNeedsSixMinutes() throws {
        var e = MotionEngine(deepSleep: false)
        var rng = SeededRandom(seed: 14)
        send(&e, .activity(.automotive, confident: true), 0)
        let parked = (301...700).map { standing(TimeInterval($0), east: 4500, rng: &rng) }
        let s = try XCTUnwrap(feed(&e, route(to: 4500, speed: 15, seed: 4) + parked).stillAt, "never went Still")
        XCTAssert((640.0...670.0).contains(s), "Still at \(s) s; parked at 300 s")
    }

    func testIndoorNoFixFallsToStill() throws {
        var e = MotionEngine(deepSleep: false)
        XCTAssertNil(feed(&e, route(to: 168, speed: 1.4, seed: 1)).stillAt)   // fixes end at 120 s
        let r = tickUntilStill(&e, from: 150, through: 600)
        let s = try XCTUnwrap(r.stillAt, "never went Still")
        XCTAssert((420.0...450.0).contains(s), "Still at \(s) s; last fix at 120 s")
        XCTAssert(r.commands.contains(.stopRecording))
        XCTAssert(r.commands.contains(log(s, "state", "still")))
        // Pinned to where the walk ended, not to the trail's weighted centre.
        let f = try XCTUnwrap(e.fence)
        let end = Geo.offset(lat: 52.37, lon: 4.90, north: 0, east: 168)
        XCTAssertLessThan(Geo.distance(f.lat, f.lon, end.lat, end.lon), 20)
        XCTAssert(r.commands.contains(.armGeofence(Fence(lat: f.lat, lon: f.lon, radius: 200))))
        let check = Sample(t: at(s + 30), lat: end.lat, lon: end.lon, hAcc: 20, speed: -1, course: -1)
        XCTAssertEqual(send(&e, .wakeFix(check, reason: "spotcheck"), s + 30), [])
        XCTAssertEqual(e.state, .still)
    }

    func testIndoorWalkingAroundStillFallsBack() throws {
        var e = MotionEngine(deepSleep: false)
        XCTAssertNil(feed(&e, route(to: 168, speed: 1.4, seed: 1)).stillAt)
        let r = tickUntilStill(&e, from: 150, through: 600) { e, t in
            self.send(&e, .steps(Int(t)), t)
            self.send(&e, .activity(.walking, confident: true), t)
        }
        let s = try XCTUnwrap(r.stillAt, "never went Still")
        XCTAssert((420.0...450.0).contains(s), "Still at \(s) s; last fix at 120 s")
    }

    func testTunnelRideKeepsMovingWithoutFixes() throws {
        var e = MotionEngine(deepSleep: false)
        XCTAssertNil(feed(&e, route(to: 4500, speed: 15, seed: 5)).stillAt)  // fixes end at 300 s
        let riding = tickUntilStill(&e, from: 330, through: 780) { e, t in   // 8 min without fixes
            _ = self.send(&e, .activity(.automotive, confident: true), t)
        }
        XCTAssertNil(riding.stillAt)
        XCTAssertEqual(e.state, .moving)
        XCTAssertEqual(tickUntilStill(&e, from: 810, through: 1200).stillAt, 1080)   // 5 min after the last automotive
    }

    func testColdStartNoFixFallsToStill() throws {
        var e = MotionEngine(deepSleep: false)
        let r = tickUntilStill(&e, from: 0, through: 400)
        XCTAssertEqual(r.stillAt, 300)
        XCTAssertNil(e.fence)
        XCTAssert(r.commands.contains(.stopRecording))
        XCTAssert(r.commands.contains(.scheduleSpotCheck(after: 30)))
        XCTAssert(r.commands.contains(log(300, "state", "still")))
        XCTAssertFalse(r.commands.contains { if case .armGeofence = $0 { true } else { false } })
        XCTAssertEqual(stillPoints(r.commands), [])
    }

    func testWakeFixSeedsFenceWhenNoneKnown() throws {
        let here = Geo.offset(lat: 52.37, lon: 4.90, north: 1000, east: 0)
        let away = Geo.offset(lat: here.lat, lon: here.lon, north: 200, east: 0)
        func fix(_ p: (lat: Double, lon: Double), hAcc: Double, _ t: TimeInterval) -> MotionEvent {
            .wakeFix(Sample(t: at(t), lat: p.lat, lon: p.lon, hAcc: hAcc, speed: -1, course: -1), reason: "spotcheck")
        }
        // Still with no position: the first wake fix pins the fence instead of waking.
        var e = MotionEngine(deepSleep: false)
        let s = try XCTUnwrap(tickUntilStill(&e, from: 0, through: 400).stillAt)
        let out = send(&e, fix(here, hAcc: 30, s + 30), s + 30)
        XCTAssertEqual(e.state, .still)
        XCTAssertFalse(out.contains(.startRecording))
        XCTAssertEqual(e.fence, Fence(lat: here.lat, lon: here.lon, radius: 30))
        XCTAssert(out.contains(.armGeofence(Fence(lat: here.lat, lon: here.lon, radius: 200))))
        assertWoke(send(&e, fix(away, hAcc: 20, s + 60), s + 60), e, reason: "spotcheck", stillAt: s, when: s + 60)
        // Moving with no fix: a wake fix seeds the position the fallback pins to.
        var m = MotionEngine(deepSleep: false)
        send(&m, .tick, 0)
        send(&m, fix(here, hAcc: 50, 10), 10)
        XCTAssertEqual(m.state, .moving)
        XCTAssertEqual(tickUntilStill(&m, from: 30, through: 400).stillAt, 300)
        XCTAssertEqual(m.fence, Fence(lat: here.lat, lon: here.lon, radius: 50))
    }

    func testNoFixAfterWakeReturnsToStillIn2Min() throws {
        var e = MotionEngine(deepSleep: false)
        XCTAssertNil(feed(&e, route(to: 168, speed: 1.4, seed: 1)).stillAt)
        let s = try XCTUnwrap(tickUntilStill(&e, from: 150, through: 600).stillAt, "never went Still")
        send(&e, .steps(15), s + 60)
        XCTAssertEqual(e.state, .moving)
        let back = tickUntilStill(&e, from: s + 90, through: s + 400)
        XCTAssertEqual(back.stillAt, s + 180)
        XCTAssert(back.commands.contains(log(s + 180, "state", "still")))
        XCTAssert(back.commands.contains(log(s + 180, "wake", "indoor-nofix")))
        // After a Still proven by fixes, a wake keeps the normal 5 min.
        var (f, fs, _) = try stillEngine()
        send(&f, .steps(15), fs + 60)
        XCTAssertNil(tickUntilStill(&f, from: fs + 90, through: fs + 330).stillAt)
    }

    func testIndoorNoFixReturnsRaiseStepThreshold() throws {
        var e = MotionEngine(deepSleep: false)
        XCTAssertNil(feed(&e, route(to: 168, speed: 1.4, seed: 1)).stillAt)
        var s = try XCTUnwrap(tickUntilStill(&e, from: 150, through: 600).stillAt, "never went Still")
        for n in [15, 50, 150] {
            XCTAssertEqual(send(&e, .steps(n - 1), s + 30), [], "\(n - 1) steps woke")
            send(&e, .steps(n), s + 60)
            XCTAssertEqual(e.state, .moving, "\(n) steps did not wake")
            let back = tickUntilStill(&e, from: s + 90, through: s + 400)
            XCTAssert(back.commands.contains(log(s + 180, "wake", "indoor-nofix")), "\(back.commands)")
            s = try XCTUnwrap(back.stillAt)
        }
        XCTAssertEqual(send(&e, .steps(149), s + 30), [])
    }

    func testInaccurateWakeFixDoesNotPin() throws {
        let far = Geo.offset(lat: 52.37, lon: 4.90, north: 1000, east: 0)
        func vague(_ t: TimeInterval) -> MotionEvent {
            .wakeFix(Sample(t: at(t), lat: far.lat, lon: far.lon, hAcc: 800, speed: -1, course: -1), reason: "slc")
        }
        // Moving with no fix: an 800 m wake fix seeds nothing for the fallback.
        var e = MotionEngine(deepSleep: false)
        send(&e, .tick, 0)
        send(&e, vague(10), 10)
        XCTAssertEqual(tickUntilStill(&e, from: 30, through: 400).stillAt, 300)
        XCTAssertNil(e.fence)
        // Still with no position: it does not pin the place either.
        XCTAssertEqual(send(&e, vague(330), 330), [])
        XCTAssertNil(e.fence)
    }

    // MARK: staying still

    func testSofaNoTrip() throws {
        var (e, s, _) = try stillEngine()
        let f = try XCTUnwrap(e.fence)
        var rng = SeededRandom(seed: 13)
        var out: [Command] = []
        for i in 1...120 {                                                    // 1 h of ticks every 30 s
            let t = s + Double(i) * 30
            out += send(&e, .tick, t)
            if i % 10 == 0 {                                                  // a spot check every 5 min
                let p = Geo.offset(lat: f.lat, lon: f.lon, north: .random(in: -30...30, using: &rng),
                                   east: .random(in: -30...30, using: &rng))
                out += send(&e, .spotCheckDue, t)
                out += send(&e, .wakeFix(Sample(t: at(t), lat: p.lat, lon: p.lon, hAcc: 40, speed: -1, course: -1),
                                         reason: "spotcheck"), t + 10)
                out += send(&e, .spotCheckEnded, t + 20)
            }
            if i % 12 == 0 { out += send(&e, .steps(i / 12), t) }             // up to 10 steps
        }
        XCTAssertEqual(e.state, .still)
        XCTAssertFalse(out.contains(.startRecording))
    }

    // MARK: waking

    func testFifteenStepsWakes() throws {
        var (e, s, _) = try stillEngine()
        XCTAssertEqual(send(&e, .steps(10), s + 10), [])
        XCTAssertEqual(send(&e, .steps(14), s + 20), [])
        assertWoke(send(&e, .steps(15), s + 30), e, reason: "steps", stillAt: s, when: s + 30)
        XCTAssertEqual(send(&e, .steps(30), s + 40), [])                      // already Moving: no second wake
    }

    func testSwivelInChairDoesNotWake() throws {
        var (e, s, _) = try stillEngine()
        for i in 1...20 {                                                     // walking flickers every 30 s for 10 min
            let t = s + Double(i) * 30
            if i % 4 == 0 { XCTAssertFalse(send(&e, .steps(i / 4), t - 5).contains(.startRecording)) }   // 5 steps in all
            XCTAssertFalse(send(&e, .activity(.walking, confident: true), t).contains(.startRecording), "woke at \(t - s)")
        }
        XCTAssertEqual(e.state, .still)
    }

    func testWalkingWithStepsWakes() throws {
        var (e, s, _) = try stillEngine()
        XCTAssertEqual(send(&e, .activity(.walking, confident: true), s + 30), [])
        assertWoke(send(&e, .steps(10), s + 45), e, reason: "activity", stillAt: s, when: s + 45)
        XCTAssertEqual(send(&e, .geofenceExit, s + 50), [])
        // Steps first, then the activity.
        var (f, fs, _) = try stillEngine()
        XCTAssertEqual(send(&f, .steps(10), fs + 30), [])
        assertWoke(send(&f, .activity(.running, confident: true), fs + 40), f, reason: "activity", stillAt: fs, when: fs + 40)
        // More than 20 s apart: no corroboration.
        var (g, gs, _) = try stillEngine()
        XCTAssertEqual(send(&g, .steps(10), gs + 30), [])
        XCTAssertEqual(send(&g, .activity(.walking, confident: true), gs + 55), [])
        XCTAssertEqual(g.state, .still)
    }

    func testRaisedThresholdIgnoresWalkingCorroboration() throws {
        var (e, s, _) = try stillEngine()
        var rng = SeededRandom(seed: 25)
        _ = wander(&e, at: s + 30, steps: 15, rng: &rng)                      // threshold 50
        let t = s + 300
        XCTAssertEqual(send(&e, .activity(.walking, confident: true), t), [])
        XCTAssertEqual(send(&e, .steps(10), t + 20), [])
        XCTAssertEqual(e.state, .still)
    }

    func testVehicleActivityStillWakesAlone() throws {
        var (e, s, _) = try stillEngine()
        assertWoke(send(&e, .activity(.cycling, confident: true), s + 30), e, reason: "activity", stillAt: s, when: s + 30)
        var (f, fs, _) = try stillEngine()
        assertWoke(send(&f, .activity(.automotive, confident: true), fs + 30), f, reason: "activity", stillAt: fs, when: fs + 30)
    }

    func testUnconfidentActivityIgnored() throws {
        var (e, s, _) = try stillEngine()
        XCTAssertEqual(send(&e, .activity(.automotive, confident: false), s + 10), [])
        XCTAssertEqual(send(&e, .activity(.walking, confident: false), s + 20), [])
        XCTAssertEqual(send(&e, .activity(.stationary, confident: true), s + 30), [])
        XCTAssertEqual(send(&e, .activity(.unknown, confident: true), s + 40), [])
        XCTAssertEqual(e.state, .still)
    }

    func testWakeFixOutsideFenceWakes() throws {
        var (e, s, _) = try stillEngine()
        let f = try XCTUnwrap(e.fence)
        func fix(north: Double, hAcc: Double) -> MotionEvent {
            let p = Geo.offset(lat: f.lat, lon: f.lon, north: north, east: 0)
            return .wakeFix(Sample(t: at(s + 60), lat: p.lat, lon: p.lon, hAcc: hAcc, speed: -1, course: -1), reason: "spotcheck")
        }
        XCTAssertEqual(send(&e, fix(north: 25, hAcc: 10), s + 60), [])        // 25 - 10 = 15 <= 20
        XCTAssertEqual(send(&e, fix(north: 60, hAcc: 45), s + 70), [])        // far, but too vague
        assertWoke(send(&e, fix(north: 100, hAcc: 30), s + 80), e, reason: "spotcheck", stillAt: s, when: s + 80)
    }

    func testGeofenceExitWakes() throws {
        var (e, s, _) = try stillEngine()
        assertWoke(send(&e, .geofenceExit, s + 30), e, reason: "geofence", stillAt: s, when: s + 30)
    }

    // MARK: wandering

    /// Wakes with `n` steps at `t`, then stands inside the fence at 1 Hz; returns the commands of the fix that made it Still.
    func wander(_ e: inout MotionEngine, at t: TimeInterval, steps n: Int, rng: inout SeededRandom) -> [Command] {
        send(&e, .steps(n), t)
        XCTAssertEqual(e.state, .moving, "\(n) steps at \(t) did not wake")
        for i in 1...120 {
            let out = e.handle(.fix(standing(t + Double(i), east: 168, rng: &rng)), at: at(t + Double(i)))
            if e.state == .still { XCTAssert(i >= 60, "back in Still after \(i) s"); return out }
        }
        XCTFail("never returned to Still")
        return []
    }

    func testWanderInsideFenceReturnsToStillAfter60s() throws {
        var (e, s, _) = try stillEngine()
        let fence = try XCTUnwrap(e.fence)
        var rng = SeededRandom(seed: 21)
        let out = wander(&e, at: s + 30, steps: 15, rng: &rng)
        XCTAssertEqual(e.fence, fence)
        XCTAssertFalse(out.contains { if case .writeStillPoint = $0 { true } else { false } }, "wander-return wrote a still point")
        XCTAssert(out.contains(.stopRecording))
        XCTAssert(out.contains(.armGeofence(Fence(lat: fence.lat, lon: fence.lon, radius: 200))))
        XCTAssert(out.contains(log(s + 90, "state", "still")), "\(out)")
        XCTAssert(out.contains(log(s + 90, "wake", "wander-return")), "\(out)")
    }

    func testWanderStepThresholdRises() throws {
        var (e, s, _) = try stillEngine()
        var rng = SeededRandom(seed: 22)
        var t = s + 30
        _ = wander(&e, at: t, steps: 15, rng: &rng); t += 100
        XCTAssertEqual(send(&e, .steps(49), t), []); t += 10
        _ = wander(&e, at: t, steps: 50, rng: &rng); t += 100
        XCTAssertEqual(send(&e, .steps(149), t), []); t += 10
        _ = wander(&e, at: t, steps: 150, rng: &rng); t += 100
        XCTAssertEqual(send(&e, .steps(149), t), []); t += 10
        _ = wander(&e, at: t, steps: 150, rng: &rng)
    }

    func testLeavingFenceResetsThreshold() throws {
        var (e, s, _) = try stillEngine()
        var rng = SeededRandom(seed: 23)
        _ = wander(&e, at: s + 30, steps: 15, rng: &rng)                      // threshold 50
        send(&e, .steps(50), s + 130)
        XCTAssertEqual(e.state, .moving)
        // Walks 300 m north and settles there: a new visit starts at 15 steps.
        let far = (1...150).map { standing(s + 130 + Double($0), north: 300, east: 168, rng: &rng) }
        let still = try XCTUnwrap(feed(&e, far).stillAt, "never settled at the new place")
        assertWoke(send(&e, .steps(15), still + 10), e, reason: "steps", stillAt: still, when: still + 10)
    }

    func testWalkAwayFromVisitStillWakes() throws {
        var (e, s, _) = try stillEngine()
        var rng = SeededRandom(seed: 24)
        _ = wander(&e, at: s + 30, steps: 15, rng: &rng)
        _ = wander(&e, at: s + 130, steps: 50, rng: &rng)
        let f = try XCTUnwrap(e.fence)
        let p = Geo.offset(lat: f.lat, lon: f.lon, north: 300, east: 0)
        let out = send(&e, .wakeFix(Sample(t: at(s + 260), lat: p.lat, lon: p.lon, hAcc: 10, speed: -1, course: -1), reason: "spotcheck"), s + 260)
        XCTAssertEqual(e.state, .moving)
        XCTAssert(out.contains(log(s + 260, "wake", "spotcheck")), "\(out)")
    }

    func testGeofenceWakeThenNewVisitResetsThreshold() throws {
        var (e, s, _) = try stillEngine()
        var rng = SeededRandom(seed: 25)
        _ = wander(&e, at: s + 30, steps: 15, rng: &rng)
        _ = wander(&e, at: s + 130, steps: 50, rng: &rng)                     // threshold 150
        send(&e, .geofenceExit, s + 200)
        XCTAssertEqual(e.state, .moving)
        let far = (1...150).map { standing(s + 200 + Double($0), north: 300, east: 168, rng: &rng) }
        let still = try XCTUnwrap(feed(&e, far).stillAt, "never settled at the new place")
        assertWoke(send(&e, .steps(15), still + 10), e, reason: "steps", stillAt: still, when: still + 10)
    }

    func testLateFirstFixIsNoWanderReturn() throws {
        var (e, s, _) = try stillEngine()
        var rng = SeededRandom(seed: 26)
        send(&e, .steps(15), s + 30)
        for t in stride(from: s + 120, through: s + 180, by: 1) {             // first fix 90 s after the wake
            send(&e, .fix(standing(t, east: 168, rng: &rng)), t)
            XCTAssertNotEqual(e.state, .still, "wander-return at \(t - s)")
        }
    }

    func testVehicleDuringWanderCancelsIt() throws {
        var (e, s, _) = try stillEngine()
        var rng = SeededRandom(seed: 27)
        send(&e, .steps(15), s + 30)
        send(&e, .activity(.automotive, confident: true), s + 50)
        for t in stride(from: s + 31, through: s + 100, by: 1) {
            send(&e, .fix(standing(t, east: 168, rng: &rng)), t)
            XCTAssertNotEqual(e.state, .still, "wander-return at \(t - s)")
        }
    }

    func testVehicleWakeBlocksNoFixReturn() throws {
        var e = MotionEngine(deepSleep: false)
        XCTAssertNil(feed(&e, route(to: 168, speed: 1.4, seed: 1)).stillAt)
        let s = try XCTUnwrap(tickUntilStill(&e, from: 150, through: 600).stillAt, "never went Still")
        send(&e, .activity(.automotive, confident: true), s + 60)             // underground garage departure
        XCTAssertEqual(e.state, .moving)
        XCTAssertNil(tickUntilStill(&e, from: s + 90, through: s + 330).stillAt)   // past the 2 min after a fallback wake
        XCTAssertEqual(tickUntilStill(&e, from: s + 360, through: s + 420).stillAt, s + 360)
    }

    // MARK: spot checks and still points

    func testSpotCheckBackoff() throws {
        var (e, s, entry) = try stillEngine()
        var delays = scheduled(entry)
        var t = s
        for _ in 0..<5 {
            t += delays.last ?? 30
            XCTAssertEqual(send(&e, .spotCheckDue, t), [.startSpotCheck])
            t += 20
            let out = send(&e, .spotCheckEnded, t)
            XCTAssert(out.contains(.stopSpotCheck))
            delays += scheduled(out)
        }
        XCTAssertEqual(delays, [30, 60, 120, 240, 300, 300])

        send(&e, .geofenceExit, t + 1)                                       // leave, stop somewhere else
        var rng = SeededRandom(seed: 15)
        let stand = (2...140).map { standing(t + Double($0), north: 500, east: 168, rng: &rng) }
        let r = feed(&e, stand)
        XCTAssertNotNil(r.stillAt)
        XCTAssertEqual(scheduled(r.commands), [30])
    }

    func testStillPointEveryFiveMinutes() throws {
        var (e, s, entry) = try stillEngine()
        let f = try XCTUnwrap(e.fence)
        var points = stillPoints(entry)
        for i in 1...40 { points += stillPoints(send(&e, .tick, s + Double(i) * 30)) }
        XCTAssertEqual(points.map(\.t), [0, 300, 600, 900, 1200].map { at(s + $0) })
        XCTAssert(points.allSatisfy { $0.kind == .still && $0.hAcc == f.radius && $0.lat == f.lat && $0.lon == f.lon })
    }

    // MARK: no motion, deep sleep

    func testNoMotionStillStopsAndWakes() throws {
        var (e, s, _) = try stillEngine()
        let f = try XCTUnwrap(e.fence)
        let p = Geo.offset(lat: f.lat, lon: f.lon, north: 300, east: 0)
        let out = send(&e, .wakeFix(Sample(t: at(s + 60), lat: p.lat, lon: p.lon, hAcc: 20, speed: -1, course: -1),
                                    reason: "spotcheck"), s + 60)
        assertWoke(out, e, reason: "spotcheck", stillAt: s, when: s + 60)
    }

    func testDeepSleepDisablesKeepAliveAndSpotChecks() throws {
        var (e, s, entry) = try stillEngine(deepSleep: true)
        XCTAssertFalse(entry.contains(.setKeepAlive(false)))                 // keeps the app alive for spot checks
        XCTAssertEqual(scheduled(entry), [900])                              // spot checks go on, every 15 min
        XCTAssertEqual(send(&e, .spotCheckDue, s + 900), [.startSpotCheck])
        XCTAssertEqual(scheduled(send(&e, .spotCheckEnded, s + 920)), [900])
        XCTAssertEqual(e.state, .still)
    }

    func testDeepSleepToggleWhileStill() throws {
        var (e, s, _) = try stillEngine()
        let on = send(&e, .deepSleepChanged(true), s + 10)
        XCTAssertFalse(on.contains(.setKeepAlive(false)))
        XCTAssert(on.contains(log(s + 10, "deepSleep", "on")))
        XCTAssertEqual(scheduled(on), [900])
        let off = send(&e, .deepSleepChanged(false), s + 100)
        XCTAssert(off.contains(.setKeepAlive(true)))
        XCTAssertEqual(scheduled(off), [30])
        XCTAssertEqual(send(&e, .spotCheckDue, s + 130), [.startSpotCheck])
    }

    // MARK: confirmed presence

    /// A reading `north` m from the fence centre, as keep-alive (`.confirmFix`) or spot check (`.wakeFix`).
    func reading(_ f: Fence, north: Double, hAcc: Double, _ t: TimeInterval, wake: Bool = false) -> MotionEvent {
        let p = Geo.offset(lat: f.lat, lon: f.lon, north: north, east: 0)
        let s = Sample(t: at(t), lat: p.lat, lon: p.lon, hAcc: hAcc, speed: -1, course: -1)
        return wake ? .wakeFix(s, reason: "spotcheck") : .confirmFix(s)
    }
    func fills(_ out: [Command]) -> [(Date, Date)] { out.compactMap { if case .fillUnconfirmed(let a, let b) = $0 { (a, b) } else { nil } } }

    func testNoConfirmationStopsStillPoints() throws {
        var (e, s, entry) = try stillEngine()
        var points = stillPoints(entry), logs: [Command] = []
        for i in 1...90 {                                                     // 45 min, no reading
            let out = send(&e, .tick, s + Double(i) * 30)
            points += stillPoints(out); logs += out.filter { if case .log = $0 { true } else { false } }
        }
        XCTAssertEqual(points.map(\.t), stride(from: 0.0, through: 1800, by: 300).map { at(s + $0) })
        XCTAssertEqual(e.state, .still)
        XCTAssertEqual(logs.filter { $0 == log(s + 2100, "still", "unconfirmed") }.count, 1)   // logged once, at the first missed point
    }

    func testConfirmFixInsideAreaKeepsStillPoints() throws {
        var (e, s, entry) = try stillEngine()
        let f = try XCTUnwrap(e.fence)
        var points = stillPoints(entry), out: [Command] = []
        for i in 1...180 {                                                    // 90 min; a keep-alive reading every 10 min
            let t = s + Double(i) * 30
            let c = i % 20 == 0 ? send(&e, reading(f, north: 60, hAcc: 65, t), t) : send(&e, .tick, t)
            points += stillPoints(c); out += c
        }
        XCTAssertEqual(points.map(\.t), stride(from: 0.0, through: 5400, by: 300).map { at(s + $0) })
        XCTAssert(fills(out).isEmpty)
        XCTAssertEqual(e.state, .still)
    }

    func testInaccurateReadingDoesNotConfirm() throws {
        var (e, s, entry) = try stillEngine()
        let f = try XCTUnwrap(e.fence)
        var points = stillPoints(entry), out: [Command] = []
        for i in 1...120 {
            let t = s + Double(i) * 30
            let c = i % 20 == 0 ? send(&e, reading(f, north: 0, hAcc: 2000, t), t) : send(&e, .tick, t)
            points += stillPoints(c); out += c
        }
        XCTAssertEqual(points.last?.t, at(s + 1800))
        XCTAssert(fills(out).isEmpty)
        XCTAssertEqual(e.state, .still)
    }

    func testConfirmationAfterGapRequestsFill() throws {
        var (e, s, _) = try stillEngine()
        let f = try XCTUnwrap(e.fence)
        for i in 1...90 { send(&e, .tick, s + Double(i) * 30) }
        let out = send(&e, reading(f, north: 10, hAcc: 30, s + 2710), s + 2710)
        XCTAssertEqual(out, [.fillUnconfirmed(from: at(s + 1800), to: at(s + 2710)), .writeStillPoint(f.stillPoint(at: at(s + 2710)))])
        XCTAssertEqual(stillPoints(send(&e, .tick, s + 3010)).map(\.t), [at(s + 3010)])   // live points resume
        // A spot-check fix inside the area confirms too.
        for i in 1...70 { send(&e, .tick, s + 3010 + Double(i) * 30) }
        let spot = send(&e, reading(f, north: 0, hAcc: 15, s + 6000, wake: true), s + 6000)
        XCTAssertEqual(fills(spot).map(\.0), [at(s + 4510)])
        XCTAssertEqual(e.state, .still)
    }

    func testReadingElsewhereAfterGapWakes() throws {
        var (e, s, _) = try stillEngine()
        let f = try XCTUnwrap(e.fence)
        for i in 1...90 { send(&e, .tick, s + Double(i) * 30) }
        let out = send(&e, reading(f, north: 300, hAcc: 20, s + 2710, wake: true), s + 2710)
        XCTAssertEqual(e.state, .moving)
        XCTAssert(out.contains(.startRecording))
        XCTAssert(out.contains(log(s + 2710, "wake", "spotcheck")))
        XCTAssert(fills(out).isEmpty)
        // Nothing confirmed the unconfirmed stretch: the departure backfill stops at the confirmed window.
        XCTAssert(out.contains(.resolveDeparture(stillSince: at(s), until: at(s + 1800))), "\(out)")
    }

    func testAirplaneModeNightIsNotAssumed() throws {
        var (e, s, _) = try stillEngine()
        let f = try XCTUnwrap(e.fence)
        XCTAssertEqual(stillPoints(send(&e, .tick, s + 3600)), [])            // a stray tick in the night writes nothing
        let out = send(&e, reading(f, north: 0, hAcc: 20, s + 28800), s + 28800)
        XCTAssertEqual(fills(out).map(\.0), [at(s)])
        XCTAssertEqual(fills(out).map(\.1), [at(s + 28800)])
    }

    func testFallbackAfterWakeDoesNotConfirm() throws {
        var (e, s, _) = try stillEngine()
        for i in 1...90 { send(&e, .tick, s + Double(i) * 30) }               // 45 min, no reading
        send(&e, .steps(15), s + 2730)                                        // a bathroom trip, no fix indoors
        XCTAssertEqual(e.state, .moving)
        var out: [Command] = []
        for i in 1...80 { out += send(&e, .tick, s + 2730 + Double(i) * 30) }
        XCTAssertEqual(e.state, .still)                                       // back by the no-fix fallback
        XCTAssertEqual(stillPoints(out), [])
    }

    func testDeepSleepDuringUnconfirmedStretchWritesNothing() throws {
        var (e, s, _) = try stillEngine()
        for i in 1...90 { send(&e, .tick, s + Double(i) * 30) }
        var out = send(&e, .deepSleepChanged(true), s + 2730)
        for i in 1...80 { out += send(&e, .tick, s + 2730 + Double(i) * 30) }
        XCTAssertEqual(stillPoints(out), [])
        let wake = send(&e, .geofenceExit, s + 6000)
        XCTAssert(wake.contains(.resolveDeparture(stillSince: at(s), until: at(s + 1800))), "\(wake)")
    }
}
