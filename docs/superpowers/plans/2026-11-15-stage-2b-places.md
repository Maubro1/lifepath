# Stage 2b: Learned Places Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** LifePath learns the places where the owner spends time as irregular shapes that follow their life, shows them as pins on the map, and rests smarter there (no pottering scribbles, fewer spot checks, a calm dot).

**Architecture:** Pure Core: a time-density grid per place (5 m cells, accuracy-sized kernel, 60-day half-life), visit detection, learning and merging, membership tests, density-peak pin. Diary v4 stores places, cells and visits. A learning service (open or charging only, alongside smoothing) folds new rests into places. The motion engine receives the current place's shape while resting. The map shows pins and outlines; pins can be renamed.

**Spec:** `docs/superpowers/specs/2026-11-14-lifepath-design.md` — "Principles", "Places (learned automatically)", "Ways of moving".

## Global Constraints

- Principles bind every choice: life-long (no place or visit ever hidden; old places fade in weight, never get deleted from the diary), honest (a place shape comes only from recorded still time), precise, private (no network: unnamed places show "Place near <lat, lon rounded>" until stage 3 brings street names), cool and light (learning only while open or charging; O(cells touched) per rest).
- Places never switch departure detection off: fixes clearly outside the shape, the 200 m geofence and vehicle motion still wake LifePath.
- Stored points never modified; places/cells/visits are derived and recomputable from stored points.
- Ponytail; Core imports Foundation only; Diary imports GRDB + Core.
- Release: version 0.3.0 build 7, tag `v0.3.0-preview.1`.

## Review Focus

1. A first visit somewhere new must not be treated as a known place (candidates need visits on 3 different days).
2. Leaving a known place must be caught as fast as before (fix outside the shape allowing for accuracy, geofence, vehicle motion).
3. Two different places 60 m apart (neighbour's house, shop across the street) must stay separate; one place with a garden must stay one place.
4. The shape and pin must follow a change (moved desk, new home) within weeks through decay, and an old home must fade, not vanish.
5. Learning must be idempotent: re-processing the same rests changes nothing.

---

### Task 1: Place grid and learner (Core)

**Files:** Create `Core/Sources/Core/PlaceGrid.swift`, `Core/Sources/Core/Places.swift`; Test `PlaceGridTests.swift`, `PlacesTests.swift`

**Interfaces (Produces):**
```swift
public struct PlaceCell: Sendable, Hashable, Codable { public var x: Int; public var y: Int }          // 5 m cells in a local equal-area metre grid (lat → y·5 m, lon scaled by cos(52°) — shortcut comment)
public struct Place: Sendable, Equatable, Codable {
    public var id: Int64; public var name: String?
    public var cells: [PlaceCell: Double]                // decayed weight (seconds·confidence)
    public var updatedAt: Date; public var totalSeconds: Double; public var visits: Int; public var isCandidate: Bool
    public var pin: (lat: Double, lon: Double)            // density peak (computed)
    public func region(share: Double = 0.9) -> Set<PlaceCell>   // smallest cell set holding `share` of weight, one-cell holes filled
    public func contains(lat: Double, lon: Double, hAcc: Double) -> Bool }   // cell of the point, widened by hAcc, intersects region
public struct Visit: Sendable, Equatable, Codable { public var start: Date; public var end: Date; public var placeId: Int64? }
public enum Places {
    public static func visits(from points: [FilteredPoint], minDuration: TimeInterval = 600) -> [(start: Date, end: Date, points: [FilteredPoint])]   // runs of still points ≥ 10 min (plus the settling fixes just before them within the still hAcc)
    public static func learn(_ places: [Place], visit: (start: Date, end: Date, points: [FilteredPoint]), now: Date, nextId: Int64) -> (places: [Place], visit: Visit)
    // learn: decay all weights by 0.5^(Δt/60 days) since updatedAt; splat each point's duration (time to next point, capped 300 s) into cells with a Gaussian kernel of σ = max(hAcc, 5 m) truncated at 2σ, weight 1/max(hAcc,5)²; join the place whose region widened by 20 m contains the majority of the visit's points, else create a candidate; candidate → place when it has visits on ≥ 3 distinct local calendar days (track `visitDays: Set<Int>` of day numbers, kept to the last 60 days); merge places whose regions touch; pin = cell with the highest 3×3-smoothed weight, ties broken by weight added in the last 30 days.
}
```
- [ ] Failing tests: `testCellSizeIs5m`, `testRegionHolds90PercentAndFillsHoles`, `testPinIsDensityPeakNotMean` (L-shaped region: pin inside the L, mean outside), `testContainsAllowsAccuracy`, `testFirstVisitIsCandidate`, `testThreeDaysPromote`, `testOneLongStayStaysCandidate` (6 h on one day → still a candidate), `testThreeVisitsSameDayStaysCandidate`, `testNeighbourSixtyMetresStaysSeparate`, `testGardenJoinsHouse`, `testDecayFollowsMove` (8 weeks at desk A then 8 weeks at desk B → pin at B), `testOldHomeFadesNotDeleted`, `testLearnIsIdempotentPerVisit` (same visit twice via a processed-until guard in the caller is fine; document), `testVisitsNeedTenMinutes`. RED → GREEN; commit `Core: learned places`.

### Task 1b: Pin rules (Core)

**Files:** Modify `Core/Sources/Core/Places.swift`, `PlacesTests.swift`
- `Place.points: Double` = 4 · visitDays.count + totalSeconds / 3600 (computed). Promotion: `isCandidate = points < 100`, re-evaluated after every joined visit and after a merge (replace the 5-days/7-apart rule).
- `Place.recentDurations: [Double]` (last 20 visit durations, seconds) and `Place.lastRealVisit: Date` (updated when a visit lasts ≥ 5 h or ≥ 0.5 × median(recentDurations before this visit); the first visit counts as real if ≥ 5 h).
- `Place.isVisible(at now: Date) -> Bool` = !isCandidate && now − lastRealVisit ≤ 182 days.
- [ ] Tests: `testHomeBecomesPinInAboutSixDays` (14 h/day), `testSchoolTwoWeeks` (6 h × 10 days), `testOneLongStayNeverPins` (10 h once), `testBenchNeverPins`, `testHiddenAfterSixMonthsWithoutRealVisit`, `testOneRealVisitBringsItBack`, `testShortGymVisitsKeepGymVisible` (1.5 h visits weekly keep it visible), `testShortDropInDoesNotCount` (10 min at home after 7 months away → still hidden), `testMergeReevaluatesPoints`. Remove the 5-days tests. RED → GREEN; commit.

### Task 2: Diary v4

**Files:** Modify `Diary/Sources/Diary/Diary.swift`, tests. Migration `v4` (additive): `place(id INTEGER PRIMARY KEY, name TEXT, updatedAt REAL, totalSeconds REAL, visits INTEGER, isCandidate INTEGER, pinLat REAL, pinLon REAL)`, `placeCell(placeId INTEGER, x INTEGER, y INTEGER, weight REAL, PRIMARY KEY(placeId, x, y))`, `visit(start REAL PRIMARY KEY, end REAL, placeId INTEGER)`, `meta(key TEXT PRIMARY KEY, value TEXT)`.
```swift
public func places() throws -> [Place]                       // with cells
public func savePlaces(_ places: [Place], removing ids: [Int64]) throws   // one transaction; removing = merged-away ids only (their cells move to the survivor)
public func saveVisits(_ visits: [Visit]) throws               // INSERT OR REPLACE on start
public func visits(from: Date, to: Date) throws -> [Visit]
public func renamePlace(_ id: Int64, to name: String?) throws
public func meta(_ key: String) throws -> String?;  public func setMeta(_ key: String, _ value: String) throws
```
- [ ] Tests (CI): round trip with cells, merge removal keeps the survivor's cells, rename, v3→v4 upgrade keeps points/smoothed/tripLine rows. Commit `Diary: places (v4)`.

### Task 3: Learning service (app)

**Files:** Create `LifePath/Places/PlaceService.swift`; Modify `LifePath/Map/SmoothingService.swift` (call it at the end of each run). Reads points since `meta("placesProcessedUntil")` (minus 1 h overlap, skipping visits already stored by start), `Places.visits`, folds each finished visit with `Places.learn`, saves places and visits, advances the meta key to the end of the last finished visit. Same cancellation and open-or-charging rules as smoothing. Posts a `placesChanged` notification. CI build green; commit.

### Task 4: Resting at a known place (engine)

**Files:** Modify `Core/Sources/Core/MotionEngine.swift`, `LifePath/Recorder/Recorder.swift`; Test `MotionEngineTests.swift`
- Known places for the engine = visible pins only (`isVisible(at:)`). Engine gains `case enteredPlace(PlaceShape?)` where `public struct PlaceShape: Sendable, Equatable { public var region: Set<PlaceCell>; public var pin: (lat: Double, lon: Double) }` (built from `Place`, non-candidates only).
- While Settling/Still with a known place: the Still fence test uses `shape.contains` (accuracy-aware) instead of the circle; still points use the pin; the steps-wake threshold starts at 50; a steps wake returns to Still after 60 s when fixes stay inside the shape; after 30 min Still at a known place the spot-check cap rises from 300 to 900 s. A fix outside the shape (allowing accuracy), the geofence or vehicle motion wakes as before.
- Recorder: on entering Settling and at launch while Still, finds the known place whose shape contains the fence centre (from the places the PlaceService last loaded, kept in memory) and sends `.enteredPlace`.
- [ ] Failing tests: `testKnownPlaceUsesShapeNotCircle`, `testStillPointAtPin`, `testPotteringAtPlaceNeedsFiftySteps`, `testSpotCheckCapRisesAtPlace`, `testLeavingPlaceStillWakesFast` (fix 80 m outside the shape with hAcc 10 → wake), `testCandidateIsNotAPlace`. RED → GREEN; CI build; commit.

### Task 4b: Still points need confirmed presence (engine)

**Files:** Modify `Core/Sources/Core/MotionEngine.swift`, `LifePath/Recorder/Recorder.swift`; Test `MotionEngineTests.swift`
- The engine tracks `lastConfirmed: Date` while Still: set on entering Still and whenever a location reading arrives that is consistent with the rest area (`.wakeFix` inside the fence/shape allowing accuracy, or a new event `.confirmFix(Sample)` the Recorder sends for keep-alive readings).
- `stillPointIfDue` writes only when `now − lastConfirmed ≤ 1800 s`. Otherwise it records `unconfirmedSince` and writes nothing.
- On the next confirming reading after an unconfirmed stretch, emit `.resolveDeparture(stillSince: unconfirmedSince)`-like command `.fillUnconfirmed(from:to:)`; the Recorder checks CoreMotion history (no step burst ≥ 15 steps/60 s, no confident moving activity) over that stretch and, only if clean, backfills still points every 5 min; otherwise leaves the gap and logs `gap unconfirmed`.
- A reading clearly outside the rest area still wakes as before.
- [ ] Failing tests: `testNoConfirmationStopsStillPoints` (Still, ticks without readings for 45 min → no still point after 30 min), `testConfirmationAfterGapRequestsFill`, `testReadingElsewhereAfterGapWakes`, `testAirplaneModeNightIsNotAssumed` (no readings 8 h, then a reading at the same place → `.fillUnconfirmed` emitted; Recorder fills only when motion history is clean). RED → GREEN; commit.

### Task 5: Places on the map

**Files:** Modify `LifePath/Map/MapScreen.swift`, `TrackMapView.swift`; Create `LifePath/Places/PlaceSheet.swift`
- Pins (annotations) for non-candidate places in the visible region at every zoom (life-long: all places, sized by total time: small < 10 h, medium < 100 h, large ≥ 100 h), label = name or "Place near 52.3731, 4.8926".
- At street zoom, the place region drawn as a soft filled outline (the cells merged into one polygon per connected component, or drawn as an MKMultiPolygon of cell squares — pick the smaller code; say which).
- Tapping a pin opens a sheet: name (editable, saves via renamePlace), total time, visits, first and last visit dates.
- Reload on `placesChanged`. Accessibility labels on pins and sheet.
- [ ] CI build green; commit.

### Task 6: Review and release

- [ ] Whole-branch review against the Principles and Review Focus; one fix wave; release `v0.3.0-preview.1`.
