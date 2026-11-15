import Core
import CoreLocation
import Diary
import Observation
import os
import UIKit

/// Thin glue: feeds CoreLocation/CoreMotion into the pure MotionEngine and TrackFilter, executes the commands, writes the Diary.
@MainActor @Observable final class Recorder {
    static let shared = Recorder()

    private(set) var state: MotionState = .moving
    /// Time of the last transition into Still; nil otherwise.
    private(set) var stillSince: Date?
    private(set) var lastPoint: Date?
    private(set) var lastCheckIn: Date?
    private(set) var authorization: Authorization = .notDetermined
    private(set) var preciseLocation = false
    /// Effective deep sleep: the manual setting or thermal (fair counts only off the charger)/low power/battery.
    private(set) var deepSleep = false

    @ObservationIgnored let settings = AppSettings()
    @ObservationIgnored private var location: LocationService!
    @ObservationIgnored private var motion: MotionService!
    @ObservationIgnored private var engine = MotionEngine(deepSleep: false)
    @ObservationIgnored private var filter = TrackFilter(quality: .balanced)
    @ObservationIgnored private var buffer = PointBuffer()
    @ObservationIgnored private var diary: Diary?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var recordingWanted = true   // the engine starts in Moving without a command
    @ObservationIgnored private var spotChecking = false
    @ObservationIgnored private var gpsOn = false
    @ObservationIgnored private var gpsSpot = false          // GPS is on for a spot check only
    @ObservationIgnored private var spotTimer: Timer?        // the only Timer in the app
    @ObservationIgnored private var lastActivity = Activity.unknown
    @ObservationIgnored private var lastStill: FilteredPoint?
    @ObservationIgnored private var deepSleepReason = ""
    @ObservationIgnored private var thermal: String?
    @ObservationIgnored private var lowPower: Bool?
    @ObservationIgnored private var charging: Bool?
    @ObservationIgnored private var flushFailedAt: Date?     // nil while writes succeed
    @ObservationIgnored private var lastWakeReason = ""

    private static let log = Logger(subsystem: "app.lifepath.LifePath", category: "recorder")
    private static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }()

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        location = LocationService(recorder: self)
        motion = MotionService(recorder: self)
    }

    /// Idempotent. Called from `LifePathApp.init` once onboarded (so every background relaunch re-arms everything),
    /// otherwise from the last onboarding page; nothing prompts before it.
    func start() {
        guard !started else { return }
        started = true
        let now = Date()
        openDiary()
        try? diary?.pruneEvents(olderThan: now.addingTimeInterval(-14 * 86400))
        let last = try? diary?.lastPoint()
        lastPoint = last?.t
        buffer.add(LoggedEvent(t: now, kind: "launch", detail: Self.version))
        buffer.add(LoggedEvent(t: now, kind: "state", detail: "moving"))   // the engine starts in Moving
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange,
                     UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification, UserDefaults.didChangeNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.refreshConditions() }
            }
        }
        location.start()
        location.setKeepAlive(true)
        motion.startActivity()
        refreshConditions()
        applyGPS()
        // Relaunched after a rest (swiped away, or a fence exit while suspended): backfill it up to the departure.
        if let p = last, p.kind == .still {
            lastStill = p
            lastWakeReason = "relaunch"
            execute(.resolveDeparture(stillSince: p.t), now)
        }
    }

    func requestWhenInUse() { location.requestWhenInUse() }
    func requestAlways() { location.requestAlways() }

    // MARK: Inputs from the services

    func send(_ e: MotionEvent) {
        let now = Date()
        lastCheckIn = now
        let before = engine.state
        let commands = engine.handle(e, at: now)
        // The wake log follows resolveDeparture in the same batch; take its reason before executing.
        for case .log(let l) in commands where l.kind == "wake" { lastWakeReason = l.detail }
        for c in commands { execute(c, now) }
        if engine.state != before {
            state = engine.state
            if state == .still { stillSince = now; motion.startSteps(from: now) }
            else if before == .still { stillSince = nil; motion.stopSteps() }
        }
        configureRecording()
        applyGPS()
        // Keep-alive off lets iOS suspend the app: write before that.
        if engine.state != before || buffer.isDue(at: now) || commands.contains(.setKeepAlive(false)) { flush() }
    }

    func recordingFix(_ s: Sample) {
        if spotChecking {
            guard wakeFix(s, reason: "spotcheck") else { return }
            if s.hAcc >= 0 && s.hAcc <= 50 { endSpotCheck() }
        } else if recordingWanted {
            guard let p = filter.process(s, receivedAt: Date(), activity: lastActivity) else { return send(.tick) }
            buffer.add(p, at: Date())
            lastPoint = p.t
            send(.fix(p))
        }
    }

    /// Spot-check and significant-change positions; a fix older than 10 s is dropped. Returns whether it was sent.
    @discardableResult func wakeFix(_ s: Sample, reason: String) -> Bool {
        guard Date().timeIntervalSince(s.t) <= 10 else { return false }
        send(.wakeFix(s, reason: reason))
        return true
    }

    /// Keep-alive positions confirm presence while Still; a stale one (> 10 s) is only a tick.
    func confirmFix(_ s: Sample) {
        send(Date().timeIntervalSince(s.t) <= 10 ? .confirmFix(s) : .tick)
    }

    func activityChanged(_ a: Activity, confident: Bool) {
        lastActivity = a
        send(.activity(a, confident: confident))
    }

    func authorizationChanged(_ a: Authorization, precise: Bool) {
        guard a != authorization || precise != preciseLocation else { return }
        authorization = a
        preciseLocation = precise
        buffer.add(LoggedEvent(t: Date(), kind: "permission", detail: precise ? a.rawValue : "\(a.rawValue) approximate"))
        flush()   // a downgrade can end background running
    }

    func log(_ kind: String, _ detail: String) { buffer.add(LoggedEvent(t: Date(), kind: kind, detail: detail)) }

    // MARK: Commands

    private func execute(_ c: Command, _ now: Date) {
        switch c {
        case .startRecording: recordingWanted = true; filter.reset()
        case .stopRecording: recordingWanted = false
        case .startSpotCheck:
            spotChecking = true
            setSpotTimer(20) { self.endSpotCheck() }
        case .stopSpotCheck: endSpotCheck()
        case .scheduleSpotCheck(let after): setSpotTimer(after) { self.send(.spotCheckDue) }
        case .setKeepAlive(let on): location.setKeepAlive(on)
        case .armGeofence(let f): location.arm(f)
        case .disarmGeofence: location.disarm()
        case .writeStillPoint(let p):
            buffer.add(p, at: now)
            lastPoint = p.t
            lastStill = p
        case .resolveDeparture(let since):
            guard let still = lastStill else { break }
            let fence = Fence(lat: still.lat, lon: still.lon, radius: still.hAcc)
            let reason = lastWakeReason
            Task {
                let departure = await motion.departure(stillSince: since, until: now)
                // Unknown departure after a position-based wake: the walked stretch stays a gap, not still points.
                if departure == nil, ["geofence", "slc", "relaunch", "spotcheck"].contains(reason) { return }
                for p in Backfill.stillPoints(fence: fence, from: still.t, to: departure ?? now) { buffer.add(p, at: Date()) }
            }
        case .fillUnconfirmed(let from, let to):
            guard let still = lastStill else { break }
            let fence = Fence(lat: still.lat, lon: still.lon, radius: still.hAcc)
            Task {
                // No motion permission, a step burst or moving activity in between: the stretch stays a gap.
                guard MotionService.available, await motion.departure(stillSince: from, until: to) == nil else {
                    return log("gap", "unconfirmed")
                }
                // The engine writes the point at `to` itself.
                for p in Backfill.stillPoints(fence: fence, from: from, to: to) where p.t < to { buffer.add(p, at: Date()) }
            }
        case .log(var e):
            if e.kind == "deepSleep", e.detail == "on" { e.detail = "on \(deepSleepReason)" }
            buffer.add(e)
        }
    }

    /// Replaces any pending spot-check timer.
    private func setSpotTimer(_ after: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) {
        spotTimer?.invalidate()
        spotTimer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { _ in MainActor.assumeIsolated { fire() } }
    }

    /// Every spot check, however it ends, is answered with `.spotCheckEnded`.
    private func endSpotCheck() {
        guard spotChecking else { return }
        spotChecking = false
        spotTimer?.invalidate()
        Task { self.send(.spotCheckEnded) }   // deferred: may be called while executing commands
    }

    private func applyGPS() {
        let on = recordingWanted || spotChecking
        if recordingWanted { gpsSpot = false }
        guard on != gpsOn else { return }
        gpsOn = on
        location.setGPS(on)
        if on && !recordingWanted { gpsSpot = true }
        buffer.add(LoggedEvent(t: Date(), kind: "gps", detail: (on ? "on" : "off") + (gpsSpot ? " spotcheck" : "")))
    }

    // MARK: Conditions

    private var quality: Quality {
        let p = ProcessInfo.processInfo
        return p.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue || p.isLowPowerModeEnabled
            ? settings.quality.lower : settings.quality
    }

    private func configureRecording() {
        let q = quality
        filter.quality = q
        // Settling and spot checks need every fix; spacing applies only while Moving.
        location.configure(quality: q, spotCheck: spotChecking,
                           distanceFilter: state == .moving && !spotChecking ? q.spacing : kCLDistanceFilterNone,
                           automotive: lastActivity == .automotive, showsIndicator: settings.showsIndicator)
    }

    private func refreshConditions() {
        let now = Date(), p = ProcessInfo.processInfo
        let t = p.thermalState, low = p.isLowPowerModeEnabled
        let name = switch t {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        default: "critical"
        }
        if name != thermal { thermal = name; buffer.add(LoggedEvent(t: now, kind: "thermal", detail: name)) }
        if low != lowPower { lowPower = low; buffer.add(LoggedEvent(t: now, kind: "lowPower", detail: low ? "on" : "off")) }
        let state = UIDevice.current.batteryState
        let onCharge = state == .charging || state == .full
        if onCharge != charging { charging = onCharge; buffer.add(LoggedEvent(t: now, kind: "charging", detail: onCharge ? "on" : "off")) }
        let battery = UIDevice.current.batteryLevel   // -1 when unknown
        let reason: String? = settings.deepSleep ? "manual"
            : t.rawValue >= ProcessInfo.ThermalState.serious.rawValue || (t == .fair && !onCharge) ? "thermal"
            : low ? "lowPower"
            : battery >= 0 && battery < 0.2 ? "battery" : nil
        deepSleepReason = reason ?? ""
        if (reason != nil) != deepSleep {
            deepSleep = reason != nil
            send(.deepSleepChanged(deepSleep))   // the engine's "deepSleep on" log gets the reason in execute
        } else {
            configureRecording()
        }
    }

    // MARK: Diary

    /// The open diary (nil before first unlock) for the map and the smoothing service (which writes only the derived cache).
    var readDiary: Diary? { diary }

    private func openDiary() {
        do { diary = try Diary(path: Diary.defaultPath()) } catch {
            Self.log.error("diary open failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func flush() {
        if let f = flushFailedAt, Date().timeIntervalSince(f) < 30 { return }   // after a failure, retry at most every 30 s
        if diary == nil { openDiary() }   // before first unlock the protected file can't open yet
        let drops = filter.takeDropCounts()
        if !drops.isEmpty {
            buffer.add(LoggedEvent(t: Date(), kind: "drops", detail: drops.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")))
        }
        let (points, events) = buffer.take()
        guard !points.isEmpty || !events.isEmpty else { return }
        do {
            guard let diary else { throw CocoaError(.fileNoSuchFile) }
            try diary.append(points)
            try diary.log(events)
            flushFailedAt = nil
        } catch {
            buffer.putBack(points: points, events: events)
            if flushFailedAt == nil { buffer.add(LoggedEvent(t: Date(), kind: "flush", detail: "failed")) }
            flushFailedAt = Date()
        }
    }

    /// Points stored for the local day so far; read on demand, only while the screen is visible.
    func pointsToday() -> Int {
        flush()
        let now = Date()
        return (try? diary?.points(from: Calendar.current.startOfDay(for: now), to: now).count) ?? 0
    }

    func healthReport() -> String {
        flush()
        let now = Date(), from = now.addingTimeInterval(-3 * 86400)
        let info: [String: String] = [
            "version": Self.version, "quality": settings.quality.rawValue, "effectiveQuality": quality.rawValue,
            "showsIndicator": "\(settings.showsIndicator)", "deepSleep": deepSleep ? "on \(deepSleepReason)" : "off",
            "authorization": authorization.rawValue, "preciseLocation": "\(preciseLocation)",
            "motion": "\(MotionService.available)", "state": state.rawValue,
        ]
        return HealthReport.render(HealthInput(now: now, events: (try? diary?.events(from: from, to: now)) ?? [],
                                               points: (try? diary?.points(from: from, to: now)) ?? [], settings: info))
    }
}
