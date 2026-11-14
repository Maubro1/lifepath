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
    case wakeFix(Sample, reason: String)    // spot check, significant change, visit
    case geofenceExit
    case spotCheckDue, spotCheckEnded
    case deepSleepChanged(Bool)             // effective deep sleep (manual setting OR thermal/low power/battery)
}

public enum Command: Sendable, Equatable {
    case startRecording, stopRecording
    case startSpotCheck, stopSpotCheck, scheduleSpotCheck(after: TimeInterval)
    case setKeepAlive(Bool)                 // false only in deep sleep
    case armGeofence(Fence), disarmGeofence
    case writeStillPoint(FilteredPoint)
    case resolveDeparture(stillSince: Date) // app queries CoreMotion history, then backfills
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
    private var spotDelay: TimeInterval = 30
    private var spotChecking = false
    private var stillByFallback = false       // the current/last Still came from the no-fix fallback
    private var needFixAfterWake = false      // woke from a fallback Still: no fix within 2 min returns to Still
    private var stepsThreshold = 15           // steps that wake from Still; 15, then 50, then 150 after each wander-return
    private var wanderFence: Fence?           // visit fence while a steps/walking wake could still be a wander
    private var wanderSince = Date.distantPast
    private var wanderFixed = false           // an accepted fix arrived since the wake

    /// `motionAvailable` is accepted for the app's sake; no rule depends on it (the fallback ignores steps).
    public init(motionAvailable: Bool, deepSleep: Bool) {
        self.deepSleep = deepSleep
    }

    public mutating func handle(_ e: MotionEvent, at now: Date) -> [Command] {
        if quietSince == nil { quietSince = now }
        if case .deepSleepChanged(let on) = e { return setDeepSleep(on, now) }
        if state == .still { return handleStill(e, now) }
        switch e {
        case .fix(let p):
            wanderOutside(p.lat, p.lon)
            wanderFixed = wanderFixed || wanderFence != nil
            return wanderReturn(now) ?? onFix(p, now)
        case .tick: return wanderReturn(now) ?? onTick(now)
        case .activity(let a, let confident) where a.isVehicle:
            lastVehicle = now
            if confident { lastConfidentVehicle = now }
        case .wakeFix(let s, _) where s.hAcc >= 0:
            lastKnown = Self.pin(s.lat, s.lon, s.hAcc)
            wanderOutside(s.lat, s.lon)
        case .steps, .activity, .wakeFix, .geofenceExit, .spotCheckDue, .spotCheckEnded, .deepSleepChanged: break
        }
        return []
    }

    private static func pin(_ lat: Double, _ lon: Double, _ hAcc: Double) -> Fence {
        Fence(lat: lat, lon: lon, radius: min(max(hAcc, 20), 100))
    }

    /// A position outside the wander fence ends the wander and resets the steps threshold.
    private mutating func wanderOutside(_ lat: Double, _ lon: Double) {
        guard let w = wanderFence, Geo.distance(lat, lon, w.lat, w.lon) > w.radius else { return }
        wanderFence = nil; stepsThreshold = 15
    }

    /// 60 s after a steps/walking wake, with fixes and all of them inside the visit fence: back to Still, no new still point.
    private mutating func wanderReturn(_ now: Date) -> [Command]? {
        guard let w = wanderFence, wanderFixed, now.timeIntervalSince(wanderSince) >= 60 else { return nil }
        stepsThreshold = stepsThreshold == 15 ? 50 : 150
        return goStill(w, now, writePoint: false) + [log("wake", "wander-return", now)]
    }

    private mutating func onFix(_ p: FilteredPoint, _ now: Date) -> [Command] {
        quietSince = now
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
            state = .moving
            return [log("state", "moving", now)]
        }
        guard state == .moving else { return settleCheck(now) }
        state = .settling
        return [log("state", "settling", now)] + settleCheck(now)
    }

    /// Still once every fix of the last 2 min (6 min after a vehicle) lies in the fence.
    private mutating func settleCheck(_ now: Date) -> [Command] {
        guard state == .settling, let f = fence else { return [] }
        let window: TimeInterval = lastVehicle.map { now.timeIntervalSince($0) <= 600 } == true ? 360 : 120
        guard let start = fixes.reversed().prefix(while: { f.contains($0) }).last,
              start.t <= now.addingTimeInterval(-window) else { return [] }
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
        let out = goStill(pinned, now, fallback: true)
        return returning ? out + [log("wake", "indoor-nofix", now)] : out
    }

    /// A nil fence (nothing ever known) still stops GPS; the first wake fix then pins the place.
    private mutating func goStill(_ f: Fence?, _ now: Date, fallback: Bool = false, writePoint: Bool = true) -> [Command] {
        state = .still; wanderFence = nil; fence = f; stillSince = now; lastStillPoint = now
        fixes = []; spotDelay = 30; stillByFallback = fallback; needFixAfterWake = false
        var out: [Command] = [.stopRecording]
        if let f { out.append(.armGeofence(Fence(lat: f.lat, lon: f.lon, radius: 200))) }
        out.append(deepSleep ? .setKeepAlive(false) : .scheduleSpotCheck(after: spotDelay))
        if let f, writePoint { out.append(.writeStillPoint(f.stillPoint(at: now))) }
        return out + [log("state", "still", now)]
    }

    private mutating func handleStill(_ e: MotionEvent, _ now: Date) -> [Command] {
        switch e {
        case .steps(let n):
            return n >= stepsThreshold ? wake("steps", now, wander: true) : []
        case .activity(let a, let confident):
            guard confident && a.isMoving else { return [] }
            if a.isVehicle { lastVehicle = now; lastConfidentVehicle = now; stepsThreshold = 15 }  // a garage departure is no fix-less fallback
            return wake("activity", now, wander: !a.isVehicle)
        case .wakeFix(let s, let reason):
            guard s.hAcc >= 0 else { return [] }
            let k = Self.pin(s.lat, s.lon, s.hAcc)
            guard let f = fence else {                    // Still with no position yet: this fix pins the place
                fence = k; lastKnown = k; lastStillPoint = now
                return [.armGeofence(Fence(lat: k.lat, lon: k.lon, radius: 200)), .writeStillPoint(k.stillPoint(at: now))]
            }
            guard Geo.distance(s.lat, s.lon, f.lat, f.lon) - s.hAcc > f.radius else { return [] }
            lastKnown = k
            stepsThreshold = 15
            return wake(reason, now)
        case .geofenceExit:
            return wake("geofence", now)
        case .spotCheckDue:
            guard !deepSleep, !spotChecking else { return [] }
            spotChecking = true
            return [.startSpotCheck]
        case .spotCheckEnded:
            var out: [Command] = []
            if spotChecking {
                spotChecking = false
                spotDelay = min(spotDelay * 2, 300)
                out = deepSleep ? [.stopSpotCheck] : [.stopSpotCheck, .scheduleSpotCheck(after: spotDelay)]
            }
            return out + stillPointIfDue(now)
        case .tick:
            return stillPointIfDue(now)
        case .fix, .deepSleepChanged:
            return []
        }
    }

    private mutating func wake(_ reason: String, _ now: Date, wander: Bool = false) -> [Command] {
        var out: [Command] = spotChecking ? [.stopSpotCheck] : []
        out += [.startRecording, .disarmGeofence, .setKeepAlive(true)]
        if let s = stillSince { out.append(.resolveDeparture(stillSince: s)) }
        state = .moving; spotChecking = false; stillSince = nil; quietSince = now; needFixAfterWake = stillByFallback
        wanderFence = wander ? fence : nil; wanderSince = now; wanderFixed = false
        return out + [log("wake", reason, now), log("state", "moving", now)]
    }

    private mutating func stillPointIfDue(_ now: Date) -> [Command] {
        guard let f = fence, let last = lastStillPoint, now.timeIntervalSince(last) >= 300 else { return [] }
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
                out.append(.setKeepAlive(false))
            } else {
                spotDelay = 30
                out += [.setKeepAlive(true), .scheduleSpotCheck(after: spotDelay)]
            }
        }
        return out + [log("deepSleep", on ? "on" : "off", now)]
    }

    private func log(_ kind: String, _ detail: String, _ t: Date) -> Command { .log(LoggedEvent(t: t, kind: kind, detail: detail)) }
}
