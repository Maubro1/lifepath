import Foundation

public enum MotionState: String, Sendable { case moving, settling, still }

public struct Fence: Sendable, Equatable {
    public var lat, lon, radius: Double
    public init(lat: Double, lon: Double, radius: Double) { self.lat = lat; self.lon = lon; self.radius = radius }
    func contains(_ p: FilteredPoint) -> Bool { Geo.distance(p.lat, p.lon, lat, lon) <= radius }
    func stillPoint(at t: Date) -> FilteredPoint {
        FilteredPoint(t: t, lat: lat, lon: lon, rawLat: lat, rawLon: lon, hAcc: radius, speed: 0, kind: .still)
    }
}

public enum MotionEvent: Sendable {
    case fix(FilteredPoint)                 // recording manager, after filter
    case tick                               // keep-alive update or any wake; drives time-based rules
    case steps(Int)                         // cumulative since Still began
    case activity(Activity, confident: Bool)
    case wakeFix(Sample, reason: String)    // spot check, significant change
    case confirmFix(Sample)                 // keep-alive position: confirms presence while Still, else a tick
    case geofenceExit
    case spotCheckDue, spotCheckEnded
    case deepSleepChanged(Bool)             // effective deep sleep (manual setting OR thermal/low power/battery)
}

public enum Command: Sendable, Equatable {
    case startRecording, stopRecording
    case startSpotCheck, stopSpotCheck, scheduleSpotCheck(after: TimeInterval)
    case setKeepAlive(Bool)                 // keep-alive stays on in deep sleep too, so the spot-check timer fires
    case armGeofence(Fence), disarmGeofence
    case writeStillPoint(FilteredPoint)
    case resolveDeparture(stillSince: Date, until: Date) // app queries CoreMotion history, then backfills up to `until` at most
    case fillUnconfirmed(from: Date, to: Date) // app backfills still points over (from, to) only if motion history is clean
    case log(LoggedEvent)
}

extension Activity {
    var isMoving: Bool { self == .walking || self == .running || isVehicle }
}

/// Decides moving / settling / still. Pure: all time comes from `now`; the app executes the returned commands.
public struct MotionEngine: Sendable {
    public private(set) var state: MotionState = .moving
    /// The settling fence (radius 20-100 m); while Still, wake fixes are judged against it.
    public private(set) var fence: Fence?
    private var deepSleep: Bool
    private var fixes: [FilteredPoint] = []   // last 6 min plus the newest older fix, so a full window can be proven
    private var quietSince: Date?             // last accepted fix, or entry into Moving
    private var lastVehicle: Date?            // any vehicle activity or a fix faster than 7 m/s
    private var lastConfidentVehicle: Date?   // blocks the indoor fallback: a ride through a tunnel
    private var lastKnown: Fence?             // last accepted fix or trusted wake fix, radius clamp(hAcc, 20, 100)
    private var stillSince: Date?
    private var lastStillPoint: Date?
    private var lastConfirmed = Date.distantPast   // Still entry on a fix or the last reading inside the rest area
    private var lastFixAt = Date.distantPast       // last accepted fix or trusted wake fix
    private var stopLogged = false                 // "still unconfirmed" logged for the current unconfirmed stretch
    private var spotDelay: TimeInterval = 30
    private var spotChecking = false
    private var stillByFallback = false       // the current/last Still came from the no-fix fallback
    private var needFixAfterWake = false      // woke from a fallback Still: no fix within 2 min returns to Still
    private var stepsThreshold = 15           // steps that wake from Still; 15, then 50, then 150 after each wander-return
    private var visitFence: Fence?            // the Still fence at the last wake; a Moving fix outside it resets the threshold
    private var wanderFence: Fence?           // same fence while a steps/walking wake could still be a wander
    private var wanderSince = Date.distantPast
    private var wanderFixed = false           // an accepted fix arrived since the wake
    private var stepLog: [(t: Date, n: Int)] = []   // step updates while Still: the last 40 s plus the newest older one
    private var walkedAt: Date?               // last confident walking/running while Still

    public init(deepSleep: Bool) {
        self.deepSleep = deepSleep
    }

    public mutating func handle(_ e: MotionEvent, at now: Date) -> [Command] {
        if quietSince == nil { quietSince = now }
        if case .deepSleepChanged(let on) = e { return setDeepSleep(on, now) }
        if state == .still { return handleStill(e, now) }
        switch e {
        case .fix(let p):
            wanderOutside(p.lat, p.lon)
            wanderFixed = wanderFixed || (wanderFence != nil && now.timeIntervalSince(wanderSince) <= 60)
            return wanderReturn(now) ?? onFix(p, now)
        case .tick, .confirmFix: return wanderReturn(now) ?? onTick(now)
        case .activity(let a, let confident) where a.isVehicle:
            lastVehicle = now
            if confident { lastConfidentVehicle = now; wanderFence = nil }   // backing out slowly is no wander
        case .wakeFix(let s, _) where (0...100).contains(s.hAcc):   // a vague fix must not pin the place
            lastKnown = Self.pin(s.lat, s.lon, s.hAcc); lastFixAt = now
            wanderOutside(s.lat, s.lon)
        case .steps, .activity, .wakeFix, .geofenceExit, .spotCheckDue, .spotCheckEnded, .deepSleepChanged: break
        }
        return []
    }

    private static func pin(_ lat: Double, _ lon: Double, _ hAcc: Double) -> Fence {
        Fence(lat: lat, lon: lon, radius: min(max(hAcc, 20), 100))
    }

    /// A position outside the visit fence ends the wander and resets the steps threshold.
    private mutating func wanderOutside(_ lat: Double, _ lon: Double) {
        guard let v = visitFence, Geo.distance(lat, lon, v.lat, v.lon) > v.radius else { return }
        visitFence = nil; wanderFence = nil; stepsThreshold = 15
    }

    /// 60 s after a steps/walking wake, with fixes and all of them inside the visit fence: back to Still, no new still point.
    private mutating func wanderReturn(_ now: Date) -> [Command]? {
        guard let w = wanderFence, wanderFixed, now.timeIntervalSince(wanderSince) >= 60 else { return nil }
        stepsThreshold = stepsThreshold == 15 ? 50 : 150
        return goStill(w, now, writePoint: false) + [log("wake", "wander-return", now)]
    }

    private mutating func onFix(_ p: FilteredPoint, _ now: Date) -> [Command] {
        quietSince = now; lastFixAt = now
        lastKnown = Self.pin(p.lat, p.lon, p.hAcc)
        needFixAfterWake = false
        if p.speed > 7 { lastVehicle = now }
        fixes.append(p)
        while fixes.count > 1, fixes[1].t <= now.addingTimeInterval(-360) { fixes.removeFirst() }
        let recent = fixes.filter { $0.t >= p.t.addingTimeInterval(-120) }
        var w = 0.0, lat = 0.0, lon = 0.0, acc = 0.0
        for f in recent {
            let wi = 1 / pow(max(f.hAcc, 1), 2)
            w += wi; lat += wi * f.lat; lon += wi * f.lon; acc += f.hAcc
        }
        let f = Fence(lat: lat / w, lon: lon / w, radius: min(max(acc / Double(recent.count), 20), 100))
        fence = f
        guard f.contains(p) else {
            guard state == .settling else { return [] }
            guard !tolerates(f, now) else { return settleCheck(now) }   // one outlier within the 10% allowance is no departure
            state = .moving
            return [log("state", "moving", now)]
        }
        guard state == .moving else { return settleCheck(now) }
        state = .settling
        return [log("state", "settling", now)] + settleCheck(now)
    }

    /// The fixes of the settling window (2 min, 6 min after a vehicle), from the newest one at or before its start.
    private func windowFixes(_ now: Date) -> ArraySlice<FilteredPoint> {
        let window: TimeInterval = lastVehicle.map { now.timeIntervalSince($0) <= 600 } == true ? 360 : 120
        return fixes[(fixes.lastIndex(where: { $0.t <= now.addingTimeInterval(-window) }) ?? 0)...]
    }

    /// At most 10% of the window's fixes outside the fence; with fewer than 10 fixes, none.
    private func tolerates(_ f: Fence, _ now: Date) -> Bool {
        let w = windowFixes(now), outside = w.filter { !f.contains($0) }.count
        return w.count < 10 ? outside == 0 : outside * 10 <= w.count
    }

    /// Still once the window is proven by fixes (the oldest inside, so a walk-in is never tolerated) and the outlier
    /// tolerance holds, so one multipath outlier does not restart the clock.
    private mutating func settleCheck(_ now: Date) -> [Command] {
        guard state == .settling, let f = fence else { return [] }
        let window: TimeInterval = lastVehicle.map { now.timeIntervalSince($0) <= 600 } == true ? 360 : 120
        guard let oldest = windowFixes(now).first, oldest.t <= now.addingTimeInterval(-window),
              f.contains(oldest), tolerates(f, now) else { return [] }
        return goStill(f, now)
    }

    /// Settling without new fixes, or the indoor fallback: no fix for 5 min (2 min after waking from a fallback Still),
    /// whatever steps or walking say, unless a confident vehicle was seen in the last 5 min.
    private mutating func onTick(_ now: Date) -> [Command] {
        let settled = settleCheck(now)
        if !settled.isEmpty { return settled }
        func quiet(_ d: Date?, _ limit: TimeInterval) -> Bool { d.map { now.timeIntervalSince($0) >= limit } ?? true }
        guard quiet(quietSince, needFixAfterWake ? 120 : 300), quiet(lastConfidentVehicle, 300) else { return [] }
        // The settling fence trails behind a walking arrival; pin to the last known position when it lies outside.
        var pinned = fence
        if let k = lastKnown, pinned.map({ Geo.distance(k.lat, k.lon, $0.lat, $0.lon) > $0.radius }) ?? true { pinned = k }
        let returning = needFixAfterWake
        if returning { stepsThreshold = stepsThreshold == 15 ? 50 : 150 }   // same backoff as a wander-return
        let out = goStill(pinned, now, fallback: true)
        return returning ? out + [log("wake", "indoor-nofix", now)] : out
    }

    /// A nil fence (nothing ever known) still stops GPS; the first wake fix then pins the place.
    private mutating func goStill(_ f: Fence?, _ now: Date, fallback: Bool = false, writePoint: Bool = true) -> [Command] {
        state = .still; wanderFence = nil; fence = f; stillSince = now; lastStillPoint = now
        lastConfirmed = fallback ? lastFixAt : now; stopLogged = false   // the no-fix fallback is confirmed only by its last fix
        fixes = []; spotDelay = 30; stillByFallback = fallback; needFixAfterWake = false; stepLog = []; walkedAt = nil
        var out: [Command] = [.stopRecording]
        if let f { out.append(.armGeofence(Fence(lat: f.lat, lon: f.lon, radius: 200))) }
        out.append(.scheduleSpotCheck(after: deepSleep ? 900 : spotDelay))
        if let f, writePoint, confirmed(now) { out.append(.writeStillPoint(f.stillPoint(at: now))) }
        return out + [log("state", "still", now)]
    }

    private mutating func handleStill(_ e: MotionEvent, _ now: Date) -> [Command] {
        switch e {
        case .steps(let n):
            if n >= stepsThreshold { return wake("steps", now, wander: true) }
            stepLog.append((now, n))
            while stepLog.count > 1, stepLog[1].t < now.addingTimeInterval(-40) { stepLog.removeFirst() }
            return walkCorroborated(now) ? wake("activity", now, wander: true) : []
        case .activity(let a, let confident):
            guard confident && a.isMoving else { return [] }
            if a.isVehicle {                              // a garage departure is no fix-less fallback
                lastVehicle = now; lastConfidentVehicle = now; stepsThreshold = 15
                return wake("activity", now)
            }
            walkedAt = now
            return walkCorroborated(now) ? wake("activity", now, wander: true) : []
        case .wakeFix(let s, let reason):
            guard s.hAcc >= 0 else { return [] }
            let k = Self.pin(s.lat, s.lon, s.hAcc)
            guard let f = fence else {                    // Still with no position yet: this fix pins the place
                guard s.hAcc <= 100 else { return [] }
                fence = k; lastKnown = k; lastStillPoint = now; lastConfirmed = now
                return [.armGeofence(Fence(lat: k.lat, lon: k.lon, radius: 200)), .writeStillPoint(k.stillPoint(at: now))]
            }
            guard Geo.distance(s.lat, s.lon, f.lat, f.lon) - s.hAcc > f.radius else { return confirm(s, now) ?? [] }
            lastKnown = k
            stepsThreshold = 15
            return wake(reason, now)
        case .geofenceExit:
            return wake("geofence", now)
        case .spotCheckDue:
            guard !spotChecking else { return [] }
            spotChecking = true
            return [.startSpotCheck]
        case .spotCheckEnded:
            var out: [Command] = []
            if spotChecking {
                spotChecking = false
                spotDelay = min(spotDelay * 2, 300)
                out = [.stopSpotCheck, .scheduleSpotCheck(after: deepSleep ? 900 : spotDelay)]
            }
            return out + stillPointIfDue(now)
        case .tick:
            return stillPointIfDue(now)
        case .confirmFix(let s):
            return (confirm(s, now) ?? []) + stillPointIfDue(now)
        case .fix, .deepSleepChanged:
            return []
        }
    }

    /// A pocket fidget can look like confident walking: it counts only with >= 8 steps arriving within 20 s of it (counted
    /// from the step updates logged since this Still began), and only at the base threshold: once a wander-return has
    /// raised it, steps alone decide.
    private func walkCorroborated(_ now: Date) -> Bool {
        guard stepsThreshold == 15, let w = walkedAt, now.timeIntervalSince(w) <= 20, let last = stepLog.last,
              last.t >= w.addingTimeInterval(-20) else { return false }
        let before = stepLog.last { $0.t < w.addingTimeInterval(-20) }?.n ?? 0
        return last.n - before >= 8
    }

    private mutating func wake(_ reason: String, _ now: Date, wander: Bool = false) -> [Command] {
        var out: [Command] = spotChecking ? [.stopSpotCheck] : []
        out += [.startRecording, .disarmGeofence, .setKeepAlive(true)]
        // The departure backfill covers only confirmed time: nothing confirmed the place after that.
        if let s = stillSince { out.append(.resolveDeparture(stillSince: s, until: min(now, lastConfirmed.addingTimeInterval(1800)))) }
        state = .moving; spotChecking = false; stillSince = nil; quietSince = now; needFixAfterWake = stillByFallback
        visitFence = fence; wanderFence = wander ? fence : nil; wanderSince = now; wanderFixed = false
        return out + [log("wake", reason, now), log("state", "moving", now)]
    }

    /// A still point at t needs a reading that confirmed presence at most 30 min before t (t - lastConfirmed <= 1800 s),
    /// in deep sleep too. The unconfirmed stretch starts at the last point written.
    private func confirmed(_ now: Date) -> Bool { now.timeIntervalSince(lastConfirmed) <= 1800 }

    /// A reading (hAcc <= 100 m) consistent with the rest area, allowing for its accuracy, confirms presence. After an
    /// unconfirmed stretch the app may fill it from motion history; a point is written for now.
    private mutating func confirm(_ s: Sample, _ now: Date) -> [Command]? {
        guard let f = fence, (0...100).contains(s.hAcc), Geo.distance(s.lat, s.lon, f.lat, f.lon) - s.hAcc <= f.radius else { return nil }
        defer { lastConfirmed = now; stopLogged = false }
        guard !confirmed(now), let from = lastStillPoint else { return [] }
        lastStillPoint = now
        return [.fillUnconfirmed(from: from, to: now), .writeStillPoint(f.stillPoint(at: now))]
    }

    private mutating func stillPointIfDue(_ now: Date) -> [Command] {
        guard let f = fence, let last = lastStillPoint, now.timeIntervalSince(last) >= 300 else { return [] }
        guard confirmed(now) else { defer { stopLogged = true }; return stopLogged ? [] : [log("still", "unconfirmed", now)] }
        lastStillPoint = now
        return [.writeStillPoint(f.stillPoint(at: now))]
    }

    private mutating func setDeepSleep(_ on: Bool, _ now: Date) -> [Command] {
        guard on != deepSleep else { return [] }
        deepSleep = on
        var out: [Command] = []
        if state == .still {
            if on {
                if spotChecking { spotChecking = false; out.append(.stopSpotCheck) }
                out.append(.scheduleSpotCheck(after: 900))
            } else {
                spotDelay = 30
                out += [.setKeepAlive(true), .scheduleSpotCheck(after: spotDelay)]
            }
        }
        return out + [log("deepSleep", on ? "on" : "off", now)]
    }

    private func log(_ kind: String, _ detail: String, _ t: Date) -> Command { .log(LoggedEvent(t: t, kind: kind, detail: detail)) }
}
