# Stage 1: Recorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** LifePath records all day in the background on the owner's iPhone: GPS only while moving, cheap rest while still, cleaned points saved to the diary, a status box, a health report, and plain onboarding.

**Architecture:** All decisions live in pure `Core` (filter, motion state machine, backfill, status, health report, buffer), tested on CI. A `Diary` package wraps GRDB. The app layer is thin glue: three `CLLocationManager`s, CoreMotion, and a `Recorder` that feeds events into `MotionEngine` and executes the commands it returns.

**Tech Stack:** Swift 6.2, SwiftUI, iOS 26, CoreLocation, CoreMotion, GRDB 7, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-11-14-lifepath-design.md` (sections "Recording engine", "Battery rules", "Filtering and smoothing", "Diary", "Health report", "Signing expiry reminder", "Where LifePath aims past existing apps")

## Global Constraints

- Core imports Foundation only. Diary imports Foundation, GRDB, Core. Only third-party dependency: GRDB (`from: "7.1.0"`).
- Package manifests `swift-tools-version: 6.2`, platforms `.iOS(.v26), .macOS(.v15)`.
- Bundle ID `app.lifepath.LifePath` unchanged. `MARKETING_VERSION` 0.1.0, build 3 at release.
- Any doubt resolves to Moving, except the indoor no-fix fallback below (endless GPS indoors is the drain this app exists to avoid).
- Battery rules: GPS off while Still except spot checks; no rendering in background; points buffered, written in one transaction every ≥30 s or on state change; only timer is the spot-check timer; no network; events logged only on decisions, never per fix.
- Stored points are never modified after writing.
- Repo is public: test fixtures are synthetic only.
- No local Swift toolchain: RED and GREEN are observed on CI. Push the failing-test commit, read the annotation, then push the implementation.

## Review Focus

1. Background relaunch before first unlock after a reboot: the diary file is unreadable → points stay buffered, write retried later, no crash, nothing lost. (Task 5 `testFailedFlushKeepsPoints`; Task 6 file protection)
2. Location permission downgraded to While Using or off mid-day → status shows a problem with a hint, event logged, no crash loop. (Task 4 `testDowngradedPermissionIsProblem`)
3. Late or out-of-order fixes (iOS delivering a batch after wake) → older-than-last samples dropped, duplicates impossible. (Task 2 `testOutOfOrderDropped`; Task 5 `testDuplicateTimestampIgnored`)
4. Motion & Fitness permission denied → stops still detected from fixes, departures caught by spot checks. (Task 3 `testNoMotionStillStopsAndWakes`)
5. Arriving indoors where GPS gives no usable fixes → Still within 5 minutes, not GPS on forever. (Task 3 `testIndoorNoFixFallsToStill`)

---

### Task 1: Core value types and geometry

**Files:**
- Create: `Core/Sources/Core/Types.swift`, `Core/Sources/Core/Geo.swift`
- Test: `Core/Tests/CoreTests/GeoTests.swift`, `Core/Tests/CoreTests/Synthetic.swift` (test helper)

**Interfaces (Produces):**
```swift
public struct Sample: Sendable, Equatable { public var t: Date; public var lat, lon, hAcc, speed, course: Double }   // speed/course < 0 = invalid, as CoreLocation
public enum Activity: String, Sendable, Codable { case stationary, walking, running, cycling, automotive, unknown
    public var isVehicle: Bool { self == .cycling || self == .automotive } }
public enum PointKind: String, Sendable, Codable { case moving, still }
public struct FilteredPoint: Sendable, Equatable, Codable { public var t: Date; public var lat, lon, rawLat, rawLon, hAcc, speed: Double; public var kind: PointKind }
public struct LoggedEvent: Sendable, Equatable, Codable { public var t: Date; public var kind: String; public var detail: String }
public enum Quality: String, CaseIterable, Sendable, Codable { case saver, balanced, precise, max
    public var accuracyCeiling: Double   // 2000, 65, 50, 30 (m)
    public var spacing: Double           // 100, 10, 5, 2 (m)
    public var lower: Quality }          // max→precise→balanced→saver→saver
public enum Geo {
    public static func distance(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double   // haversine, R = 6_371_008.8 m
    public static func offset(lat: Double, lon: Double, north: Double, east: Double) -> (lat: Double, lon: Double) }
```

`Synthetic.swift` (tests only): seeded generator (`struct SeededRandom: RandomNumberGenerator`, SplitMix64) and `func walk(path: [(north: Double, east: Double)], speed: Double, every: TimeInterval, noise: Double, seed: UInt64, start: Date) -> (truth: [(Date, Double, Double)], samples: [Sample])` around origin 52.37, 4.90. Gaussian noise via Box–Muller, `hAcc` = noise × 1.5.

- [ ] **Step 1: Failing tests** — `testDistanceKnownPair` (Amsterdam Centraal 52.3791,4.9003 → Dam 52.3731,4.8926 ≈ 832 m ± 5), `testOffsetRoundTrip` (offset 100 m north, 50 m east → distance 111.8 ± 0.5), `testQualityLowerChain` (`max.lower == .precise`, `saver.lower == .saver`).
- [ ] **Step 2: Push, observe RED on CI.**
- [ ] **Step 3: Implement.** Push, observe GREEN. Commit `Core: value types and geometry`.

### Task 2: TrackFilter

**Files:** Create `Core/Sources/Core/TrackFilter.swift`; Test `Core/Tests/CoreTests/TrackFilterTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `public struct TrackFilter { public init(quality: Quality); public var quality: Quality; public mutating func process(_ s: Sample, receivedAt: Date, activity: Activity) -> FilteredPoint?; public mutating func reset() }`

Rules (spec values):
1. Drop if `hAcc < 0`, `hAcc > quality.accuracyCeiling`, `receivedAt − t > 10 s`, `t > receivedAt + 2 s`, or `t <= last accepted t`.
2. Drop teleport: (distance to last accepted raw − s.hAcc − last.hAcc) / Δt > 60 m/s.
3. Kalman per axis in metres relative to the first accepted sample, no velocity term: `P += Δt · q²`; `k = P / (P + hAcc²)`; `x += k (z − x)`; `P = (1 − k) P`. q = 4 m/s for stationary/walking/running/unknown, 8 cycling, 15 automotive.
4. Output = accuracy-weighted mean (weights 1/hAcc²) of the last 3 Kalman outputs. `kind = .moving`. `rawLat/rawLon` = sample.

- [ ] **Step 1: Failing tests**
  - `testDropsNegativeAndCeilingAccuracy`, `testDropsStaleAndFuture` (11 s old; 3 s ahead), `testOutOfOrderDropped`, `testTeleportDropped` (1 km in 1 s, hAcc 10).
  - `testWalkMedianErrorAtMost8m`: `walk` around a 400 m × 300 m block at 1.4 m/s, 1 s fixes, noise σ 12 m, seed 7; median distance from output to truth ≤ 8.
  - `testCornerNotCutMoreThan10m`: same walk; at each corner, min distance from outputs to the corner point ≤ 10.
- [ ] **Step 2: Push, RED.** **Step 3: Implement, push, GREEN.** Commit `Core: track filter`.

### Task 3: MotionEngine, backfill and departure time

**Files:** Create `Core/Sources/Core/MotionEngine.swift`, `Core/Sources/Core/Backfill.swift`; Test `Core/Tests/CoreTests/MotionEngineTests.swift`, `BackfillTests.swift`

**Interfaces (Produces):**
```swift
public enum MotionState: String, Sendable { case moving, settling, still }
public struct Fence: Sendable, Equatable { public var lat, lon, radius: Double }
public enum MotionEvent: Sendable {
    case fix(FilteredPoint)                 // recording manager, after filter
    case tick                               // keep-alive update or any wake; drives time-based rules
    case steps(Int)                         // cumulative since Still began
    case activity(Activity, confident: Bool)
    case wakeFix(Sample, reason: String)    // spot check, significant change, visit
    case geofenceExit
    case spotCheckDue, spotCheckEnded }
public enum Command: Sendable, Equatable {
    case startRecording, stopRecording
    case startSpotCheck, stopSpotCheck, scheduleSpotCheck(after: TimeInterval)
    case setKeepAlive(Bool)                 // false only in deep sleep
    case armGeofence(Fence), disarmGeofence
    case writeStillPoint(FilteredPoint)
    case resolveDeparture(stillSince: Date) // app queries CoreMotion history, then backfills
    case log(LoggedEvent) }
public struct MotionEngine {
    public init(motionAvailable: Bool, deepSleep: Bool)
    public var deepSleep: Bool
    public private(set) var state: MotionState      // starts .moving
    public private(set) var fence: Fence?
    public mutating func handle(_ e: MotionEvent, at now: Date) -> [Command] }
public enum Backfill {
    public static func stillPoints(fence: Fence, from: Date, to: Date, every: TimeInterval = 300) -> [FilteredPoint]   // exclusive of `from`, kind .still, hAcc = radius
    public static func departure(stillSince: Date, activities: [(Date, Activity)], stepTimes: [Date]) -> Date? }       // earliest of: first non-stationary confident activity, first step burst (≥15 steps within 60 s, timestamp of its first step)
```

Rules (spec values; record any refinement as a ruling):
- **Moving → Settling** on every `.fix`: keep fixes of the last 6 min. Fence centre = accuracy-weighted mean of fixes in the last 2 min; radius = clamp(mean hAcc, 20, 100). Settling when the current fix is inside the fence.
- **Settling → Still** when all fixes for the last 2 min (+4 min if a vehicle activity or speed > 7 m/s was seen in the last 10 min) are within the fence. Commands: `stopRecording`, `armGeofence(fence(radius: 200))`, `scheduleSpotCheck(after: 30)` (unless deep sleep → `setKeepAlive(false)`), `writeStillPoint`, log `state still`.
- **Settling → Moving** on a fix outside the fence.
- **Indoor fallback:** in Moving/Settling, if no accepted `.fix` for 5 min on `.tick` (with motion available: also no confident moving activity and no steps in that time) → Still at the last fence or last fix.
- **Still wakes (→ Moving, `startRecording`, `disarmGeofence`, `setKeepAlive(true)`, `resolveDeparture`, log `wake <reason>`):** `.steps(n ≥ 15)`; confident walking/running/cycling/automotive; `.wakeFix` with distance − hAcc > fence radius; `.geofenceExit`.
- **Spot checks:** `.spotCheckDue` → `startSpotCheck`; `.spotCheckEnded` → `stopSpotCheck`, `scheduleSpotCheck(after: next)` with next = 30, 60, 120, 240, 300, 300…; reset to 30 on each Still entry.
- **Still points:** on `.tick` or `.spotCheckEnded` while Still, `writeStillPoint` when ≥ 300 s since the last one.
- **Per-place drift (spec "learned drift"):** deferred. Stage 1 relies on subtracting `hAcc` before comparing with the fence radius; learned per-place tolerance is added only if health reports show false night-time wakes (each becomes a fixture first).

- [ ] **Step 1: Failing tests**
  - `testStopsAfterTwoMinutesWalking` (walk then 3 min of fixes within 10 m → Still at ≈ 2 min after arrival).
  - `testRedLightNotStop` (automotive 15 m/s, 90 s stop, drive on → never Still).
  - `testStopAfterDriveNeedsSixMinutes`.
  - `testSofaNoTrip` (Still; 1 h of `.tick`, `.wakeFix` with ±30 m noise hAcc 40 inside 200 m fence, steps ≤ 10 → stays Still).
  - `testFifteenStepsWakes`, `testConfidentWalkingWakes`, `testUnconfidentActivityIgnored`, `testWakeFixOutsideFenceWakes`, `testGeofenceExitWakes`.
  - `testSpotCheckBackoff` (30, 60, 120, 240, 300, 300).
  - `testStillPointEveryFiveMinutes`.
  - `testIndoorNoFixFallsToStill` (fixes stop after arrival; ticks every 30 s → Still by 5 min).
  - `testNoMotionStillStopsAndWakes` (`motionAvailable: false`: stops from fixes; wakes on a spot-check `.wakeFix` 300 m away).
  - `testDeepSleepDisablesKeepAliveAndSpotChecks`.
  - Backfill: `testStillPointsEveryFiveMinutes` (from 10:00 to 10:17 → 10:05, 10:10, 10:15), `testDepartureFromActivity`, `testDepartureFromStepBurst`, `testDepartureNilWithoutEvidence`.
- [ ] **Step 2: Push, RED.** **Step 3: Implement, push, GREEN.** Commit `Core: motion engine and backfill`.

### Task 4: Status and health report

**Files:** Create `Core/Sources/Core/TrackingStatus.swift`, `Core/Sources/Core/HealthReport.swift`; Test `TrackingStatusTests.swift`, `HealthReportTests.swift`

**Interfaces (Produces):**
```swift
public enum Authorization: String, Sendable { case always, whenInUse, denied, notDetermined }
public struct TrackingStatus: Sendable, Equatable { public enum Level: String, Sendable { case healthy, resting, problem }
    public var level: Level; public var headline: String; public var hint: String?
    public static func evaluate(authorization: Authorization, preciseLocation: Bool, state: MotionState, lastPoint: Date?, lastCheckIn: Date?, signingExpiry: Date?, now: Date) -> TrackingStatus }
public struct HealthInput: Sendable { public var now: Date; public var events: [LoggedEvent]; public var points: [FilteredPoint]; public var settings: [String: String] }
public enum HealthReport { public static func render(_ input: HealthInput, days: Int = 3) -> String }
```

Status rules: authorization ≠ always → problem ("Location access isn't set to Always", hint "Settings → LifePath → Location → Always"); precise off → problem; last check-in > 60 min ago → problem (hint about swiping away); signing expiry < 24 h → problem; state still → resting ("Resting: you've been still since HH:mm"); else healthy.

Health report sections, in order: header (generated time, version from settings); settings and permissions (`settings` dict, one per line); per day: GPS-on hours, wakes by reason, points moving/still; per hour (24 rows per day): % resting, wakes, points; accuracy histogram of moving points (<5, 5–10, 10–20, 20–50, ≥50 m); gaps > 15 min between consecutive points with the last event before each; thermal and low-power events; the last 200 events verbatim. Event kinds used everywhere: `state`, `wake`, `gps` (on/off), `thermal`, `lowPower`, `permission`, `flush`, `launch`.

- [ ] **Step 1: Failing tests** — `testDowngradedPermissionIsProblem`, `testStillIsResting`, `testStaleCheckInIsProblem`, `testSigningExpirySoonIsProblem`; `testReportListsGapWithLastEvent`, `testReportRestingPercentPerHour` (still from 10:00 to 10:30 → hour 10 row "50%"), `testReportAccuracyHistogram`, `testReportGpsOnHours`.
- [ ] **Step 2: Push, RED.** **Step 3: Implement, push, GREEN.** Commit `Core: tracking status and health report`.

### Task 5: Diary package and point buffer

**Files:**
- Create: `Diary/Package.swift` (deps: `../Core`, GRDB `from: "7.1.0"`), `Diary/Sources/Diary/Diary.swift`, `Core/Sources/Core/PointBuffer.swift`
- Test: `Diary/Tests/DiaryTests/DiaryTests.swift`, `Core/Tests/CoreTests/PointBufferTests.swift`
- Modify: `.github/workflows/ci.yml` (test job: also `swift test --package-path Diary` with the same annotation wrapper)

**Interfaces (Produces):**
```swift
public final class Diary: Sendable {
    public init(path: String) throws                     // DatabasePool (WAL), runs migrations
    public static func defaultPath() throws -> String    // Application Support/diary.sqlite; directory created with FileProtectionType.completeUntilFirstUserAuthentication
    public func append(_ points: [FilteredPoint]) throws // INSERT OR IGNORE on t
    public func log(_ events: [LoggedEvent]) throws
    public func lastPoint() throws -> FilteredPoint?
    public func points(from: Date, to: Date) throws -> [FilteredPoint]
    public func events(from: Date, to: Date) throws -> [LoggedEvent]
    public func pruneEvents(olderThan: Date) throws }
public struct PointBuffer: Sendable {
    public init()
    public mutating func add(_ p: FilteredPoint, at now: Date); public mutating func add(_ e: LoggedEvent)
    public func isDue(at now: Date) -> Bool               // oldest pending item ≥ 30 s old
    public mutating func take() -> (points: [FilteredPoint], events: [LoggedEvent])
    public mutating func putBack(points: [FilteredPoint], events: [LoggedEvent]) }   // keeps order, after a failed write
```

Migration `v1`: `point(t REAL PRIMARY KEY, lat, lon, rawLat, rawLon, hAcc, speed, kind TEXT)`; `event(id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL, kind TEXT, detail TEXT)` + index on `event.t`. (Later tables arrive with their stages.)

- [ ] **Step 1: Failing tests** — Diary on a temp file: `testAppendAndReadBack`, `testDuplicateTimestampIgnored`, `testLastPoint`, `testPruneEvents`, `testReopenKeepsData`. Buffer: `testDueAfterThirtySeconds`, `testFailedFlushKeepsPoints` (take, putBack, take again returns same items in order).
- [ ] **Step 2: Push, RED.** **Step 3: Implement, push, GREEN.** Commit `Diary: GRDB store; Core: point buffer`.

### Task 6: Recorder (app glue)

**Files:**
- Create: `LifePath/Recorder/LocationService.swift`, `LifePath/Recorder/MotionService.swift`, `LifePath/Recorder/Recorder.swift`, `LifePath/Recorder/AppSettings.swift`
- Modify: `project.yml` (package `Diary: { path: Diary }`, target dependency `- package: Diary`)

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: `@MainActor @Observable final class Recorder { static let shared; func start(); var state: MotionState; var lastPoint: Date?; var lastCheckIn: Date?; var authorization: Authorization; var preciseLocation: Bool; func requestWhenInUse(); func requestAlways(); func healthReport() -> String }`
- `AppSettings`: `@AppStorage`-backed `quality: Quality` (default `.balanced`), `showsIndicator: Bool` (default true), `deepSleep: Bool` (default false), `onboarded: Bool`.

Decisions:
- `Recorder.shared.start()` is called from `LifePathApp.init`, so background relaunches (CLMonitor, visits, significant change, service session) re-arm everything at launch.
- **LocationService** owns three managers, never sharing roles:
  - recording: `desiredAccuracy` saver `kCLLocationAccuracyKilometer`, balanced/precise `kCLLocationAccuracyBest`, max `kCLLocationAccuracyBestForNavigation`; `distanceFilter = quality.spacing`; `activityType` `.automotiveNavigation` if last activity automotive else `.fitness`; `pausesLocationUpdatesAutomatically = false`; `allowsBackgroundLocationUpdates = true`; `showsBackgroundLocationIndicator = settings.showsIndicator`. Used for Moving/Settling and spot checks (spot-check fixes go to `.wakeFix(reason: "spotcheck")`, not the filter). A spot check ends (`.spotCheckEnded`) at the first fix with `hAcc ≤ 50` or after 20 s, whichever comes first; the spot-check timer is the only `Timer`.
  - keep-alive: `desiredAccuracy = 999`, `distanceFilter = kCLDistanceFilterNone`, background on, pausing off; every update → `.tick`, location discarded.
  - safety: `startMonitoringSignificantLocationChanges()` + `startMonitoringVisits()`; updates → `.wakeFix(reason: "slc"/"visit")`.
  - Holds `CLServiceSession(authorization: .always)` from launch; holds `CLBackgroundActivitySession()` while `showsIndicator`.
  - `CLMonitor("lifepath")` with one `CircularGeographicCondition` id `"stop"`; iterate `events` in a task; `.unsatisfied` → `.geofenceExit`.
- **MotionService:** `CMPedometer.startUpdates(from: stillSince)` → `.steps`; `CMMotionActivityManager.startActivityUpdates` → `.activity(confident: confidence != .low)`; history queries for `resolveDeparture` → `Backfill.departure`. Absent permission → engine `motionAvailable: false`.
- **Recorder** executes commands; on `resolveDeparture` writes `Backfill.stillPoints(fence, from: lastStillPoint, to: departure ?? now)`. Thermal ≥ `.serious` or Low Power Mode → filter and recording use `quality.lower`; logs `thermal`/`lowPower`. Flushes `PointBuffer` when due on each event, on every state change and on `scenePhase` background; a failed write → `putBack` and log `flush failed`. `lastCheckIn` = time of the last event of any kind. Events pruned at 14 days once per launch. `Logger` (os) for debug only, no per-fix logging.
- `NSLocationAlwaysAndWhenInUseUsageDescription` etc. already exist; no new Info.plist keys.

- [ ] **Step 1:** Implement; push; CI build green (no unit tests: hardware glue; logic is in Core).
- [ ] **Step 2:** Commit `App: recorder with location and motion services`.

### Task 7: Onboarding, status screen, health report export, signing reminder

**Files:**
- Create: `LifePath/Features/Onboarding/OnboardingView.swift`, `LifePath/Features/Settings/SettingsView.swift`, `LifePath/Features/Settings/SigningReminder.swift`
- Modify: `LifePath/LifePathApp.swift` (root: `OnboardingView` until `onboarded`, then `SettingsView`); delete `LifePath/PipelineView.swift` and the launch counter.

Decisions:
- **Onboarding** pages (plain SwiftUI, copy restyled at the design stage): 1 what LifePath does (private, on-device); 2 "Allow While Using" → `requestWhenInUse()`; 3 "Allow Always" → `requestAlways()`; 4 please don't swipe LifePath away in the app switcher (it stops recording); 5 optional Motion & Fitness (start `CMMotionActivityManager` query to trigger the prompt) plus notification permission for the weekly signing reminder; 6 Start → `onboarded = true`.
- **SettingsView:** status box from `TrackingStatus.evaluate` (level colour, headline, hint, last point, last check-in, signing expiry, today's point count); Quality picker; "Show blue location bar" toggle; "Deep sleep" toggle with one-line explanation; "Create health report" → `.fileExporter` of `LifePath-health-YYYY-MM-DD.txt`; version line. Pull to refresh re-reads diary values.
- **SigningReminder:** on each foreground, reads expiry via `ProvisioningProfile.expirationDate`, replaces the pending notification `signing-expiry` at expiry − 24 h ("LifePath needs a refresh: open SideStore and tap Refresh All").

- [ ] **Step 1:** Implement; push; CI green.
- [ ] **Step 2:** Bump `MARKETING_VERSION` 0.1.0, build 3; commit `App: onboarding, status, health report, signing reminder`; tag `v0.1.0`.

### Task 8: Real-world check (owner, several days)

- [ ] **Step 1:** Owner installs v0.1.0 over 0.0.2, completes onboarding (Always, Motion, Notifications).
- [ ] **Step 2:** Two ordinary days, including one walk. Owner exports the health report each evening and sends it.
- [ ] **Step 3:** Pass bars: no gap > 15 min without a stated reason; trip start within 30 s of first step in the log; < 15 spot checks per hour of rest; battery per iOS Settings → Battery for LifePath reported alongside. Failures → superpowers:systematic-debugging, a new synthetic fixture reproducing the case, fix, new release.
