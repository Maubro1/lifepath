import Core
import CoreLocation

/// Three managers, never sharing roles: recording (Moving/Settling and spot checks), keep-alive (ticks), safety (SLC + visits).
/// All managers are created on the main thread, so CoreLocation calls the delegate there.
@MainActor final class LocationService: NSObject, CLLocationManagerDelegate {
    private unowned let recorder: Recorder
    private let recording = CLLocationManager(), keepAlive = CLLocationManager(), safety = CLLocationManager()
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?
    private var monitor: Task<CLMonitor, Never>?
    private var gpsOn = false, keepAliveOn = false

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init()
        for m in [recording, keepAlive] {
            m.pausesLocationUpdatesAutomatically = false
            m.allowsBackgroundLocationUpdates = true
        }
        keepAlive.desiredAccuracy = 999
        keepAlive.distanceFilter = kCLDistanceFilterNone
        for m in [recording, keepAlive, safety] { m.delegate = self }
    }

    func start() {
        serviceSession = CLServiceSession(authorization: .always)
        safety.startMonitoringSignificantLocationChanges()
        safety.startMonitoringVisits()
        let monitor = Task { await CLMonitor("lifepath") }
        self.monitor = monitor
        Task {
            // A fence left from the last launch is kept: its exit may be what relaunched us. The engine starts in Moving,
            // which ignores a stale exit, and the next Still's arm replaces it.
            let m = await monitor.value
            do {
                for try await e in await m.events where e.identifier == "stop" && e.state == .unsatisfied {
                    recorder.send(.geofenceExit)
                }
            } catch {
                recorder.log("geofence", "monitor failed")
            }
        }
    }

    func requestWhenInUse() { safety.requestWhenInUseAuthorization() }
    func requestAlways() { safety.requestAlwaysAuthorization() }

    func configure(quality: Quality, spotCheck: Bool, distanceFilter: CLLocationDistance, automotive: Bool, showsIndicator: Bool) {
        // Spot checks ignore quality: km accuracy can never prove a departure.
        let byQuality = switch quality {
        case .saver: kCLLocationAccuracyKilometer
        case .balanced, .precise: kCLLocationAccuracyBest
        case .max: kCLLocationAccuracyBestForNavigation
        }
        let accuracy = spotCheck ? kCLLocationAccuracyBest : byQuality
        let type: CLActivityType = automotive ? .automotiveNavigation : .fitness
        // Called after every event: only touch what changed.
        if recording.desiredAccuracy != accuracy { recording.desiredAccuracy = accuracy }
        if recording.distanceFilter != distanceFilter { recording.distanceFilter = distanceFilter }
        if recording.activityType != type { recording.activityType = type }
        if recording.showsBackgroundLocationIndicator != showsIndicator { recording.showsBackgroundLocationIndicator = showsIndicator }
        if showsIndicator, backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        if !showsIndicator, let s = backgroundSession { s.invalidate(); backgroundSession = nil }
    }

    func setGPS(_ on: Bool) {
        gpsOn = on
        if on { recording.startUpdatingLocation() } else { recording.stopUpdatingLocation() }
    }

    func setKeepAlive(_ on: Bool) {
        keepAliveOn = on
        if on { keepAlive.startUpdatingLocation() } else { keepAlive.stopUpdatingLocation() }
    }

    func arm(_ f: Fence) {
        guard let monitor else { return }
        let condition = CLMonitor.CircularGeographicCondition(
            center: CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon), radius: f.radius)
        Task { await monitor.value.add(condition, identifier: "stop", assuming: .satisfied) }
    }

    /// Removing an absent condition is a no-op.
    func disarm() {
        guard let monitor else { return }
        Task { await monitor.value.remove("stop") }
    }

    private static func sample(_ l: CLLocation) -> Sample {
        Sample(t: l.timestamp, lat: l.coordinate.latitude, lon: l.coordinate.longitude,
               hAcc: l.horizontalAccuracy, speed: l.speed, course: l.course)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let id = ObjectIdentifier(manager)   // the manager itself is not Sendable
        MainActor.assumeIsolated {
            if id == ObjectIdentifier(recording) {
                for l in locations { recorder.recordingFix(Self.sample(l)) }
            } else if id == ObjectIdentifier(keepAlive) {
                recorder.send(.tick)   // location discarded
            } else if let l = locations.last {
                recorder.wakeFix(Self.sample(l), reason: "slc")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // Relaunch net only: the coordinate is a place left or reached minutes ago, not where the phone is now.
        MainActor.assumeIsolated { recorder.send(.tick) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let id = ObjectIdentifier(manager), status = manager.authorizationStatus
        let precise = manager.accuracyAuthorization == .fullAccuracy
        MainActor.assumeIsolated {
            guard id == ObjectIdentifier(safety) else { return }
            let a: Authorization = switch status {
            case .authorizedAlways: .always
            case .authorizedWhenInUse: .whenInUse
            case .notDetermined: .notDetermined
            default: .denied
            }
            recorder.authorizationChanged(a, precise: precise)
            guard serviceSession != nil, a == .always || a == .whenInUse else { return }   // nothing starts before start()
            // Starts issued before the grant may not have taken; re-issuing is harmless.
            if gpsOn { recording.startUpdatingLocation() }
            if keepAliveOn { keepAlive.startUpdatingLocation() }
            safety.startMonitoringSignificantLocationChanges()
            safety.startMonitoringVisits()
        }
    }
}
